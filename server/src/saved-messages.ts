import { createHash } from "node:crypto";
import type { SQL } from "bun";
import { requireActiveDevice } from "./auth";
import { fanoutDialogEvent, type FanoutPush } from "./fanout";
import { lockAccountMutations } from "./locks";

export class SavedMessagesError extends Error {
  constructor(
    message: string,
    readonly code: string,
    readonly status = 400,
  ) {
    super(message);
    this.name = "SavedMessagesError";
  }
}

export type SavedMessagesResult = {
  dialogId: string;
  type: "saved";
  created: boolean;
  repaired: boolean;
  eventPts?: number;
  pushes: FanoutPush[];
};

const n = (value: unknown) => Number(value as any);
const SYNC_NOTIFY_CHANNEL = "toj_sync_events";

export function savedMessagesConfigured(): boolean {
  return process.env.TOJ_SAVED_MESSAGES_V1_ENABLED === "1";
}

/** Stable per-account rollout. The global switch is always the outer kill switch. */
export function savedMessagesEnabledForAccount(accountId: string): boolean {
  if (!savedMessagesConfigured()) return false;
  const normalizedAccountId = accountId.trim().toLowerCase();
  const allowlist = new Set((process.env.TOJ_SAVED_MESSAGES_ALLOWLIST ?? "")
    .split(",").map((value) => value.trim().toLowerCase()).filter(Boolean));
  if (allowlist.has(normalizedAccountId)) return true;
  const configuredPercent = Number(process.env.TOJ_SAVED_MESSAGES_ROLLOUT_PERCENT ?? "0");
  if (!Number.isFinite(configuredPercent) || configuredPercent <= 0) return false;
  if (configuredPercent >= 100) return true;
  const digest = createHash("sha256")
    .update(`toj-saved-messages-rollout-v1|${normalizedAccountId}`)
    .digest();
  const bucket = digest.readUInt32BE(0) / 0x1_0000_0000 * 100;
  return bucket < configuredPercent;
}

async function notifySyncWakeups(sql: SQL, pushes: FanoutPush[]): Promise<void> {
  for (const push of pushes) {
    await sql`SELECT pg_notify(${SYNC_NOTIFY_CHANNEL}, ${JSON.stringify(push)})`;
  }
}

/**
 * Resolves the account's single Saved Messages dialog and repairs its self-only owner membership.
 * The account-scoped advisory lock makes the read/insert path deterministic; the partial unique
 * index remains the final protection against callers outside this function.
 */
export async function ensureSavedMessages(
  sql: SQL,
  accountId: string,
  actorDeviceId?: string | null,
): Promise<SavedMessagesResult> {
  return await sql.begin(async (tx) => {
    await lockAccountMutations(tx, [accountId]);
    const account = (await tx`
      SELECT id FROM accounts
      WHERE id = ${accountId} AND status IN ('active','limited')
      FOR SHARE`)[0];
    if (!account) {
      throw new SavedMessagesError("account unavailable", "account_unavailable", 403);
    }
    if (actorDeviceId) await requireActiveDevice(tx, accountId, actorDeviceId);

    let dialog = (await tx`
      SELECT id, title, closed_at FROM dialogs
      WHERE type = 'saved' AND created_by = ${accountId}
      FOR UPDATE`)[0];
    let created = false;
    if (!dialog) {
      dialog = (await tx`
        INSERT INTO dialogs (type, title, created_by)
        VALUES ('saved', NULL, ${accountId})
        RETURNING id, title, closed_at`)[0];
      created = true;
    }

    const dialogId = String(dialog.id);
    const dialogMetadataValid = dialog.title == null && dialog.closed_at == null;
    if (!dialogMetadataValid) {
      await tx`
        UPDATE dialogs
        SET title = NULL, closed_at = NULL, updated_at = now()
        WHERE id = ${dialogId}`;
    }

    const removed = await tx`
      DELETE FROM dialog_members
      WHERE dialog_id = ${dialogId} AND account_id <> ${accountId}
      RETURNING account_id`;
    const previous = (await tx`
      SELECT role, notification_mode, left_at
      FROM dialog_members
      WHERE dialog_id = ${dialogId} AND account_id = ${accountId}
      FOR UPDATE`)[0];
    const memberValid = previous
      && previous.role === "owner"
      && previous.notification_mode === "all"
      && previous.left_at == null;

    if (!memberValid) {
      await tx`
        INSERT INTO dialog_members (
          dialog_id, account_id, role, invited_by, notification_mode, left_at
        ) VALUES (
          ${dialogId}, ${accountId}, 'owner', ${accountId}, 'all', NULL
        )
        ON CONFLICT (dialog_id, account_id) DO UPDATE SET
          role = 'owner',
          invited_by = ${accountId},
          notification_mode = 'all',
          left_at = NULL`;
    }

    const repaired = !created && (!dialogMetadataValid || !memberValid || removed.length > 0);
    if (!created && !repaired) {
      return { dialogId, type: "saved", created: false, repaired: false, pushes: [] };
    }

    const pushes = await fanoutDialogEvent(tx, {
      dialogId,
      type: "dialog.created",
      actorAccountId: accountId,
      sourceDeviceId: actorDeviceId,
      alertRecipients: false,
      recipientAccountIds: [accountId],
      data: {
        dialog_type: "saved",
        member_count: 1,
        self_role: "owner",
      },
    });
    await notifySyncWakeups(tx, pushes);
    return {
      dialogId,
      type: "saved",
      created,
      repaired,
      eventPts: pushes.find((push) => push.accountId === accountId)?.pts,
      pushes,
    };
  });
}

/** Bounded, restart-safe worker primitive used by the operational backfill command. */
export async function savedMessagesBackfillCandidates(
  sql: SQL,
  limit = 100,
): Promise<string[]> {
  const boundedLimit = Number.isSafeInteger(limit) ? Math.max(1, Math.min(limit, 1_000)) : 100;
  return await sql.begin(async (tx) => {
    const rows = await tx`
      SELECT account.id
      FROM accounts account
      WHERE account.status IN ('active','limited')
        AND NOT EXISTS (
          SELECT 1 FROM dialogs dialog
          WHERE dialog.type = 'saved' AND dialog.created_by = account.id
        )
      ORDER BY account.id
      LIMIT ${boundedLimit}
      FOR UPDATE OF account SKIP LOCKED`;
    return rows.map((row: any) => String(row.id));
  });
}
