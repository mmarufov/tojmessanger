import { $ } from "bun";
import { DEFAULT_URL } from "./db";

// Applies schema.sql (idempotent DDL) via psql, which reliably handles multi-statement DDL.
const url = process.env.DATABASE_URL ?? DEFAULT_URL;
const schema = new URL("./schema.sql", import.meta.url).pathname;

await $`psql ${url} -v ON_ERROR_STOP=1 -f ${schema}`.quiet();

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
