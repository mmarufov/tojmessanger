import { createHash } from "node:crypto";
import type { SQL } from "bun";
import { requireActiveDevice } from "./auth";
import {
  appendAccessRevokedEvent,
  fanoutDialogEvent,
  type FanoutPush,
} from "./fanout";
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

export type SavedMessagesBackfillClaim = {
  accountId: string;
  workerId: string;
};

const n = (value: unknown) => Number(value as any);
const SYNC_NOTIFY_CHANNEL = "toj_sync_events";

export function savedMessagesConfigured(): boolean {
  return process.env.TOJ_SAVED_MESSAGES_V1_ENABLED === "1";
}

export type SavedMessagesSchemaReadiness = {
  ready: boolean;
  missing: string[];
};

/** Fail-closed catalog check used by readiness, capability advertisement, and the ensure route. */
export async function savedMessagesSchemaReadiness(
  sql: SQL,
): Promise<SavedMessagesSchemaReadiness> {
  const row = (await sql`
    SELECT
      EXISTS (
        SELECT 1 FROM pg_attribute
        WHERE attrelid = to_regclass('public.messages')
          AND attname = 'is_forwarded' AND NOT attisdropped AND attnotnull
      ) AS marker_column,
      EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = to_regclass('public.messages')
          AND conname = 'messages_forward_marker_check' AND convalidated
      ) AS marker_constraint,
      EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = to_regclass('public.dialogs')
          AND conname = 'dialogs_type_check' AND convalidated
          AND pg_get_constraintdef(oid) LIKE '%saved%'
      ) AS dialog_type_constraint,
      EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = to_regclass('public.dialogs')
          AND conname = 'dialogs_saved_owner_check' AND convalidated
      ) AS dialog_owner_constraint,
      EXISTS (
        SELECT 1
        FROM pg_class class
        JOIN pg_index index ON index.indexrelid = class.oid
        WHERE class.oid = to_regclass('public.dialogs_one_saved_per_account_idx')
          AND index.indisvalid AND index.indisready AND index.indisunique
      ) AS saved_unique_index,
      EXISTS (
        SELECT 1
        FROM pg_class class
        JOIN pg_index index ON index.indexrelid = class.oid
        WHERE class.oid = to_regclass('public.messages_forward_provenance_idx')
          AND index.indisvalid AND index.indisready
      ) AS forward_index,
      EXISTS (
        SELECT 1
        FROM pg_class class
        JOIN pg_index index ON index.indexrelid = class.oid
        WHERE class.oid = to_regclass('public.messages_reply_target_idx')
          AND index.indisvalid AND index.indisready
      ) AS reply_index,
      (
        SELECT count(*) = 6
        FROM pg_attribute
        WHERE attrelid = to_regclass('public.saved_messages_backfill_claims')
          AND attname = ANY(ARRAY[
            'account_id','worker_id','claimed_at','completed_at','attempts','last_error'
          ])
          AND NOT attisdropped
      ) AS claims_schema,
      EXISTS (
        SELECT 1 FROM pg_trigger
        WHERE tgrelid = to_regclass('public.messages')
          AND tgname = 'messages_derive_forward_marker' AND tgenabled <> 'D'
      ) AS writer_trigger,
      EXISTS (
        SELECT 1 FROM pg_trigger
        WHERE tgrelid = to_regclass('public.accounts')
          AND tgname = 'accounts_cleanup_saved_messages' AND tgenabled <> 'D'
      ) AS deletion_trigger,
      to_regclass('public.schema_migration_progress') IS NOT NULL AS progress_schema`)[0];

  const checks: Array<[string, boolean]> = [
    ["messages.is_forwarded", Boolean(row.marker_column)],
    ["messages_forward_marker_check", Boolean(row.marker_constraint)],
    ["dialogs_type_check", Boolean(row.dialog_type_constraint)],
    ["dialogs_saved_owner_check", Boolean(row.dialog_owner_constraint)],
    ["dialogs_one_saved_per_account_idx", Boolean(row.saved_unique_index)],
    ["messages_forward_provenance_idx", Boolean(row.forward_index)],
    ["messages_reply_target_idx", Boolean(row.reply_index)],
    ["saved_messages_backfill_claims", Boolean(row.claims_schema)],
    ["messages_derive_forward_marker", Boolean(row.writer_trigger)],
    ["accounts_cleanup_saved_messages", Boolean(row.deletion_trigger)],
    ["schema_migration_progress", Boolean(row.progress_schema)],
  ];
  if (row.progress_schema) {
    const progress = await sql`
      SELECT 1
      FROM schema_migration_progress
      WHERE migration_name = ${"messages_is_forwarded_v1"} AND completed_at IS NOT NULL`;
    checks.push(["messages_is_forwarded_v1", progress.length === 1]);
  } else {
    checks.push(["messages_is_forwarded_v1", false]);
  }
  const missing = checks.filter(([, present]) => !present).map(([name]) => name);
  return { ready: missing.length === 0, missing };
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
    const revokedPushes: FanoutPush[] = [];
    for (const row of removed) {
      revokedPushes.push(await appendAccessRevokedEvent(
        tx,
        String(row.account_id),
        dialogId,
        accountId,
        "saved",
      ));
    }
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

    const ownerPushes = await fanoutDialogEvent(tx, {
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
    const pushes = [...revokedPushes, ...ownerPushes];
    await notifySyncWakeups(tx, pushes);
    return {
      dialogId,
      type: "saved",
      created,
      repaired,
      eventPts: ownerPushes.find((push) => push.accountId === accountId)?.pts,
      pushes,
    };
  });
}

export function requireSavedMessagesBackfillAuthorization(
  env: Record<string, string | undefined> = process.env,
): void {
  if (env.NODE_ENV !== "production") {
    throw new SavedMessagesError(
      "saved messages backfill requires NODE_ENV=production",
      "backfill_not_production",
      503,
    );
  }
  if (env.TOJ_SAVED_MESSAGES_V1_ENABLED !== "1") {
    throw new SavedMessagesError(
      "saved messages backfill requires the global feature switch",
      "backfill_feature_disabled",
      503,
    );
  }
  if (env.TOJ_SAVED_MESSAGES_ROLLOUT_PERCENT?.trim() !== "100") {
    throw new SavedMessagesError(
      "saved messages backfill requires an explicit 100 percent rollout",
      "backfill_partial_rollout",
      503,
    );
  }
  if (env.TOJ_SAVED_MESSAGES_BACKFILL_CONFIRM !== "PROVISION_ALL_ACTIVE_ACCOUNTS") {
    throw new SavedMessagesError(
      "saved messages backfill production confirmation missing",
      "backfill_confirmation_missing",
      503,
    );
  }
}

export function savedMessagesBackfillThrottleMs(
  value = process.env.TOJ_SAVED_MESSAGES_BACKFILL_THROTTLE_MS,
): number {
  const parsed = Number(value ?? "25");
  return Number.isFinite(parsed) ? Math.max(0, Math.min(Math.floor(parsed), 60_000)) : 25;
}

/** Claims bounded durable leases so multiple workers never provision the same account concurrently. */
export async function claimSavedMessagesBackfillAccounts(
  sql: SQL,
  workerId: string,
  limit = 100,
  staleAfterSeconds = 15 * 60,
): Promise<SavedMessagesBackfillClaim[]> {
  const boundedLimit = Number.isSafeInteger(limit) ? Math.max(1, Math.min(limit, 1_000)) : 100;
  const boundedStaleSeconds = Number.isSafeInteger(staleAfterSeconds)
    ? Math.max(60, Math.min(staleAfterSeconds, 24 * 60 * 60))
    : 15 * 60;
  return await sql.begin(async (tx) => {
    const rows = await tx`
      WITH candidates AS MATERIALIZED (
        SELECT account.id
        FROM accounts account
        LEFT JOIN saved_messages_backfill_claims claim ON claim.account_id = account.id
        WHERE account.status IN ('active','limited')
          AND NOT EXISTS (
            SELECT 1 FROM dialogs dialog
            WHERE dialog.type = 'saved' AND dialog.created_by = account.id
          )
          AND (
            claim.account_id IS NULL
            OR (
              claim.completed_at IS NULL
              AND claim.claimed_at < now() - make_interval(secs => ${boundedStaleSeconds})
            )
          )
        ORDER BY account.id
        LIMIT ${boundedLimit}
        FOR UPDATE OF account SKIP LOCKED
      )
      INSERT INTO saved_messages_backfill_claims AS claim (
        account_id, worker_id, claimed_at, completed_at, attempts, last_error
      )
      SELECT candidate.id, ${workerId}::uuid, now(), NULL, 1, NULL
      FROM candidates candidate
      ON CONFLICT (account_id) DO UPDATE SET
        worker_id = EXCLUDED.worker_id,
        claimed_at = now(),
        completed_at = NULL,
        attempts = claim.attempts + 1,
        last_error = NULL
      WHERE claim.completed_at IS NULL
        AND claim.claimed_at < now() - make_interval(secs => ${boundedStaleSeconds})
      RETURNING account_id`;
    return rows.map((row: any) => ({ accountId: String(row.account_id), workerId }));
  });
}

export async function completeSavedMessagesBackfillClaim(
  sql: SQL,
  claim: SavedMessagesBackfillClaim,
  outcome: "completed" | "account_unavailable" = "completed",
): Promise<boolean> {
  const rows = await sql`
    UPDATE saved_messages_backfill_claims
    SET completed_at = now(), last_error = ${outcome === "completed" ? null : outcome}
    WHERE account_id = ${claim.accountId}
      AND worker_id = ${claim.workerId}::uuid
      AND completed_at IS NULL
    RETURNING account_id`;
  return rows.length === 1;
}

export async function refreshSavedMessagesBackfillClaim(
  sql: SQL,
  claim: SavedMessagesBackfillClaim,
): Promise<boolean> {
  const rows = await sql`
    UPDATE saved_messages_backfill_claims
    SET claimed_at = now()
    WHERE account_id = ${claim.accountId}
      AND worker_id = ${claim.workerId}::uuid
      AND completed_at IS NULL
    RETURNING account_id`;
  return rows.length === 1;
}

export async function failSavedMessagesBackfillClaim(
  sql: SQL,
  claim: SavedMessagesBackfillClaim,
  errorCode: string,
): Promise<boolean> {
  const rows = await sql`
    UPDATE saved_messages_backfill_claims
    SET last_error = ${errorCode.slice(0, 120)}
    WHERE account_id = ${claim.accountId}
      AND worker_id = ${claim.workerId}::uuid
      AND completed_at IS NULL
    RETURNING account_id`;
  return rows.length === 1;
}
