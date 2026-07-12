import type { SQL } from "bun";
import { seal, open, bodyAAD } from "./crypto";
import { enqueuePushDeliveries } from "./push";

export class SyncError extends Error {}

// Global lock order for EVERY mutation (review B4), to stay deadlock-free:
//   1 send_requests/message_mutation_requests row → 2 accounts (ascending, FOR SHARE) → 3 direct_dialog_pairs
//   → 4 dialogs row → 5 dialog_members → 6 messages → 7 account_sync_states (ascending account_id)
//   → 8 account_events insert → 9 push_deliveries insert

export type MessageDTO = {
  dialog_id: string; msg_id: number; sender_account_id: string; client_msg_id: string;
  kind: string; text: string; reply_to_msg_id: number | null; edit_version: number;
  forwarded: boolean; reactions: { account_id: string; emoji: string }[];
  state: string; server_ts: string;
};
export type Push = { accountId: string; pts: number; ptsCount: number };

const n = (v: unknown) => Number(v as any);
const buf = (v: unknown) => Buffer.from(v as Uint8Array);
const iso = (v: unknown) => v instanceof Date ? v.toISOString() : String(v);
const clamp = (value: number, min: number, max: number) => Math.max(min, Math.min(max, value));

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

async function requireActiveMember(sql: SQL, accountId: string, dialogId: string): Promise<void> {
  const rows = await sql`
    SELECT 1 FROM dialog_members
    WHERE dialog_id = ${dialogId} AND account_id = ${accountId} AND left_at IS NULL`;
  if (rows.length === 0) throw new SyncError("not a member of this dialog");
}

async function requireActiveAccount(sql: SQL, accountId: string): Promise<void> {
  const rows = await sql`
    SELECT id FROM accounts
    WHERE id = ${accountId} AND status IN ('active','limited')
    FOR SHARE`;
  if (rows.length === 0) throw new SyncError("account unavailable");
}

async function loadMessage(sql: SQL, dialogId: string, msgId: number): Promise<MessageDTO | null> {
  const r = (await sql`
    SELECT dialog_id, msg_id, sender_account_id, client_msg_id, kind,
           body_key_id, body_nonce, body_ciphertext, reply_to_msg_id,
           forwarded_from_account_id, forwarded_from_dialog_id, forwarded_from_msg_id,
           edit_version, state, server_ts
    FROM messages WHERE dialog_id = ${dialogId} AND msg_id = ${msgId}`)[0];
  if (!r) return null;
  const text = r.state === "deleted_for_all"
    ? ""
    : open(
        { keyId: r.body_key_id, nonce: buf(r.body_nonce), ciphertext: buf(r.body_ciphertext) },
        bodyAAD(dialogId, n(r.msg_id), r.sender_account_id),
      ).toString("utf8");
  const reactions = await sql`
    SELECT account_id, emoji FROM message_reactions
    WHERE dialog_id = ${dialogId} AND msg_id = ${msgId}
    ORDER BY created_at, account_id`;
  return {
    dialog_id: dialogId, msg_id: n(r.msg_id), sender_account_id: r.sender_account_id,
    client_msg_id: r.client_msg_id, kind: r.kind, text,
    reply_to_msg_id: r.reply_to_msg_id == null ? null : n(r.reply_to_msg_id), edit_version: r.edit_version,
    // Source identifiers stay server-side. Recipients only need the presentation marker; exposing
    // source dialog/account ids would create a cross-dialog privacy leak.
    forwarded: r.forwarded_from_dialog_id != null && r.forwarded_from_msg_id != null,
    reactions: reactions.map((reaction) => ({ account_id: reaction.account_id, emoji: reaction.emoji })),
    state: r.state, server_ts: iso(r.server_ts),
  };
}

const MAX_TEXT_BYTES = 16 * 1024;
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
export async function getOrCreateDirectDialog(sql: SQL, aId: string, bId: string): Promise<{ dialogId: string; created: boolean }> {
  if (aId === bId) throw new SyncError("cannot open a direct dialog with yourself");
  const [low, high] = aId < bId ? [aId, bId] : [bId, aId];
  return await sql.begin(async (tx) => {
    await requireActiveAccount(tx, low);
    await requireActiveAccount(tx, high);
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
      await tx`INSERT INTO account_events (account_id, pts, type, dialog_id, actor_account_id) VALUES (${acc}, ${n(upd[0].pts)}, 'dialog.created', ${dialogId}, ${aId})`;
    }
    return { dialogId, created: true };
  });
}

export type SendResult = {
  dialogId: string; clientMsgId: string; msgId: number; senderPts: number;
  duplicate: boolean; serverTs?: string; text?: string; senderAccountId?: string; pushes: Push[];
};

/** review B2: claim the idempotency row BEFORE allocating a msg_id; a retry echoes the original result. */
export async function sendMessage(sql: SQL, p: {
  senderAccountId: string; senderDeviceId?: string | null; dialogId: string;
  clientMsgId: string; kind?: string; body?: string; replyToMsgId?: number | null;
  forwardedFrom?: { dialogId: string; msgId: number } | null;
}): Promise<SendResult> {
  return await sql.begin(async (tx) => {
    let body = p.forwardedFrom ? "" : requireTextBody(p.body);
    let kind = p.kind ?? "text";
    let forwardedFromAccountId: string | null = null;
    const replyToMsgId = optionalMessageId(p.replyToMsgId);
    // 1) idempotency gate — before any counter is touched
    const claim = await tx`
      INSERT INTO send_requests (sender_account_id, client_msg_id, dialog_id, status)
      VALUES (${p.senderAccountId}, ${p.clientMsgId}, ${p.dialogId}, 'pending')
      ON CONFLICT (sender_account_id, client_msg_id) DO NOTHING RETURNING status`;
    if (claim.length === 0) {
      const row = (await tx`
        SELECT status, dialog_id, msg_id, sender_pts
        FROM send_requests
        WHERE sender_account_id = ${p.senderAccountId} AND client_msg_id = ${p.clientMsgId}
        FOR UPDATE`)[0];
      if (row.status !== "completed") throw new SyncError("send already in progress");
      const msg = await loadMessage(tx, row.dialog_id, n(row.msg_id));
      return {
        dialogId: row.dialog_id, clientMsgId: p.clientMsgId, msgId: n(row.msg_id),
        senderPts: n(row.sender_pts), duplicate: true, pushes: [],
        serverTs: msg?.server_ts, text: msg?.text, senderAccountId: msg?.sender_account_id,
      };
    }

    await requireActiveAccount(tx, p.senderAccountId);
    await requireActiveMember(tx, p.senderAccountId, p.dialogId);

    if (p.forwardedFrom) {
      const sourceMsgId = optionalMessageId(p.forwardedFrom.msgId)!;
      await requireActiveMember(tx, p.senderAccountId, p.forwardedFrom.dialogId);
      const source = (await tx`
        SELECT sender_account_id, kind, state, body_key_id, body_nonce, body_ciphertext
        FROM messages WHERE dialog_id = ${p.forwardedFrom.dialogId} AND msg_id = ${sourceMsgId}`)[0];
      if (!source || source.state !== "visible") throw new SyncError("forward source not found");
      if (source.kind !== "text") throw new SyncError("this message type cannot be forwarded yet");
      body = open(
        { keyId: source.body_key_id, nonce: buf(source.body_nonce), ciphertext: buf(source.body_ciphertext) },
        bodyAAD(p.forwardedFrom.dialogId, sourceMsgId, source.sender_account_id),
      ).toString("utf8");
      kind = source.kind;
      forwardedFromAccountId = source.sender_account_id;
    }

    if (replyToMsgId != null) {
      const target = await tx`
        SELECT state FROM messages
        WHERE dialog_id = ${p.dialogId} AND msg_id = ${replyToMsgId}`;
      if (target.length === 0) throw new SyncError("reply target not found");
      if (target[0].state !== "visible") throw new SyncError("cannot reply to a deleted message");
    }

    // 3) allocate per-dialog msg_id
    const dlg = await tx`UPDATE dialogs SET last_msg_id = last_msg_id + 1, updated_at = now() WHERE id = ${p.dialogId} RETURNING last_msg_id`;
    const msgId = n(dlg[0].last_msg_id);

    // 5) encrypt + store the body once
    const sealed = seal(body, bodyAAD(p.dialogId, msgId, p.senderAccountId));
    const inserted = await tx`
      INSERT INTO messages (dialog_id, msg_id, sender_account_id, sender_device_id, client_msg_id, kind,
                            body_key_id, body_nonce, body_ciphertext, reply_to_msg_id,
                            forwarded_from_account_id, forwarded_from_dialog_id, forwarded_from_msg_id)
      VALUES (${p.dialogId}, ${msgId}, ${p.senderAccountId}, ${p.senderDeviceId ?? null}, ${p.clientMsgId},
              ${kind}, ${sealed.keyId}, ${sealed.nonce}, ${sealed.ciphertext}, ${replyToMsgId},
              ${forwardedFromAccountId}, ${p.forwardedFrom?.dialogId ?? null}, ${p.forwardedFrom?.msgId ?? null})
      RETURNING server_ts`;

    // 6) fan out one event per active member, ascending account_id (deadlock-free)
    const members = await tx`SELECT account_id FROM dialog_members WHERE dialog_id = ${p.dialogId} AND left_at IS NULL ORDER BY account_id`;
    let senderPts = 0;
    const pushes: Push[] = [];
    for (const m of members) {
      const upd = await tx`UPDATE account_sync_states SET pts = pts + 1, updated_at = now() WHERE account_id = ${m.account_id} RETURNING pts`;
      const pts = n(upd[0].pts);
      await tx`INSERT INTO account_events (account_id, pts, type, dialog_id, msg_id, actor_account_id) VALUES (${m.account_id}, ${pts}, 'message.new', ${p.dialogId}, ${msgId}, ${p.senderAccountId})`;
      await enqueuePushDeliveries(tx, {
        accountId: m.account_id,
        pts,
        senderAccountId: p.senderAccountId,
        sourceDeviceId: p.senderDeviceId,
      });
      if (m.account_id === p.senderAccountId) senderPts = pts;
      pushes.push({ accountId: m.account_id, pts, ptsCount: 1 });
    }

    // complete the idempotency row so retries return this exact result
    await tx`UPDATE send_requests SET status = 'completed', msg_id = ${msgId}, sender_pts = ${senderPts} WHERE sender_account_id = ${p.senderAccountId} AND client_msg_id = ${p.clientMsgId}`;

    return {
      dialogId: p.dialogId, clientMsgId: p.clientMsgId, msgId, senderPts, duplicate: false,
      serverTs: iso(inserted[0].server_ts), text: body, senderAccountId: p.senderAccountId, pushes,
    };
  });
}

export type MessageMutationResult = {
  dialogId: string; msgId: number; actorPts: number; duplicate: boolean;
  message: MessageDTO; pushes: Push[];
};

async function mutateMessage(sql: SQL, p: {
  actorAccountId: string; actorDeviceId?: string | null; dialogId: string; msgId: number;
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
    await requireActiveMember(tx, p.actorAccountId, p.dialogId);
    const members = await tx`
      SELECT account_id FROM dialog_members
      WHERE dialog_id = ${p.dialogId} AND left_at IS NULL
      ORDER BY account_id FOR UPDATE`;
    const row = (await tx`
      SELECT sender_account_id, kind, state, edit_version
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
          body_ciphertext = ${sealed.ciphertext}, state = 'deleted_for_all', deleted_at = now()
        WHERE dialog_id = ${p.dialogId} AND msg_id = ${msgId}`;
    }

    let actorPts = 0;
    const pushes: Push[] = [];
    const eventType = p.operation === "edit" ? "message.edited" : "message.deleted";
    for (const member of members) {
      const upd = await tx`
        UPDATE account_sync_states SET pts = pts + 1, updated_at = now()
        WHERE account_id = ${member.account_id} RETURNING pts`;
      const pts = n(upd[0].pts);
      await tx`
        INSERT INTO account_events (account_id, pts, type, dialog_id, msg_id, actor_account_id)
        VALUES (${member.account_id}, ${pts}, ${eventType}, ${p.dialogId}, ${msgId}, ${p.actorAccountId})`;
      await enqueuePushDeliveries(tx, {
        accountId: member.account_id, pts, senderAccountId: p.actorAccountId,
        sourceDeviceId: p.actorDeviceId, alertRecipients: false,
      });
      if (member.account_id === p.actorAccountId) actorPts = pts;
      pushes.push({ accountId: member.account_id, pts, ptsCount: 1 });
    }
    await tx`
      UPDATE message_mutation_requests SET status = 'completed', actor_pts = ${actorPts}
      WHERE actor_account_id = ${p.actorAccountId} AND client_mutation_id = ${mutationId}`;
    const message = await loadMessage(tx, p.dialogId, msgId);
    if (!message) throw new SyncError("message not found after mutation");
    return { dialogId: p.dialogId, msgId, actorPts, duplicate: false, message, pushes };
  });
}

export async function editMessage(sql: SQL, p: {
  actorAccountId: string; actorDeviceId?: string | null; dialogId: string; msgId: number;
  clientMutationId: string; body: string; expectedEditVersion: number;
}): Promise<MessageMutationResult> {
  return mutateMessage(sql, { ...p, operation: "edit" });
}

export async function deleteMessage(sql: SQL, p: {
  actorAccountId: string; actorDeviceId?: string | null; dialogId: string; msgId: number;
  clientMutationId: string;
}): Promise<MessageMutationResult> {
  return mutateMessage(sql, { ...p, operation: "delete" });
}

export async function setReaction(sql: SQL, p: {
  actorAccountId: string; actorDeviceId?: string | null; dialogId: string; msgId: number;
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
    await requireActiveMember(tx, p.actorAccountId, p.dialogId);
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

    let actorPts = 0;
    const pushes: Push[] = [];
    for (const member of members) {
      const upd = await tx`
        UPDATE account_sync_states SET pts = pts + 1, updated_at = now()
        WHERE account_id = ${member.account_id} RETURNING pts`;
      const pts = n(upd[0].pts);
      await tx`
        INSERT INTO account_events (account_id, pts, type, dialog_id, msg_id, actor_account_id, data)
        VALUES (${member.account_id}, ${pts}, 'reaction.updated', ${p.dialogId}, ${msgId}, ${p.actorAccountId},
                ${JSON.stringify({ reactor_account_id: p.actorAccountId, emoji })}::jsonb)`;
      await enqueuePushDeliveries(tx, {
        accountId: member.account_id, pts, senderAccountId: p.actorAccountId,
        sourceDeviceId: p.actorDeviceId, alertRecipients: false,
      });
      if (member.account_id === p.actorAccountId) actorPts = pts;
      pushes.push({ accountId: member.account_id, pts, ptsCount: 1 });
    }
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
  | { kind: "difference" | "difference_slice"; state: { pts: number }; updates: any[]; hasMore: boolean };

/** review B3 (pruned floor → too_long) + I3 (byte + count budget, slicing). */
export async function getDifference(
  sql: SQL, accountId: string, sincePts: number,
  opts: { maxEvents?: number; maxBytes?: number } = {},
): Promise<Difference> {
  const maxEvents = opts.maxEvents ?? 200;
  const maxBytes = opts.maxBytes ?? 256 * 1024;
  const st = (await sql`SELECT pts, pruned_through_pts FROM account_sync_states WHERE account_id = ${accountId}`)[0];
  if (!st) throw new SyncError("unknown account");
  const statePts = n(st.pts);
  if (sincePts < n(st.pruned_through_pts)) return { kind: "difference_too_long", state: { pts: statePts } };

  const rows = await sql`
    SELECT ae.pts, ae.type, ae.dialog_id, ae.msg_id, ae.actor_account_id, ae.data,
           CASE WHEN d.type = 'direct' THEN NULLIF(peer.display_name, '') ELSE d.title END AS dialog_title
    FROM account_events ae
    LEFT JOIN dialogs d ON d.id = ae.dialog_id
    LEFT JOIN direct_dialog_pairs pair ON pair.dialog_id = d.id
    LEFT JOIN accounts peer ON peer.id = CASE
      WHEN pair.account_low = ${accountId} THEN pair.account_high
      WHEN pair.account_high = ${accountId} THEN pair.account_low
      ELSE NULL
    END
    WHERE ae.account_id = ${accountId} AND ae.pts > ${sincePts}
    ORDER BY ae.pts ASC LIMIT ${maxEvents}`;

  const updates: any[] = [];
  let bytes = 0, lastPts = sincePts, truncated = false;
  for (const ev of rows) {
    const pts = n(ev.pts);
    let update: any;
    if (ev.type === "message.new" || ev.type === "message.edited" || ev.type === "message.deleted" || ev.type === "reaction.updated") {
      const message = await loadMessage(sql, ev.dialog_id, n(ev.msg_id));
      if (!message) {
        update = {
          pts, ptsCount: 1, type: "message.missing", dialog_id: ev.dialog_id,
          dialog_title: ev.dialog_title ?? undefined, msg_id: n(ev.msg_id),
        };
      } else {
        update = {
          pts, ptsCount: 1, type: ev.type, dialog_id: ev.dialog_id,
          dialog_title: ev.dialog_title ?? undefined, message,
        };
      }
    } else {
      update = {
        pts, ptsCount: 1, type: ev.type, dialog_id: ev.dialog_id,
        dialog_title: ev.dialog_title ?? undefined,
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
  return { kind: hasMore ? "difference_slice" : "difference", state: { pts: hasMore ? lastPts : statePts }, updates, hasMore };
}

export type BootstrapStart = { token: string; state: { pts: number }; expiresAt: string; dialogCount: number };

/**
 * review B1/I2: new-device bootstrap is a resumable snapshot. The snapshot pins the account pts and
 * each dialog's message ceiling, so page-by-page history cannot duplicate or drop messages that land
 * while a weak network is still downloading.
 */
export async function startBootstrap(sql: SQL, accountId: string): Promise<BootstrapStart> {
  return await sql.begin(async (tx) => {
    const state = (await tx`SELECT pts FROM account_sync_states WHERE account_id = ${accountId}`)[0];
    if (!state) throw new SyncError("unknown account");

    const snap = (await tx`
      INSERT INTO bootstrap_snapshots (account_id, snapshot_pts)
      VALUES (${accountId}, ${n(state.pts)})
      RETURNING id, expires_at`)[0];

    await tx`
      INSERT INTO bootstrap_snapshot_dialogs (snapshot_id, dialog_id, ceiling_msg_id, sort_updated_at)
      SELECT ${snap.id}, d.id, d.last_msg_id, d.updated_at
      FROM dialog_members dm
      JOIN dialogs d ON d.id = dm.dialog_id
      WHERE dm.account_id = ${accountId} AND dm.left_at IS NULL
      ORDER BY d.updated_at DESC, d.id DESC`;

    const count = (await tx`
      SELECT count(*)::int AS count FROM bootstrap_snapshot_dialogs WHERE snapshot_id = ${snap.id}`)[0];
    return { token: snap.id, state: { pts: n(state.pts) }, expiresAt: iso(snap.expires_at), dialogCount: n(count.count) };
  });
}

export type BootstrapDialog = {
  dialog_id: string; type: string; title: string | null; last_msg_id: number;
  updated_at: string; members: { account_id: string; role: string; last_read_msg_id: number }[];
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
  opts: { cursor?: string; limit?: number; previewMessages?: number } = {},
): Promise<BootstrapPage> {
  const limit = clamp(opts.limit ?? 20, 1, 100);
  const previewMessages = clamp(opts.previewMessages ?? 1, 0, 25);
  const cursor = decodeCursor<{ updatedAt: string; dialogId: string }>(opts.cursor);

  const snap = (await sql`
    SELECT id, snapshot_pts FROM bootstrap_snapshots
    WHERE id = ${token} AND account_id = ${accountId} AND expires_at > now()`)[0];
  if (!snap) throw new SyncError("unknown or expired bootstrap token");

  const rows = cursor
    ? await sql`
        SELECT bsd.dialog_id, bsd.ceiling_msg_id, bsd.sort_updated_at, d.type,
               CASE WHEN d.type = 'direct' THEN NULLIF(peer.display_name, '') ELSE d.title END AS title,
               d.updated_at
        FROM bootstrap_snapshot_dialogs bsd
        JOIN dialogs d ON d.id = bsd.dialog_id
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
               d.updated_at
        FROM bootstrap_snapshot_dialogs bsd
        JOIN dialogs d ON d.id = bsd.dialog_id
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
  const dialogs: BootstrapDialog[] = [];
  for (const row of pageRows) {
    const members = await sql`
      SELECT account_id, role, last_read_msg_id
      FROM dialog_members
      WHERE dialog_id = ${row.dialog_id}
      ORDER BY account_id`;
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
      members: members.map((m) => ({ account_id: m.account_id, role: m.role, last_read_msg_id: n(m.last_read_msg_id) })),
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

export type HistoryPage = { dialogId: string; messages: MessageDTO[]; nextBeforeMsgId?: number; hasMore: boolean };

export async function getHistory(
  sql: SQL,
  accountId: string,
  dialogId: string,
  opts: { beforeMsgId?: number; limit?: number; maxBytes?: number } = {},
): Promise<HistoryPage> {
  await requireActiveMember(sql, accountId, dialogId);
  const limit = clamp(opts.limit ?? 50, 1, 200);
  const maxBytes = opts.maxBytes ?? 512 * 1024;
  const rows = opts.beforeMsgId
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
  for (const row of rows.slice(0, limit)) {
    const msg = await loadMessage(sql, dialogId, n(row.msg_id));
    if (!msg) continue;
    const size = Buffer.byteLength(JSON.stringify(msg));
    if (messages.length > 0 && bytes + size > maxBytes) { hasMore = true; break; }
    messages.push(msg);
    bytes += size;
  }
  messages.reverse();
  return {
    dialogId, messages, hasMore,
    nextBeforeMsgId: hasMore && messages.length ? messages[0].msg_id : undefined,
  };
}

export async function readHistory(sql: SQL, p: {
  accountId: string; dialogId: string; maxReadMsgId: number;
}): Promise<{ dialogId: string; maxReadMsgId: number; pushes: Push[] }> {
  return await sql.begin(async (tx) => {
    await requireActiveAccount(tx, p.accountId);
    await requireActiveMember(tx, p.accountId, p.dialogId);
    const member = (await tx`
      UPDATE dialog_members SET last_read_msg_id = ${p.maxReadMsgId}
      WHERE dialog_id = ${p.dialogId} AND account_id = ${p.accountId} AND left_at IS NULL
        AND last_read_msg_id < ${p.maxReadMsgId}
      RETURNING last_read_msg_id`)[0];
    if (!member) {
      const current = (await tx`
        SELECT last_read_msg_id FROM dialog_members
        WHERE dialog_id = ${p.dialogId} AND account_id = ${p.accountId} AND left_at IS NULL`)[0];
      return { dialogId: p.dialogId, maxReadMsgId: n(current.last_read_msg_id), pushes: [] };
    }

    const members = await tx`SELECT account_id FROM dialog_members WHERE dialog_id = ${p.dialogId} AND left_at IS NULL ORDER BY account_id`;
    const pushes: Push[] = [];
    const data = JSON.stringify({ reader_account_id: p.accountId, max_read_msg_id: n(member.last_read_msg_id) });
    for (const m of members) {
      const upd = await tx`UPDATE account_sync_states SET pts = pts + 1, updated_at = now() WHERE account_id = ${m.account_id} RETURNING pts`;
      const pts = n(upd[0].pts);
      await tx`
        INSERT INTO account_events (account_id, pts, type, dialog_id, actor_account_id, data)
        VALUES (${m.account_id}, ${pts}, 'read.updated', ${p.dialogId}, ${p.accountId}, ${data}::jsonb)`;
      pushes.push({ accountId: m.account_id, pts, ptsCount: 1 });
    }
    return { dialogId: p.dialogId, maxReadMsgId: n(member.last_read_msg_id), pushes };
  });
}
