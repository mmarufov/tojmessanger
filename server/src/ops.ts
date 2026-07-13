import type { SQL } from "bun";

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
  if (/^\/v1\/media\/uploads\/[0-9a-f-]+\/thumbnail$/i.test(pathname)) return "/v1/media/uploads/:id/thumbnail";
  if (/^\/v1\/media\/uploads\/[0-9a-f-]+\/complete$/i.test(pathname)) return "/v1/media/uploads/:id/complete";
  if (/^\/v1\/media\/uploads\/[0-9a-f-]+$/i.test(pathname)) return "/v1/media/uploads/:id";
  if (/^\/v1\/media\/[0-9a-f-]+\/chunks$/i.test(pathname)) return "/v1/media/:id/chunks";
  if (/^\/v1\/media\/[0-9a-f-]+\/thumbnail$/i.test(pathname)) return "/v1/media/:id/thumbnail";
  const known = new Set([
    "/health", "/ready", "/metrics", "/v1/ws", "/v1/auth/start", "/v1/auth/check",
    "/v1/devices", "/v1/devices/push", "/v1/session", "/v1/account/deletion/start",
    "/v1/account", "/v1/sync/state",
    "/v1/sync/difference", "/v1/bootstrap/start", "/v1/bootstrap/dialogs",
    "/v1/contacts/lookup", "/v1/dialogs/direct", "/v1/messages/send", "/v1/history", "/v1/read",
    "/v1/media/uploads",
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

export function providerState(value: unknown): ProviderState {
  return value ? "configured" : "disabled";
}

export async function readiness(sql: SQL, providers: { sms: ProviderState; push: ProviderState }) {
  const started = performance.now();
  await sql`SELECT 1`;
  return {
    status: "ready",
    database: "ready",
    providers,
    databaseLatencyMs: Math.max(0, Math.round((performance.now() - started) * 10) / 10),
  };
}

export async function cleanupExpiredData(sql: SQL, batchSize = CLEANUP_BATCH_SIZE) {
  const otp = await sql`
    WITH doomed AS (
      SELECT id FROM otp_challenges
      WHERE expires_at < now() - interval '24 hours'
      ORDER BY expires_at LIMIT ${batchSize}
    )
    DELETE FROM otp_challenges WHERE id IN (SELECT id FROM doomed)
    RETURNING id`;
  const snapshots = await sql`
    WITH doomed AS (
      SELECT id FROM bootstrap_snapshots
      WHERE expires_at < now()
      ORDER BY expires_at LIMIT ${batchSize}
    )
    DELETE FROM bootstrap_snapshots WHERE id IN (SELECT id FROM doomed)
    RETURNING id`;
  const deliveries = await sql`
    WITH doomed AS (
      SELECT id FROM push_deliveries
      WHERE status IN ('sent', 'dead') AND created_at < now() - interval '7 days'
      ORDER BY created_at LIMIT ${batchSize}
    )
    DELETE FROM push_deliveries WHERE id IN (SELECT id FROM doomed)
    RETURNING id`;
  const contactLookups = await sql`
    WITH doomed AS (
      SELECT id FROM contact_lookup_attempts
      WHERE created_at < now() - interval '24 hours'
      ORDER BY created_at LIMIT ${batchSize}
    )
    DELETE FROM contact_lookup_attempts WHERE id IN (SELECT id FROM doomed)
    RETURNING id`;
  const media = await sql`
    WITH doomed AS (
      SELECT id FROM media_objects
      WHERE status = 'uploading' AND expires_at < now()
      ORDER BY expires_at LIMIT ${batchSize}
    )
    DELETE FROM media_objects WHERE id IN (SELECT id FROM doomed)
    RETURNING id`;
  const mediaOrphans = await sql`
    WITH doomed AS (
      SELECT mo.id FROM media_objects mo
      WHERE mo.status = 'ready' AND mo.completed_at < now() - interval '24 hours'
        AND NOT EXISTS (SELECT 1 FROM messages m WHERE m.media_id = mo.id AND m.state = 'visible')
      ORDER BY mo.completed_at LIMIT ${batchSize}
    )
    DELETE FROM media_objects WHERE id IN (SELECT id FROM doomed)
    RETURNING id`;
  return {
    otp: otp.length,
    snapshots: snapshots.length,
    pushDeliveries: deliveries.length,
    contactLookups: contactLookups.length,
    mediaUploads: media.length,
    mediaOrphans: mediaOrphans.length,
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
      const deleted = await cleanupExpiredData(sql);
      if (deleted.otp || deleted.snapshots || deleted.pushDeliveries || deleted.contactLookups ||
          deleted.mediaUploads || deleted.mediaOrphans) {
        console.log(JSON.stringify({ ts: new Date().toISOString(), event: "maintenance.cleanup", deleted }));
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
