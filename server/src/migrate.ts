import { $ } from "bun";
import { DEFAULT_URL } from "./db";

// Apply contract DDL atomically, build indexes on existing hot tables without blocking writes,
// then validate the new constraint under a short lock timeout. Every phase is idempotent.
const url = process.env.DATABASE_URL ?? DEFAULT_URL;
const schema = new URL("./schema.sql", import.meta.url).pathname;
const concurrentSchema = new URL("./schema-concurrent.sql", import.meta.url).pathname;
const callMediaBackfillBatchSize = 1_000;

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

function redactUrl(value: string): string {
  try {
    const parsed = new URL(value);
    if (parsed.password) parsed.password = "REDACTED";
    return parsed.toString();
  } catch {
    return value.replace(/:\/\/([^:\s]+):([^@\s]+)@/, "://$1:REDACTED@");
  }
}

console.log(`migrated: ${redactUrl(url)} (${backfilledCallCount} calls backfilled)`);
