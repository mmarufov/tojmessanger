import { $ } from "bun";
import { DEFAULT_URL } from "./db";

// Apply contract DDL atomically, build indexes on existing hot tables without blocking writes,
// then validate the new constraint under a short lock timeout. Every phase is idempotent.
const url = process.env.DATABASE_URL ?? DEFAULT_URL;
const schema = new URL("./schema.sql", import.meta.url).pathname;
const concurrentSchema = new URL("./schema-concurrent.sql", import.meta.url).pathname;
const dialogPreferencesExpand = new URL(
  "./schema-dialog-preferences-expand.sql",
  import.meta.url,
).pathname;
const dialogPreferencesConcurrent = new URL(
  "./schema-dialog-preferences-concurrent.sql",
  import.meta.url,
).pathname;
const dialogPreferencesContract = new URL(
  "./schema-dialog-preferences-contract.sql",
  import.meta.url,
).pathname;
const callMediaBackfillBatchSize = 1_000;
const preferenceBackfillBatchSize = Math.max(
  1,
  Math.min(10_000, Number(process.env.TOJ_DIALOG_PREFERENCE_BACKFILL_BATCH_SIZE ?? 1_000)),
);
const migrationStartedAt = performance.now();

await $`psql ${url} -v ON_ERROR_STOP=1 --single-transaction -c "SET LOCAL lock_timeout = '5s'" -f ${schema}`.quiet();
let backfilledCallCount = 0;
while (true) {
  const query = `
    WITH batch AS (
      SELECT id
      FROM calls
      WHERE selectable_media_profiles IS NULL
      ORDER BY created_at, id
      LIMIT ${callMediaBackfillBatchSize}
      FOR UPDATE SKIP LOCKED
    ), updated AS (
      UPDATE calls AS target
      SET selectable_media_profiles = target.offered_media_profiles
      FROM batch
      WHERE target.id = batch.id
      RETURNING 1
    )
    SELECT count(*) FROM updated
  `;
  const output = await $`psql ${url} -v ON_ERROR_STOP=1 -qAt -c ${query}`.quiet().text();
  const updated = Number(output.trim());
  if (!Number.isSafeInteger(updated) || updated < 0) {
    throw new Error("invalid selectable_media_profiles backfill count");
  }
  backfilledCallCount += updated;
  if (updated === 0) break;
}
await $`psql ${url} -v ON_ERROR_STOP=1 -c "SET lock_timeout = '5s'; ALTER TABLE calls VALIDATE CONSTRAINT calls_selectable_media_profiles_not_null"`.quiet();
await $`psql ${url} -v ON_ERROR_STOP=1 -c "SET lock_timeout = '5s'; ALTER TABLE calls ALTER COLUMN selectable_media_profiles SET NOT NULL"`.quiet();
await $`psql ${url} -v ON_ERROR_STOP=1 -f ${concurrentSchema}`.quiet();
await $`psql ${url} -v ON_ERROR_STOP=1 -c "SET lock_timeout = '5s'; ALTER TABLE devices VALIDATE CONSTRAINT devices_voip_push_environment_check"`.quiet();

async function completeConstraintMigration(
  marker: string,
  table: string,
  constraints: string[],
): Promise<void> {
  const pending = (await $`psql ${url} -v ON_ERROR_STOP=1 -qAt -c ${
    `SELECT NOT EXISTS (SELECT 1 FROM schema_migrations WHERE name = '${marker}')`
  }`.quiet().text()).trim() === "t";
  if (!pending) return;
  for (const constraint of constraints) {
    await $`psql ${url} -v ON_ERROR_STOP=1 -c ${
      `SET lock_timeout = '5s'; ALTER TABLE ${table} VALIDATE CONSTRAINT ${constraint}_v2`
    }`.quiet();
  }
  const swaps = constraints.map((constraint) =>
    `ALTER TABLE ${table} DROP CONSTRAINT IF EXISTS ${constraint};`
      + ` ALTER TABLE ${table} RENAME CONSTRAINT ${constraint}_v2 TO ${constraint};`
  ).join(" ");
  await $`psql ${url} -v ON_ERROR_STOP=1 -c ${
    `BEGIN; SET LOCAL lock_timeout = '5s'; ${swaps}`
      + ` INSERT INTO schema_migrations(name) VALUES ('${marker}'); COMMIT;`
  }`.quiet();
}

await completeConstraintMigration("media-constraints-v2", "media_objects", [
  "media_objects_upload_protocol_check",
  "media_objects_status_check",
  "media_objects_purpose_check",
]);
await completeConstraintMigration(
  "messages-media-group-shape-v2",
  "messages",
  ["messages_media_group_shape_check"],
);
await completeConstraintMigration("messages-domain-constraints-v2", "messages", [
  "messages_kind_check",
  "messages_service_type_check",
]);
await completeConstraintMigration(
  "account-events-type-v2",
  "account_events",
  ["account_events_type_check"],
);
async function completeNamedConstraintMigration(
  marker: string,
  table: string,
  current: string,
  candidate: string,
): Promise<void> {
  const pending = (await $`psql ${url} -v ON_ERROR_STOP=1 -qAt -c ${
    `SELECT NOT EXISTS (SELECT 1 FROM schema_migrations WHERE name = '${marker}')`
  }`.quiet().text()).trim() === "t";
  if (!pending) return;
  await $`psql ${url} -v ON_ERROR_STOP=1 -c ${
    `SET lock_timeout = '5s'; ALTER TABLE ${table} VALIDATE CONSTRAINT ${candidate}`
  }`.quiet();
  await $`psql ${url} -v ON_ERROR_STOP=1 -c ${
    `BEGIN; SET LOCAL lock_timeout = '5s';`
      + ` ALTER TABLE ${table} DROP CONSTRAINT IF EXISTS ${current};`
      + ` ALTER TABLE ${table} RENAME CONSTRAINT ${candidate} TO ${current};`
      + ` INSERT INTO schema_migrations(name) VALUES ('${marker}'); COMMIT;`
  }`.quiet();
}

await completeNamedConstraintMigration(
  "account-events-type-v3",
  "account_events",
  "account_events_type_check",
  "account_events_type_check_v3",
);
await completeConstraintMigration(
  "message-mutation-operation-v2",
  "message_mutation_requests",
  ["message_mutation_requests_operation_check"],
);

async function dropLegacyConstraintOnce(
  marker: string,
  table: string,
  constraint: string,
): Promise<void> {
  await $`psql ${url} -v ON_ERROR_STOP=1 -c ${
    `BEGIN; SET LOCAL lock_timeout = '5s';`
      + ` DO $migration$ BEGIN`
      + ` IF NOT EXISTS (SELECT 1 FROM schema_migrations WHERE name = '${marker}') THEN`
      + ` ALTER TABLE ${table} DROP CONSTRAINT IF EXISTS ${constraint};`
      + ` INSERT INTO schema_migrations(name) VALUES ('${marker}');`
      + ` END IF; END $migration$; COMMIT;`
  }`.quiet();
}

await dropLegacyConstraintOnce(
  "draft-request-dialog-fk-removal-v1",
  "draft_mutation_requests",
  "draft_mutation_requests_dialog_id_fkey",
);
await dropLegacyConstraintOnce(
  "media-group-request-dialog-fk-removal-v1",
  "media_group_send_requests",
  "media_group_send_requests_dialog_id_fkey",
);

const walStart = (await $`psql ${url} -v ON_ERROR_STOP=1 -qAt -c "SELECT pg_current_wal_lsn()"`.quiet().text()).trim();
await $`psql ${url} -v ON_ERROR_STOP=1 -f ${dialogPreferencesExpand}`.quiet();

let preferenceRowsScanned = 0;
let preferenceRowsInserted = 0;
let preferenceBackfillBatches = 0;
while (true) {
  const query = `
    WITH cursor AS MATERIALIZED (
      SELECT last_dialog_id, last_account_id
      FROM online_migration_cursors
      WHERE migration_name = 'dialog_preferences_v1'
      FOR UPDATE
    ), batch AS MATERIALIZED (
      SELECT member.dialog_id, member.account_id, member.notification_mode
      FROM dialog_members member
      CROSS JOIN cursor
      WHERE cursor.last_dialog_id IS NULL
         OR (member.dialog_id, member.account_id)
              > (cursor.last_dialog_id, cursor.last_account_id)
      ORDER BY member.dialog_id, member.account_id
      LIMIT ${preferenceBackfillBatchSize}
    ), inserted AS (
      INSERT INTO dialog_preferences (dialog_id, account_id, is_muted)
      SELECT dialog_id, account_id, notification_mode = 'muted'
      FROM batch
      ON CONFLICT (dialog_id, account_id) DO NOTHING
      RETURNING 1
    ), advanced AS (
      UPDATE online_migration_cursors progress
      SET last_dialog_id = COALESCE(
            (SELECT dialog_id FROM batch ORDER BY dialog_id DESC, account_id DESC LIMIT 1),
            progress.last_dialog_id
          ),
          last_account_id = COALESCE(
            (SELECT account_id FROM batch ORDER BY dialog_id DESC, account_id DESC LIMIT 1),
            progress.last_account_id
          ),
          rows_processed = progress.rows_processed + (SELECT count(*) FROM batch),
          completed_at = CASE
            WHEN (SELECT count(*) FROM batch) = 0 THEN COALESCE(progress.completed_at, now())
            ELSE NULL
          END,
          updated_at = now()
      WHERE progress.migration_name = 'dialog_preferences_v1'
      RETURNING rows_processed
    )
    SELECT
      (SELECT count(*) FROM batch),
      (SELECT count(*) FROM inserted),
      (SELECT rows_processed FROM advanced)
  `;
  const output = await $`psql ${url} -v ON_ERROR_STOP=1 -qAt -F "|" -c ${query}`.quiet().text();
  const [scannedText, insertedText] = output.trim().split("|");
  const scanned = Number(scannedText);
  const inserted = Number(insertedText);
  if (
    !Number.isSafeInteger(scanned)
    || scanned < 0
    || !Number.isSafeInteger(inserted)
    || inserted < 0
  ) {
    throw new Error("invalid dialog preference backfill result");
  }
  preferenceRowsScanned += scanned;
  preferenceRowsInserted += inserted;
  if (scanned === 0) break;
  preferenceBackfillBatches += 1;
}

await $`psql ${url} -v ON_ERROR_STOP=1 -f ${dialogPreferencesConcurrent}`.quiet();
await $`psql ${url} -v ON_ERROR_STOP=1 -c ${`
  SET lock_timeout = '2s';
  SET statement_timeout = '30min';
  DO $$
  BEGIN
    IF EXISTS (
      SELECT 1 FROM pg_constraint
      WHERE conrelid = 'account_events'::regclass
        AND conname = 'account_events_type_check_v5'
        AND NOT convalidated
    ) THEN
      ALTER TABLE account_events
        VALIDATE CONSTRAINT account_events_type_check_v5;
    END IF;
  END;
  $$;
`}`.quiet();
await $`psql ${url} -v ON_ERROR_STOP=1 -f ${dialogPreferencesContract}`.quiet();
let legacyPreferenceReconciliations = 0;
while (true) {
  const reconciliationQuery = `
    WITH batch AS MATERIALIZED (
      SELECT queue.dialog_id, queue.account_id
      FROM dialog_preference_legacy_reconciliation queue
      ORDER BY queue.account_id, queue.dialog_id
      LIMIT ${preferenceBackfillBatchSize}
      FOR UPDATE SKIP LOCKED
    ), account_counts AS MATERIALIZED (
      SELECT account_id, count(*)::bigint AS count
      FROM batch
      GROUP BY account_id
    ), locked AS MATERIALIZED (
      SELECT state.account_id, state.pts
      FROM account_sync_states state
      JOIN account_counts counts ON counts.account_id = state.account_id
      ORDER BY state.account_id
      FOR NO KEY UPDATE OF state
    ), numbered AS MATERIALIZED (
      SELECT batch.dialog_id, batch.account_id,
             locked.pts + row_number() OVER (
               PARTITION BY batch.account_id ORDER BY batch.dialog_id
             ) AS pts
      FROM batch
      JOIN locked ON locked.account_id = batch.account_id
    ), bumped AS (
      UPDATE account_sync_states state
      SET pts = state.pts + counts.count, updated_at = now()
      FROM account_counts counts
      WHERE state.account_id = counts.account_id
      RETURNING state.account_id
    ), events AS (
      INSERT INTO account_events (
        account_id, pts, type, dialog_id, actor_account_id, data
      )
      SELECT numbered.account_id, numbered.pts, 'dialog.preferences_updated',
             numbered.dialog_id, numbered.account_id,
             jsonb_build_object(
               'preferences', jsonb_build_object(
                 'dialogId', preference.dialog_id,
                 'pinned', preference.is_pinned,
                 'pinnedAt', preference.pinned_at,
                 'muted', preference.is_muted,
                 'archived', preference.is_archived,
                 'updatedAt', preference.updated_at
               ),
               'changed_fields', jsonb_build_array('muted'),
               'legacy_reconciled', TRUE
             )
      FROM numbered
      JOIN bumped ON bumped.account_id = numbered.account_id
      JOIN dialog_preferences preference
        ON preference.dialog_id = numbered.dialog_id
       AND preference.account_id = numbered.account_id
      RETURNING account_id, pts, dialog_id
    ), pushes AS (
      INSERT INTO push_deliveries (account_id, pts, device_id, alert)
      SELECT event.account_id, event.pts, device.id, FALSE
      FROM events event
      JOIN devices device ON device.account_id = event.account_id
      WHERE device.platform = 'ios'
        AND device.revoked_at IS NULL
        AND device.push_token_hash IS NOT NULL
        AND device.push_token_ciphertext IS NOT NULL
      ON CONFLICT (account_id, pts, device_id) DO NOTHING
      RETURNING account_id
    ), notified AS (
      SELECT pg_notify(
        'toj_sync_events',
        json_build_object(
          'accountId', account_id,
          'pts', max(pts),
          'ptsCount', count(*)
        )::text
      )
      FROM events
      GROUP BY account_id
    ), deleted AS (
      DELETE FROM dialog_preference_legacy_reconciliation queue
      USING events
      WHERE queue.dialog_id = events.dialog_id
        AND queue.account_id = events.account_id
      RETURNING queue.dialog_id
    )
    SELECT
      (SELECT count(*) FROM deleted),
      (SELECT count(*) FROM notified),
      (SELECT count(*) FROM pushes)
  `;
  const output = await $`psql ${url} -v ON_ERROR_STOP=1 -qAt -F "|" -c ${reconciliationQuery}`.quiet().text();
  const reconciled = Number(output.trim().split("|")[0]);
  if (!Number.isSafeInteger(reconciled) || reconciled < 0) {
    throw new Error("invalid legacy dialog preference reconciliation result");
  }
  legacyPreferenceReconciliations += reconciled;
  if (reconciled === 0) break;
}
const walBytesText = (
  await $`psql ${url} -v ON_ERROR_STOP=1 -qAt -c "SELECT pg_wal_lsn_diff(pg_current_wal_lsn(), '${walStart}'::pg_lsn)"`.quiet().text()
).trim();
const preferenceWalBytes = Number(walBytesText);
const migrationRuntimeMs = Math.round(performance.now() - migrationStartedAt);
const maxRuntimeMs = Number(process.env.TOJ_DIALOG_PREFERENCES_MIGRATION_MAX_RUNTIME_MS ?? 0);
const maxWalBytes = Number(process.env.TOJ_DIALOG_PREFERENCES_MIGRATION_MAX_WAL_BYTES ?? 0);
if (maxRuntimeMs > 0 && migrationRuntimeMs > maxRuntimeMs) {
  throw new Error(
    `dialog preference migration runtime ${migrationRuntimeMs}ms exceeded ${maxRuntimeMs}ms`,
  );
}
if (maxWalBytes > 0 && preferenceWalBytes > maxWalBytes) {
  throw new Error(
    `dialog preference migration WAL ${preferenceWalBytes} bytes exceeded ${maxWalBytes} bytes`,
  );
}

function redactUrl(value: string): string {
  try {
    const parsed = new URL(value);
    if (parsed.password) parsed.password = "REDACTED";
    return parsed.toString();
  } catch {
    return value.replace(/:\/\/([^:\s]+):([^@\s]+)@/, "://$1:REDACTED@");
  }
}

console.log(JSON.stringify({
  event: "database.migrated",
  database: redactUrl(url),
  callsBackfilled: backfilledCallCount,
  dialogPreferences: {
    rowsScanned: preferenceRowsScanned,
    rowsInserted: preferenceRowsInserted,
    batches: preferenceBackfillBatches,
    batchSize: preferenceBackfillBatchSize,
    legacyReconciliations: legacyPreferenceReconciliations,
    walBytes: preferenceWalBytes,
  },
  runtimeMs: migrationRuntimeMs,
}));
