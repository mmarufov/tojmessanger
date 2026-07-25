import { $ } from "bun";

const sourceURL = new URL(
  process.env.TEST_DATABASE_URL ?? "postgres://localhost:5432/toj_test",
);
const suffix = crypto.randomUUID().replaceAll("-", "").slice(0, 12);
const databaseName = `toj_pref_migration_${suffix}`;
const adminURL = new URL(sourceURL);
adminURL.pathname = "/postgres";
const fixtureURL = new URL(sourceURL);
fixtureURL.pathname = `/${databaseName}`;
const fixtureRows = Math.max(
  10_000,
  Number(process.env.TOJ_MIGRATION_FIXTURE_ROWS ?? 100_000),
);
const maxWriterLatencyMs = Number(
  process.env.TOJ_MIGRATION_MAX_WRITER_LATENCY_MS ?? 1_000,
);
const maxRuntimeMs = Number(
  process.env.TOJ_MIGRATION_MAX_RUNTIME_MS ?? 120_000,
);
const maxWalBytes = Number(
  process.env.TOJ_MIGRATION_MAX_WAL_BYTES ?? 1_073_741_824,
);
const schema = new URL("../src/schema.sql", import.meta.url).pathname;
const concurrentSchema = new URL("../src/schema-concurrent.sql", import.meta.url).pathname;
const migrate = new URL("../src/migrate.ts", import.meta.url).pathname;
const accountId = "00000000-0000-4000-8000-000000000001";

let migrationFinished = false;
let maximumWriterLatencyMs = 0;
let writerSamples = 0;

try {
  await $`psql ${adminURL.toString()} -v ON_ERROR_STOP=1 -c ${`CREATE DATABASE ${databaseName}`}`.quiet();
  await $`psql ${fixtureURL.toString()} -v ON_ERROR_STOP=1 --single-transaction -f ${schema}`.quiet();
  await $`psql ${fixtureURL.toString()} -v ON_ERROR_STOP=1 -f ${concurrentSchema}`.quiet();
  await $`psql ${fixtureURL.toString()} -v ON_ERROR_STOP=1 -c ${`
    INSERT INTO accounts (
      id, phone_lookup_hash, phone_e164_ciphertext, phone_nonce, phone_key_id,
      display_name
    ) VALUES (
      '${accountId}', digest('migration-fixture', 'sha256'), decode('01', 'hex'),
      decode('02', 'hex'), 'fixture-key', 'Migration fixture'
    );
    INSERT INTO account_sync_states (account_id) VALUES ('${accountId}');
    INSERT INTO dialogs (id, type, title, created_by, updated_at)
    SELECT gen_random_uuid(), 'group', 'Migration fixture', '${accountId}',
           now() - (series * interval '1 millisecond')
    FROM generate_series(1, ${fixtureRows}) AS series;
    INSERT INTO dialog_members (dialog_id, account_id, notification_mode)
    SELECT id, '${accountId}', CASE WHEN row_number() OVER (ORDER BY id) % 3 = 0
      THEN 'muted' ELSE 'all' END
    FROM dialogs;
  `}`.quiet();
  const writerDialogId = (
    await $`psql ${fixtureURL.toString()} -v ON_ERROR_STOP=1 -qAt -c ${`
      SELECT dialog_id
      FROM dialog_members
      WHERE account_id = '${accountId}'
      ORDER BY dialog_id
      LIMIT 1
    `}`.quiet().text()
  ).trim();
  if (!writerDialogId) {
    throw new Error("migration fixture has no writable dialog member");
  }

  const migration = Bun.spawn(["bun", "run", migrate], {
    cwd: new URL("..", import.meta.url).pathname,
    env: {
      ...process.env,
      DATABASE_URL: fixtureURL.toString(),
      TOJ_DIALOG_PREFERENCE_BACKFILL_BATCH_SIZE: "1000",
      TOJ_DIALOG_PREFERENCES_MIGRATION_MAX_RUNTIME_MS: String(maxRuntimeMs),
      TOJ_DIALOG_PREFERENCES_MIGRATION_MAX_WAL_BYTES: String(maxWalBytes),
    },
    stdout: "pipe",
    stderr: "pipe",
  });

  const writer = (async () => {
    while (!migrationFinished) {
      const started = performance.now();
      await $`psql ${fixtureURL.toString()} -v ON_ERROR_STOP=1 -q -c ${`
        UPDATE dialog_members
        SET last_read_msg_id = last_read_msg_id + 1
        WHERE dialog_id = '${writerDialogId}'
          AND account_id = '${accountId}'
      `}`.quiet();
      maximumWriterLatencyMs = Math.max(
        maximumWriterLatencyMs,
        performance.now() - started,
      );
      writerSamples += 1;
      await Bun.sleep(5);
    }
  })();

  const exitCode = await migration.exited;
  migrationFinished = true;
  await writer;
  const stdout = await new Response(migration.stdout).text();
  const stderr = await new Response(migration.stderr).text();
  if (exitCode !== 0) {
    throw new Error(`migration failed (${exitCode}): ${stderr || stdout}`);
  }

  const verification = (
    await $`psql ${fixtureURL.toString()} -v ON_ERROR_STOP=1 -qAt -F "|" -c ${`
      SELECT
        (SELECT count(*) FROM dialog_preferences),
        (SELECT rows_processed FROM online_migration_cursors
         WHERE migration_name = 'dialog_preferences_v1'),
        (SELECT completed_at IS NOT NULL FROM online_migration_cursors
         WHERE migration_name = 'dialog_preferences_v1'),
        (SELECT convalidated FROM pg_constraint
         WHERE conrelid = 'account_events'::regclass
           AND conname = 'account_events_type_check'),
        (SELECT count(*) FROM dialog_preference_legacy_reconciliation)
    `}`.quiet().text()
  ).trim().split("|");
  const [preferenceCount, processedCount, completed, constraintValidated, backlog] =
    verification;
  if (
    Number(preferenceCount) !== fixtureRows
    || Number(processedCount) !== fixtureRows
    || completed !== "t"
    || constraintValidated !== "t"
    || Number(backlog) !== 0
  ) {
    throw new Error(`migration verification mismatch: ${verification.join("|")}`);
  }
  if (maximumWriterLatencyMs > maxWriterLatencyMs) {
    throw new Error(
      `writer latency ${maximumWriterLatencyMs.toFixed(1)}ms exceeded ${maxWriterLatencyMs}ms`,
    );
  }

  const reportLine = stdout.trim().split("\n").at(-1);
  const migrationReport = JSON.parse(reportLine ?? "{}");
  console.log(JSON.stringify({
    event: "dialog_preferences.online_migration_verified",
    fixtureRows,
    writerSamples,
    maximumWriterLatencyMs: Math.round(maximumWriterLatencyMs * 10) / 10,
    migration: migrationReport,
  }));
} finally {
  migrationFinished = true;
  await $`psql ${adminURL.toString()} -v ON_ERROR_STOP=1 -c ${`
    SELECT pg_terminate_backend(pid)
    FROM pg_stat_activity
    WHERE datname = '${databaseName}' AND pid <> pg_backend_pid();
  `}`.quiet();
  await $`psql ${adminURL.toString()} -v ON_ERROR_STOP=1 -c ${`
    DROP DATABASE IF EXISTS ${databaseName}
  `}`.quiet();
}
