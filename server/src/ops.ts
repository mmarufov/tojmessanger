import type { SQL } from "bun";
import { cleanupCallData } from "./calls";
import { dialogPreferenceSchemaState } from "./dialog-preference-readiness";

const REQUEST_ID_PATTERN = /^[A-Za-z0-9._:-]{8,128}$/;
const CLEANUP_BATCH_SIZE = 1_000;

export type ProviderState = "configured" | "development" | "disabled";

export function requestIdFrom(req: Request): string {
  const supplied = req.headers.get("x-request-id")?.trim() ?? "";
  return REQUEST_ID_PATTERN.test(supplied) ? supplied : crypto.randomUUID();
}

export function safeRoute(pathname: string): string {
  if (/^\/v1\/devices\/[0-9a-f-]+$/i.test(pathname)) return "/v1/devices/:id";
  if (/^\/v1\/media\/uploads\/[0-9a-f-]+\/chunks$/i.test(pathname)) return "/v1/media/uploads/:id/chunks";
  if (/^\/v1\/media\/uploads\/[0-9a-f-]+\/parts\/\d+$/i.test(pathname)) return "/v1/media/uploads/:id/parts/:part";
  if (/^\/v1\/media\/uploads\/[0-9a-f-]+\/thumbnail$/i.test(pathname)) return "/v1/media/uploads/:id/thumbnail";
  if (/^\/v1\/media\/uploads\/[0-9a-f-]+\/complete$/i.test(pathname)) return "/v1/media/uploads/:id/complete";
  if (/^\/v1\/media\/uploads\/[0-9a-f-]+$/i.test(pathname)) return "/v1/media/uploads/:id";
  if (/^\/v1\/media\/[0-9a-f-]+\/chunks$/i.test(pathname)) return "/v1/media/:id/chunks";
  if (/^\/v1\/media\/[0-9a-f-]+\/thumbnail$/i.test(pathname)) return "/v1/media/:id/thumbnail";
  if (/^\/v1\/blocks\/[0-9a-f-]+$/i.test(pathname)) return "/v1/blocks/:id";
  if (/^\/v1\/dialogs\/[0-9a-f-]+\/preferences$/i.test(pathname)) {
    return "/v1/dialogs/:id/preferences";
  }
  if (/^\/v1\/calls\/[0-9a-f-]+\/(accept|reveal|confirm|decline|cancel|end|events|ice-config|telemetry)$/i.test(pathname)) {
    return pathname.replace(/[0-9a-f-]{36}/i, ":id");
  }
  if (/^\/v1\/calls\/[0-9a-f-]+$/i.test(pathname)) return "/v1/calls/:id";
  const known = new Set([
    "/health", "/ready", "/metrics", "/v1/capabilities", "/v1/ws", "/v1/auth/start", "/v1/auth/check",
    "/v1/devices", "/v1/devices/push", "/v1/devices/voip-push", "/v1/session", "/v1/account/deletion/start",
    "/v1/account", "/v1/sync/state",
    "/v1/sync/difference", "/v1/bootstrap/start", "/v1/bootstrap/dialogs",
    "/v1/contacts/lookup", "/v1/dialogs/direct", "/v1/messages/send", "/v1/messages/react",
    "/v1/messages/edit", "/v1/messages/delete", "/v1/history", "/v1/read",
    "/v1/media/uploads", "/v1/calls", "/v1/calls/active",
  ]);
  return known.has(pathname) ? pathname : "unmatched";
}

function statusClass(status: number): string {
  return `${Math.floor(status / 100)}xx`;
}

function metricLabel(value: string): string {
  return value.replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/\n/g, "\\n");
}

export class OperationalMetrics {
  private readonly startedAt = Date.now();
  private readonly requests = new Map<string, number>();
  private readonly durations = new Map<string, { count: number; sumSeconds: number }>();

  record(method: string, route: string, status: number, durationMs: number): void {
    const key = `${method}\u0000${route}\u0000${statusClass(status)}`;
    this.requests.set(key, (this.requests.get(key) ?? 0) + 1);
    const durationKey = `${method}\u0000${route}`;
    const duration = this.durations.get(durationKey) ?? { count: 0, sumSeconds: 0 };
    duration.count += 1;
    duration.sumSeconds += durationMs / 1_000;
    this.durations.set(durationKey, duration);
  }

  render(): string {
    const lines = [
      "# HELP toj_process_uptime_seconds Process uptime in seconds.",
      "# TYPE toj_process_uptime_seconds gauge",
      `toj_process_uptime_seconds ${Math.floor((Date.now() - this.startedAt) / 1_000)}`,
      "# HELP toj_http_requests_total HTTP requests by safe route and status class.",
      "# TYPE toj_http_requests_total counter",
    ];
    for (const [key, count] of [...this.requests].sort()) {
      const [method, route, status] = key.split("\u0000");
      lines.push(`toj_http_requests_total{method="${metricLabel(method)}",route="${metricLabel(route)}",status="${status}"} ${count}`);
    }
    lines.push(
      "# HELP toj_http_request_duration_seconds_sum Cumulative HTTP request duration.",
      "# TYPE toj_http_request_duration_seconds_sum counter",
      "# HELP toj_http_request_duration_seconds_count Count of timed HTTP requests.",
      "# TYPE toj_http_request_duration_seconds_count counter",
    );
    for (const [key, value] of [...this.durations].sort()) {
      const [method, route] = key.split("\u0000");
      const labels = `method="${metricLabel(method)}",route="${metricLabel(route)}"`;
      lines.push(`toj_http_request_duration_seconds_sum{${labels}} ${value.sumSeconds.toFixed(6)}`);
      lines.push(`toj_http_request_duration_seconds_count{${labels}} ${value.count}`);
    }
    return `${lines.join("\n")}\n`;
  }
}

export async function dialogPreferenceBacklogMetrics(sql: SQL): Promise<string> {
  const schema = (await sql`
    SELECT pg_catalog.to_regclass('public.dialog_preference_requests') IS NOT NULL
             AS requests_present,
           pg_catalog.to_regclass('public.dialog_preference_action_budgets') IS NOT NULL
             AS budgets_present`)[0];
  if (!schema?.requests_present || !schema?.budgets_present) {
    return [
      "# HELP toj_dialog_preference_schema_available Whether preference metrics relations exist.",
      "# TYPE toj_dialog_preference_schema_available gauge",
      "toj_dialog_preference_schema_available 0",
      "",
    ].join("\n");
  }
  const row = (await sql`
    SELECT
      (SELECT pg_catalog.count(*)
       FROM public.dialog_preference_requests
       WHERE status = 'pending')
        AS pending_requests,
      (SELECT GREATEST(reltuples, 0)::bigint
       FROM pg_catalog.pg_class
       WHERE oid = 'public.dialog_preference_requests'::pg_catalog.regclass)
        AS retained_request_estimate,
      (SELECT pg_catalog.count(*)
       FROM public.dialog_preference_action_budgets
       WHERE updated_at < now() - interval '24 hours')
        AS expired_budget_rows`)[0];
  return [
    "# HELP toj_dialog_preference_schema_available Whether preference metrics relations exist.",
    "# TYPE toj_dialog_preference_schema_available gauge",
    "toj_dialog_preference_schema_available 1",
    "# HELP toj_dialog_preference_pending_requests Pending idempotency claims.",
    "# TYPE toj_dialog_preference_pending_requests gauge",
    `toj_dialog_preference_pending_requests ${Number(row.pending_requests)}`,
    "# HELP toj_dialog_preference_idempotency_rows_estimate Planner estimate of durable dedupe rows.",
    "# TYPE toj_dialog_preference_idempotency_rows_estimate gauge",
    `toj_dialog_preference_idempotency_rows_estimate ${Number(row.retained_request_estimate)}`,
    "# HELP toj_dialog_preference_cleanup_backlog_rows Expired bounded-lifecycle rows awaiting cleanup.",
    "# TYPE toj_dialog_preference_cleanup_backlog_rows gauge",
    `toj_dialog_preference_cleanup_backlog_rows{table="budgets"} ${Number(row.expired_budget_rows)}`,
    "",
  ].join("\n");
}

export function providerState(value: unknown): ProviderState {
  return value ? "configured" : "disabled";
}

export async function readiness(sql: SQL, providers: { sms: ProviderState; push: ProviderState }) {
  const started = performance.now();
  await sql`SELECT 1`;
  const preferences = await dialogPreferenceSchemaState(sql, { bypassCache: true });
  return {
    // Preference relations and snapshot columns are linked into ordinary messaging SQL. Feature
    // switches control entrypoints and behavior, not whether this binary can run on a pre-expand
    // schema, so traffic admission must always fail closed while they are incomplete.
    status: preferences.ready ? "ready" : "not_ready",
    database: "ready",
    providers,
    dialogPreferences: preferences,
    databaseLatencyMs: Math.max(0, Math.round((performance.now() - started) * 10) / 10),
  };
}

export async function cleanupExpiredData(sql: SQL, batchSize = CLEANUP_BATCH_SIZE) {
  const callData = await cleanupCallData(sql, batchSize);
  const otp = await sql`
    WITH doomed AS (
      SELECT id FROM otp_challenges
      WHERE expires_at < now() - interval '24 hours'
      ORDER BY expires_at LIMIT ${batchSize}
      FOR UPDATE SKIP LOCKED
    )
    DELETE FROM otp_challenges WHERE id IN (SELECT id FROM doomed)
    RETURNING id`;
  const snapshots = await sql`
    WITH doomed AS (
      SELECT id FROM bootstrap_snapshots
      WHERE expires_at < now()
      ORDER BY expires_at LIMIT ${batchSize}
      FOR UPDATE SKIP LOCKED
    )
    DELETE FROM bootstrap_snapshots WHERE id IN (SELECT id FROM doomed)
    RETURNING id`;
  const deliveries = await sql`
    WITH doomed AS (
      SELECT id FROM push_deliveries
      WHERE status IN ('sent', 'dead') AND created_at < now() - interval '7 days'
      ORDER BY created_at LIMIT ${batchSize}
      FOR UPDATE SKIP LOCKED
    )
    DELETE FROM push_deliveries WHERE id IN (SELECT id FROM doomed)
    RETURNING id`;
  const contactLookups = await sql`
    WITH doomed AS (
      SELECT id FROM contact_lookup_attempts
      WHERE created_at < now() - interval '24 hours'
      ORDER BY created_at LIMIT ${batchSize}
      FOR UPDATE SKIP LOCKED
    )
    DELETE FROM contact_lookup_attempts WHERE id IN (SELECT id FROM doomed)
    RETURNING id`;
  const media = await sql`
    WITH doomed AS (
      SELECT id FROM media_objects
      WHERE status IN ('uploading', 'rejected') AND expires_at < now()
      ORDER BY expires_at LIMIT ${batchSize}
      FOR UPDATE SKIP LOCKED
    )
    DELETE FROM media_objects WHERE id IN (SELECT id FROM doomed)
    RETURNING id`;
  const mediaAttempts = await sql`
    WITH doomed AS (
      SELECT id FROM media_upload_attempts
      WHERE created_at < now() - interval '24 hours'
      ORDER BY created_at LIMIT ${batchSize}
      FOR UPDATE SKIP LOCKED
    )
    DELETE FROM media_upload_attempts WHERE id IN (SELECT id FROM doomed)
    RETURNING id`;
  const mediaOrphans = await sql`
    WITH doomed AS (
      SELECT mo.id FROM media_objects mo
      WHERE mo.status = 'ready' AND mo.completed_at < now() - interval '24 hours'
        AND NOT EXISTS (SELECT 1 FROM messages m WHERE m.media_id = mo.id AND m.state = 'visible')
        AND NOT EXISTS (SELECT 1 FROM dialogs d WHERE d.photo_media_id = mo.id)
      ORDER BY mo.completed_at LIMIT ${batchSize}
      FOR UPDATE OF mo SKIP LOCKED
    )
    DELETE FROM media_objects WHERE id IN (SELECT id FROM doomed)
    RETURNING id`;
  const sendRequests = await sql`
    WITH doomed AS (
      SELECT sender_account_id, client_msg_id FROM send_requests
      WHERE created_at < now() - interval '24 hours'
      ORDER BY created_at LIMIT ${batchSize}
      FOR UPDATE SKIP LOCKED
    )
    DELETE FROM send_requests request USING doomed
    WHERE request.sender_account_id = doomed.sender_account_id
      AND request.client_msg_id = doomed.client_msg_id
    RETURNING request.client_msg_id`;
  const messageMutations = await sql`
    WITH doomed AS (
      SELECT actor_account_id, client_mutation_id FROM message_mutation_requests
      WHERE created_at < now() - interval '24 hours'
      ORDER BY created_at LIMIT ${batchSize}
      FOR UPDATE SKIP LOCKED
    )
    DELETE FROM message_mutation_requests request USING doomed
    WHERE request.actor_account_id = doomed.actor_account_id
      AND request.client_mutation_id = doomed.client_mutation_id
    RETURNING request.client_mutation_id`;
  const groupCreates = await sql`
    WITH doomed AS (
      SELECT creator_account_id, client_group_id FROM group_create_requests
      WHERE created_at < now() - interval '24 hours'
      ORDER BY created_at LIMIT ${batchSize}
      FOR UPDATE SKIP LOCKED
    )
    DELETE FROM group_create_requests request USING doomed
    WHERE request.creator_account_id = doomed.creator_account_id
      AND request.client_group_id = doomed.client_group_id
    RETURNING request.client_group_id`;
  const groupMutations = await sql`
    WITH doomed AS (
      SELECT actor_account_id, client_mutation_id FROM group_mutation_requests
      WHERE created_at < now() - interval '24 hours'
      ORDER BY created_at LIMIT ${batchSize}
      FOR UPDATE SKIP LOCKED
    )
    DELETE FROM group_mutation_requests request USING doomed
    WHERE request.actor_account_id = doomed.actor_account_id
      AND request.client_mutation_id = doomed.client_mutation_id
    RETURNING request.client_mutation_id`;
  // Preference mutation IDs are client-generated and can be retried after an arbitrarily long
  // offline period or lost response. Keep completed dedupe state until account deletion so a
  // committed patch can never be interpreted as a new mutation.
  const dialogPreferenceRequests: any[] = [];
  const dialogPreferenceBudgets = await sql`
    WITH doomed AS (
      SELECT account_id, bucket_started FROM dialog_preference_action_budgets
      WHERE updated_at < now() - interval '24 hours'
      ORDER BY updated_at LIMIT ${batchSize}
      FOR UPDATE SKIP LOCKED
    )
    DELETE FROM dialog_preference_action_budgets budget USING doomed
    WHERE budget.account_id = doomed.account_id
      AND budget.bucket_started = doomed.bucket_started
    RETURNING budget.account_id`;
  const events = await sql.begin(async (tx) => {
    const doomed = await tx`
      SELECT account_id, pts
      FROM account_events
      WHERE created_at < now() - interval '30 days'
      ORDER BY created_at, account_id, pts
      LIMIT ${batchSize}
      FOR UPDATE SKIP LOCKED`;
    if (doomed.length === 0) return [];
    const accountIds = [...new Set(doomed.map((row: any) => String(row.account_id)))];
    await tx`
      WITH floors AS (
        SELECT account_id, max(pts) AS pts
        FROM account_events
        WHERE (account_id, pts) IN (
          SELECT * FROM unnest(
            ${tx.array(doomed.map((row: any) => row.account_id), "uuid")}::uuid[],
            ${tx.array(doomed.map((row: any) => Number(row.pts)), "int8")}::bigint[]
          )
        )
        GROUP BY account_id
      )
      UPDATE account_sync_states state
      SET pruned_through_pts = GREATEST(state.pruned_through_pts, floors.pts),
          updated_at = now()
      FROM floors
      WHERE state.account_id = floors.account_id`;
    const deleted = await tx`
      DELETE FROM account_events event
      WHERE (event.account_id, event.pts) IN (
        SELECT * FROM unnest(
          ${tx.array(doomed.map((row: any) => row.account_id), "uuid")}::uuid[],
          ${tx.array(doomed.map((row: any) => Number(row.pts)), "int8")}::bigint[]
        )
      )
      RETURNING event.account_id`;
    void accountIds;
    return deleted;
  });
  return {
    otp: otp.length,
    snapshots: snapshots.length,
    pushDeliveries: deliveries.length,
    contactLookups: contactLookups.length,
    mediaUploads: media.length,
    mediaAttempts: mediaAttempts.length,
    mediaOrphans: mediaOrphans.length,
    sendRequests: sendRequests.length,
    messageMutations: messageMutations.length,
    groupCreates: groupCreates.length,
    groupMutations: groupMutations.length,
    dialogPreferenceRequests: dialogPreferenceRequests.length,
    dialogPreferenceBudgets: dialogPreferenceBudgets.length,
    accountEvents: events.length,
    callData,
  };
}

function cleanupCount(value: Awaited<ReturnType<typeof cleanupExpiredData>>): number {
  return value.otp + value.snapshots + value.pushDeliveries + value.contactLookups
    + value.mediaUploads + value.mediaAttempts + value.mediaOrphans + value.sendRequests
    + value.messageMutations + value.groupCreates + value.groupMutations
    + value.dialogPreferenceRequests + value.dialogPreferenceBudgets + value.accountEvents
    + Object.values(value.callData).reduce((sum, count) => sum + count, 0);
}

export async function drainExpiredData(
  sql: SQL,
  options: { batchSize?: number; maxRows?: number; maxRuntimeMs?: number } = {},
) {
  const batchSize = Math.max(1, options.batchSize ?? Number(
    process.env.TOJ_MAINTENANCE_BATCH_SIZE ?? CLEANUP_BATCH_SIZE,
  ));
  const maxRows = Math.max(batchSize, options.maxRows ?? Number(
    process.env.TOJ_MAINTENANCE_MAX_ROWS_PER_TICK ?? 10_000,
  ));
  const maxRuntimeMs = Math.max(1, options.maxRuntimeMs ?? Number(
    process.env.TOJ_MAINTENANCE_MAX_RUNTIME_MS ?? 5_000,
  ));
  const startedAt = performance.now();
  let rows = 0;
  let passes = 0;
  let last = await cleanupExpiredData(sql, Math.min(batchSize, maxRows));
  while (true) {
    passes += 1;
    const deleted = cleanupCount(last);
    rows += deleted;
    if (
      deleted === 0
      || rows >= maxRows
      || performance.now() - startedAt >= maxRuntimeMs
    ) break;
    last = await cleanupExpiredData(sql, Math.min(batchSize, maxRows - rows));
  }
  return {
    rows,
    passes,
    runtimeMs: Math.round((performance.now() - startedAt) * 10) / 10,
    exhausted: rows >= maxRows || performance.now() - startedAt >= maxRuntimeMs,
  };
}

function cleanError(value: unknown): string {
  return (value instanceof Error ? value.message : String(value)).replace(/[\r\n]+/g, " ").slice(0, 300);
}

export function startMaintenanceWorker(sql: SQL, intervalMs = 60 * 60 * 1_000): () => void {
  let running = false;
  const tick = async () => {
    if (running) return;
    running = true;
    try {
      const drained = await drainExpiredData(sql);
      if (drained.rows > 0) {
        console.log(JSON.stringify({ ts: new Date().toISOString(), event: "maintenance.cleanup", drained }));
      }
    } catch (error) {
      console.error(JSON.stringify({ ts: new Date().toISOString(), event: "maintenance.error", error: cleanError(error) }));
    } finally {
      running = false;
    }
  };
  const timer = setInterval(() => { void tick(); }, intervalMs);
  timer.unref?.();
  return () => clearInterval(timer);
}

export function logRequest(fields: {
  requestId: string; method: string; route: string; status: number; durationMs: number;
}): void {
  console.log(JSON.stringify({
    ts: new Date().toISOString(),
    event: "http.request",
    requestId: fields.requestId,
    method: fields.method,
    route: fields.route,
    status: fields.status,
    durationMs: Math.round(fields.durationMs * 10) / 10,
  }));
}
