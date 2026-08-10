import { beforeEach, describe, expect, test } from "bun:test";
import { checkVerification, startVerification } from "./auth";
import {
  ChatFolderError,
  createChatFolder,
  getChatFolders,
  updateChatFolder,
} from "./chat-folders";
import { makeSql } from "./db";
import { isPublicAddress, validatePublicURL } from "./safe-http-client";
import { parseLinkPreviewMetadata } from "./link-previews";
import {
  cancelScheduledDelivery,
  createScheduledDelivery,
  drainScheduledDeliveries,
  failScheduledDeliveriesForRevokedDialogInTransaction,
  listScheduledDeliveries,
} from "./scheduled-deliveries";
import { editMessage, getDifference, getOrCreateDirectDialog, sendMessage } from "./sync";

// Worker behavior is exercised deterministically through drain functions below. Background loops
// from HTTP-route tests would otherwise race assertions against the shared integration database.
process.env.TOJ_PRODUCTIVITY_WORKERS_DISABLED = "1";

const TEST_URL = process.env.TEST_DATABASE_URL ?? "postgres://localhost:5432/toj_test";
const db = makeSql(TEST_URL);

async function resetDb() {
  await db`TRUNCATE accounts, otp_challenges RESTART IDENTITY CASCADE`;
}

async function account(phone: string, name: string) {
  const { code } = await startVerification(db, phone);
  return await checkVerification(db, phone, code, "ios", `${name} iPhone`, name);
}

async function directPair() {
  const alice = await account("+16505554101", "Alice");
  const bob = await account("+16505554102", "Bob");
  const dialog = await getOrCreateDirectDialog(
    db, alice.accountId, bob.accountId, alice.deviceId,
  );
  return { alice, bob, dialogId: dialog.dialogId };
}

describe("cloud productivity features", () => {
  beforeEach(resetDb);

  test("chat folders are encrypted, idempotent, revision checked, and sync as snapshots", async () => {
    const { alice, dialogId } = await directPair();
    const before = Number((await db`
      SELECT pts FROM account_sync_states WHERE account_id = ${alice.accountId}`)[0].pts);
    const folderId = crypto.randomUUID();
    const mutationId = crypto.randomUUID();
    const body = {
      folderId,
      clientMutationId: mutationId,
      title: "Family",
      icon: "family",
      includeDirect: true,
      includeGroups: false,
      includeSaved: false,
      excludeRead: false,
      excludeMuted: false,
      excludeArchived: true,
      rules: [{ dialogId, rule: "include" }],
    };
    const created = await createChatFolder(db, {
      accountId: alice.accountId, deviceId: alice.deviceId, body,
    });
    const duplicate = await createChatFolder(db, {
      accountId: alice.accountId, deviceId: alice.deviceId, body,
    });
    expect(created.folders[0].title).toBe("Family");
    expect(duplicate.duplicate).toBe(true);
    const stored = (await db`
      SELECT title_ciphertext FROM chat_folders
      WHERE account_id = ${alice.accountId} AND folder_id = ${folderId}`)[0];
    expect(Buffer.from(stored.title_ciphertext).includes(Buffer.from("Family"))).toBe(false);

    await expect(updateChatFolder(db, {
      accountId: alice.accountId,
      deviceId: alice.deviceId,
      folderId,
      body: { ...body, clientMutationId: crypto.randomUUID(), expectedRevision: 999 },
    })).rejects.toBeInstanceOf(ChatFolderError);

    const difference = await getDifference(db, alice.accountId, before, {
      chatFoldersEnabled: true,
    });
    if (difference.kind === "difference_too_long") throw new Error("unexpected rebuild");
    expect(difference.updates.at(-1).chat_folders.folders[0].title).toBe("Family");
    expect((await getChatFolders(db, alice.accountId)).collectionRevision).toBe(1);
  });

  test("server dispatch survives client disappearance and is exactly once across worker retries", async () => {
    const { alice, bob, dialogId } = await directPair();
    const scheduleId = crypto.randomUUID();
    const created = await createScheduledDelivery(db, {
      accountId: alice.accountId,
      deviceId: alice.deviceId,
      body: {
        scheduleId,
        clientMutationId: crypto.randomUUID(),
        dialogId,
        deliverAt: new Date(Date.now() + 61_000).toISOString(),
        items: [{ clientMsgId: crypto.randomUUID(), kind: "text", body: "from server" }],
      },
    });
    expect(created.scheduledDelivery.state).toBe("scheduled");
    // No client process participates after creation. Move the test clock by making the row due.
    await db`
      UPDATE scheduled_deliveries SET deliver_at = now(), available_at = now()
      WHERE id = ${scheduleId}`;
    expect(await drainScheduledDeliveries(db)).toBe(1);
    expect(await drainScheduledDeliveries(db)).toBe(0);
    const count = Number((await db`
      SELECT count(*) AS count FROM messages
      WHERE dialog_id = ${dialogId} AND body_ciphertext IS NOT NULL`)[0].count);
    expect(count).toBe(1);
    const state = (await listScheduledDeliveries(db, alice.accountId)).deliveries[0];
    expect(state.state).toBe("delivered");
    expect(state.items).toEqual([]);
    const bobState = Number((await db`
      SELECT pts FROM account_sync_states WHERE account_id = ${bob.accountId}`)[0].pts);
    expect(bobState).toBeGreaterThan(0);
  });

  test("cancel is final before a worker claim and cannot produce a message", async () => {
    const { alice, dialogId } = await directPair();
    const scheduleId = crypto.randomUUID();
    const created = await createScheduledDelivery(db, {
      accountId: alice.accountId,
      deviceId: alice.deviceId,
      body: {
        scheduleId,
        clientMutationId: crypto.randomUUID(),
        dialogId,
        deliverAt: new Date(Date.now() + 61_000).toISOString(),
        items: [{ clientMsgId: crypto.randomUUID(), kind: "text", body: "cancel me" }],
      },
    });
    await cancelScheduledDelivery(db, {
      accountId: alice.accountId,
      deviceId: alice.deviceId,
      deliveryId: scheduleId,
      body: {
        clientMutationId: crypto.randomUUID(),
        expectedRevision: created.scheduledDelivery.revision,
      },
    });
    await db`
      UPDATE scheduled_deliveries SET deliver_at = now(), available_at = now()
      WHERE id = ${scheduleId}`;
    expect(await drainScheduledDeliveries(db)).toBe(0);
    expect(Number((await db`
      SELECT count(*) AS count FROM messages WHERE dialog_id = ${dialogId}`)[0].count)).toBe(0);
  });

  test("dialog revocation immediately fails schedules and erases encrypted payloads", async () => {
    const { alice, dialogId } = await directPair();
    const scheduleId = crypto.randomUUID();
    await createScheduledDelivery(db, {
      accountId: alice.accountId,
      deviceId: alice.deviceId,
      body: {
        scheduleId,
        clientMutationId: crypto.randomUUID(),
        dialogId,
        deliverAt: new Date(Date.now() + 61_000).toISOString(),
        items: [{ clientMsgId: crypto.randomUUID(), kind: "text", body: "erase me" }],
      },
    });
    await db.begin(async (tx) => {
      await failScheduledDeliveriesForRevokedDialogInTransaction(
        tx, alice.accountId, dialogId,
      );
    });
    expect((await db`
      SELECT state, last_error_code FROM scheduled_deliveries WHERE id = ${scheduleId}`)[0])
      .toMatchObject({ state: "failed", last_error_code: "access_revoked" });
    expect((await db`
      SELECT payload_key_id, payload_nonce, payload_ciphertext, media_id
      FROM scheduled_delivery_items WHERE delivery_id = ${scheduleId}`)[0])
      .toEqual(expect.objectContaining({
        payload_key_id: null, payload_nonce: null, payload_ciphertext: null, media_id: null,
      }));
  });

  test("an expired post-send lease replays through message idempotency without duplication", async () => {
    const { alice, dialogId } = await directPair();
    const scheduleId = crypto.randomUUID();
    const clientMsgId = crypto.randomUUID();
    await createScheduledDelivery(db, {
      accountId: alice.accountId,
      deviceId: alice.deviceId,
      body: {
        scheduleId,
        clientMutationId: crypto.randomUUID(),
        dialogId,
        deliverAt: new Date(Date.now() + 61_000).toISOString(),
        items: [{ clientMsgId, kind: "text", body: "once" }],
      },
    });
    await sendMessage(db, {
      senderAccountId: alice.accountId,
      senderDeviceId: null,
      dialogId,
      clientMsgId,
      body: "once",
      scheduledDeliveryId: scheduleId,
    });
    await db`
      UPDATE scheduled_deliveries SET state = 'processing', deliver_at = now(),
        available_at = now(), claimed_at = now() - interval '2 seconds',
        lease_token = gen_random_uuid(),
        lease_expires_at = now() - interval '1 second'
      WHERE id = ${scheduleId}`;
    expect(await drainScheduledDeliveries(db)).toBe(1);
    expect(Number((await db`
      SELECT count(*) AS count FROM messages WHERE dialog_id = ${dialogId}`)[0].count)).toBe(1);
    expect((await listScheduledDeliveries(db, alice.accountId)).deliveries[0].state).toBe("delivered");
  });

  test("preview fetch policy rejects private, loopback, mapped, credentialed, and nonstandard targets", () => {
    for (const address of ["127.0.0.1", "::1", "10.0.0.1", "169.254.169.254", "::ffff:127.0.0.1"]) {
      expect(isPublicAddress(address)).toBe(false);
    }
    expect(() => validatePublicURL("http://127.0.0.1/private")).toThrow();
    expect(() => validatePublicURL("https://user:pass@example.com/")).toThrow();
    expect(() => validatePublicURL("https://example.com:8443/")).toThrow();
    expect(validatePublicURL("https://example.com/path").hostname).toBe("example.com");
  });

  test("metadata parsing prefers Open Graph, sanitizes hostile controls, and honors nosnippet", () => {
    const parsed = parseLinkPreviewMetadata(`
      <html><head>
        <title>Fallback title</title>
        <meta property="og:title" content="Open &amp; Graph\u202e">
        <meta property="og:description" content="  Useful   summary  ">
        <meta property="og:site_name" content="Example">
        <meta property="og:image" content="/card.jpg">
      </head></html>
    `, new URL("https://example.com/article"));
    expect(parsed).toEqual({
      title: "Open & Graph",
      description: "Useful summary",
      siteName: "Example",
      imageURL: "https://example.com/card.jpg",
    });
    expect(() => parseLinkPreviewMetadata(
      '<meta name="robots" content="noindex,nosnippet"><title>Private</title>',
      new URL("https://example.com/"),
    )).toThrow("origin disabled snippets");
  });

  test("editing away a pending URL removes its waiter so stale metadata cannot attach", async () => {
    const { alice, dialogId } = await directPair();
    const url = `https://example.com/story/${crypto.randomUUID()}`;
    const body = `Read ${url}`;
    const sent = await sendMessage(db, {
      senderAccountId: alice.accountId,
      senderDeviceId: alice.deviceId,
      dialogId,
      clientMsgId: crypto.randomUUID(),
      body,
      linkPreviewsEnabled: true,
      linkPreviewCandidate: {
        url,
        utf16Offset: 5,
        utf16Length: url.length,
        disabled: false,
      },
    });
    expect(Number((await db`
      SELECT count(*) AS count FROM link_preview_waiters
      WHERE dialog_id = ${dialogId} AND msg_id = ${sent.msgId}`)[0].count)).toBe(1);
    await editMessage(db, {
      actorAccountId: alice.accountId,
      actorDeviceId: alice.deviceId,
      dialogId,
      msgId: sent.msgId,
      clientMutationId: crypto.randomUUID(),
      body: "No link now",
      expectedEditVersion: 0,
      linkPreviewsEnabled: true,
      linkPreviewCandidate: null,
    });
    expect(Number((await db`
      SELECT count(*) AS count FROM link_preview_waiters
      WHERE dialog_id = ${dialogId} AND msg_id = ${sent.msgId}`)[0].count)).toBe(0);
    expect(Number((await db`
      SELECT count(*) AS count FROM message_link_previews
      WHERE dialog_id = ${dialogId} AND msg_id = ${sent.msgId}`)[0].count)).toBe(0);
  });
});
