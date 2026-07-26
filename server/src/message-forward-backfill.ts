import type { SQL } from "bun";

export const MESSAGE_FORWARD_MIGRATION = "messages_is_forwarded_v1";

export type MessageForwardBackfillResult = {
  processed: number;
  batches: number;
  skippedCompleted: boolean;
};

/**
 * Restart-safe keyset backfill. Each batch and cursor advance commit together. The temporary
 * partial index contains only unfinished legacy rows, so the end probe and interrupted reruns never
 * scan the full messages table.
 */
export async function backfillMessageForwardMarkers(
  sql: SQL,
  requestedBatchSize = 1_000,
): Promise<MessageForwardBackfillResult> {
  const batchSize = Number.isSafeInteger(requestedBatchSize)
    ? Math.max(1, Math.min(requestedBatchSize, 10_000))
    : 1_000;
  const existing = (await sql`
    SELECT completed_at
    FROM schema_migration_progress
    WHERE migration_name = ${MESSAGE_FORWARD_MIGRATION}`)[0];
  if (existing?.completed_at != null) {
    return { processed: 0, batches: 0, skippedCompleted: true };
  }

  let processed = 0;
  let batches = 0;
  while (true) {
    const result = await sql.begin(async (tx) => {
      const progress = (await tx`
        SELECT cursor_dialog_id, cursor_msg_id
        FROM schema_migration_progress
        WHERE migration_name = ${MESSAGE_FORWARD_MIGRATION}
        FOR UPDATE`)[0];
      if (!progress) throw new Error("message forwarding migration progress row is missing");
      const cursorDialogId = progress.cursor_dialog_id == null
        ? null
        : String(progress.cursor_dialog_id);
      const cursorMsgId = progress.cursor_msg_id == null
        ? null
        : Number(progress.cursor_msg_id);
      const rows = await tx`
        WITH batch AS MATERIALIZED (
          SELECT dialog_id, msg_id
          FROM messages
          WHERE is_forwarded IS NOT TRUE
            AND forwarded_from_dialog_id IS NOT NULL
            AND forwarded_from_msg_id IS NOT NULL
            AND (
              ${cursorDialogId}::uuid IS NULL
              OR (dialog_id, msg_id) > (${cursorDialogId}::uuid, ${cursorMsgId}::bigint)
            )
          ORDER BY dialog_id, msg_id
          LIMIT ${batchSize}
          FOR UPDATE
        ), updated AS (
          UPDATE messages AS target
          SET is_forwarded = TRUE
          FROM batch
          WHERE target.dialog_id = batch.dialog_id AND target.msg_id = batch.msg_id
          RETURNING target.dialog_id, target.msg_id
        ), edge AS (
          SELECT dialog_id, msg_id FROM updated
          ORDER BY dialog_id DESC, msg_id DESC LIMIT 1
        ), advanced AS (
          UPDATE schema_migration_progress
          SET cursor_dialog_id = edge.dialog_id,
              cursor_msg_id = edge.msg_id,
              rows_processed = rows_processed + (SELECT count(*) FROM updated),
              updated_at = now()
          FROM edge
          WHERE migration_name = ${MESSAGE_FORWARD_MIGRATION}
          RETURNING cursor_dialog_id
        )
        SELECT
          (SELECT count(*)::int FROM updated) AS count,
          EXISTS(SELECT 1 FROM advanced) AS advanced`;
      return {
        count: Number(rows[0]?.count ?? 0),
        advanced: Boolean(rows[0]?.advanced),
      };
    });
    if (result.count > 0) {
      processed += result.count;
      batches += 1;
      continue;
    }

    // Rows behind the cursor are not expected because the expand trigger marks all new writes.
    // This indexed probe makes the recovery path safe if an operator restored an older snapshot.
    const remaining = await sql`
      SELECT dialog_id, msg_id
      FROM messages
      WHERE is_forwarded IS NOT TRUE
        AND forwarded_from_dialog_id IS NOT NULL
        AND forwarded_from_msg_id IS NOT NULL
      ORDER BY dialog_id, msg_id
      LIMIT 1`;
    if (remaining.length === 0) break;
    await sql`
      UPDATE schema_migration_progress
      SET cursor_dialog_id = NULL, cursor_msg_id = NULL, updated_at = now()
      WHERE migration_name = ${MESSAGE_FORWARD_MIGRATION}`;
  }
  return { processed, batches, skippedCompleted: false };
}
