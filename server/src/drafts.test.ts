import { beforeEach, describe, expect, test } from "bun:test";
import { checkVerification, startVerification } from "./auth";
import { startCloudServer } from "./cloud";
import { makeSql } from "./db";
import { DraftError, getDraft, putDraft } from "./drafts";
import { cancelMediaUpload, downloadMediaChunk } from "./media";
import { cleanupExpiredData } from "./ops";
import {
  getBootstrapDialogsPage,
  getDifference,
  getOrCreateDirectDialog,
  sendMediaGroup,
  sendMessage,
  startBootstrap,
} from "./sync";

const TEST_URL = process.env.TEST_DATABASE_URL ?? "postgres://localhost:5432/toj_test";
const db = makeSql(TEST_URL);

async function resetDb() {
  await db`TRUNCATE accounts, otp_challenges RESTART IDENTITY CASCADE`;
}

async function makeAccount(phone: string, name: string) {
  const { code } = await startVerification(db, phone);
  return await checkVerification(db, phone, code, "ios", `${name}'s iPhone`, name);
}

async function addDevice(accountId: string) {
  const row = (await db`
    INSERT INTO devices (account_id, platform, device_name, auth_token_hash)
    VALUES (${accountId}, 'ios', 'Second iPhone', gen_random_bytes(32))
    RETURNING id`)[0];
  return String(row.id);
}

async function readyMedia(accountId: string, kind: "photo" | "video" | "file" = "photo") {
  const row = (await db`
    INSERT INTO media_objects (
      owner_account_id, kind, content_type, byte_size, expected_sha256, uploaded_bytes,
      status, purpose, completed_at, expires_at
    )
    VALUES (
      ${accountId}, ${kind},
      ${kind === "file" ? "application/pdf" : kind === "video" ? "video/mp4" : "image/jpeg"},
      8, ${Buffer.alloc(32, 7)}, 8, 'ready', 'message', now(), 'infinity'
    )
    RETURNING id`)[0];
  return String(row.id);
}

async function pair() {
  const alice = await makeAccount("+16505557001", "Alice");
  const bob = await makeAccount("+16505557002", "Bob");
  const dialog = await getOrCreateDirectDialog(db, alice.accountId, bob.accountId);
  return { alice, bob, dialogId: dialog.dialogId };
}

describe("cloud drafts and media groups", () => {
  beforeEach(resetDb);

  test("drafts are encrypted, exactly idempotent, private, and included in sync/bootstrap", async () => {
    const { alice, bob, dialogId } = await pair();
    const mediaId = await readyMedia(alice.accountId);
    const operationId = crypto.randomUUID();
    const attachmentId = crypto.randomUUID();
    const first = await putDraft(db, {
      accountId: alice.accountId,
      deviceId: alice.deviceId,
      dialogId,
      operationId,
      state: "active",
      text: "raw  draft \n",
      replyToMsgId: null,
      mentions: [],
      attachments: [{ attachment_id: attachmentId, media_id: mediaId, position: 0 }],
    });
    expect(first.duplicate).toBe(false);
    expect(first.draft.text).toBe("raw  draft \n");
    expect(first.draft.attachments.map((item) => item.media_id)).toEqual([mediaId]);

    const stored = (await db`
      SELECT body_ciphertext, revision FROM account_dialog_drafts
      WHERE account_id = ${alice.accountId} AND dialog_id = ${dialogId}`)[0];
    expect(Buffer.from(stored.body_ciphertext).includes(Buffer.from("raw  draft"))).toBe(false);
    expect(Number(stored.revision)).toBe(first.draft.revision);

    const duplicate = await putDraft(db, {
      accountId: alice.accountId,
      deviceId: alice.deviceId,
      dialogId,
      operationId,
      state: "active",
      text: "raw  draft \n",
      mentions: [],
      attachments: [{ attachment_id: attachmentId, media_id: mediaId, position: 0 }],
    });
    expect(duplicate).toEqual({ ...first, duplicate: true, pushes: [] });
    await expect(putDraft(db, {
      accountId: alice.accountId,
      deviceId: alice.deviceId,
      dialogId,
      operationId,
      state: "active",
      text: "different",
    })).rejects.toMatchObject({
      status: 409,
      code: "draft_idempotency_conflict",
    } satisfies Partial<DraftError>);

    const aliceDifference = await getDifference(db, alice.accountId, first.draft.revision - 1);
    expect(aliceDifference.kind).toBe("difference");
    if (aliceDifference.kind === "difference") {
      expect(aliceDifference.updates).toContainEqual(expect.objectContaining({
        type: "draft.updated",
        dialog_id: dialogId,
        draft: expect.objectContaining({ text: "raw  draft \n", revision: first.draft.revision }),
      }));
    }
    const bobDifference = await getDifference(db, bob.accountId, 0);
    if (bobDifference.kind === "difference") {
      expect(bobDifference.updates.some((update) => update.type === "draft.updated")).toBe(false);
    }
    expect(await getDraft(db, bob.accountId, dialogId)).toBeNull();

    const bootstrap = await startBootstrap(db, alice.accountId);
    const page = await getBootstrapDialogsPage(db, alice.accountId, bootstrap.token);
    expect(page.dialogs[0].draft).toEqual(expect.objectContaining({
      operation_id: operationId,
      text: "raw  draft \n",
    }));
  });

  test("concurrent device commits converge by the account pts revision and clears remain tombstones", async () => {
    const { alice, dialogId } = await pair();
    const secondDeviceId = await addDevice(alice.accountId);
    const writes = await Promise.all([
      putDraft(db, {
        accountId: alice.accountId,
        deviceId: alice.deviceId,
        dialogId,
        operationId: crypto.randomUUID(),
        state: "active",
        text: "device one",
      }),
      putDraft(db, {
        accountId: alice.accountId,
        deviceId: secondDeviceId,
        dialogId,
        operationId: crypto.randomUUID(),
        state: "active",
        text: "device two",
      }),
    ]);
    const winner = writes.reduce((left, right) =>
      left.draft.revision > right.draft.revision ? left : right
    );
    expect(await getDraft(db, alice.accountId, dialogId)).toEqual(winner.draft);

    const cleared = await putDraft(db, {
      accountId: alice.accountId,
      deviceId: alice.deviceId,
      dialogId,
      operationId: crypto.randomUUID(),
      state: "active",
      text: " \n\t ",
    });
    expect(cleared.draft.state).toBe("cleared");
    expect(cleared.draft.revision).toBeGreaterThan(winner.draft.revision);
    expect(await db`
      SELECT state FROM account_dialog_drafts
      WHERE account_id = ${alice.accountId} AND dialog_id = ${dialogId}`)
      .toEqual([expect.objectContaining({ state: "cleared" })]);
  });

  test("a racing send can consume only its exact generation and never clears a newer device write", async () => {
    const { alice, dialogId } = await pair();
    const secondDeviceId = await addDevice(alice.accountId);
    const attempted = await putDraft(db, {
      accountId: alice.accountId,
      deviceId: alice.deviceId,
      dialogId,
      operationId: crypto.randomUUID(),
      text: "attempted generation",
    });
    const [, newer] = await Promise.all([
      sendMessage(db, {
        senderAccountId: alice.accountId,
        senderDeviceId: alice.deviceId,
        dialogId,
        clientMsgId: crypto.randomUUID(),
        body: "attempted generation",
        draftConsumeOperationId: attempted.draft.operation_id,
      }),
      putDraft(db, {
        accountId: alice.accountId,
        deviceId: secondDeviceId,
        dialogId,
        operationId: crypto.randomUUID(),
        text: "newer device generation",
      }),
    ]);
    const finalDraft = await getDraft(db, alice.accountId, dialogId);
    expect(finalDraft?.operation_id).toBe(newer.draft.operation_id);
    expect(finalDraft?.text).toBe("newer device generation");
    expect(finalDraft?.state).toBe("active");
  });

  test("group send allocates consecutive rows atomically, emits ordinary events, and consumes one draft generation", async () => {
    const { alice, bob, dialogId } = await pair();
    const mediaIds = [await readyMedia(alice.accountId), await readyMedia(alice.accountId, "file")];
    const draft = await putDraft(db, {
      accountId: alice.accountId,
      deviceId: alice.deviceId,
      dialogId,
      operationId: crypto.randomUUID(),
      state: "active",
      text: "album caption",
      attachments: mediaIds.map((mediaId, position) => ({
        attachment_id: crypto.randomUUID(),
        media_id: mediaId,
        position,
      })),
    });
    const clientGroupId = crypto.randomUUID();
    const request = {
      senderAccountId: alice.accountId,
      senderDeviceId: alice.deviceId,
      dialogId,
      clientGroupId,
      items: mediaIds.map((media_id) => ({ media_id })),
      body: draft.draft.text,
      draftConsumeOperationId: draft.draft.operation_id,
    };
    const sent = await sendMediaGroup(db, request);
    expect(sent.duplicate).toBe(false);
    expect(sent.messages).toHaveLength(2);
    expect(sent.messages[1].msg_id).toBe(sent.messages[0].msg_id + 1);
    expect(sent.messages.map((message) => message.media_group_index)).toEqual([0, 1]);
    expect(sent.messages.every((message) =>
      message.media_group_id === clientGroupId && message.media_group_count === 2
    )).toBe(true);
    expect(sent.messages.map((message) => message.text)).toEqual(["album caption", ""]);
    expect(sent.clearedDraftRevision).toBeGreaterThan(draft.draft.revision);
    expect((await getDraft(db, alice.accountId, dialogId))?.state).toBe("cleared");

    const duplicate = await sendMediaGroup(db, request);
    expect(duplicate.duplicate).toBe(true);
    expect(duplicate.messages.map((message) => message.msg_id))
      .toEqual(sent.messages.map((message) => message.msg_id));
    const recipientEvents = await db`
      SELECT type FROM account_events
      WHERE account_id = ${bob.accountId} AND type = 'message.new'
        AND msg_id BETWEEN ${sent.messages[0].msg_id} AND ${sent.messages[1].msg_id}`;
    expect(recipientEvents).toHaveLength(2);
    expect(await db`
      SELECT type FROM account_events
      WHERE account_id = ${bob.accountId} AND type = 'draft.updated'`).toHaveLength(0);
  });

  test("one invalid group item rolls back before consuming ids or the draft", async () => {
    const { alice, dialogId } = await pair();
    const validMediaId = await readyMedia(alice.accountId);
    const invalidMediaId = crypto.randomUUID();
    const draft = await putDraft(db, {
      accountId: alice.accountId,
      deviceId: alice.deviceId,
      dialogId,
      operationId: crypto.randomUUID(),
      text: "keep me",
    });
    const before = Number((await db`SELECT last_msg_id FROM dialogs WHERE id = ${dialogId}`)[0].last_msg_id);
    await expect(sendMediaGroup(db, {
      senderAccountId: alice.accountId,
      senderDeviceId: alice.deviceId,
      dialogId,
      clientGroupId: crypto.randomUUID(),
      items: [{ media_id: validMediaId }, { media_id: invalidMediaId }],
      draftConsumeOperationId: draft.draft.operation_id,
    })).rejects.toMatchObject({ code: "media_group_item_unavailable" });
    expect(Number((await db`SELECT last_msg_id FROM dialogs WHERE id = ${dialogId}`)[0].last_msg_id))
      .toBe(before);
    expect((await getDraft(db, alice.accountId, dialogId))?.text).toBe("keep me");
  });

  test("draft media is owner-private, live while referenced, and receives a 24-hour dereference grace", async () => {
    const { alice, bob, dialogId } = await pair();
    const mediaId = await readyMedia(alice.accountId);
    await db`
      UPDATE media_objects
      SET completed_at = now() - interval '2 days',
          last_accessed_at = now() - interval '2 days'
      WHERE id = ${mediaId}`;
    await putDraft(db, {
      accountId: alice.accountId,
      deviceId: alice.deviceId,
      dialogId,
      operationId: crypto.randomUUID(),
      text: "",
      attachments: [{
        attachment_id: crypto.randomUUID(),
        media_id: mediaId,
        position: 0,
      }],
    });

    expect((await downloadMediaChunk(db, alice.accountId, mediaId, 8)).bytes).toHaveLength(0);
    await expect(downloadMediaChunk(db, bob.accountId, mediaId, 8))
      .rejects.toMatchObject({ status: 404 });
    await expect(cancelMediaUpload(db, alice.accountId, alice.deviceId, mediaId))
      .rejects.toMatchObject({ status: 409 });
    await cleanupExpiredData(db);
    expect(await db`SELECT id FROM media_objects WHERE id = ${mediaId}`).toHaveLength(1);

    await putDraft(db, {
      accountId: alice.accountId,
      deviceId: alice.deviceId,
      dialogId,
      operationId: crypto.randomUUID(),
      state: "cleared",
      text: "",
    });
    await cleanupExpiredData(db);
    expect(await db`SELECT id FROM media_objects WHERE id = ${mediaId}`).toHaveLength(1);

    await db`
      UPDATE media_objects SET last_accessed_at = now() - interval '25 hours'
      WHERE id = ${mediaId}`;
    await cleanupExpiredData(db);
    expect(await db`SELECT id FROM media_objects WHERE id = ${mediaId}`).toHaveLength(0);
  });

  test("capability flags advertise drafts and media groups independently", async () => {
    const oldDrafts = process.env.TOJ_CLOUD_DRAFTS_V1_ENABLED;
    const oldGroups = process.env.TOJ_MEDIA_GROUPS_V1_ENABLED;
    process.env.TOJ_CLOUD_DRAFTS_V1_ENABLED = "1";
    delete process.env.TOJ_MEDIA_GROUPS_V1_ENABLED;
    const server = startCloudServer(0, db, null, null);
    try {
      const response = await fetch(`http://127.0.0.1:${server.port}/v1/capabilities`);
      const body = await response.json() as { api_version: number; capabilities: string[] };
      expect(body.api_version).toBe(5);
      expect(body.capabilities).toContain("cloud_drafts_v1");
      expect(body.capabilities).not.toContain("media_groups_v1");
    } finally {
      server.stop(true);
      if (oldDrafts == null) delete process.env.TOJ_CLOUD_DRAFTS_V1_ENABLED;
      else process.env.TOJ_CLOUD_DRAFTS_V1_ENABLED = oldDrafts;
      if (oldGroups == null) delete process.env.TOJ_MEDIA_GROUPS_V1_ENABLED;
      else process.env.TOJ_MEDIA_GROUPS_V1_ENABLED = oldGroups;
    }
  });
});
