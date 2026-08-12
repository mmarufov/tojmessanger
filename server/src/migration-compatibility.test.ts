import { $, type SQL } from "bun";
import { beforeEach, describe, expect, test } from "bun:test";
import { checkVerification, startVerification } from "./auth";
import { makeSql } from "./db";
import { getOrCreateDirectDialog } from "./sync";

const TEST_URL = process.env.TEST_DATABASE_URL ?? "postgres://localhost:5432/toj_test";
const db = makeSql(TEST_URL);
const sourceURL = new URL(TEST_URL);
const adminURL = new URL(sourceURL);
adminURL.pathname = "/postgres";
const schema = new URL("./schema.sql", import.meta.url).pathname;
const cloudProductivityExpand = new URL(
  "./schema-cloud-productivity-expand.sql",
  import.meta.url,
).pathname;
const cloudProductivityContract = new URL(
  "./schema-cloud-productivity-contract.sql",
  import.meta.url,
).pathname;

async function withSchemaDatabase(
  body: (fixture: { sql: SQL; runFile: (path: string) => Promise<void> }) => Promise<void>,
): Promise<void> {
  const databaseName = `toj_migration_${crypto.randomUUID().replaceAll("-", "").slice(0, 16)}`;
  const databaseURL = new URL(sourceURL);
  databaseURL.pathname = `/${databaseName}`;
  let sql: SQL | null = null;
  try {
    await $`psql ${adminURL.toString()} -v ON_ERROR_STOP=1 -c ${
      `CREATE DATABASE ${databaseName}`
    }`.quiet();
    const runFile = async (path: string) => {
      await $`psql ${databaseURL.toString()} -v ON_ERROR_STOP=1 -f ${path}`.quiet();
    };
    await runFile(schema);
    sql = makeSql(databaseURL.toString());
    await body({ sql, runFile });
  } finally {
    if (sql) await sql.close();
    await $`psql ${adminURL.toString()} -v ON_ERROR_STOP=1 -c ${`
      SELECT pg_terminate_backend(pid)
      FROM pg_stat_activity
      WHERE datname = '${databaseName}' AND pid <> pg_backend_pid()
    `}`.quiet();
    await $`psql ${adminURL.toString()} -v ON_ERROR_STOP=1 -c ${
      `DROP DATABASE IF EXISTS ${databaseName}`
    }`.quiet();
  }
}

async function accountEventConstraint(sql: SQL, name = "account_events_type_check") {
  return (await sql`
    SELECT convalidated, pg_get_constraintdef(oid, TRUE) AS definition
    FROM pg_constraint
    WHERE conrelid = 'account_events'::regclass
      AND conname = ${name}`)[0];
}

async function makeAccount(phone: string, name: string) {
  const { code } = await startVerification(db, phone);
  return await checkVerification(db, phone, code, "ios", `${name}'s iPhone`, name);
}

describe("forward migration and previous-release startup compatibility", () => {
  beforeEach(async () => {
    await db`TRUNCATE accounts, otp_challenges RESTART IDENTITY CASCADE`;
  });

  test("all appended event types write successfully and an older reader advances past opaque rows", async () => {
    const alice = await makeAccount("+16505557901", "Alice");
    const bob = await makeAccount("+16505557902", "Bob");
    const dialog = await getOrCreateDirectDialog(db, alice.accountId, bob.accountId);
    const appendedTypes = [
      "message.expired",
      "message.preview_updated",
      "member.role_changed",
      "member.left",
      "dialog.profile_updated",
      "dialog.closed",
      "dialog.access_revoked",
      "dialog.preferences_updated",
      "draft.updated",
      "security.changed",
      "chat_folders.updated",
      "scheduled.created",
      "scheduled.updated",
      "scheduled.canceled",
      "scheduled.failed",
      "pin.updated",
      "dialog.auto_delete_updated",
      "poll.updated",
      "sticker_preferences.updated",
    ];
    const startingPts = Number((await db`
      SELECT pts FROM account_sync_states WHERE account_id = ${alice.accountId}`)[0].pts);
    await db`
      UPDATE account_sync_states
      SET pts = pts + ${appendedTypes.length}
      WHERE account_id = ${alice.accountId}`;
    await db`
      INSERT INTO account_events(account_id, pts, type, dialog_id, actor_account_id)
      SELECT ${alice.accountId}, ${startingPts} + ordinal, type, ${dialog.dialogId}, ${alice.accountId}
      FROM unnest(${db.array(appendedTypes, "text")}::text[]) WITH ORDINALITY
        AS event(type, ordinal)`;

    // This is the previous-release startup contract: account/session rows and the monotonic state
    // remain readable, while unrecognized event payloads are treated as opaque and skipped.
    const previousStartup = (await db`
      SELECT account.status, state.pts
      FROM accounts account
      JOIN account_sync_states state ON state.account_id = account.id
      WHERE account.id = ${alice.accountId}`)[0];
    const opaquePage = await db`
      SELECT pts, type FROM account_events
      WHERE account_id = ${alice.accountId} AND pts > ${startingPts}
      ORDER BY pts`;
    expect(previousStartup.status).toBe("active");
    expect(Number(previousStartup.pts)).toBe(startingPts + appendedTypes.length);
    expect(opaquePage.map((row: any) => row.type)).toEqual(appendedTypes);
    expect(Number(opaquePage.at(-1)?.pts)).toBe(Number(previousStartup.pts));

    const constraint = (await db`
      SELECT pg_get_constraintdef(oid) AS definition
      FROM pg_constraint
      WHERE conrelid = 'account_events'::regclass
        AND conname = 'account_events_type_check'`)[0];
    expect(String(constraint.definition)).toContain("draft.updated");
    expect(String(constraint.definition)).toContain("dialog.preferences_updated");
    expect(String(constraint.definition)).toContain("security.changed");
    expect(String(constraint.definition)).toContain("chat_folders.updated");
    expect(String(constraint.definition)).toContain("scheduled.created");
    expect(String(constraint.definition)).toContain("pin.updated");
    expect(String(constraint.definition)).toContain("sticker_preferences.updated");
    expect(await db`
      SELECT name FROM schema_migrations
      WHERE name = 'account-events-type-v7'`).toHaveLength(1);
  });

  test("productivity reruns preserve newer event types and repair stale older candidates", async () => {
    await withSchemaDatabase(async ({ sql, runFile }) => {
      const current = await accountEventConstraint(sql);
      expect(current.convalidated).toBe(true);
      expect(String(current.definition)).toContain("sticker_preferences.updated");

      // A completed current schema is a no-op: do not create and validate another full-table
      // candidate merely because the historical migration file is rerun at startup.
      await runFile(cloudProductivityExpand);
      expect(await accountEventConstraint(sql, "account_events_type_check_v6")).toBeUndefined();

      // An out-of-order old deployment can leave its productivity-only candidate beside the newer
      // current constraint. The expand phase must remove it so contract cannot downgrade v7.
      await sql`
        ALTER TABLE account_events
        ADD CONSTRAINT account_events_type_check_v6 CHECK (type IN (
          'message.new','message.edited','message.deleted','message.preview_updated',
          'reaction.updated','read.updated','dialog.created','member.added','member.removed',
          'member.role_changed','member.left','dialog.profile_updated','dialog.closed',
          'dialog.access_revoked','dialog.preferences_updated','profile.updated','draft.updated',
          'chat_folders.updated','scheduled.created','scheduled.updated',
          'scheduled.canceled','scheduled.failed'
        )) NOT VALID`;
      await runFile(cloudProductivityExpand);
      expect(await accountEventConstraint(sql, "account_events_type_check_v6")).toBeUndefined();
      expect(String((await accountEventConstraint(sql)).definition))
        .toContain("sticker_preferences.updated");

      // If that older candidate was already contracted and its migration markers remain, current
      // code must still reconstruct the complete cross-feature constraint without relying on v7's
      // one-time marker to run again.
      await sql`ALTER TABLE account_events DROP CONSTRAINT account_events_type_check`;
      await sql`
        ALTER TABLE account_events
        ADD CONSTRAINT account_events_type_check CHECK (type IN (
          'message.new','message.edited','message.deleted','message.preview_updated',
          'reaction.updated','read.updated','dialog.created','member.added','member.removed',
          'member.role_changed','member.left','dialog.profile_updated','dialog.closed',
          'dialog.access_revoked','dialog.preferences_updated','profile.updated','draft.updated',
          'chat_folders.updated','scheduled.created','scheduled.updated',
          'scheduled.canceled','scheduled.failed'
        ))`;
      await runFile(cloudProductivityExpand);
      const replacement = await accountEventConstraint(sql, "account_events_type_check_v6");
      expect(replacement.convalidated).toBe(false);
      expect(String(replacement.definition)).toContain("security.changed");
      expect(String(replacement.definition)).toContain("sticker_preferences.updated");
      await sql`ALTER TABLE account_events VALIDATE CONSTRAINT account_events_type_check_v6`;
      await runFile(cloudProductivityContract);
      const repaired = await accountEventConstraint(sql);
      expect(repaired.convalidated).toBe(true);
      expect(String(repaired.definition)).toContain("message.expired");
      expect(String(repaired.definition)).toContain("security.changed");
      expect(String(repaired.definition)).toContain("pin.updated");
      expect(String(repaired.definition)).toContain("sticker_preferences.updated");
      expect(await accountEventConstraint(sql, "account_events_type_check_v6")).toBeUndefined();
    });
  }, 120_000);
});
