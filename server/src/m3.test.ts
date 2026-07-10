import { beforeEach, describe, expect, test } from "bun:test";
import { makeSql } from "./db";
import { startVerification, checkVerification, lookupAccountByPhone } from "./auth";
import {
  getBootstrapDialogsPage,
  getDifference,
  getHistory,
  getOrCreateDirectDialog,
  readHistory,
  sendMessage,
  startBootstrap,
} from "./sync";

const TEST_URL = process.env.TEST_DATABASE_URL ?? "postgres://localhost:5432/toj_test";
const db = makeSql(TEST_URL);

async function resetDb() {
  await db`
    TRUNCATE
      user_reports,
      content_access_audit,
      bootstrap_snapshot_dialogs,
      bootstrap_snapshots,
      send_requests,
      account_events,
      messages,
      dialog_members,
      direct_dialog_pairs,
      dialogs,
      devices,
      account_sync_states,
      accounts,
      otp_challenges
    RESTART IDENTITY CASCADE`;
}

async function makeAccount(phone: string, name: string) {
  const { code } = await startVerification(db, phone);
  return await checkVerification(db, phone, code, "ios", "Test iPhone", name);
}

async function makePair() {
  const alice = await makeAccount("+16505550100", "Alice");
  const bob = await makeAccount("+16505550101", "Bob");
  const direct = await getOrCreateDirectDialog(db, alice.accountId, bob.accountId);
  return { alice, bob, dialogId: direct.dialogId };
}

describe("M3 cloud sync", () => {
  beforeEach(resetDb);

  test("phone OTP creates an account, device, and sync state", async () => {
    const alice = await makeAccount("+16505550110", "Alice");
    expect(alice.accountId).toBeString();
    expect(alice.deviceId).toBeString();
    expect(alice.token.length).toBeGreaterThan(20);

    const state = (await db`SELECT pts, pruned_through_pts FROM account_sync_states WHERE account_id = ${alice.accountId}`)[0];
    expect(Number(state.pts)).toBe(0);
    expect(Number(state.pruned_through_pts)).toBe(0);
  });

  test("send retries are idempotent and do not burn message ids", async () => {
    const { alice, dialogId } = await makePair();
    const clientMsgId = crypto.randomUUID();

    const first = await sendMessage(db, {
      senderAccountId: alice.accountId,
      senderDeviceId: alice.deviceId,
      dialogId,
      clientMsgId,
      body: "retry once",
    });
    const second = await sendMessage(db, {
      senderAccountId: alice.accountId,
      senderDeviceId: alice.deviceId,
      dialogId,
      clientMsgId,
      body: "retry once",
    });

    expect(first.duplicate).toBe(false);
    expect(second.duplicate).toBe(true);
    expect(second.msgId).toBe(first.msgId);
    expect(second.senderPts).toBe(first.senderPts);
    expect(second.text).toBe("retry once");

    const counts = (await db`
      SELECT d.last_msg_id, count(m.*)::int AS message_count
      FROM dialogs d
      LEFT JOIN messages m ON m.dialog_id = d.id
      WHERE d.id = ${dialogId}
      GROUP BY d.last_msg_id`)[0];
    expect(Number(counts.last_msg_id)).toBe(1);
    expect(Number(counts.message_count)).toBe(1);
  });

  test("get_difference catches up in pts order and respects byte slicing", async () => {
    const { alice, bob, dialogId } = await makePair();
    for (let i = 0; i < 4; i++) {
      await sendMessage(db, {
        senderAccountId: alice.accountId,
        senderDeviceId: alice.deviceId,
        dialogId,
        clientMsgId: crypto.randomUUID(),
        body: `message ${i} ${"x".repeat(600)}`,
      });
    }

    const firstSlice = await getDifference(db, bob.accountId, 1, { maxEvents: 20, maxBytes: 900 });
    expect(firstSlice.kind).toBe("difference_slice");
    expect(firstSlice.updates.length).toBeGreaterThanOrEqual(1);

    const rest = await getDifference(db, bob.accountId, firstSlice.state.pts, { maxEvents: 20, maxBytes: 4096 });
    expect(rest.kind).toBe("difference");
    expect(rest.state.pts).toBeGreaterThan(firstSlice.state.pts);
    expect(firstSlice.updates[0].pts).toBeLessThan(rest.updates.at(-1).pts);
  });

  test("pruned event floor returns difference_too_long instead of a fake partial catch-up", async () => {
    const { alice, bob, dialogId } = await makePair();
    await sendMessage(db, {
      senderAccountId: alice.accountId,
      senderDeviceId: alice.deviceId,
      dialogId,
      clientMsgId: crypto.randomUUID(),
      body: "old event",
    });
    await db`UPDATE account_sync_states SET pruned_through_pts = 2 WHERE account_id = ${bob.accountId}`;

    const diff = await getDifference(db, bob.accountId, 1);
    expect(diff.kind).toBe("difference_too_long");
  });

  test("bootstrap snapshot does not duplicate or swallow messages sent during onboarding", async () => {
    const { alice, bob, dialogId } = await makePair();
    const aliceCreation = await getDifference(db, alice.accountId, 0);
    const bobCreation = await getDifference(db, bob.accountId, 0);
    expect(aliceCreation.updates.find((u) => u.type === "dialog.created")?.dialog_title).toBe("Bob");
    expect(bobCreation.updates.find((u) => u.type === "dialog.created")?.dialog_title).toBe("Alice");
    await sendMessage(db, {
      senderAccountId: alice.accountId,
      senderDeviceId: alice.deviceId,
      dialogId,
      clientMsgId: crypto.randomUUID(),
      body: "before snapshot",
    });

    const bootstrap = await startBootstrap(db, bob.accountId);

    await sendMessage(db, {
      senderAccountId: alice.accountId,
      senderDeviceId: alice.deviceId,
      dialogId,
      clientMsgId: crypto.randomUUID(),
      body: "after snapshot",
    });

    const page = await getBootstrapDialogsPage(db, bob.accountId, bootstrap.token, { previewMessages: 10 });
    expect(page.state.pts).toBe(bootstrap.state.pts);
    expect(page.dialogs).toHaveLength(1);
    expect(page.dialogs[0].title).toBe("Alice");
    expect(page.dialogs[0].messages.map((m) => m.text)).toEqual(["before snapshot"]);

    const diff = await getDifference(db, bob.accountId, bootstrap.state.pts);
    expect(diff.kind).toBe("difference");
    expect(diff.updates.map((u) => u.message?.text).filter(Boolean)).toEqual(["after snapshot"]);
  });

  test("history pages load locally decryptable message bodies", async () => {
    const { alice, bob, dialogId } = await makePair();
    await sendMessage(db, {
      senderAccountId: alice.accountId,
      senderDeviceId: alice.deviceId,
      dialogId,
      clientMsgId: crypto.randomUUID(),
      body: "one",
    });
    await sendMessage(db, {
      senderAccountId: bob.accountId,
      senderDeviceId: bob.deviceId,
      dialogId,
      clientMsgId: crypto.randomUUID(),
      body: "two",
    });

    const page = await getHistory(db, alice.accountId, dialogId, { limit: 50 });
    expect(page.messages.map((m) => m.text)).toEqual(["one", "two"]);
  });

  test("read receipts advance member state and emit sync updates", async () => {
    const { alice, bob, dialogId } = await makePair();
    const sent = await sendMessage(db, {
      senderAccountId: alice.accountId,
      senderDeviceId: alice.deviceId,
      dialogId,
      clientMsgId: crypto.randomUUID(),
      body: "read me",
    });

    const read = await readHistory(db, { accountId: bob.accountId, dialogId, maxReadMsgId: sent.msgId });
    expect(read.maxReadMsgId).toBe(sent.msgId);

    const diff = await getDifference(db, alice.accountId, sent.senderPts);
    expect(diff.kind).toBe("difference");
    expect(diff.updates.some((u) => u.type === "read.updated" && u.max_read_msg_id === sent.msgId)).toBe(true);

    const repeat = await readHistory(db, { accountId: bob.accountId, dialogId, maxReadMsgId: sent.msgId });
    expect(repeat.pushes).toHaveLength(0);
    const afterRepeat = await getDifference(db, alice.accountId, diff.state.pts);
    expect(afterRepeat.kind).toBe("difference");
    expect(afterRepeat.updates).toEqual([]);
  });

  test("message plaintext is not stored on disk", async () => {
    const { alice, dialogId } = await makePair();
    const body = "plaintext must not appear here";
    await sendMessage(db, {
      senderAccountId: alice.accountId,
      senderDeviceId: alice.deviceId,
      dialogId,
      clientMsgId: crypto.randomUUID(),
      body,
    });

    const row = (await db`SELECT encode(body_ciphertext, 'escape') AS ciphertext FROM messages LIMIT 1`)[0];
    expect(String(row.ciphertext)).not.toContain(body);
  });

  test("concurrent sends with the same client_msg_id collapse to one message (B2 race)", async () => {
    const { alice, dialogId } = await makePair();
    const params = {
      senderAccountId: alice.accountId, senderDeviceId: alice.deviceId,
      dialogId, clientMsgId: crypto.randomUUID(), body: "race",
    };
    const [a, b] = await Promise.all([sendMessage(db, params), sendMessage(db, params)]);
    expect(a.msgId).toBe(b.msgId);
    expect(a.senderPts).toBe(b.senderPts);
    expect([a.duplicate, b.duplicate].sort()).toEqual([false, true]);
    const count = (await db`SELECT count(*)::int AS c FROM messages WHERE dialog_id = ${dialogId}`)[0];
    expect(Number(count.c)).toBe(1);
  });

  test("contact lookup resolves a phone to an account and null for unknown", async () => {
    const { code } = await startVerification(db, "+16505550140");
    const session = await checkVerification(db, "+16505550140", code, "ios", "iPhone", "Muhammad");
    const found = await lookupAccountByPhone(db, "+16505550140");
    expect(found?.accountId).toBe(session.accountId);
    expect(found?.displayName).toBe("Muhammad");
    expect(await lookupAccountByPhone(db, "+16505559999")).toBeNull();
  });
});
