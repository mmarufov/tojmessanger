import { $ } from "bun";
import { DEFAULT_URL, makeSql } from "./db";
import { backfillMessageForwardMarkers } from "./message-forward-backfill";
import { reconcileExistingSavedDialogs } from "./saved-dialog-reconciliation";

// Apply contract DDL atomically, build indexes on existing hot tables without blocking writes,
// then validate the new constraint under a short lock timeout. Every phase is idempotent.
const url = process.env.DATABASE_URL ?? DEFAULT_URL;
const schema = new URL("./schema.sql", import.meta.url).pathname;
const concurrentSchema = new URL("./schema-concurrent.sql", import.meta.url).pathname;
const dialogExpandSchema = new URL("./schema-dialogs-expand.sql", import.meta.url).pathname;
const dialogSwapSchema = new URL("./schema-dialogs-swap.sql", import.meta.url).pathname;
const messageForwardExpandSchema = new URL(
  "./schema-message-forward-expand.sql",
  import.meta.url,
).pathname;
const messageForwardContractSchema = new URL(
  "./schema-message-forward-contract.sql",
  import.meta.url,
).pathname;
const messageForwardBackfillIndexSchema = new URL(
  "./schema-message-forward-backfill-index.sql",
  import.meta.url,
).pathname;
const savedAccessExpandSchema = new URL(
  "./schema-saved-access-expand.sql",
  import.meta.url,
).pathname;
const callMediaBackfillBatchSize = 1_000;

await $`psql ${url} -v ON_ERROR_STOP=1 --single-transaction -c "SET LOCAL lock_timeout = '5s'" -f ${schema}`.quiet();
await $`psql ${url} -v ON_ERROR_STOP=1 -f ${dialogExpandSchema}`.quiet();
await $`psql ${url} -v ON_ERROR_STOP=1 -c "SET lock_timeout = '5s'; ALTER TABLE dialogs VALIDATE CONSTRAINT dialogs_type_check_saved_expand"`.quiet();
await $`psql ${url} -v ON_ERROR_STOP=1 -c "SET lock_timeout = '5s'; ALTER TABLE dialogs VALIDATE CONSTRAINT dialogs_saved_owner_check"`.quiet();
await $`psql ${url} -v ON_ERROR_STOP=1 -f ${dialogSwapSchema}`.quiet();
await $`psql ${url} -v ON_ERROR_STOP=1 -f ${messageForwardExpandSchema}`.quiet();
await $`psql ${url} -v ON_ERROR_STOP=1 -f ${savedAccessExpandSchema}`.quiet();
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
const forwardMigrationComplete = (
  await $`psql ${url} -v ON_ERROR_STOP=1 -qAt -c "SELECT EXISTS (SELECT 1 FROM schema_migration_progress WHERE migration_name = 'messages_is_forwarded_v1' AND completed_at IS NOT NULL)"`.quiet().text()
).trim() === "t";
if (!forwardMigrationComplete) {
  await $`psql ${url} -v ON_ERROR_STOP=1 -f ${messageForwardBackfillIndexSchema}`.quiet();
}
const migrationSql = makeSql(url);
let messageForwardBackfill;
let savedDialogReconciliation;
try {
  messageForwardBackfill = await backfillMessageForwardMarkers(migrationSql);
  savedDialogReconciliation = await reconcileExistingSavedDialogs(migrationSql);
} finally {
  await migrationSql.end();
}
await $`psql ${url} -v ON_ERROR_STOP=1 -f ${messageForwardContractSchema}`.quiet();
await $`psql ${url} -v ON_ERROR_STOP=1 -c "SET lock_timeout = '5s'; ALTER TABLE devices VALIDATE CONSTRAINT devices_voip_push_environment_check"`.quiet();

function redactUrl(value: string): string {
  try {
    const parsed = new URL(value);
    if (parsed.password) parsed.password = "REDACTED";
    return parsed.toString();
  } catch {
    return value.replace(/:\/\/([^:\s]+):([^@\s]+)@/, "://$1:REDACTED@");
  }
}

console.log(
  `migrated: ${redactUrl(url)} (${backfilledCallCount} calls backfilled, `
  + `${messageForwardBackfill.processed} forward markers in ${messageForwardBackfill.batches} batches, `
  + `${savedDialogReconciliation.processed} Saved dialogs reconciled)`,
);
