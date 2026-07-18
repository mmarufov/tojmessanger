import { $ } from "bun";
import { DEFAULT_URL } from "./db";

// Apply contract DDL atomically, build indexes on existing hot tables without blocking writes,
// then validate the new constraint under a short lock timeout. Every phase is idempotent.
const url = process.env.DATABASE_URL ?? DEFAULT_URL;
const schema = new URL("./schema.sql", import.meta.url).pathname;
const concurrentSchema = new URL("./schema-concurrent.sql", import.meta.url).pathname;

await $`psql ${url} -v ON_ERROR_STOP=1 --single-transaction -c "SET LOCAL lock_timeout = '5s'" -f ${schema}`.quiet();
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

console.log(`migrated: ${redactUrl(url)}`);
