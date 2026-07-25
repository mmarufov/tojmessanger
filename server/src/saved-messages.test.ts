import { beforeEach, describe, expect, test } from "bun:test";
import { createHash } from "node:crypto";
import {
  checkVerification,
  deleteAccount,
  startAccountDeletion,
  startVerification,
} from "./auth";
import { startCloudServer } from "./cloud";
import { makeSql } from "./db";
import { createGroup } from "./groups";
import {
  completeMediaUpload,
  createMediaUpload,
  downloadMediaChunk,
  uploadMediaChunk,
} from "./media";
import {
  claimSavedMessagesBackfillAccounts,
  completeSavedMessagesBackfillClaim,
  ensureSavedMessages,
  refreshSavedMessagesBackfillClaim,
  requireSavedMessagesBackfillAuthorization,
  savedMessagesBackfillThrottleMs,
  savedMessagesEnabledForAccount,
  SavedMessagesError,
} from "./saved-messages";
import {
  getBootstrapDialogsPage,
  getDifference,
  getHistory,
  getOrCreateDirectDialog,
  sendMessage,
  startBootstrap,
} from "./sync";

const TEST_URL = process.env.TEST_DATABASE_URL ?? "postgres://localhost:5432/toj_test";
const db = makeSql(TEST_URL);

async function resetDb() {
  await db`TRUNCATE accounts, otp_challenges RESTART IDENTITY CASCADE`;
}

async function account(phone: string, name: string) {
  const { code } = await startVerification(db, phone);
  return checkVerification(db, phone, code, "ios", `${name} iPhone`, name);
}

describe("Saved Messages v1", () => {
  beforeEach(resetDb);

  test("provisions one self-only dialog and retries without consuming PTS", async () => {
    const owner = await account("+16505554100", "Owner");
    const first = await ensureSavedMessages(db, owner.accountId, owner.deviceId);
    const ptsAfterFirst = Number((await db`
      SELECT pts FROM account_sync_states WHERE account_id = ${owner.accountId}`)[0].pts);
    const retry = await ensureSavedMessages(db, owner.accountId, owner.deviceId);
    const ptsAfterRetry = Number((await db`
      SELECT pts FROM account_sync_states WHERE account_id = ${owner.accountId}`)[0].pts);

    expect(first).toMatchObject({ type: "saved", created: true, repaired: false });
    expect(retry).toMatchObject({
      dialogId: first.dialogId,
      type: "saved",
      created: false,
      repaired: false,
      pushes: [],
    });
    expect(ptsAfterFirst).toBe(1);
    expect(ptsAfterRetry).toBe(ptsAfterFirst);

    const dialog = (await db`
      SELECT type, title, created_by FROM dialogs WHERE id = ${first.dialogId}`)[0];
    expect(dialog).toMatchObject({
      type: "saved",
      title: null,
      created_by: owner.accountId,
    });
    const members = await db`
      SELECT account_id, role, notification_mode, left_at
      FROM dialog_members WHERE dialog_id = ${first.dialogId}`;
    expect(members).toEqual([expect.objectContaining({
      account_id: owner.accountId,
      role: "owner",
      notification_mode: "all",
      left_at: null,
    })]);
  });

  test("25 concurrent ensures converge on one dialog, membership, and event", async () => {
    const owner = await account("+16505554101", "Owner");
    const results = await Promise.all(Array.from({ length: 25 }, () =>
      ensureSavedMessages(db, owner.accountId, owner.deviceId)));
    expect(new Set(results.map((result) => result.dialogId)).size).toBe(1);
    expect(results.filter((result) => result.created)).toHaveLength(1);
    expect(Number((await db`
      SELECT count(*) AS count FROM dialogs
      WHERE type = 'saved' AND created_by = ${owner.accountId}`)[0].count)).toBe(1);
    expect(Number((await db`
      SELECT count(*) AS count FROM dialog_members
      WHERE dialog_id = ${results[0].dialogId} AND left_at IS NULL`)[0].count)).toBe(1);
    expect(Number((await db`
      SELECT count(*) AS count FROM account_events
      WHERE account_id = ${owner.accountId} AND type = 'dialog.created'
        AND dialog_id = ${results[0].dialogId}`)[0].count)).toBe(1);
  });

  test("backfill fails closed unless production, global enablement, 100 percent, and confirmation agree", () => {
    const authorized = {
      NODE_ENV: "production",
      TOJ_SAVED_MESSAGES_V1_ENABLED: "1",
      TOJ_SAVED_MESSAGES_ROLLOUT_PERCENT: "100",
      TOJ_SAVED_MESSAGES_BACKFILL_CONFIRM: "PROVISION_ALL_ACTIVE_ACCOUNTS",
    };
    expect(() => requireSavedMessagesBackfillAuthorization({
      ...authorized,
      TOJ_SAVED_MESSAGES_V1_ENABLED: "0",
    })).toThrow("global feature switch");
    expect(() => requireSavedMessagesBackfillAuthorization({
      ...authorized,
      TOJ_SAVED_MESSAGES_ROLLOUT_PERCENT: "99",
    })).toThrow("100 percent rollout");
    expect(() => requireSavedMessagesBackfillAuthorization({
      ...authorized,
      TOJ_SAVED_MESSAGES_BACKFILL_CONFIRM: "yes",
    })).toThrow("confirmation missing");
    expect(() => requireSavedMessagesBackfillAuthorization({
      ...authorized,
      NODE_ENV: "development",
    })).toThrow("NODE_ENV=production");
    expect(() => requireSavedMessagesBackfillAuthorization(authorized)).not.toThrow();
    expect(savedMessagesBackfillThrottleMs("250")).toBe(250);
    expect(savedMessagesBackfillThrottleMs("-1")).toBe(0);
    expect(savedMessagesBackfillThrottleMs("999999")).toBe(60_000);
  });

  test("durable claims divide accounts between concurrent workers without overlap", async () => {
    for (let index = 0; index < 8; index += 1) {
      await account(`+165055542${String(index).padStart(2, "0")}`, `Claim ${index}`);
    }
    const workerA = crypto.randomUUID();
    const workerB = crypto.randomUUID();
    const [claimsA, claimsB] = await Promise.all([
      claimSavedMessagesBackfillAccounts(db, workerA, 5),
      claimSavedMessagesBackfillAccounts(db, workerB, 5),
    ]);
    const workerC = crypto.randomUUID();
    const remainingClaims = await claimSavedMessagesBackfillAccounts(db, workerC, 8);
    const accountIdsA = new Set(claimsA.map((claim) => claim.accountId));
    const accountIdsB = new Set(claimsB.map((claim) => claim.accountId));
    const accountIdsC = new Set(remainingClaims.map((claim) => claim.accountId));
    expect([...accountIdsA].filter((accountId) => accountIdsB.has(accountId))).toHaveLength(0);
    expect([...accountIdsA].filter((accountId) => accountIdsC.has(accountId))).toHaveLength(0);
    expect([...accountIdsB].filter((accountId) => accountIdsC.has(accountId))).toHaveLength(0);
    expect(accountIdsA.size + accountIdsB.size + accountIdsC.size).toBe(8);
    const firstClaim = [...claimsA, ...claimsB, ...remainingClaims][0];
    expect(await refreshSavedMessagesBackfillClaim(db, {
      ...firstClaim,
      workerId: crypto.randomUUID(),
    })).toBe(false);
    expect(await refreshSavedMessagesBackfillClaim(db, firstClaim)).toBe(true);
    expect(Number((await db`
      SELECT count(*) AS count FROM saved_messages_backfill_claims
      WHERE completed_at IS NULL`)[0].count)).toBe(8);
  });

  test("a claimed account deleted before provisioning is durably completed as unavailable", async () => {
    const owner = await account("+16505554220", "Deleted claim");
    const workerId = crypto.randomUUID();
    const claims = await claimSavedMessagesBackfillAccounts(db, workerId, 1);
    expect(claims).toEqual([{ accountId: owner.accountId, workerId }]);
    await db`UPDATE accounts SET status = 'deleted' WHERE id = ${owner.accountId}`;
    let unavailable: SavedMessagesError | null = null;
    try {
      await ensureSavedMessages(db, owner.accountId);
    } catch (error) {
      if (error instanceof SavedMessagesError) unavailable = error;
      else throw error;
    }
    expect(unavailable?.code).toBe("account_unavailable");
    expect(await completeSavedMessagesBackfillClaim(
      db,
      claims[0],
      "account_unavailable",
    )).toBe(true);
    expect((await db`
      SELECT completed_at, last_error
      FROM saved_messages_backfill_claims
      WHERE account_id = ${owner.accountId}`)[0]).toMatchObject({
      last_error: "account_unavailable",
    });
  });

  test("repairs damaged membership once and removes non-owner access", async () => {
    const owner = await account("+16505554102", "Owner");
    const outsider = await account("+16505554103", "Outsider");
    const saved = await ensureSavedMessages(db, owner.accountId, owner.deviceId);
    await db`
      UPDATE dialog_members SET role = 'member', notification_mode = 'muted', left_at = now()
      WHERE dialog_id = ${saved.dialogId} AND account_id = ${owner.accountId}`;
    await db`
      UPDATE dialogs SET title = 'damaged', closed_at = now()
      WHERE id = ${saved.dialogId}`;
    await db`
      INSERT INTO dialog_members (dialog_id, account_id, role)
      VALUES (${saved.dialogId}, ${outsider.accountId}, 'member')`;

    const repaired = await ensureSavedMessages(db, owner.accountId, owner.deviceId);
    expect(repaired).toMatchObject({ dialogId: saved.dialogId, created: false, repaired: true });
    const members = await db`
      SELECT account_id, role, notification_mode, left_at
      FROM dialog_members WHERE dialog_id = ${saved.dialogId}`;
    expect(members).toEqual([expect.objectContaining({
      account_id: owner.accountId,
      role: "owner",
      notification_mode: "all",
      left_at: null,
    })]);
    expect((await db`
      SELECT title, closed_at FROM dialogs WHERE id = ${saved.dialogId}`)[0]).toMatchObject({
      title: null,
      closed_at: null,
    });
  });

  test("reuses ordinary send, difference, history, and bootstrap pipelines", async () => {
    const owner = await account("+16505554104", "Owner");
    const saved = await ensureSavedMessages(db, owner.accountId, owner.deviceId);
    const beforeSend = Number((await db`
      SELECT pts FROM account_sync_states WHERE account_id = ${owner.accountId}`)[0].pts);
    const sent = await sendMessage(db, {
      senderAccountId: owner.accountId,
      senderDeviceId: owner.deviceId,
      dialogId: saved.dialogId,
      clientMsgId: crypto.randomUUID(),
      body: "Remember the charger",
    });
    expect(sent.duplicate).toBe(false);

    const difference = await getDifference(db, owner.accountId, beforeSend);
    if (difference.kind === "difference_too_long") throw new Error("unexpected rebuild");
    expect(difference.updates).toHaveLength(1);
    expect(difference.updates[0]).toMatchObject({
      type: "message.new",
      dialog_id: saved.dialogId,
      dialog_type: "saved",
      dialog_title: "Saved Messages",
    });
    expect(difference.updates[0].peer_account_id).toBeUndefined();
    expect(difference.updates[0].message.text).toBe("Remember the charger");

    const history = await getHistory(db, owner.accountId, saved.dialogId);
    expect(history.messages.map((message) => message.text)).toEqual(["Remember the charger"]);

    const bootstrap = await startBootstrap(db, owner.accountId);
    const page = await getBootstrapDialogsPage(db, owner.accountId, bootstrap.token);
    expect(page.dialogs).toHaveLength(1);
    expect(page.dialogs[0]).toMatchObject({
      dialog_id: saved.dialogId,
      type: "saved",
      title: "Saved Messages",
      unread_count: 0,
      member_count: 1,
      self_role: "owner",
    });
  });

  test("a second device receives Saved creation and messages through ordered account PTS", async () => {
    const phone = "+16505554112";
    const firstDevice = await account(phone, "Owner");
    const secondDeviceId = String((await db`
      INSERT INTO devices (account_id, platform, device_name, auth_token_hash, last_seen_at)
      VALUES (
        ${firstDevice.accountId},
        'ios',
        'Owner iPad',
        ${createHash("sha256").update(crypto.randomUUID()).digest()},
        now()
      )
      RETURNING id`)[0].id);
    const saved = await ensureSavedMessages(
      db,
      firstDevice.accountId,
      firstDevice.deviceId,
    );
    await sendMessage(db, {
      senderAccountId: firstDevice.accountId,
      senderDeviceId: secondDeviceId,
      dialogId: saved.dialogId,
      clientMsgId: crypto.randomUUID(),
      body: "Written on the second device",
    });

    const difference = await getDifference(db, firstDevice.accountId, 0);
    if (difference.kind === "difference_too_long") throw new Error("unexpected rebuild");
    expect(difference.updates.map((update) => update.type)).toEqual([
      "dialog.created",
      "message.new",
    ]);
    expect(difference.updates.map((update) => update.pts)).toEqual([1, 2]);
    expect(difference.updates[1]).toMatchObject({
      dialog_id: saved.dialogId,
      dialog_type: "saved",
      message: expect.objectContaining({
        text: "Written on the second device",
        sender_account_id: firstDevice.accountId,
      }),
    });
  });

  test("database rejects ownerless and duplicate Saved Messages dialogs", async () => {
    const owner = await account("+16505554105", "Owner");
    let ownerlessRejected = false;
    try {
      await db`INSERT INTO dialogs (type, created_by) VALUES ('saved', NULL)`;
    } catch {
      ownerlessRejected = true;
    }
    expect(ownerlessRejected).toBe(true);
    await db`INSERT INTO dialogs (type, created_by) VALUES ('saved', ${owner.accountId})`;
    let duplicateRejected = false;
    try {
      await db`INSERT INTO dialogs (type, created_by) VALUES ('saved', ${owner.accountId})`;
    } catch {
      duplicateRejected = true;
    }
    expect(duplicateRejected).toBe(true);
  });

  test("dialog constraint migration uses expand, validate, and a short contract transaction", async () => {
    const schema = await Bun.file(new URL("./schema.sql", import.meta.url)).text();
    const migrate = await Bun.file(new URL("./migrate.ts", import.meta.url)).text();
    const expand = await Bun.file(new URL("./schema-dialogs-expand.sql", import.meta.url)).text();
    const swap = await Bun.file(new URL("./schema-dialogs-swap.sql", import.meta.url)).text();
    expect(schema).not.toContain("DROP CONSTRAINT IF EXISTS dialogs_type_check");
    expect(expand).toContain("dialogs_type_check_saved_expand");
    expect(expand).toContain("NOT VALID");
    expect(migrate).toContain("VALIDATE CONSTRAINT dialogs_type_check_saved_expand");
    expect(swap).toContain("BEGIN;");
    expect(swap).toContain("SET LOCAL lock_timeout = '5s'");
    expect(swap).toContain("RENAME CONSTRAINT dialogs_type_check_saved_expand");
    expect(swap).toContain("COMMIT;");
  });

  test("account deletion removes Saved Messages and its history", async () => {
    const owner = await account("+16505554106", "Owner");
    const saved = await ensureSavedMessages(db, owner.accountId, owner.deviceId);
    await sendMessage(db, {
      senderAccountId: owner.accountId,
      senderDeviceId: owner.deviceId,
      dialogId: saved.dialogId,
      clientMsgId: crypto.randomUUID(),
      body: "Private note",
    });
    const deletion = await startAccountDeletion(db, owner.accountId);
    await deleteAccount(db, owner.accountId, deletion.code!);
    expect(Number((await db`
      SELECT count(*) AS count FROM dialogs WHERE id = ${saved.dialogId}`)[0].count)).toBe(0);
    expect(Number((await db`
      SELECT count(*) AS count FROM messages WHERE dialog_id = ${saved.dialogId}`)[0].count)).toBe(0);
  });

  test("account deletion detaches Saved text provenance and preserves the direct-chat copy", async () => {
    const owner = await account("+16505554108", "Owner");
    const peer = await account("+16505554109", "Peer");
    const saved = await ensureSavedMessages(db, owner.accountId, owner.deviceId);
    const source = await sendMessage(db, {
      senderAccountId: owner.accountId,
      senderDeviceId: owner.deviceId,
      dialogId: saved.dialogId,
      clientMsgId: crypto.randomUUID(),
      body: "Keep the passport scan",
    });
    const direct = await getOrCreateDirectDialog(db, owner.accountId, peer.accountId);
    const copy = await sendMessage(db, {
      senderAccountId: owner.accountId,
      senderDeviceId: owner.deviceId,
      dialogId: direct.dialogId,
      clientMsgId: crypto.randomUUID(),
      forwardedFrom: { dialogId: saved.dialogId, msgId: source.msgId },
    });

    const deletion = await startAccountDeletion(db, owner.accountId);
    await deleteAccount(db, owner.accountId, deletion.code!);

    expect(await db`SELECT id FROM dialogs WHERE id = ${saved.dialogId}`).toHaveLength(0);
    const history = await getHistory(db, peer.accountId, direct.dialogId);
    expect(history.messages.find((message) => message.msg_id === copy.msgId)).toMatchObject({
      text: "Keep the passport scan",
      forwarded: true,
      state: "visible",
    });
    expect((await db`
      SELECT is_forwarded, forwarded_from_account_id, forwarded_from_dialog_id,
             forwarded_from_msg_id
      FROM messages
      WHERE dialog_id = ${direct.dialogId} AND msg_id = ${copy.msgId}`)[0]).toMatchObject({
      is_forwarded: true,
      forwarded_from_account_id: null,
      forwarded_from_dialog_id: null,
      forwarded_from_msg_id: null,
    });
  });

  test("account deletion preserves Saved media forwarded into a group", async () => {
    const owner = await account("+16505554110", "Owner");
    const peer = await account("+16505554111", "Peer");
    const saved = await ensureSavedMessages(db, owner.accountId, owner.deviceId);
    const bytes = Buffer.from("saved media forwarded before account deletion");
    const upload = await createMediaUpload(db, owner.accountId, owner.deviceId, {
      kind: "file",
      contentType: "application/octet-stream",
      fileName: "saved-proof.bin",
      byteSize: bytes.length,
      sha256: createHash("sha256").update(bytes).digest("hex"),
    });
    await uploadMediaChunk(db, owner.accountId, owner.deviceId, upload.mediaId, 0, bytes);
    await completeMediaUpload(db, owner.accountId, owner.deviceId, upload.mediaId);
    const source = await sendMessage(db, {
      senderAccountId: owner.accountId,
      senderDeviceId: owner.deviceId,
      dialogId: saved.dialogId,
      clientMsgId: crypto.randomUUID(),
      body: "",
      mediaId: upload.mediaId,
    });
    const group = await createGroup(db, {
      creatorAccountId: peer.accountId,
      creatorDeviceId: peer.deviceId,
      groupId: crypto.randomUUID(),
      title: "Deletion regression",
      memberIds: [owner.accountId],
    });
    const copy = await sendMessage(db, {
      senderAccountId: owner.accountId,
      senderDeviceId: owner.deviceId,
      dialogId: group.group.id,
      clientMsgId: crypto.randomUUID(),
      forwardedFrom: { dialogId: saved.dialogId, msgId: source.msgId },
    });

    const deletion = await startAccountDeletion(db, owner.accountId);
    await deleteAccount(db, owner.accountId, deletion.code!);

    const history = await getHistory(db, peer.accountId, group.group.id);
    expect(history.messages.find((message) => message.msg_id === copy.msgId)).toMatchObject({
      forwarded: true,
      media: expect.objectContaining({ id: upload.mediaId, kind: "file" }),
    });
    expect((await downloadMediaChunk(db, peer.accountId, upload.mediaId, 0)).bytes).toEqual(bytes);
    expect((await db`
      SELECT is_forwarded, forwarded_from_dialog_id, forwarded_from_msg_id, media_id
      FROM messages
      WHERE dialog_id = ${group.group.id} AND msg_id = ${copy.msgId}`)[0]).toMatchObject({
      is_forwarded: true,
      forwarded_from_dialog_id: null,
      forwarded_from_msg_id: null,
      media_id: upload.mediaId,
    });
  });

  test("rollout flag hard-closes the route and authenticated capability", async () => {
    const owner = await account("+16505554107", "Owner");
    const previousEnabled = process.env.TOJ_SAVED_MESSAGES_V1_ENABLED;
    const previousPercent = process.env.TOJ_SAVED_MESSAGES_ROLLOUT_PERCENT;
    const previousMetricsToken = process.env.TOJ_METRICS_TOKEN;
    try {
      delete process.env.TOJ_SAVED_MESSAGES_V1_ENABLED;
      delete process.env.TOJ_SAVED_MESSAGES_ROLLOUT_PERCENT;
      const disabledServer = startCloudServer(0, db, null);
      try {
        const base = `http://127.0.0.1:${disabledServer.port}`;
        const route = await fetch(`${base}/v1/dialogs/saved`, {
          method: "POST",
          headers: { authorization: `Bearer ${owner.token}` },
        });
        expect(route.status).toBe(404);
        const capabilities = await (await fetch(`${base}/v1/capabilities`, {
          headers: { authorization: `Bearer ${owner.token}` },
        })).json() as { capabilities: string[] };
        expect(capabilities.capabilities).not.toContain("saved_messages_v1");
        expect(Number((await db`
          SELECT count(*) AS count FROM dialogs WHERE type = 'saved'`)[0].count)).toBe(0);
      } finally {
        disabledServer.stop(true);
      }

      process.env.TOJ_SAVED_MESSAGES_V1_ENABLED = "1";
      process.env.TOJ_SAVED_MESSAGES_ROLLOUT_PERCENT = "100";
      process.env.TOJ_METRICS_TOKEN = "saved-messages-metrics-test";
      expect(savedMessagesEnabledForAccount(owner.accountId)).toBe(true);
      const enabledServer = startCloudServer(0, db, null);
      try {
        const base = `http://127.0.0.1:${enabledServer.port}`;
        const capabilities = await (await fetch(`${base}/v1/capabilities`, {
          headers: { authorization: `Bearer ${owner.token}` },
        })).json() as { capabilities: string[] };
        expect(capabilities.capabilities).toContain("saved_messages_v1");
        const response = await fetch(`${base}/v1/dialogs/saved`, {
          method: "POST",
          headers: {
            authorization: `Bearer ${owner.token}`,
            "content-type": "application/json",
          },
          body: "{}",
        });
        expect(response.status).toBe(201);
        const body = await response.json() as { dialogId: string; type: string; created: boolean };
        expect(body).toMatchObject({ type: "saved", created: true });
        const retry = await fetch(`${base}/v1/dialogs/saved`, {
          method: "POST",
          headers: {
            authorization: `Bearer ${owner.token}`,
            "content-type": "application/json",
          },
          body: "{}",
        });
        expect(retry.status).toBe(200);
        expect(await retry.json()).toMatchObject({ dialogId: body.dialogId, created: false });
        const metrics = await (await fetch(`${base}/metrics`, {
          headers: { authorization: "Bearer saved-messages-metrics-test" },
        })).text();
        expect(metrics).toContain('toj_saved_messages_ensure_total{result="created"} 1');
        expect(metrics).toContain('toj_saved_messages_ensure_total{result="existing"} 1');
        expect(metrics).toContain("toj_saved_messages_ensure_duration_seconds_count 2");
        expect(metrics).toContain("toj_saved_messages_invariant_violation_total 0");
      } finally {
        enabledServer.stop(true);
      }
    } finally {
      if (previousEnabled === undefined) delete process.env.TOJ_SAVED_MESSAGES_V1_ENABLED;
      else process.env.TOJ_SAVED_MESSAGES_V1_ENABLED = previousEnabled;
      if (previousPercent === undefined) delete process.env.TOJ_SAVED_MESSAGES_ROLLOUT_PERCENT;
      else process.env.TOJ_SAVED_MESSAGES_ROLLOUT_PERCENT = previousPercent;
      if (previousMetricsToken === undefined) delete process.env.TOJ_METRICS_TOKEN;
      else process.env.TOJ_METRICS_TOKEN = previousMetricsToken;
    }
  });
});
