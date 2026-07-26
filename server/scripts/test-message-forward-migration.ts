import { $ } from "bun";
import { checkVerification, startVerification } from "../src/auth";
import { makeSql } from "../src/db";
import { backfillMessageForwardMarkers } from "../src/message-forward-backfill";
import { ensureSavedMessages } from "../src/saved-messages";
import { getOrCreateDirectDialog, sendMessage } from "../src/sync";

const url = process.env.MIGRATION_TEST_DATABASE_URL
  ?? "postgres://localhost:5432/toj_migration_test";
const parsed = new URL(url);
const databaseName = parsed.pathname.slice(1);
if (!["localhost", "127.0.0.1", "::1"].includes(parsed.hostname)
    || !databaseName.endsWith("_migration_test")) {
  throw new Error("migration test refuses non-local databases or names without _migration_test");
}

// A dedicated disposable database prevents production-sized DDL tests from perturbing toj_test.
await $`createdb ${databaseName}`.nothrow().quiet();
const db = makeSql(url);
await db.unsafe("DROP SCHEMA public CASCADE; CREATE SCHEMA public");
await db.end();

process.env.DATABASE_URL = url;
await $`bun run src/migrate.ts`.quiet();
const sql = makeSql(url);

async function account(phone: string, name: string) {
  const { code } = await startVerification(sql, phone);
  return checkVerification(sql, phone, code, "ios", `${name} iPhone`, name);
}

const owner = await account("+16505554990", "Migration Owner");
const peer = await account("+16505554991", "Migration Peer");
const saved = await ensureSavedMessages(sql, owner.accountId, owner.deviceId);
const source = await sendMessage(sql, {
  senderAccountId: owner.accountId,
  senderDeviceId: owner.deviceId,
  dialogId: saved.dialogId,
  clientMsgId: crypto.randomUUID(),
  body: "migration source",
});
const direct = await getOrCreateDirectDialog(sql, owner.accountId, peer.accountId);
await sendMessage(sql, {
  senderAccountId: owner.accountId,
  senderDeviceId: owner.deviceId,
  dialogId: direct.dialogId,
  clientMsgId: crypto.randomUUID(),
  body: "reply anchor",
});

await sql`ALTER TABLE messages DROP CONSTRAINT messages_forward_marker_check`;
await sql`ALTER TABLE messages DISABLE TRIGGER messages_derive_forward_marker`;
await sql`
  INSERT INTO messages (
    dialog_id, msg_id, sender_account_id, sender_device_id, client_msg_id, kind,
    body_key_id, body_nonce, body_ciphertext, reply_to_msg_id,
    forwarded_from_account_id, forwarded_from_dialog_id, forwarded_from_msg_id,
    is_forwarded
  )
  SELECT
    ${direct.dialogId}, generated, ${owner.accountId}, ${owner.deviceId},
    gen_random_uuid(), 'text', 'migration-test', decode('00', 'hex'), decode('00', 'hex'),
    CASE WHEN generated BETWEEN 1_002 AND 1_101 THEN 1 ELSE NULL END,
    CASE WHEN generated <= 1_001 THEN ${owner.accountId}::uuid ELSE NULL END,
    CASE WHEN generated <= 1_001 THEN ${saved.dialogId}::uuid ELSE NULL END,
    CASE WHEN generated <= 1_001 THEN ${source.msgId}::bigint ELSE NULL END,
    FALSE
  FROM generate_series(2, 100001) AS generated`;
await sql`ALTER TABLE messages ENABLE TRIGGER messages_derive_forward_marker`;
await sql`
  ALTER TABLE messages ADD CONSTRAINT messages_forward_marker_check
  CHECK (
    forwarded_from_dialog_id IS NULL
    OR forwarded_from_msg_id IS NULL
    OR is_forwarded = TRUE
  ) NOT VALID`;
await sql`
  UPDATE schema_migration_progress
  SET cursor_dialog_id = NULL, cursor_msg_id = NULL, rows_processed = 0,
      completed_at = NULL, updated_at = now()
  WHERE migration_name = 'messages_is_forwarded_v1'`;
await sql.end();

const backfillIndex = new URL(
  "../src/schema-message-forward-backfill-index.sql",
  import.meta.url,
).pathname;
await $`psql ${url} -v ON_ERROR_STOP=1 -f ${backfillIndex}`.quiet();
const migrationSql = makeSql(url);
const beforeLsn = String((await migrationSql`SELECT pg_current_wal_lsn() AS lsn`)[0].lsn);
const startedAt = performance.now();
const backfillPromise = backfillMessageForwardMarkers(migrationSql, 250);
const oldWriter = migrationSql`
  INSERT INTO messages (
    dialog_id, msg_id, sender_account_id, sender_device_id, client_msg_id, kind,
    body_key_id, body_nonce, body_ciphertext,
    forwarded_from_account_id, forwarded_from_dialog_id, forwarded_from_msg_id
  ) VALUES (
    ${direct.dialogId}, 100002, ${owner.accountId}, ${owner.deviceId}, gen_random_uuid(),
    'text', 'migration-test', decode('00', 'hex'), decode('00', 'hex'),
    ${owner.accountId}, ${saved.dialogId}, ${source.msgId}
  )
  RETURNING is_forwarded`;
const [backfill, oldWriterRows] = await Promise.all([backfillPromise, oldWriter]);
const runtimeMs = performance.now() - startedAt;
const afterLsn = String((await migrationSql`SELECT pg_current_wal_lsn() AS lsn`)[0].lsn);
const walBytes = Number((await migrationSql`
  SELECT pg_wal_lsn_diff(${afterLsn}::pg_lsn, ${beforeLsn}::pg_lsn) AS bytes`)[0].bytes);
if (backfill.processed !== 1_000 || backfill.batches !== 4) {
  throw new Error(`unexpected keyset result: ${JSON.stringify(backfill)}`);
}
if (!Boolean(oldWriterRows[0]?.is_forwarded)) {
  throw new Error("old writer omission did not derive is_forwarded=true");
}
if (runtimeMs > 30_000 || walBytes <= 0 || walBytes > 256 * 1024 * 1024) {
  throw new Error(`migration budget exceeded: runtime=${runtimeMs}ms wal=${walBytes}`);
}

const contract = new URL("../src/schema-message-forward-contract.sql", import.meta.url).pathname;
await migrationSql.end();
await $`psql ${url} -v ON_ERROR_STOP=1 -f ${contract}`.quiet();
const evidenceSql = makeSql(url);
const repeat = await backfillMessageForwardMarkers(evidenceSql, 250);
if (!repeat.skippedCompleted || repeat.processed !== 0 || repeat.batches !== 0) {
  throw new Error(`completed migration did not skip: ${JSON.stringify(repeat)}`);
}

const provenancePlanRows = await evidenceSql`
  EXPLAIN (FORMAT TEXT)
  UPDATE messages AS copy
  SET is_forwarded = TRUE,
      forwarded_from_account_id = NULL,
      forwarded_from_dialog_id = NULL,
      forwarded_from_msg_id = NULL
  FROM dialogs AS source_dialog
  WHERE copy.forwarded_from_dialog_id = source_dialog.id
    AND copy.forwarded_from_msg_id IS NOT NULL
    AND source_dialog.type = 'saved'
    AND source_dialog.created_by = ${owner.accountId}`;
const replyPlanRows = await evidenceSql`
  EXPLAIN (FORMAT TEXT)
  SELECT dialog_id, msg_id
  FROM messages
  WHERE dialog_id = ${direct.dialogId} AND reply_to_msg_id = 1`;
const planText = (rows: any[]) => rows.map((row) => String(Object.values(row)[0])).join("\n");
const provenancePlan = planText(provenancePlanRows);
const replyPlan = planText(replyPlanRows);
if (!provenancePlan.includes("messages_forward_provenance_idx")) {
  throw new Error(`account deletion plan missed provenance index:\n${provenancePlan}`);
}
if (!replyPlan.includes("messages_reply_target_idx")) {
  throw new Error(`reply plan missed reply index:\n${replyPlan}`);
}
const tempIndex = await evidenceSql`
  SELECT 1 FROM pg_class WHERE oid = to_regclass('messages_forward_marker_backfill_idx')`;
if (tempIndex.length !== 0) throw new Error("contract did not remove temporary backfill index");

const normalSchema = await Bun.file(
  new URL("../src/schema.sql", import.meta.url),
).text();
if (/UPDATE\s+messages[\s\S]{0,200}is_forwarded/i.test(normalSchema)) {
  throw new Error("normal schema migration contains an is_forwarded table update");
}
const concurrentSchema = await Bun.file(
  new URL("../src/schema-concurrent.sql", import.meta.url),
).text();
for (const index of [
  "messages_forward_provenance_idx",
  "messages_reply_target_idx",
  "messages_forward_marker_backfill_idx",
]) {
  if (!concurrentSchema.includes(index) || !concurrentSchema.includes("NOT idx.indisvalid")) {
    throw new Error(`interrupted-index cleanup is incomplete for ${index}`);
  }
}
await evidenceSql.end();

// Rerun the normal migration twice against 100k rows. Completion state skips the temporary index
// and keyset probe; this intentionally does not execute the production Saved-dialog backfill.
const rerunStartedAt = performance.now();
await $`bun run src/migrate.ts`.quiet();
await $`bun run src/migrate.ts`.quiet();
const rerunRuntimeMs = performance.now() - rerunStartedAt;

console.log(JSON.stringify({
  rows: 100_001,
  keysetRows: backfill.processed,
  batches: backfill.batches,
  batchSize: 250,
  concurrentOldWriterDerivedMarker: true,
  runtimeMs: Math.round(runtimeMs),
  walBytes,
  rerunRuntimeMs: Math.round(rerunRuntimeMs),
  completedRerunSkipped: repeat.skippedCompleted,
  provenancePlan: provenancePlan.split("\n").find((line) =>
    line.includes("messages_forward_provenance_idx")),
  replyPlan: replyPlan.split("\n").find((line) =>
    line.includes("messages_reply_target_idx")),
  temporaryIndexRemoved: true,
}));
