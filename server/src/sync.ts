import type { SQL } from "bun";
import { Client } from "pg";
import { timingSafeEqual } from "node:crypto";
import { seal, open, bodyAAD, requestFingerprintHMAC } from "./crypto";
import { loadMediaDTO, mediaDTOFromRow, type MediaDTO } from "./media";
import { requireActiveDevice } from "./auth";
import {
  lockAccountMutations,
  lockMutationKeys,
  mediaGroupReceiptKey,
} from "./locks";
import { fanoutDialogEvent } from "./fanout";
import {
  consumeDraftInTransaction,
  loadDrafts,
  type DraftDTO,
} from "./drafts";
import {
  DialogAccessError,
  lockDialogForMutation,
  requireDialogReadAccess,
} from "./dialog-access";
import {
  SYNC_NOTIFY_CHANNEL,
  isSyncWakeupChannel,
  notifySyncWakeups,
  type SyncPush,
} from "./sync-wakeup";

export class SyncError extends Error {
  constructor(
    message: string,
    readonly status = 400,
    readonly code = "invalid_sync_request",
    readonly details: Record<string, unknown> = {},
  ) {
    super(message);
    this.name = "SyncError";
  }
}

// Global lock order for EVERY mutation (review B4), to stay deadlock-free:
//   1 idempotency row (send_requests / message_mutation_requests / group_*_requests)
//   → 2 accounts (ascending account_id, FOR SHARE) → 3 acting device
//   → 4 media_objects (FOR UPDATE) → 5 direct_dialog_pairs → 6 dialogs (FOR UPDATE)
//   → 7 dialog_members (ascending account_id, FOR UPDATE) → 8 messages
//   → 9 account_sync_states (ascending account_id, FOR NO KEY UPDATE)
//   → 10 account_events insert → 11 push_deliveries insert

export type MessageDTO = {
  dialog_id: string; msg_id: number; sender_account_id: string; client_msg_id: string;
  kind: string; text: string; reply_to_msg_id: number | null; edit_version: number;
  forwarded: boolean; reactions: { account_id: string; emoji: string }[];
  mentions: { account_id: string; offset: number; length: number }[];
  media: MediaDTO | null;
  media_group_id: string | null;
  media_group_index: number | null;
  media_group_count: number | null;
  service_type: string | null; service_data: Record<string, unknown> | null;
  state: string; server_ts: string;
};
export type Push = SyncPush;
export type SyncWakeup = Push;
const ACCOUNT_UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export { notifySyncWakeups };
const n = (v: unknown) => Number(v as any);
const buf = (v: unknown) => Buffer.from(v as Uint8Array);
const iso = (v: unknown) => v instanceof Date ? v.toISOString() : String(v);
const clamp = (value: number, min: number, max: number) => Math.max(min, Math.min(max, value));
const boundedInteger = (value: unknown, fallback: number, min: number, max: number) => {
  const parsed = Number(value ?? fallback);
  return Number.isSafeInteger(parsed) ? clamp(parsed, min, max) : fallback;
};

function eventData(v: unknown): Record<string, unknown> {
  if (!v) return {};
  if (typeof v === "string") return JSON.parse(v);
  return v as Record<string, unknown>;
}

function encodeCursor(value: unknown): string {
  return Buffer.from(JSON.stringify(value), "utf8").toString("base64url");
}

function decodeCursor<T>(cursor?: string): T | null {
  if (!cursor) return null;
  try {
    return JSON.parse(Buffer.from(cursor, "base64url").toString("utf8")) as T;
  } catch {
    throw new SyncError("invalid cursor");
  }
}

async function requireActiveAccount(sql: SQL, accountId: string): Promise<void> {
  const rows = await sql`
    SELECT id FROM accounts
    WHERE id = ${accountId} AND status IN ('active','limited')
    FOR SHARE`;
  if (rows.length === 0) throw new SyncError("account unavailable");
}

async function loadMessage(sql: SQL, dialogId: string, msgId: number): Promise<MessageDTO | null> {
  return (await loadMessages(sql, [{ dialogId, msgId }])).get(`${dialogId}:${msgId}`) ?? null;
}

type MessageKey = { dialogId: string; msgId: number };

/** Loads an arbitrary event page in two bounded queries: messages+media, then all reactions. */
async function loadMessages(sql: SQL, inputKeys: MessageKey[]): Promise<Map<string, MessageDTO>> {
  const unique = new Map<string, MessageKey>();
  for (const key of inputKeys) unique.set(`${key.dialogId}:${key.msgId}`, key);
  const keys = [...unique.values()];
  if (keys.length === 0) return new Map();
  const dialogIds = sql.array(keys.map((key) => key.dialogId), "uuid");
  const messageIds = sql.array(keys.map((key) => key.msgId), "int8");

  const rows = await sql`
    WITH wanted AS (
      SELECT * FROM unnest(${dialogIds}::uuid[], ${messageIds}::bigint[])
        AS key(dialog_id, msg_id)
    )
    SELECT m.dialog_id, m.msg_id, m.sender_account_id, m.client_msg_id, m.kind,
           m.body_key_id, m.body_nonce, m.body_ciphertext, m.reply_to_msg_id,
           m.forwarded_from_account_id, m.forwarded_from_dialog_id, m.forwarded_from_msg_id,
           m.media_id, m.service_type, m.service_data, m.edit_version, m.state, m.server_ts,
           m.media_group_id, m.media_group_index, m.media_group_count,
           media.id AS media_object_id, media.kind AS media_object_kind,
           media.content_type AS media_content_type, media.file_name AS media_file_name,
           media.file_name_key_id AS media_file_name_key_id,
           media.file_name_nonce AS media_file_name_nonce,
           media.file_name_ciphertext AS media_file_name_ciphertext,
           media.byte_size AS media_byte_size, media.duration_ms AS media_duration_ms,
           media.width AS media_width, media.height AS media_height,
           media.thumbnail_ciphertext AS media_thumbnail_ciphertext
    FROM wanted key
    JOIN messages m ON m.dialog_id = key.dialog_id AND m.msg_id = key.msg_id
    LEFT JOIN media_objects media ON media.id = m.media_id AND media.status = 'ready'`;

  const metadataRows = await sql`
    WITH wanted AS (
      SELECT * FROM unnest(${dialogIds}::uuid[], ${messageIds}::bigint[])
        AS key(dialog_id, msg_id)
    )
    SELECT key.dialog_id, key.msg_id,
           COALESCE((
             SELECT jsonb_agg(
               jsonb_build_object('account_id', reaction.account_id, 'emoji', reaction.emoji)
               ORDER BY reaction.created_at, reaction.account_id
             )
             FROM message_reactions reaction
             WHERE reaction.dialog_id = key.dialog_id AND reaction.msg_id = key.msg_id
           ), '[]'::jsonb) AS reactions,
           COALESCE((
             SELECT jsonb_agg(
               jsonb_build_object(
                 'account_id', mention.account_id,
                 'offset', mention.entity_offset,
                 'length', mention.length
               )
               ORDER BY mention.entity_offset, mention.account_id
             )
             FROM message_mentions mention
             WHERE mention.dialog_id = key.dialog_id AND mention.msg_id = key.msg_id
           ), '[]'::jsonb) AS mentions
    FROM wanted key`;

  const reactions = new Map<string, { account_id: string; emoji: string }[]>();
  const mentions = new Map<string, { account_id: string; offset: number; length: number }[]>();
  for (const metadata of metadataRows) {
    const key = `${metadata.dialog_id}:${n(metadata.msg_id)}`;
    reactions.set(key, (metadata.reactions ?? []).map((reaction: any) => ({
      account_id: reaction.account_id,
      emoji: reaction.emoji,
    })));
    mentions.set(key, (metadata.mentions ?? []).map((mention: any) => ({
      account_id: mention.account_id,
      offset: n(mention.offset),
      length: n(mention.length),
    })));
  }

  const result = new Map<string, MessageDTO>();
  for (const row of rows) {
    const dialogId = row.dialog_id;
    const msgId = n(row.msg_id);
    const key = `${dialogId}:${msgId}`;
    const text = row.state === "deleted_for_all"
      ? ""
      : open(
          { keyId: row.body_key_id, nonce: buf(row.body_nonce), ciphertext: buf(row.body_ciphertext) },
          bodyAAD(dialogId, msgId, row.sender_account_id),
        ).toString("utf8");
    const media = row.media_object_id == null ? null : mediaDTOFromRow({
      id: row.media_object_id,
      kind: row.media_object_kind,
      content_type: row.media_content_type,
      file_name: row.media_file_name,
      file_name_key_id: row.media_file_name_key_id,
      file_name_nonce: row.media_file_name_nonce,
      file_name_ciphertext: row.media_file_name_ciphertext,
      byte_size: row.media_byte_size,
      duration_ms: row.media_duration_ms,
      width: row.media_width,
      height: row.media_height,
      thumbnail_ciphertext: row.media_thumbnail_ciphertext,
    });
    result.set(key, {
      dialog_id: dialogId, msg_id: msgId, sender_account_id: row.sender_account_id,
      client_msg_id: row.client_msg_id, kind: row.kind, text,
      reply_to_msg_id: row.reply_to_msg_id == null ? null : n(row.reply_to_msg_id),
      edit_version: row.edit_version,
      // Source identifiers stay server-side. Recipients only need the marker.
      forwarded: row.forwarded_from_dialog_id != null && row.forwarded_from_msg_id != null,
      reactions: reactions.get(key) ?? [],
      mentions: mentions.get(key) ?? [],
      media: row.state === "deleted_for_all" ? null : media,
      media_group_id: row.media_group_id ?? null,
      media_group_index: row.media_group_index == null ? null : n(row.media_group_index),
      media_group_count: row.media_group_count == null ? null : n(row.media_group_count),
      service_type: row.service_type ?? null,
      service_data: row.service_data == null ? null : eventData(row.service_data),
      state: row.state, server_ts: iso(row.server_ts),
    });
  }
  return result;
}

const MAX_TEXT_BYTES = 16 * 1024;
const MAX_MEDIA_GROUP_ITEMS_PER_MINUTE = 600;
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function requireTextBody(body: unknown): string {
  if (typeof body !== "string" || body.trim().length === 0) throw new SyncError("message body required");
  if (Buffer.byteLength(body, "utf8") > MAX_TEXT_BYTES) throw new SyncError("message body too large");
  return body;
}

function optionalMessageId(value: unknown): number | null {
  if (value == null) return null;
  const id = Number(value);
  if (!Number.isSafeInteger(id) || id <= 0) throw new SyncError("invalid message id");
  return id;
}

/** Idempotent 1:1 dialog creation (review I5: conflict-safe on the pair). Emits dialog.created. */
export async function getOrCreateDirectDialog(
  sql: SQL, aId: string, bId: string, actorDeviceId?: string,
): Promise<{ dialogId: string; created: boolean }> {
  if (aId === bId) throw new SyncError("cannot open a direct dialog with yourself");
  const [low, high] = aId < bId ? [aId, bId] : [bId, aId];
  return await sql.begin(async (tx) => {
    await requireActiveAccount(tx, low);
    await requireActiveAccount(tx, high);
    if (actorDeviceId) await requireActiveDevice(tx, aId, actorDeviceId);
    // Serialize the unordered pair before creating a dialog row. This preserves the B4 lock order
    // even though the FK means the direct_dialog_pairs row cannot exist before dialogs.id exists.
    await tx`SELECT pg_advisory_xact_lock(hashtextextended(${`direct:${low}:${high}`}, 0))`;
    const existing = await tx`SELECT dialog_id FROM direct_dialog_pairs WHERE account_low = ${low} AND account_high = ${high}`;
    if (existing.length) return { dialogId: existing[0].dialog_id, created: false };

    const dlg = await tx`INSERT INTO dialogs (type, created_by) VALUES ('direct', ${aId}) RETURNING id`;
    const dialogId = dlg[0].id;
    const pair = await tx`
      INSERT INTO direct_dialog_pairs (dialog_id, account_low, account_high)
      VALUES (${dialogId}, ${low}, ${high})
      ON CONFLICT (account_low, account_high) DO NOTHING RETURNING dialog_id`;
    if (pair.length === 0) {
      await tx`DELETE FROM dialogs WHERE id = ${dialogId}`; // lost the race; drop our orphan
      const winner = await tx`SELECT dialog_id FROM direct_dialog_pairs WHERE account_low = ${low} AND account_high = ${high}`;
      return { dialogId: winner[0].dialog_id, created: false };
    }
    await tx`INSERT INTO dialog_members (dialog_id, account_id, role) VALUES (${dialogId}, ${low}, 'member'), (${dialogId}, ${high}, 'member')`;
    for (const acc of [low, high]) { // already ascending
      const upd = await tx`UPDATE account_sync_states SET pts = pts + 1, updated_at = now() WHERE account_id = ${acc} RETURNING pts`;
      await tx`
        INSERT INTO account_events (
          account_id, pts, type, dialog_id, actor_account_id, data
        )
        SELECT ${acc}, ${n(upd[0].pts)}, 'dialog.created', ${dialogId}, ${aId},
               jsonb_build_object(
                 'preferences',
                 jsonb_build_object(
                   'dialogId', ${dialogId}::uuid,
                   'pinned', COALESCE(preference.is_pinned, FALSE),
                   'pinnedAt', preference.pinned_at,
                   'muted', COALESCE(preference.is_muted, member.notification_mode = 'muted'),
                   'archived', COALESCE(preference.is_archived, FALSE),
                   'updatedAt', COALESCE(preference.updated_at, member.joined_at)
                 )
               )
        FROM dialog_members member
        LEFT JOIN dialog_preferences preference
          ON preference.dialog_id = member.dialog_id
         AND preference.account_id = member.account_id
        WHERE member.dialog_id = ${dialogId}
          AND member.account_id = ${acc}`;
    }
    return { dialogId, created: true };
  });
}

export type SendResult = {
  dialogId: string; clientMsgId: string; msgId: number; senderPts: number;
  clearedDraftRevision: number | null;
  duplicate: boolean; serverTs?: string; text?: string; senderAccountId?: string; pushes: Push[];
};

type MessageMention = { accountId: string; offset: number; length: number };

function normalizeMentions(value: unknown, body: string): MessageMention[] {
  if (value == null) return [];
  if (!Array.isArray(value)) throw new SyncError("mentions must be an array");
  if (value.length > 100) throw new SyncError("too many mentions");
  const seen = new Set<string>();
  const mentions = value.map((raw: any) => {
    const accountId = String(raw?.accountId ?? raw?.account_id ?? "").toLowerCase();
    const offset = Number(raw?.offset);
    const length = Number(raw?.length);
    if (
      !UUID_PATTERN.test(accountId)
      || !Number.isSafeInteger(offset) || offset < 0
      || !Number.isSafeInteger(length) || length <= 0
      || offset + length > body.length
    ) {
      throw new SyncError("invalid mention");
    }
    if (seen.has(accountId)) throw new SyncError("duplicate mention target");
    seen.add(accountId);
    return { accountId, offset, length };
  });
  return mentions.sort((left, right) =>
    left.offset - right.offset || left.accountId.localeCompare(right.accountId)
  );
}

/** review B2: claim the idempotency row BEFORE allocating a msg_id; a retry echoes the original result. */
export async function sendMessage(sql: SQL, p: {
  senderAccountId: string; senderDeviceId?: string | null; dialogId: string;
  clientMsgId: string; kind?: string; body?: string; replyToMsgId?: number | null;
  mediaId?: string | null;
  forwardedFrom?: { dialogId: string; msgId: number } | null;
  mentions?: unknown;
  draftConsumeOperationId?: string | null;
  allowDraftConsumption?: boolean;
  /** Server-only escape hatch for generated lifecycle rows such as call history. */
  internalService?: boolean;
}): Promise<SendResult> {
  if (p.draftConsumeOperationId != null && p.allowDraftConsumption === false) {
    throw new SyncError("cloud drafts are unavailable", 404, "capability_unavailable");
  }
  return await sql.begin(async (tx) => {
    const draftConsumeOperationId = p.draftConsumeOperationId == null
      ? null
      : String(p.draftConsumeOperationId).toLowerCase();
    if (draftConsumeOperationId != null && !UUID_PATTERN.test(draftConsumeOperationId)) {
      throw new SyncError("invalid draft consume operation id");
    }
    let body = p.forwardedFrom || p.mediaId ? String(p.body ?? "") : requireTextBody(p.body);
    if (Buffer.byteLength(body, "utf8") > MAX_TEXT_BYTES) throw new SyncError("message body too large");
    let kind = p.kind ?? "text";
    let forwardedFromAccountId: string | null = null;
    let mediaId: string | null = p.mediaId ?? null;
    const replyToMsgId = optionalMessageId(p.replyToMsgId);
    let mentions = normalizeMentions(p.mentions, body);
    // 1) idempotency gate — before any counter is touched
    const claim = await tx`
      INSERT INTO send_requests (
        sender_account_id, client_msg_id, dialog_id, status, draft_consume_operation_id
      )
      VALUES (
        ${p.senderAccountId}, ${p.clientMsgId}, ${p.dialogId}, 'pending',
        ${draftConsumeOperationId}
      )
      ON CONFLICT (sender_account_id, client_msg_id) DO NOTHING RETURNING status`;
    if (claim.length === 0) {
      const row = (await tx`
        SELECT status, dialog_id, msg_id, sender_pts, draft_consume_operation_id,
               cleared_draft_revision
        FROM send_requests
        WHERE sender_account_id = ${p.senderAccountId} AND client_msg_id = ${p.clientMsgId}
        FOR UPDATE`)[0];
      if (row.status !== "completed") throw new SyncError("send already in progress");
      if ((row.draft_consume_operation_id ?? null) !== draftConsumeOperationId) {
        throw new SyncError(
          "client message id already used with a different draft",
          409,
          "send_idempotency_conflict",
        );
      }
      const msg = await loadMessage(tx, row.dialog_id, n(row.msg_id));
      if (p.internalService === true && (
        row.dialog_id !== p.dialogId
        || msg?.sender_account_id !== p.senderAccountId
        || msg?.kind !== "service"
        || msg?.text !== body
      )) {
        throw new SyncError("internal send idempotency conflict");
      }
      return {
        dialogId: row.dialog_id, clientMsgId: p.clientMsgId, msgId: n(row.msg_id),
        senderPts: n(row.sender_pts),
        clearedDraftRevision: row.cleared_draft_revision == null
          ? null : n(row.cleared_draft_revision),
        duplicate: true, pushes: [],
        serverTs: msg?.server_ts, text: msg?.text, senderAccountId: msg?.sender_account_id,
      };
    }

    // Lifecycle service rows are authored by the original actor even if account deletion and call
    // termination commit together. `internalService` is never accepted from an HTTP request.
    if (p.internalService !== true) await requireActiveAccount(tx, p.senderAccountId);
    if (p.senderDeviceId) {
      const device = await tx`
        SELECT id FROM devices
        WHERE id = ${p.senderDeviceId} AND account_id = ${p.senderAccountId} AND revoked_at IS NULL
        FOR SHARE`;
      if (!device.length) throw new SyncError("sending device is no longer active");
    }
    const directPair = (await tx`
      SELECT account_low, account_high
      FROM direct_dialog_pairs WHERE dialog_id = ${p.dialogId}`)[0];
    if (directPair) {
      await lockAccountMutations(tx, [directPair.account_low, directPair.account_high]);
    } else {
      await lockAccountMutations(tx, [p.senderAccountId]);
    }
    if (p.forwardedFrom) {
      if (mentions.length) throw new SyncError("forwarded messages cannot add mentions");
      const sourceMsgId = optionalMessageId(p.forwardedFrom.msgId)!;
      await requireDialogReadAccess(tx, p.senderAccountId, p.forwardedFrom.dialogId);
      const source = (await tx`
        SELECT sender_account_id, kind, state, body_key_id, body_nonce, body_ciphertext, media_id
        FROM messages WHERE dialog_id = ${p.forwardedFrom.dialogId} AND msg_id = ${sourceMsgId}
        FOR SHARE`)[0];
      if (!source || source.state !== "visible") throw new SyncError("forward source not found");
      body = open(
        { keyId: source.body_key_id, nonce: buf(source.body_nonce), ciphertext: buf(source.body_ciphertext) },
        bodyAAD(p.forwardedFrom.dialogId, sourceMsgId, source.sender_account_id),
      ).toString("utf8");
      kind = source.kind;
      mediaId = source.media_id;
      forwardedFromAccountId = source.sender_account_id;
    }

    if (mediaId && !p.forwardedFrom) {
      const media = (await tx`
        SELECT owner_account_id, kind, status, purpose FROM media_objects
        WHERE id = ${mediaId} FOR UPDATE`)[0];
      if (!media || media.owner_account_id !== p.senderAccountId) throw new SyncError("media upload not found");
      if (media.status !== "ready") throw new SyncError("media upload is incomplete");
      if (media.purpose !== "message") throw new SyncError("media purpose does not allow messages");
      kind = media.kind;
      await tx`UPDATE media_objects SET last_accessed_at = now() WHERE id = ${mediaId}`;
    } else if (!mediaId && !p.forwardedFrom && kind !== "text"
      && !(kind === "service" && p.internalService === true)) {
      throw new SyncError("media upload required");
    }

    await lockDialogForMutation(tx, p.senderAccountId, p.dialogId);
    const blocked = await tx`
      SELECT 1
      FROM direct_dialog_pairs pair
      JOIN account_blocks b ON
        (b.blocker_account_id = pair.account_low AND b.blocked_account_id = pair.account_high)
        OR (b.blocker_account_id = pair.account_high AND b.blocked_account_id = pair.account_low)
      WHERE pair.dialog_id = ${p.dialogId}
      LIMIT 1`;
    if (blocked.length && p.internalService !== true) throw new SyncError("conversation is blocked");

    if (replyToMsgId != null) {
      const target = await tx`
        SELECT state FROM messages
        WHERE dialog_id = ${p.dialogId} AND msg_id = ${replyToMsgId}`;
      if (target.length === 0) {
        throw new SyncError("reply target not found", 409, "invalid_reply_target");
      }
      if (target[0].state !== "visible") {
        throw new SyncError(
          "original message is unavailable",
          409,
          "invalid_reply_target",
          { reply_to_msg_id: replyToMsgId },
        );
      }
    }
    if (mentions.length) {
      const activeTargets = await tx`
        SELECT account_id
        FROM dialog_members
        WHERE dialog_id = ${p.dialogId} AND left_at IS NULL
          AND account_id = ANY(${tx.array(mentions.map((mention) => mention.accountId), "uuid")}::uuid[])
        ORDER BY account_id`;
      const activeIds = new Set(activeTargets.map((row: any) => String(row.account_id)));
      const unavailable = mentions
        .map((mention) => mention.accountId)
        .filter((accountId) => !activeIds.has(accountId));
      if (unavailable.length) throw new SyncError("mention target is not an active member");
    }

    // 3) allocate per-dialog msg_id
    const dlg = await tx`UPDATE dialogs SET last_msg_id = last_msg_id + 1, updated_at = now() WHERE id = ${p.dialogId} RETURNING last_msg_id`;
    const msgId = n(dlg[0].last_msg_id);

    // 5) encrypt + store the body once
    const sealed = seal(body, bodyAAD(p.dialogId, msgId, p.senderAccountId));
    const inserted = await tx`
      INSERT INTO messages (dialog_id, msg_id, sender_account_id, sender_device_id, client_msg_id, kind,
                            body_key_id, body_nonce, body_ciphertext, reply_to_msg_id,
                            forwarded_from_account_id, forwarded_from_dialog_id, forwarded_from_msg_id,
                            media_id)
      VALUES (${p.dialogId}, ${msgId}, ${p.senderAccountId}, ${p.senderDeviceId ?? null}, ${p.clientMsgId},
              ${kind}, ${sealed.keyId}, ${sealed.nonce}, ${sealed.ciphertext}, ${replyToMsgId},
              ${forwardedFromAccountId}, ${p.forwardedFrom?.dialogId ?? null}, ${p.forwardedFrom?.msgId ?? null},
              ${mediaId})
      RETURNING server_ts`;
    if (mentions.length) {
      await tx`
        INSERT INTO message_mentions (dialog_id, msg_id, account_id, entity_offset, length)
        SELECT ${p.dialogId}, ${msgId}, account_id, entity_offset, entity_length
        FROM unnest(
          ${tx.array(mentions.map((mention) => mention.accountId), "uuid")}::uuid[],
          ${tx.array(mentions.map((mention) => mention.offset), "int4")}::int[],
          ${tx.array(mentions.map((mention) => mention.length), "int4")}::int[]
        ) AS mention(account_id, entity_offset, entity_length)`;
    }

    // 6) fan out one event per active member, ascending account_id (deadlock-free)
    const pushes = await fanoutDialogEvent(tx, {
      dialogId: p.dialogId,
      type: "message.new",
      msgId,
      actorAccountId: p.senderAccountId,
      sourceDeviceId: p.senderDeviceId,
      unarchiveOnIncomingMessage: true,
    });
    let senderPts = pushes.find((push) => push.accountId === p.senderAccountId)?.pts ?? 0;
    const consumed = await consumeDraftInTransaction(tx, {
      accountId: p.senderAccountId,
      deviceId: p.senderDeviceId,
      dialogId: p.dialogId,
      operationId: draftConsumeOperationId,
    });
    if (consumed) {
      pushes.push(...consumed.pushes);
      senderPts = consumed.revision;
    }

    // complete the idempotency row so retries return this exact result
    await tx`
      UPDATE send_requests SET
        status = 'completed',
        msg_id = ${msgId},
        sender_pts = ${senderPts},
        cleared_draft_revision = ${consumed?.revision ?? null}
      WHERE sender_account_id = ${p.senderAccountId} AND client_msg_id = ${p.clientMsgId}`;
    // A bounded PostgreSQL wake-up keeps connected clients on every server process current. The
    // account_events rows remain authoritative, so local immediate and cross-process hints may
    // safely be delivered more than once.
    await notifySyncWakeups(tx, pushes);

    return {
      dialogId: p.dialogId, clientMsgId: p.clientMsgId, msgId, senderPts, duplicate: false,
      clearedDraftRevision: consumed?.revision ?? null,
      serverTs: iso(inserted[0].server_ts), text: body, senderAccountId: p.senderAccountId, pushes,
    };
  });
}

export type MediaGroupSendResult = {
  dialogId: string;
  clientGroupId: string;
  messages: MessageDTO[];
  senderPts: number;
  clearedDraftRevision: number | null;
  duplicate: boolean;
  pushes: Push[];
};

type NormalizedGroupItem = {
  mediaId: string;
  clientMsgId: string;
};

function deterministicGroupClientMessageId(clientGroupId: string, index: number): string {
  const bytes = Buffer.from(requestFingerprintHMAC(
    "media-group-client-message-id",
    `${clientGroupId}:${index}`,
  ).subarray(0, 16));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = bytes.toString("hex");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

function normalizeMediaGroupItems(value: unknown, clientGroupId: string): NormalizedGroupItem[] {
  if (!Array.isArray(value) || value.length < 2 || value.length > 10) {
    throw new SyncError("media groups require 2 to 10 items");
  }
  const mediaIds = new Set<string>();
  const clientMessageIds = new Set<string>();
  return value.map((raw: any, index: number) => {
    const mediaId = String(raw?.media_id ?? raw?.mediaId ?? "").toLowerCase();
    if (!UUID_PATTERN.test(mediaId) || mediaIds.has(mediaId)) {
      throw new SyncError("invalid or duplicate group media id");
    }
    mediaIds.add(mediaId);
    const supplied = raw?.client_msg_id ?? raw?.clientMsgId;
    const fingerprintClientMsgId = supplied == null ? null : String(supplied).toLowerCase();
    if (fingerprintClientMsgId != null && !UUID_PATTERN.test(fingerprintClientMsgId)) {
      throw new SyncError("invalid group client message id");
    }
    const clientMsgId = fingerprintClientMsgId
      ?? deterministicGroupClientMessageId(clientGroupId, index);
    if (clientMessageIds.has(clientMsgId)) throw new SyncError("duplicate group client message id");
    clientMessageIds.add(clientMsgId);
    return { mediaId, clientMsgId };
  });
}

function mediaGroupFingerprint(input: {
  dialogId: string;
  body: string;
  replyToMsgId: number | null;
  mentions: MessageMention[];
  draftConsumeOperationId: string | null;
  items: NormalizedGroupItem[];
}): Buffer {
  return requestFingerprintHMAC("media-group-send", JSON.stringify({
    dialog_id: input.dialogId,
    body: input.body,
    reply_to_msg_id: input.replyToMsgId,
    mentions: input.mentions.map((mention) => ({
      account_id: mention.accountId,
      offset: mention.offset,
      length: mention.length,
    })),
    draft_consume_operation_id: input.draftConsumeOperationId,
    items: input.items.map((item) => ({
      media_id: item.mediaId,
      client_msg_id: item.clientMsgId,
    })),
  }));
}

/**
 * Validates every media object before allocating one consecutive message-id range. All album rows,
 * their ordinary message.new events, and exact-operation draft consumption commit together.
 */
export async function sendMediaGroup(sql: SQL, p: {
  senderAccountId: string;
  senderDeviceId: string;
  dialogId: string;
  clientGroupId: string;
  items: unknown;
  body?: unknown;
  replyToMsgId?: unknown;
  mentions?: unknown;
  draftConsumeOperationId?: string | null;
  allowDraftConsumption?: boolean;
}): Promise<MediaGroupSendResult> {
  const dialogId = String(p.dialogId ?? "").toLowerCase();
  const clientGroupId = String(p.clientGroupId ?? "").toLowerCase();
  if (!UUID_PATTERN.test(dialogId)) throw new SyncError("invalid dialog id");
  if (!UUID_PATTERN.test(clientGroupId)) throw new SyncError("invalid client group id");
  if (p.body != null && typeof p.body !== "string") throw new SyncError("caption must be a string");
  const body = String(p.body ?? "");
  if (Buffer.byteLength(body, "utf8") > MAX_TEXT_BYTES) throw new SyncError("message body too large");
  const replyToMsgId = optionalMessageId(p.replyToMsgId);
  const mentions = normalizeMentions(p.mentions, body);
  const items = normalizeMediaGroupItems(p.items, clientGroupId);
  const draftConsumeOperationId = p.draftConsumeOperationId == null
    ? null
    : String(p.draftConsumeOperationId).toLowerCase();
  if (draftConsumeOperationId != null && !UUID_PATTERN.test(draftConsumeOperationId)) {
    throw new SyncError("invalid draft consume operation id");
  }
  if (draftConsumeOperationId != null && p.allowDraftConsumption === false) {
    throw new SyncError("cloud drafts are unavailable", 404, "capability_unavailable");
  }
  const fingerprint = mediaGroupFingerprint({
    dialogId,
    body,
    replyToMsgId,
    mentions,
    draftConsumeOperationId,
    items,
  });

  return await sql.begin(async (tx) => {
    // Serialize the live receipt and compact tombstone with maintenance cleanup. Without this
    // exact-operation lock, cleanup could delete the request after our tombstone read and allow
    // the retry's claim to succeed as a new group send.
    await lockMutationKeys(tx, [
      mediaGroupReceiptKey(p.senderAccountId, clientGroupId),
    ]);
    await requireActiveAccount(tx, p.senderAccountId);
    await requireActiveDevice(tx, p.senderAccountId, p.senderDeviceId);
    try {
      await requireDialogReadAccess(tx, p.senderAccountId, dialogId);
    } catch (error) {
      if (error instanceof DialogAccessError) {
        throw new SyncError("dialog access denied", 403, "dialog_access_denied");
      }
      throw error;
    }

    const requestStillPresent = (await tx`
      SELECT 1 FROM media_group_send_requests
      WHERE sender_account_id = ${p.senderAccountId}
        AND client_group_id = ${clientGroupId}`)[0] != null;
    const durableGroup = requestStillPresent ? [] : await tx`
      SELECT dialog_id, msg_id, client_msg_id, media_id, media_group_index, media_group_count,
             draft_consume_operation_id, draft_cleared_revision
      FROM messages
      WHERE sender_account_id = ${p.senderAccountId}
        AND media_group_id = ${clientGroupId}
      ORDER BY media_group_index`;
    if (durableGroup.length) {
      const shapeMatches = durableGroup.length === items.length
        && durableGroup.every((row: any, index: number) =>
          row.dialog_id === dialogId
          && n(row.media_group_index) === index
          && n(row.media_group_count) === items.length
          && row.media_id === items[index].mediaId
          && row.client_msg_id === items[index].clientMsgId
          && (row.draft_consume_operation_id ?? null) === draftConsumeOperationId
        );
      const keys = durableGroup.map((row: any) => ({
        dialogId: String(row.dialog_id),
        msgId: n(row.msg_id),
      }));
      const loaded = await loadMessages(tx, keys);
      const messages = keys.map((key) => loaded.get(`${key.dialogId}:${key.msgId}`))
        .filter((message): message is MessageDTO => message != null);
      const first = messages[0];
      const contentMatches = first?.text === body
        && first?.reply_to_msg_id === replyToMsgId
        && JSON.stringify(first?.mentions ?? []) === JSON.stringify(
          mentions.map((mention) => ({
            account_id: mention.accountId,
            offset: mention.offset,
            length: mention.length,
          })),
        );
      if (!shapeMatches || !contentMatches || messages.length !== items.length) {
        throw new SyncError(
          "client group id already used with different media",
          409,
          "media_group_idempotency_conflict",
        );
      }
      const firstMsgId = n(durableGroup[0].msg_id);
      const lastMsgId = n(durableGroup[durableGroup.length - 1].msg_id);
      const clearedRevision = durableGroup[0].draft_cleared_revision == null
        ? null : n(durableGroup[0].draft_cleared_revision);
      const messagePts = (await tx`
        SELECT COALESCE(max(pts), 0)::bigint AS pts
        FROM account_events
        WHERE account_id = ${p.senderAccountId}
          AND dialog_id = ${dialogId}
          AND type = 'message.new'
          AND msg_id BETWEEN ${firstMsgId} AND ${lastMsgId}`)[0];
      const senderPts = Math.max(n(messagePts.pts), clearedRevision ?? 0);
      await tx`
        INSERT INTO media_group_send_requests (
          sender_account_id, client_group_id, dialog_id, payload_fingerprint, status,
          first_msg_id, last_msg_id, sender_pts, draft_consume_operation_id,
          cleared_draft_revision
        ) VALUES (
          ${p.senderAccountId}, ${clientGroupId}, ${dialogId}, ${fingerprint}, 'completed',
          ${firstMsgId}, ${lastMsgId}, ${senderPts}, ${draftConsumeOperationId},
          ${clearedRevision}
        )
        ON CONFLICT (sender_account_id, client_group_id) DO NOTHING`;
      return {
        dialogId,
        clientGroupId,
        messages,
        senderPts,
        clearedDraftRevision: clearedRevision,
        duplicate: true,
        pushes: [],
      };
    }
    const tombstone = requestStillPresent ? null : (await tx`
      SELECT dialog_id, payload_fingerprint
      FROM media_group_send_tombstones
      WHERE sender_account_id = ${p.senderAccountId}
        AND client_group_id = ${clientGroupId}
      FOR SHARE`)[0];
    if (tombstone) {
      const existingFingerprint = buf(tombstone.payload_fingerprint);
      if (tombstone.dialog_id !== dialogId
        || existingFingerprint.length !== fingerprint.length
        || !timingSafeEqual(existingFingerprint, fingerprint)) {
        throw new SyncError(
          "client group id already used with different media",
          409,
          "media_group_idempotency_conflict",
        );
      }
      throw new SyncError(
        "media group result is no longer available",
        409,
        "media_group_result_expired",
      );
    }
    const claim = await tx`
      INSERT INTO media_group_send_requests (
        sender_account_id, client_group_id, dialog_id, payload_fingerprint, status,
        draft_consume_operation_id
      )
      VALUES (
        ${p.senderAccountId}, ${clientGroupId}, ${dialogId}, ${fingerprint}, 'pending',
        ${draftConsumeOperationId}
      )
      ON CONFLICT (sender_account_id, client_group_id) DO NOTHING
      RETURNING client_group_id`;
    if (claim.length === 0) {
      const existing = (await tx`
        SELECT dialog_id, payload_fingerprint, status, first_msg_id, last_msg_id,
               sender_pts, cleared_draft_revision
        FROM media_group_send_requests
        WHERE sender_account_id = ${p.senderAccountId}
          AND client_group_id = ${clientGroupId}
        FOR UPDATE`)[0];
      const existingFingerprint = buf(existing.payload_fingerprint);
      if (existing.dialog_id !== dialogId
        || existingFingerprint.length !== fingerprint.length
        || !timingSafeEqual(existingFingerprint, fingerprint)) {
        throw new SyncError(
          "client group id already used with different media",
          409,
          "media_group_idempotency_conflict",
        );
      }
      if (existing.status !== "completed") {
        throw new SyncError("media group send already in progress", 409);
      }
      const keys: MessageKey[] = [];
      for (let msgId = n(existing.first_msg_id); msgId <= n(existing.last_msg_id); msgId += 1) {
        keys.push({ dialogId, msgId });
      }
      const loaded = await loadMessages(tx, keys);
      const messages = keys.map((key) => loaded.get(`${key.dialogId}:${key.msgId}`))
        .filter((message): message is MessageDTO => message != null);
      return {
        dialogId,
        clientGroupId,
        messages,
        senderPts: n(existing.sender_pts),
        clearedDraftRevision: existing.cleared_draft_revision == null
          ? null : n(existing.cleared_draft_revision),
        duplicate: true,
        pushes: [],
      };
    }

    const directPair = (await tx`
      SELECT account_low, account_high
      FROM direct_dialog_pairs WHERE dialog_id = ${dialogId}`)[0];
    await lockAccountMutations(tx, directPair
      ? [directPair.account_low, directPair.account_high]
      : [p.senderAccountId]);
    const itemBudget = (await tx`
      SELECT COALESCE(sum(item_count), 0)::int AS count
      FROM media_group_send_budgets
      WHERE account_id = ${p.senderAccountId}
        AND accepted_at > now() - interval '1 minute'`)[0];
    if (n(itemBudget.count) + items.length > MAX_MEDIA_GROUP_ITEMS_PER_MINUTE) {
      throw new SyncError("media group item budget exceeded", 429, "media_group_rate_limited");
    }
    await tx`
      INSERT INTO media_group_send_budgets(account_id, device_id, item_count)
      VALUES (${p.senderAccountId}, ${p.senderDeviceId}, ${items.length})`;

    const sortedMediaIds = items.map((item) => item.mediaId).sort();
    const mediaRows = await tx`
      SELECT id, owner_account_id, kind, status, purpose
      FROM media_objects
      WHERE id = ANY(${tx.array(sortedMediaIds, "uuid")}::uuid[])
      ORDER BY id
      FOR UPDATE`;
    if (mediaRows.length !== items.length
      || mediaRows.some((row: any) =>
        row.owner_account_id !== p.senderAccountId
        || row.status !== "ready"
        || row.purpose !== "message"
        || row.kind === "voice"
      )) {
      throw new SyncError("group media is unavailable", 409, "media_group_item_unavailable");
    }
    await tx`
      UPDATE media_objects SET last_accessed_at = now()
      WHERE id = ANY(${tx.array(sortedMediaIds, "uuid")}::uuid[])`;
    const mediaById = new Map(mediaRows.map((row: any) => [String(row.id), row]));

    await lockDialogForMutation(tx, p.senderAccountId, dialogId);
    const blocked = await tx`
      SELECT 1
      FROM direct_dialog_pairs pair
      JOIN account_blocks block ON
        (block.blocker_account_id = pair.account_low AND block.blocked_account_id = pair.account_high)
        OR (block.blocker_account_id = pair.account_high AND block.blocked_account_id = pair.account_low)
      WHERE pair.dialog_id = ${dialogId}
      LIMIT 1`;
    if (blocked.length) throw new SyncError("conversation is blocked");
    if (replyToMsgId != null) {
      const target = (await tx`
        SELECT state FROM messages
        WHERE dialog_id = ${dialogId} AND msg_id = ${replyToMsgId}`)[0];
      if (!target || target.state !== "visible") {
        throw new SyncError(
          "original message is unavailable",
          409,
          "invalid_reply_target",
          { reply_to_msg_id: replyToMsgId },
        );
      }
    }
    if (mentions.length) {
      const mentionIds = mentions.map((mention) => mention.accountId);
      const active = await tx`
        SELECT account_id FROM dialog_members
        WHERE dialog_id = ${dialogId} AND left_at IS NULL
          AND account_id = ANY(${tx.array(mentionIds, "uuid")}::uuid[])`;
      if (active.length !== mentionIds.length) {
        throw new SyncError("mention target is not an active member");
      }
    }

    const allocation = (await tx`
      UPDATE dialogs
      SET last_msg_id = last_msg_id + ${items.length}, updated_at = now()
      WHERE id = ${dialogId}
      RETURNING last_msg_id`)[0];
    const lastMsgId = n(allocation.last_msg_id);
    const firstMsgId = lastMsgId - items.length + 1;
    for (let index = 0; index < items.length; index += 1) {
      const item = items[index];
      const msgId = firstMsgId + index;
      const caption = index === 0 ? body : "";
      const sealed = seal(caption, bodyAAD(dialogId, msgId, p.senderAccountId));
      const media = mediaById.get(item.mediaId)!;
      await tx`
        INSERT INTO messages (
          dialog_id, msg_id, sender_account_id, sender_device_id, client_msg_id, kind,
          body_key_id, body_nonce, body_ciphertext, reply_to_msg_id, media_id,
          media_group_id, media_group_index, media_group_count
        )
        VALUES (
          ${dialogId}, ${msgId}, ${p.senderAccountId}, ${p.senderDeviceId},
          ${item.clientMsgId}, ${media.kind}, ${sealed.keyId}, ${sealed.nonce},
          ${sealed.ciphertext}, ${index === 0 ? replyToMsgId : null}, ${item.mediaId},
          ${clientGroupId}, ${index}, ${items.length}
        )`;
    }
    if (mentions.length) {
      await tx`
        INSERT INTO message_mentions (dialog_id, msg_id, account_id, entity_offset, length)
        SELECT ${dialogId}, ${firstMsgId}, account_id, entity_offset, entity_length
        FROM unnest(
          ${tx.array(mentions.map((mention) => mention.accountId), "uuid")}::uuid[],
          ${tx.array(mentions.map((mention) => mention.offset), "int4")}::int[],
          ${tx.array(mentions.map((mention) => mention.length), "int4")}::int[]
        ) AS mention(account_id, entity_offset, entity_length)`;
    }

    const pushes: Push[] = [];
    let senderPts = 0;
    for (let index = 0; index < items.length; index += 1) {
      const eventPushes = await fanoutDialogEvent(tx, {
        dialogId,
        type: "message.new",
        msgId: firstMsgId + index,
        actorAccountId: p.senderAccountId,
        sourceDeviceId: p.senderDeviceId,
        alertRecipients: index === 0,
      });
      pushes.push(...eventPushes);
      senderPts = eventPushes.find((push) => push.accountId === p.senderAccountId)?.pts ?? senderPts;
    }
    const consumed = await consumeDraftInTransaction(tx, {
      accountId: p.senderAccountId,
      deviceId: p.senderDeviceId,
      dialogId,
      operationId: draftConsumeOperationId,
    });
    if (consumed) {
      pushes.push(...consumed.pushes);
      senderPts = consumed.revision;
    }
    await tx`
      UPDATE messages SET
        draft_consume_operation_id = ${draftConsumeOperationId},
        draft_cleared_revision = ${consumed?.revision ?? null}
      WHERE dialog_id = ${dialogId} AND msg_id = ${firstMsgId}`;
    await tx`
      UPDATE media_group_send_requests SET
        status = 'completed',
        first_msg_id = ${firstMsgId},
        last_msg_id = ${lastMsgId},
        sender_pts = ${senderPts},
        cleared_draft_revision = ${consumed?.revision ?? null}
      WHERE sender_account_id = ${p.senderAccountId}
        AND client_group_id = ${clientGroupId}`;
    await notifySyncWakeups(tx, pushes);
    const keys = items.map((_, index) => ({ dialogId, msgId: firstMsgId + index }));
    const loaded = await loadMessages(tx, keys);
    return {
      dialogId,
      clientGroupId,
      messages: keys.map((key) => loaded.get(`${key.dialogId}:${key.msgId}`)!),
      senderPts,
      clearedDraftRevision: consumed?.revision ?? null,
      duplicate: false,
      pushes,
    };
  });
}

/** Listen for bounded account-sync wake-ups emitted transactionally with message events. */
export function startSyncNotificationListener(
  databaseUrl: string | null,
  onWakeup: (wakeup: SyncWakeup) => void | Promise<void>,
): () => void {
  if (!databaseUrl) return () => {};
  let stopped = false;
  let client: Client | null = null;
  let retry: ReturnType<typeof setTimeout> | null = null;
  let attempts = 0;

  const schedule = () => {
    if (stopped || retry) return;
    const delay = Math.min(30_000, 500 * 2 ** Math.min(attempts, 6));
    attempts += 1;
    retry = setTimeout(() => { retry = null; void connect(); }, delay);
    retry.unref?.();
  };
  const connect = async () => {
    if (stopped) return;
    const next = new Client({ connectionString: databaseUrl, application_name: "toj-sync-notify" });
    client = next;
    next.on("notification", (notification) => {
      if (!isSyncWakeupChannel(notification.channel) || !notification.payload) return;
      try {
        const value = JSON.parse(notification.payload) as SyncWakeup;
        if (!ACCOUNT_UUID_PATTERN.test(value.accountId) || !Number.isSafeInteger(value.pts)
          || value.pts < 0 || !Number.isSafeInteger(value.ptsCount)
          || value.ptsCount < 1 || value.ptsCount > 1_000) return;
        void onWakeup(value);
      } catch { /* notification hints are never authoritative */ }
    });
    let handledDisconnect = false;
    const disconnected = () => {
      if (handledDisconnect) return;
      handledDisconnect = true;
      if (client !== next) return;
      client = null;
      schedule();
    };
    next.once("error", disconnected);
    next.once("end", disconnected);
    try {
      await next.connect();
      await next.query(`LISTEN ${SYNC_NOTIFY_CHANNEL}`);
      attempts = 0;
    } catch {
      try { await next.end(); } catch { /* already closed */ }
      disconnected();
    }
  };
  void connect();
  return () => {
    stopped = true;
    if (retry) clearTimeout(retry);
    retry = null;
    if (client) void client.end().catch(() => {});
    client = null;
  };
}

export type MessageMutationResult = {
  dialogId: string; msgId: number; actorPts: number; duplicate: boolean;
  message: MessageDTO; pushes: Push[];
};

async function mutateMessage(sql: SQL, p: {
  actorAccountId: string; actorDeviceId: string; dialogId: string; msgId: number;
  clientMutationId: string; operation: "edit" | "delete"; body?: string;
  expectedEditVersion?: number;
}): Promise<MessageMutationResult> {
  return await sql.begin(async (tx) => {
    const msgId = optionalMessageId(p.msgId)!;
    const mutationId = String(p.clientMutationId ?? "");
    if (!UUID_PATTERN.test(mutationId)) throw new SyncError("invalid client mutation id");

    const claim = await tx`
      INSERT INTO message_mutation_requests
        (actor_account_id, client_mutation_id, operation, dialog_id, msg_id, status)
      VALUES (${p.actorAccountId}, ${mutationId}, ${p.operation}, ${p.dialogId}, ${msgId}, 'pending')
      ON CONFLICT (actor_account_id, client_mutation_id) DO NOTHING
      RETURNING status`;
    if (claim.length === 0) {
      const existing = (await tx`
        SELECT operation, dialog_id, msg_id, status, actor_pts
        FROM message_mutation_requests
        WHERE actor_account_id = ${p.actorAccountId} AND client_mutation_id = ${mutationId}
        FOR UPDATE`)[0];
      if (existing.operation !== p.operation || existing.dialog_id !== p.dialogId || n(existing.msg_id) !== msgId) {
        throw new SyncError("client mutation id already used");
      }
      if (existing.status !== "completed") throw new SyncError("message mutation already in progress");
      const message = await loadMessage(tx, p.dialogId, msgId);
      if (!message) throw new SyncError("message not found");
      return {
        dialogId: p.dialogId, msgId, actorPts: n(existing.actor_pts), duplicate: true,
        message, pushes: [],
      };
    }

    await requireActiveAccount(tx, p.actorAccountId);
    await requireActiveDevice(tx, p.actorAccountId, p.actorDeviceId);
    await lockDialogForMutation(tx, p.actorAccountId, p.dialogId);
    const members = await tx`
      SELECT account_id FROM dialog_members
      WHERE dialog_id = ${p.dialogId} AND left_at IS NULL
      ORDER BY account_id FOR UPDATE`;
    const row = (await tx`
      SELECT sender_account_id, kind, state, edit_version, media_id
      FROM messages WHERE dialog_id = ${p.dialogId} AND msg_id = ${msgId}
      FOR UPDATE`)[0];
    if (!row) throw new SyncError("message not found");
    if (row.sender_account_id !== p.actorAccountId) throw new SyncError("only the sender can change this message");
    if (row.state !== "visible") throw new SyncError("message already deleted");
    if (p.operation === "edit") {
      if (row.kind !== "text") throw new SyncError("only text messages can be edited");
      const body = requireTextBody(p.body);
      const expected = Number(p.expectedEditVersion);
      if (!Number.isSafeInteger(expected) || expected < 0) throw new SyncError("expected edit version required");
      if (n(row.edit_version) !== expected) throw new SyncError("message was edited on another device");
      const sealed = seal(body, bodyAAD(p.dialogId, msgId, p.actorAccountId));
      await tx`
        UPDATE messages SET body_key_id = ${sealed.keyId}, body_nonce = ${sealed.nonce},
          body_ciphertext = ${sealed.ciphertext}, edit_version = edit_version + 1,
          edited_at = now()
        WHERE dialog_id = ${p.dialogId} AND msg_id = ${msgId}`;
    } else {
      // Replace the live ciphertext as well as returning a tombstone. This prevents deleted text
      // from remaining decryptable in the primary database (backups retain their normal lifecycle).
      const sealed = seal("", bodyAAD(p.dialogId, msgId, p.actorAccountId));
      await tx`
        UPDATE messages SET body_key_id = ${sealed.keyId}, body_nonce = ${sealed.nonce},
          body_ciphertext = ${sealed.ciphertext}, media_id = NULL,
          state = 'deleted_for_all', deleted_at = now()
        WHERE dialog_id = ${p.dialogId} AND msg_id = ${msgId}`;
      if (row.media_id) {
        // A forwarded copy owns a live reference of its own. Delete the encrypted object only when
        // this was the final visible reference, otherwise that forwarded message must keep working.
        await tx`
          DELETE FROM media_objects mo
          WHERE mo.id = ${row.media_id}
            AND NOT EXISTS (
              SELECT 1 FROM messages m WHERE m.media_id = mo.id AND m.state = 'visible'
            )`;
      }
    }

    const eventType = p.operation === "edit" ? "message.edited" : "message.deleted";
    const pushes = await fanoutDialogEvent(tx, {
      dialogId: p.dialogId,
      type: eventType,
      msgId,
      actorAccountId: p.actorAccountId,
      sourceDeviceId: p.actorDeviceId,
      alertRecipients: false,
      recipientAccountIds: members.map((member: any) => member.account_id),
    });
    const actorPts = pushes.find((push) => push.accountId === p.actorAccountId)?.pts ?? 0;
    await tx`
      UPDATE message_mutation_requests SET status = 'completed', actor_pts = ${actorPts}
      WHERE actor_account_id = ${p.actorAccountId} AND client_mutation_id = ${mutationId}`;
    const message = await loadMessage(tx, p.dialogId, msgId);
    if (!message) throw new SyncError("message not found after mutation");
    return { dialogId: p.dialogId, msgId, actorPts, duplicate: false, message, pushes };
  });
}

export async function editMessage(sql: SQL, p: {
  actorAccountId: string; actorDeviceId: string; dialogId: string; msgId: number;
  clientMutationId: string; body: string; expectedEditVersion: number;
}): Promise<MessageMutationResult> {
  return mutateMessage(sql, { ...p, operation: "edit" });
}

export async function deleteMessage(sql: SQL, p: {
  actorAccountId: string; actorDeviceId: string; dialogId: string; msgId: number;
  clientMutationId: string;
}): Promise<MessageMutationResult> {
  return mutateMessage(sql, { ...p, operation: "delete" });
}

export async function setReaction(sql: SQL, p: {
  actorAccountId: string; actorDeviceId: string; dialogId: string; msgId: number;
  clientMutationId: string; emoji: string | null;
}): Promise<MessageMutationResult> {
  return await sql.begin(async (tx) => {
    const msgId = optionalMessageId(p.msgId)!;
    if (!UUID_PATTERN.test(p.clientMutationId)) throw new SyncError("invalid client mutation id");
    const emoji = p.emoji == null ? null : String(p.emoji).trim();
    if (emoji != null && (emoji.length < 1 || [...emoji].length > 8)) throw new SyncError("invalid reaction");

    const claim = await tx`
      INSERT INTO message_mutation_requests
        (actor_account_id, client_mutation_id, operation, dialog_id, msg_id, status)
      VALUES (${p.actorAccountId}, ${p.clientMutationId}, 'reaction', ${p.dialogId}, ${msgId}, 'pending')
      ON CONFLICT (actor_account_id, client_mutation_id) DO NOTHING RETURNING status`;
    if (claim.length === 0) {
      const existing = (await tx`
        SELECT operation, dialog_id, msg_id, status, actor_pts FROM message_mutation_requests
        WHERE actor_account_id = ${p.actorAccountId} AND client_mutation_id = ${p.clientMutationId}
        FOR UPDATE`)[0];
      if (existing.operation !== "reaction" || existing.dialog_id !== p.dialogId || n(existing.msg_id) !== msgId) {
        throw new SyncError("client mutation id already used");
      }
      if (existing.status !== "completed") throw new SyncError("message mutation already in progress");
      const message = await loadMessage(tx, p.dialogId, msgId);
      if (!message) throw new SyncError("message not found");
      return { dialogId: p.dialogId, msgId, actorPts: n(existing.actor_pts), duplicate: true, message, pushes: [] };
    }

    await requireActiveAccount(tx, p.actorAccountId);
    await requireActiveDevice(tx, p.actorAccountId, p.actorDeviceId);
    await lockDialogForMutation(tx, p.actorAccountId, p.dialogId);
    const members = await tx`
      SELECT account_id FROM dialog_members WHERE dialog_id = ${p.dialogId} AND left_at IS NULL
      ORDER BY account_id FOR UPDATE`;
    const messageRow = (await tx`
      SELECT state FROM messages WHERE dialog_id = ${p.dialogId} AND msg_id = ${msgId} FOR UPDATE`)[0];
    if (!messageRow || messageRow.state !== "visible") throw new SyncError("message not found");
    if (emoji == null) {
      await tx`DELETE FROM message_reactions WHERE dialog_id = ${p.dialogId} AND msg_id = ${msgId} AND account_id = ${p.actorAccountId}`;
    } else {
      await tx`
        INSERT INTO message_reactions (dialog_id, msg_id, account_id, emoji)
        VALUES (${p.dialogId}, ${msgId}, ${p.actorAccountId}, ${emoji})
        ON CONFLICT (dialog_id, msg_id, account_id) DO UPDATE SET emoji = excluded.emoji, created_at = now()`;
    }

    const pushes = await fanoutDialogEvent(tx, {
      dialogId: p.dialogId,
      type: "reaction.updated",
      msgId,
      actorAccountId: p.actorAccountId,
      sourceDeviceId: p.actorDeviceId,
      alertRecipients: false,
      recipientAccountIds: members.map((member: any) => member.account_id),
      data: { reactor_account_id: p.actorAccountId, emoji },
    });
    const actorPts = pushes.find((push) => push.accountId === p.actorAccountId)?.pts ?? 0;
    await tx`
      UPDATE message_mutation_requests SET status = 'completed', actor_pts = ${actorPts}
      WHERE actor_account_id = ${p.actorAccountId} AND client_mutation_id = ${p.clientMutationId}`;
    const message = await loadMessage(tx, p.dialogId, msgId);
    if (!message) throw new SyncError("message not found");
    return { dialogId: p.dialogId, msgId, actorPts, duplicate: false, message, pushes };
  });
}

export async function getState(sql: SQL, accountId: string): Promise<{ pts: number }> {
  const r = (await sql`SELECT pts FROM account_sync_states WHERE account_id = ${accountId}`)[0];
  if (!r) throw new SyncError("unknown account");
  return { pts: n(r.pts) };
}

export type Difference =
  | { kind: "difference_too_long"; state: { pts: number } }
  | {
      kind: "difference" | "difference_slice";
      state: { pts: number };
      updates: any[];
      profiles: ProfileDTO[];
      hasMore: boolean;
    };

export type ProfileDTO = {
  accountId: string;
  firstName: string;
  lastName: string;
  displayName: string;
  bio: string;
  birthday: string | null;
  colorIndex: number;
  updatedAt: string;
};

function collectAccountIds(value: unknown, into: Set<string>): void {
  if (Array.isArray(value)) {
    for (const item of value) collectAccountIds(item, into);
    return;
  }
  if (!value || typeof value !== "object") return;
  for (const [key, child] of Object.entries(value as Record<string, unknown>)) {
    if ((key.endsWith("account_id") || key.endsWith("AccountId"))
      && typeof child === "string" && ACCOUNT_UUID_PATTERN.test(child)) {
      into.add(child);
    } else {
      collectAccountIds(child, into);
    }
  }
}

export async function loadProfiles(sql: SQL, accountIds: Iterable<string>): Promise<ProfileDTO[]> {
  const ids = [...new Set(accountIds)].filter((id) => ACCOUNT_UUID_PATTERN.test(id)).sort();
  if (ids.length === 0) return [];
  const rows = await sql`
    SELECT id, first_name, last_name, display_name, bio, birthday, profile_color, updated_at
    FROM accounts
    WHERE id = ANY(${sql.array(ids, "uuid")}::uuid[])
    ORDER BY id`;
  return rows.map((profile: any) => ({
    accountId: profile.id,
    firstName: profile.first_name,
    lastName: profile.last_name,
    displayName: profile.display_name,
    bio: profile.bio,
    birthday: profile.birthday == null ? null : (
      profile.birthday instanceof Date
        ? profile.birthday.toISOString().slice(0, 10)
        : String(profile.birthday).slice(0, 10)
    ),
    colorIndex: n(profile.profile_color),
    updatedAt: iso(profile.updated_at),
  }));
}

/** review B3 (pruned floor → too_long) + I3 (byte + count budget, slicing). */
export async function getDifference(
  sql: SQL, accountId: string, sincePts: number,
  opts: { maxEvents?: number; maxBytes?: number; cloudDraftsEnabled?: boolean } = {},
): Promise<Difference> {
  const maxEvents = boundedInteger(opts.maxEvents, 200, 1, 200);
  const maxBytes = boundedInteger(opts.maxBytes, 256 * 1024, 1, 512 * 1024);
  const st = (await sql`SELECT pts, pruned_through_pts FROM account_sync_states WHERE account_id = ${accountId}`)[0];
  if (!st) throw new SyncError("unknown account");
  const statePts = n(st.pts);
  if (sincePts < n(st.pruned_through_pts)) return { kind: "difference_too_long", state: { pts: statePts } };

  const rows = await sql`
    WITH page AS MATERIALIZED (
      SELECT *
      FROM account_events
      WHERE account_id = ${accountId} AND pts > ${sincePts}
      ORDER BY pts ASC
      LIMIT ${maxEvents}
    ), referenced_accounts AS (
      SELECT actor_account_id AS account_id FROM page WHERE actor_account_id IS NOT NULL
      UNION
      SELECT peer_account.id
      FROM page
      JOIN dialogs peer_dialog ON peer_dialog.id = page.dialog_id
      JOIN direct_dialog_pairs peer_pair ON peer_pair.dialog_id = peer_dialog.id
      JOIN accounts peer_account ON peer_account.id = CASE
        WHEN peer_pair.account_low = ${accountId} THEN peer_pair.account_high
        ELSE peer_pair.account_low
      END
      UNION
      SELECT message.sender_account_id
      FROM page JOIN messages message
        ON message.dialog_id = page.dialog_id AND message.msg_id = page.msg_id
      UNION
      SELECT message.forwarded_from_account_id
      FROM page JOIN messages message
        ON message.dialog_id = page.dialog_id AND message.msg_id = page.msg_id
      WHERE message.forwarded_from_account_id IS NOT NULL
      UNION
      SELECT (page.data->>'subject_account_id')::uuid
      FROM page
      WHERE page.data ? 'subject_account_id'
      UNION
      SELECT member_id::uuid
      FROM page
      CROSS JOIN LATERAL jsonb_array_elements_text(
        COALESCE(page.data->'member_account_ids', '[]'::jsonb)
      ) AS member(member_id)
    ), profile_payload AS (
      SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'accountId', profile.id,
        'firstName', profile.first_name,
        'lastName', profile.last_name,
        'displayName', profile.display_name,
        'bio', profile.bio,
        'birthday', profile.birthday,
        'colorIndex', profile.profile_color,
        'updatedAt', profile.updated_at
      ) ORDER BY profile.id), '[]'::jsonb) AS profiles
      FROM accounts profile
      WHERE profile.id IN (SELECT account_id FROM referenced_accounts)
    )
    SELECT ae.pts, ae.type, ae.dialog_id, ae.msg_id, ae.actor_account_id, ae.data,
           d.type AS dialog_type, d.revision AS group_revision,
           self.role AS self_role, self.left_at AS self_left_at, d.closed_at,
           peer.id AS peer_account_id,
           CASE WHEN d.type = 'direct' THEN NULLIF(peer.display_name, '') ELSE d.title END AS dialog_title,
           profile_payload.profiles
    FROM page ae
    CROSS JOIN profile_payload
    LEFT JOIN dialogs d ON d.id = ae.dialog_id
    LEFT JOIN direct_dialog_pairs pair ON pair.dialog_id = d.id
    LEFT JOIN dialog_members self
      ON self.dialog_id = d.id AND self.account_id = ${accountId}
    LEFT JOIN accounts peer ON peer.id = CASE
      WHEN pair.account_low = ${accountId} THEN pair.account_high
      WHEN pair.account_high = ${accountId} THEN pair.account_low
      ELSE NULL
    END
    ORDER BY ae.pts ASC`;

  const revokedDialogs = new Set(rows
    .filter((event: any) =>
      event.dialog_type === "group"
      && (event.self_role == null || event.self_left_at != null || event.closed_at != null)
    )
    .map((event: any) => String(event.dialog_id)));
  const messageKeys: MessageKey[] = rows.flatMap((event) =>
    event.msg_id != null && [
      "message.new", "message.edited", "message.deleted", "reaction.updated",
    ].includes(event.type) && !revokedDialogs.has(event.dialog_id)
      ? [{ dialogId: event.dialog_id, msgId: n(event.msg_id) }]
      : []
  );
  const messages = await loadMessages(sql, messageKeys);
  const draftDialogIds = rows
    .filter((event: any) => event.type === "draft.updated" && !revokedDialogs.has(event.dialog_id))
    .map((event: any) => String(event.dialog_id));
  const drafts = opts.cloudDraftsEnabled === false
    ? new Map<string, DraftDTO>()
    : await loadDrafts(sql, accountId, draftDialogIds);

  const updates: any[] = [];
  let bytes = 0, lastPts = sincePts, truncated = false;
  for (const ev of rows) {
    const pts = n(ev.pts);
    let update: any;
    if (revokedDialogs.has(ev.dialog_id)) {
      update = {
        pts,
        ptsCount: 1,
        type: "dialog.access_revoked",
        dialog_id: ev.dialog_id,
        dialog_type: "group",
      };
    } else if (ev.type === "message.new" || ev.type === "message.edited" || ev.type === "message.deleted" || ev.type === "reaction.updated") {
      const message = messages.get(`${ev.dialog_id}:${n(ev.msg_id)}`) ?? null;
      if (!message) {
        update = {
          pts, ptsCount: 1, type: "message.missing", dialog_id: ev.dialog_id,
          dialog_type: ev.dialog_type,
          dialog_title: ev.dialog_title ?? undefined, peer_account_id: ev.peer_account_id ?? undefined,
          msg_id: n(ev.msg_id),
          ...eventData(ev.data),
        };
      } else {
        update = {
          pts, ptsCount: 1, type: ev.type, dialog_id: ev.dialog_id,
          dialog_type: ev.dialog_type,
          dialog_title: ev.dialog_title ?? undefined, peer_account_id: ev.peer_account_id ?? undefined,
          message,
          ...eventData(ev.data),
        };
      }
    } else if (ev.type === "draft.updated" && opts.cloudDraftsEnabled === false) {
      // Preserve the contiguous account pts stream while the lane is killed. No draft payload
      // leaks through the disabled capability; re-enable is recovered by replacement bootstrap.
      update = { pts, ptsCount: 1, type: "capability.skipped" };
    } else if (ev.type === "draft.updated") {
      update = {
        pts,
        ptsCount: 1,
        type: "draft.updated",
        dialog_id: ev.dialog_id,
        dialog_type: ev.dialog_type,
        dialog_title: ev.dialog_title ?? undefined,
        peer_account_id: ev.peer_account_id ?? undefined,
        draft: drafts.get(String(ev.dialog_id)) ?? null,
      };
    } else {
      update = {
        pts, ptsCount: 1, type: ev.type, dialog_id: ev.dialog_id,
        dialog_type: ev.dialog_type,
        dialog_title: ev.dialog_title ?? undefined,
        peer_account_id: ev.peer_account_id ?? undefined,
        msg_id: ev.msg_id ? n(ev.msg_id) : undefined,
        actor_account_id: ev.actor_account_id, ...eventData(ev.data),
      };
    }
    const updateBytes = Buffer.byteLength(JSON.stringify(update));
    if (bytes + updateBytes > maxBytes && updates.length >= 1) { truncated = true; break; } // budget hit; leave this for next slice
    updates.push(update);
    bytes += updateBytes;
    lastPts = pts;
  }
  const hasMore = truncated || (rows.length === maxEvents && lastPts < statePts);
  const eventProfiles: ProfileDTO[] = rows.length
    ? (typeof rows[0].profiles === "string" ? JSON.parse(rows[0].profiles) : rows[0].profiles)
    : [];
  const draftProfileIds = new Set<string>();
  collectAccountIds([...drafts.values()], draftProfileIds);
  const profileById = new Map(eventProfiles.map((profile) => [profile.accountId, profile]));
  for (const profile of await loadProfiles(sql, draftProfileIds)) {
    profileById.set(profile.accountId, profile);
  }
  return {
    kind: hasMore ? "difference_slice" : "difference",
    state: { pts: hasMore ? lastPts : statePts },
    updates,
    profiles: [...profileById.values()].sort((left, right) => left.accountId.localeCompare(right.accountId)),
    hasMore,
  };
}

export type BootstrapStart = { token: string; state: { pts: number }; expiresAt: string; dialogCount: number };

/**
 * review B1/I2: new-device bootstrap is a resumable snapshot. The snapshot pins the account pts and
 * each dialog's message ceiling, so page-by-page history cannot duplicate or drop messages that land
 * while a weak network is still downloading.
 */
export async function startBootstrap(sql: SQL, accountId: string): Promise<BootstrapStart> {
  return await sql.begin(async (tx) => {
    // The cursor and every captured dialog/preference value must come from one PostgreSQL statement
    // snapshot. Separate SELECT/INSERT statements under READ COMMITTED could otherwise pair an old
    // pts with a preference that committed a moment later.
    const snap = (await tx`
      WITH captured_state AS MATERIALIZED (
        SELECT pts
        FROM account_sync_states
        WHERE account_id = ${accountId}
      ), created AS (
        INSERT INTO bootstrap_snapshots (account_id, snapshot_pts)
        SELECT ${accountId}, pts FROM captured_state
        RETURNING id, snapshot_pts, expires_at
      ), captured_dialogs AS (
        INSERT INTO bootstrap_snapshot_dialogs (
          snapshot_id, dialog_id, ceiling_msg_id, sort_updated_at,
          preferences_captured, preference_is_pinned, preference_pinned_at,
          preference_is_muted, preference_is_archived, preference_updated_at
        )
        SELECT
          created.id, d.id, d.last_msg_id, d.updated_at,
          TRUE,
          COALESCE(preference.is_pinned, FALSE),
          preference.pinned_at,
          COALESCE(preference.is_muted, dm.notification_mode = 'muted'),
          COALESCE(preference.is_archived, FALSE),
          COALESCE(preference.updated_at, d.updated_at)
        FROM created
        JOIN dialog_members dm ON dm.account_id = ${accountId} AND dm.left_at IS NULL
        JOIN dialogs d ON d.id = dm.dialog_id
        LEFT JOIN dialog_preferences preference
          ON preference.dialog_id = dm.dialog_id AND preference.account_id = dm.account_id
        ORDER BY d.updated_at DESC, d.id DESC
        RETURNING snapshot_id
      )
      SELECT created.id, created.snapshot_pts, created.expires_at,
             (SELECT count(*)::int FROM captured_dialogs) AS dialog_count
      FROM created`)[0];
    if (!snap) throw new SyncError("unknown account");
    return {
      token: snap.id,
      state: { pts: n(snap.snapshot_pts) },
      expiresAt: iso(snap.expires_at),
      dialogCount: n(snap.dialog_count),
    };
  });
}

export type BootstrapDialog = {
  dialog_id: string; type: string; title: string | null; last_msg_id: number;
  updated_at: string; unread_count: number; revision: number; member_count: number;
  self_role: string; notification_mode: string; photo: MediaDTO | null;
  draft: DraftDTO | null;
  preferences: {
    dialogId: string; pinned: boolean; pinnedAt: string | null;
    muted: boolean; archived: boolean; updatedAt: string;
  };
  members: {
    account_id: string; role: string; last_read_msg_id: number;
    joined_at: string; is_active: boolean;
  }[];
  profiles: { accountId: string; firstName: string; lastName: string; displayName: string; bio: string;
    birthday: string | null; colorIndex: number; updatedAt: string }[];
  messages: MessageDTO[];
};

export type BootstrapPage = {
  token: string; state: { pts: number }; dialogs: BootstrapDialog[];
  nextCursor?: string; hasMore: boolean;
};

export async function getBootstrapDialogsPage(
  sql: SQL,
  accountId: string,
  token: string,
  opts: {
    cursor?: string;
    limit?: number;
    previewMessages?: number;
    cloudDraftsEnabled?: boolean;
  } = {},
): Promise<BootstrapPage> {
  // Keep worst-case hydration bounded. The client pages dialogs and history separately, so a
  // bootstrap response never needs thousands of per-message lookups in one request.
  const limit = boundedInteger(opts.limit, 20, 1, 20);
  const previewMessages = boundedInteger(opts.previewMessages, 1, 0, 5);
  const cursor = decodeCursor<{ updatedAt: string; dialogId: string }>(opts.cursor);

  const snap = (await sql`
    SELECT id, snapshot_pts FROM bootstrap_snapshots
    WHERE id = ${token} AND account_id = ${accountId} AND expires_at > now()`)[0];
  if (!snap) throw new SyncError("unknown or expired bootstrap token");

  const rows = cursor
    ? await sql`
        SELECT bsd.dialog_id, bsd.ceiling_msg_id, bsd.sort_updated_at, d.type,
               CASE WHEN d.type = 'direct' THEN NULLIF(peer.display_name, '') ELSE d.title END AS title,
               d.updated_at, d.revision, d.photo_media_id,
               self.role AS self_role, self.notification_mode,
               CASE WHEN bsd.preferences_captured
                 THEN bsd.preference_is_pinned ELSE COALESCE(preference.is_pinned, FALSE)
               END AS preference_is_pinned,
               CASE WHEN bsd.preferences_captured
                 THEN bsd.preference_pinned_at ELSE preference.pinned_at
               END AS preference_pinned_at,
               CASE WHEN bsd.preferences_captured
                 THEN bsd.preference_is_muted
                 ELSE COALESCE(preference.is_muted, self.notification_mode = 'muted')
               END AS preference_is_muted,
               CASE WHEN bsd.preferences_captured
                 THEN bsd.preference_is_archived ELSE COALESCE(preference.is_archived, FALSE)
               END AS preference_is_archived,
               CASE WHEN bsd.preferences_captured
                 THEN bsd.preference_updated_at ELSE COALESCE(preference.updated_at, d.updated_at)
               END AS preference_updated_at,
               (SELECT count(*)::int FROM dialog_members active
                WHERE active.dialog_id = d.id AND active.left_at IS NULL) AS member_count
        FROM bootstrap_snapshot_dialogs bsd
        JOIN dialogs d ON d.id = bsd.dialog_id
        JOIN dialog_members self
          ON self.dialog_id = d.id AND self.account_id = ${accountId} AND self.left_at IS NULL
        LEFT JOIN dialog_preferences preference
          ON preference.dialog_id = d.id AND preference.account_id = ${accountId}
        LEFT JOIN direct_dialog_pairs pair ON pair.dialog_id = d.id
        LEFT JOIN accounts peer ON peer.id = CASE
          WHEN pair.account_low = ${accountId} THEN pair.account_high
          WHEN pair.account_high = ${accountId} THEN pair.account_low
          ELSE NULL
        END
        WHERE bsd.snapshot_id = ${token}
          AND (bsd.sort_updated_at, bsd.dialog_id) < (${cursor.updatedAt}::timestamptz, ${cursor.dialogId}::uuid)
        ORDER BY bsd.sort_updated_at DESC, bsd.dialog_id DESC
        LIMIT ${limit + 1}`
    : await sql`
        SELECT bsd.dialog_id, bsd.ceiling_msg_id, bsd.sort_updated_at, d.type,
               CASE WHEN d.type = 'direct' THEN NULLIF(peer.display_name, '') ELSE d.title END AS title,
               d.updated_at, d.revision, d.photo_media_id,
               self.role AS self_role, self.notification_mode,
               CASE WHEN bsd.preferences_captured
                 THEN bsd.preference_is_pinned ELSE COALESCE(preference.is_pinned, FALSE)
               END AS preference_is_pinned,
               CASE WHEN bsd.preferences_captured
                 THEN bsd.preference_pinned_at ELSE preference.pinned_at
               END AS preference_pinned_at,
               CASE WHEN bsd.preferences_captured
                 THEN bsd.preference_is_muted
                 ELSE COALESCE(preference.is_muted, self.notification_mode = 'muted')
               END AS preference_is_muted,
               CASE WHEN bsd.preferences_captured
                 THEN bsd.preference_is_archived ELSE COALESCE(preference.is_archived, FALSE)
               END AS preference_is_archived,
               CASE WHEN bsd.preferences_captured
                 THEN bsd.preference_updated_at ELSE COALESCE(preference.updated_at, d.updated_at)
               END AS preference_updated_at,
               (SELECT count(*)::int FROM dialog_members active
                WHERE active.dialog_id = d.id AND active.left_at IS NULL) AS member_count
        FROM bootstrap_snapshot_dialogs bsd
        JOIN dialogs d ON d.id = bsd.dialog_id
        JOIN dialog_members self
          ON self.dialog_id = d.id AND self.account_id = ${accountId} AND self.left_at IS NULL
        LEFT JOIN dialog_preferences preference
          ON preference.dialog_id = d.id AND preference.account_id = ${accountId}
        LEFT JOIN direct_dialog_pairs pair ON pair.dialog_id = d.id
        LEFT JOIN accounts peer ON peer.id = CASE
          WHEN pair.account_low = ${accountId} THEN pair.account_high
          WHEN pair.account_high = ${accountId} THEN pair.account_low
          ELSE NULL
        END
        WHERE bsd.snapshot_id = ${token}
        ORDER BY bsd.sort_updated_at DESC, bsd.dialog_id DESC
        LIMIT ${limit + 1}`;

  const pageRows = rows.slice(0, limit);
  const pageDrafts = opts.cloudDraftsEnabled === false
    ? new Map<string, DraftDTO>()
    : await loadDrafts(
      sql,
      accountId,
      pageRows.map((row: any) => String(row.dialog_id)),
    );
  const dialogs: BootstrapDialog[] = [];
  for (const row of pageRows) {
    const members = await sql`
      SELECT account_id, role, last_read_msg_id, joined_at
      FROM dialog_members
      WHERE dialog_id = ${row.dialog_id} AND left_at IS NULL
      ORDER BY account_id`;
    const profiles = await sql`
      SELECT a.id, a.first_name, a.last_name, a.display_name, a.bio, a.birthday,
             a.profile_color, a.updated_at
      FROM accounts a
      WHERE a.id IN (
        SELECT dm.account_id FROM dialog_members dm
        WHERE dm.dialog_id = ${row.dialog_id} AND dm.left_at IS NULL
        UNION
        SELECT message.sender_account_id FROM messages message
        WHERE message.dialog_id = ${row.dialog_id}
        UNION
        SELECT message.forwarded_from_account_id FROM messages message
        WHERE message.dialog_id = ${row.dialog_id}
          AND message.forwarded_from_account_id IS NOT NULL
        UNION
        SELECT (message.service_data->>'subject_account_id')::uuid FROM messages message
        WHERE message.dialog_id = ${row.dialog_id}
          AND message.service_data ? 'subject_account_id'
      )
      ORDER BY a.id`;
    // The five-message preview is intentionally sparse. Carry the authoritative unread count
    // separately so a new device can prioritize unread dialogs without first downloading history.
    const unread = (await sql`
      SELECT count(*)::int AS count
      FROM messages m
      JOIN dialog_members self
        ON self.dialog_id = m.dialog_id AND self.account_id = ${accountId} AND self.left_at IS NULL
      WHERE m.dialog_id = ${row.dialog_id}
        AND m.msg_id <= ${n(row.ceiling_msg_id)}
        AND m.msg_id > self.last_read_msg_id
        AND m.sender_account_id <> ${accountId}
        AND m.state = 'visible'`)[0];
    const msgRows = previewMessages === 0 ? [] : await sql`
      SELECT msg_id FROM messages
      WHERE dialog_id = ${row.dialog_id} AND msg_id <= ${n(row.ceiling_msg_id)}
      ORDER BY msg_id DESC
      LIMIT ${previewMessages}`;
    const messages: MessageDTO[] = [];
    for (const msgRow of [...msgRows].reverse()) {
      const msg = await loadMessage(sql, row.dialog_id, n(msgRow.msg_id));
      if (msg) messages.push(msg);
    }
    dialogs.push({
      dialog_id: row.dialog_id, type: row.type, title: row.title, last_msg_id: n(row.ceiling_msg_id),
      updated_at: iso(row.updated_at),
      unread_count: n(unread?.count),
      revision: n(row.revision),
      member_count: n(row.member_count),
      self_role: row.self_role,
      notification_mode: row.preference_is_muted ? "muted" : "all",
      preferences: {
        dialogId: row.dialog_id,
        pinned: Boolean(row.preference_is_pinned),
        pinnedAt: row.preference_pinned_at == null ? null : iso(row.preference_pinned_at),
        muted: Boolean(row.preference_is_muted),
        archived: Boolean(row.preference_is_archived),
        updatedAt: iso(row.preference_updated_at),
      },
      photo: await loadMediaDTO(sql, row.photo_media_id),
      draft: pageDrafts.get(String(row.dialog_id)) ?? null,
      members: members.map((m) => ({
        account_id: m.account_id,
        role: m.role,
        last_read_msg_id: n(m.last_read_msg_id),
        joined_at: iso(m.joined_at),
        is_active: true,
      })),
      profiles: profiles.map((p) => ({
        accountId: p.id, firstName: p.first_name, lastName: p.last_name,
        displayName: p.display_name, bio: p.bio,
        birthday: p.birthday == null ? null : (p.birthday instanceof Date
          ? p.birthday.toISOString().slice(0, 10) : String(p.birthday).slice(0, 10)),
        colorIndex: n(p.profile_color), updatedAt: iso(p.updated_at),
      })),
      messages,
    });
  }

  const next = rows.length > limit ? pageRows[pageRows.length - 1] : null;
  return {
    token, state: { pts: n(snap.snapshot_pts) }, dialogs,
    nextCursor: next ? encodeCursor({ updatedAt: iso(next.sort_updated_at), dialogId: next.dialog_id }) : undefined,
    hasMore: rows.length > limit,
  };
}

export type HistoryPage = {
  dialogId: string;
  messages: MessageDTO[];
  profiles: ProfileDTO[];
  nextBeforeMsgId?: number;
  nextAfterMsgId?: number;
  hasMore: boolean;
};

export async function getHistory(
  sql: SQL,
  accountId: string,
  dialogId: string,
  opts: { beforeMsgId?: number; afterMsgId?: number; limit?: number; maxBytes?: number } = {},
): Promise<HistoryPage> {
  await requireDialogReadAccess(sql, accountId, dialogId);
  if (opts.beforeMsgId !== undefined && opts.afterMsgId !== undefined) {
    throw new SyncError("history cursors are mutually exclusive");
  }
  const limit = clamp(opts.limit ?? 50, 1, 200);
  const maxBytes = opts.maxBytes ?? 512 * 1024;
  const rows = opts.afterMsgId !== undefined
    ? await sql`
        SELECT msg_id FROM messages
        WHERE dialog_id = ${dialogId} AND msg_id > ${opts.afterMsgId}
        ORDER BY msg_id ASC
        LIMIT ${limit + 1}`
    : opts.beforeMsgId
    ? await sql`
        SELECT msg_id FROM messages
        WHERE dialog_id = ${dialogId} AND msg_id < ${opts.beforeMsgId}
        ORDER BY msg_id DESC
        LIMIT ${limit + 1}`
    : await sql`
        SELECT msg_id FROM messages
        WHERE dialog_id = ${dialogId}
        ORDER BY msg_id DESC
        LIMIT ${limit + 1}`;

  const messages: MessageDTO[] = [];
  let bytes = 0;
  let hasMore = rows.length > limit;
  const loaded = await loadMessages(sql, rows.slice(0, limit).map((row: any) => ({
    dialogId,
    msgId: n(row.msg_id),
  })));
  for (const row of rows.slice(0, limit)) {
    const msg = loaded.get(`${dialogId}:${n(row.msg_id)}`);
    if (!msg) continue;
    const size = Buffer.byteLength(JSON.stringify(msg));
    if (messages.length > 0 && bytes + size > maxBytes) { hasMore = true; break; }
    messages.push(msg);
    bytes += size;
  }
  if (opts.afterMsgId === undefined) messages.reverse();
  const profileIds = new Set<string>();
  collectAccountIds(messages, profileIds);
  return {
    dialogId, messages, profiles: await loadProfiles(sql, profileIds), hasMore,
    nextBeforeMsgId: opts.afterMsgId === undefined && hasMore && messages.length
      ? messages[0].msg_id
      : undefined,
    nextAfterMsgId: opts.afterMsgId !== undefined && hasMore && messages.length
      ? messages[messages.length - 1].msg_id
      : undefined,
  };
}

export async function readHistory(sql: SQL, p: {
  accountId: string; deviceId?: string; dialogId: string; maxReadMsgId: number;
}): Promise<{ dialogId: string; maxReadMsgId: number; unreadCount: number; pushes: Push[] }> {
  return await sql.begin(async (tx) => {
    await requireActiveAccount(tx, p.accountId);
    if (p.deviceId) await requireActiveDevice(tx, p.accountId, p.deviceId);
    const access = await lockDialogForMutation(tx, p.accountId, p.dialogId);
    const member = (await tx`
      UPDATE dialog_members SET last_read_msg_id = ${p.maxReadMsgId}
      WHERE dialog_id = ${p.dialogId} AND account_id = ${p.accountId} AND left_at IS NULL
        AND last_read_msg_id < ${p.maxReadMsgId}
      RETURNING last_read_msg_id`)[0];
    if (!member) {
      const current = (await tx`
        SELECT last_read_msg_id FROM dialog_members
        WHERE dialog_id = ${p.dialogId} AND account_id = ${p.accountId} AND left_at IS NULL`)[0];
      const unread = (await tx`
        SELECT count(*)::int AS count FROM messages
        WHERE dialog_id = ${p.dialogId}
          AND msg_id > ${n(current.last_read_msg_id)}
          AND sender_account_id <> ${p.accountId}
          AND state = 'visible'`)[0];
      return {
        dialogId: p.dialogId,
        maxReadMsgId: n(current.last_read_msg_id),
        unreadCount: n(unread?.count),
        pushes: [],
      };
    }

    const pushes: Push[] = [];
    const unread = (await tx`
      SELECT count(*)::int AS count FROM messages
      WHERE dialog_id = ${p.dialogId}
        AND msg_id > ${n(member.last_read_msg_id)}
        AND sender_account_id <> ${p.accountId}
        AND state = 'visible'`)[0];
    const unreadCount = n(unread?.count);
    const data = JSON.stringify({
      reader_account_id: p.accountId,
      max_read_msg_id: n(member.last_read_msg_id),
      unread_count: unreadCount,
    });
    pushes.push(...await fanoutDialogEvent(tx, {
      dialogId: p.dialogId,
      type: "read.updated",
      actorAccountId: p.accountId,
      sourceDeviceId: p.deviceId,
      alertRecipients: false,
      recipientAccountIds: access.type === "group" ? [p.accountId] : undefined,
      data: JSON.parse(data),
    }));
    return { dialogId: p.dialogId, maxReadMsgId: n(member.last_read_msg_id), unreadCount, pushes };
  });
}
