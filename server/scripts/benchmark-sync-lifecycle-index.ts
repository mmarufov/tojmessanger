import { makeSql } from "../src/db";

const url = process.env.DATABASE_URL
  ?? process.env.TEST_DATABASE_URL
  ?? "postgres://localhost:5432/toj_test";
const sql = makeSql(url);
const accountId = crypto.randomUUID();
const lifecycleDialogId = crypto.randomUUID();
const unrelatedEvents = Number(process.env.TOJ_SYNC_BENCH_EVENTS ?? 250_000);

if (!Number.isSafeInteger(unrelatedEvents) || unrelatedEvents < 100_000) {
  throw new Error("TOJ_SYNC_BENCH_EVENTS must be an integer of at least 100000");
}

const planText = (rows: any[]) =>
  rows.map((row) => String(Object.values(row)[0])).join("\n");

try {
  await sql`
    INSERT INTO accounts (
      id, phone_lookup_hash, phone_e164_ciphertext, phone_nonce, phone_key_id,
      display_name
    ) VALUES (
      ${accountId}, ${crypto.getRandomValues(new Uint8Array(32))},
      ${crypto.getRandomValues(new Uint8Array(32))},
      ${crypto.getRandomValues(new Uint8Array(12))}, 'sync-benchmark', 'Sync Benchmark'
    )`;
  await sql`
    INSERT INTO account_events (
      account_id, pts, type, dialog_id, data
    )
    SELECT
      ${accountId},
      series,
      CASE WHEN series = ${Math.floor(unrelatedEvents / 2)}
        THEN 'dialog.access_revoked'
        ELSE 'profile.updated'
      END,
      CASE WHEN series = ${Math.floor(unrelatedEvents / 2)}
        THEN ${lifecycleDialogId}::uuid
        ELSE gen_random_uuid()
      END,
      '{}'::jsonb
    FROM generate_series(1, ${unrelatedEvents}) AS series`;
  await sql`
    INSERT INTO account_events (account_id, pts, type, dialog_id, data)
    SELECT ${accountId}, ${unrelatedEvents} + series, 'member.added',
           ${lifecycleDialogId}, '{}'::jsonb
    FROM generate_series(1, 200) AS series`;
  await sql`ANALYZE account_events`;

  const plan = planText(await sql`
    EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
    WITH page AS MATERIALIZED (
      SELECT *
      FROM account_events
      WHERE account_id = ${accountId} AND pts > ${unrelatedEvents}
      ORDER BY pts
      LIMIT 200
    )
    SELECT ae.pts, prior_access.type, prior_access.pts
    FROM page ae
    LEFT JOIN LATERAL (
      SELECT boundary.type, boundary.pts
      FROM account_events boundary
      WHERE boundary.account_id = ${accountId}
        AND boundary.dialog_id = ae.dialog_id
        AND boundary.pts <= ${unrelatedEvents}
        AND boundary.type IN ('dialog.created', 'dialog.access_revoked')
      ORDER BY boundary.pts DESC
      LIMIT 1
    ) prior_access ON true`);

  if (!plan.includes("account_events_lifecycle_lookup_idx")) {
    throw new Error(`sync lifecycle lookup missed partial index:\n${plan}`);
  }
  if (/Rows Removed by Filter: [1-9][0-9]{4,}/.test(plan)) {
    throw new Error(`sync lifecycle lookup scanned unrelated account history:\n${plan}`);
  }
  const executionMs = Number(plan.match(/Execution Time: ([0-9.]+) ms/)?.[1] ?? "NaN");
  if (!Number.isFinite(executionMs) || executionMs > 500) {
    throw new Error(`sync lifecycle lookup exceeded 500ms: ${executionMs}\n${plan}`);
  }
  console.log(JSON.stringify({
    event: "sync.lifecycle_lookup_benchmark",
    unrelatedEvents,
    pageEvents: 200,
    executionMs,
    index: "account_events_lifecycle_lookup_idx",
  }));
} finally {
  await sql`DELETE FROM accounts WHERE id = ${accountId}`.catch(() => {});
  await sql.end();
}
