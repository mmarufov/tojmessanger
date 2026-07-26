import type { SQL } from "bun";
import { ensureSavedMessages, SavedMessagesError } from "./saved-messages";

export const SAVED_DIALOG_RECONCILIATION = "saved_dialog_membership_v1";

export type SavedDialogReconciliationResult = {
  processed: number;
  repaired: number;
  deletedOwners: number;
  batches: number;
  skippedCompleted: boolean;
};

/**
 * Reconciles every already-existing Saved dialog independently of provisioning-backfill claims.
 * Cursor advancement follows each idempotent reconciliation, so a crash can only repeat a dialog
 * that is already clean and therefore cannot emit duplicate revocation PTS.
 */
export async function reconcileExistingSavedDialogs(
  sql: SQL,
  requestedBatchSize = 100,
): Promise<SavedDialogReconciliationResult> {
  const batchSize = Number.isSafeInteger(requestedBatchSize)
    ? Math.max(1, Math.min(requestedBatchSize, 1_000))
    : 100;
  const progress = (await sql`
    SELECT completed_at
    FROM schema_migration_progress
    WHERE migration_name = ${SAVED_DIALOG_RECONCILIATION}`)[0];
  if (progress?.completed_at != null) {
    return {
      processed: 0, repaired: 0, deletedOwners: 0, batches: 0, skippedCompleted: true,
    };
  }

  let processed = 0;
  let repaired = 0;
  let deletedOwners = 0;
  let batches = 0;
  while (true) {
    const cursor = (await sql`
      SELECT cursor_dialog_id
      FROM schema_migration_progress
      WHERE migration_name = ${SAVED_DIALOG_RECONCILIATION}`)[0]?.cursor_dialog_id;
    const rows = await sql`
      SELECT dialog.id, dialog.created_by, account.status
      FROM dialogs dialog
      JOIN accounts account ON account.id = dialog.created_by
      WHERE dialog.type = 'saved'
        AND (${cursor ?? null}::uuid IS NULL OR dialog.id > ${cursor ?? null}::uuid)
      ORDER BY dialog.id
      LIMIT ${batchSize}`;
    if (rows.length === 0) {
      await sql`
        UPDATE schema_migration_progress
        SET completed_at = COALESCE(completed_at, now()), updated_at = now()
        WHERE migration_name = ${SAVED_DIALOG_RECONCILIATION}`;
      break;
    }
    batches += 1;
    for (const row of rows) {
      const accountId = String(row.created_by);
      try {
        const result = await ensureSavedMessages(sql, accountId);
        if (result.repaired) repaired += 1;
      } catch (error) {
        if (!(error instanceof SavedMessagesError) || error.code !== "account_unavailable") {
          throw error;
        }
        await sql`SELECT toj_cleanup_saved_messages_for_account(${accountId})`;
        deletedOwners += 1;
      }
      processed += 1;
      await sql`
        UPDATE schema_migration_progress
        SET cursor_dialog_id = ${String(row.id)}, cursor_msg_id = 0,
            rows_processed = rows_processed + 1, updated_at = now()
        WHERE migration_name = ${SAVED_DIALOG_RECONCILIATION}`;
    }
  }
  return { processed, repaired, deletedOwners, batches, skippedCompleted: false };
}
