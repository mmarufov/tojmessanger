import type { SQL } from "bun";

export type ProductivityWorkerKind = "scheduled_delivery" | "link_preview";

function boundedInteger(name: string, fallback: number, minimum: number, maximum: number): number {
  const raw = process.env[name];
  if (raw == null || raw.trim() === "") return fallback;
  const parsed = Number(raw);
  if (!Number.isSafeInteger(parsed) || parsed < minimum || parsed > maximum) {
    throw new Error(`${name} must be an integer from ${minimum} through ${maximum}`);
  }
  return parsed;
}

export function scheduledDeliveryWorkerConcurrency(): number {
  return boundedInteger("TOJ_SCHEDULED_DELIVERY_WORKER_CONCURRENCY", 8, 1, 32);
}

export function linkPreviewWorkerConcurrency(): number {
  return boundedInteger("TOJ_LINK_PREVIEW_WORKER_CONCURRENCY", 4, 1, 16);
}

export function productivityWorkerLeaseSeconds(): number {
  return boundedInteger("TOJ_PRODUCTIVITY_WORKER_LEASE_SECONDS", 120, 30, 600);
}

const activeJobs: Record<ProductivityWorkerKind, number> = {
  scheduled_delivery: 0,
  link_preview: 0,
};
const renewalFailures: Record<ProductivityWorkerKind, number> = {
  scheduled_delivery: 0,
  link_preview: 0,
};
let resolvedPreviewWaiters = 0;
let heartbeatCacheDatabaseErrors = 0;

export function adjustProductivityActiveJobs(kind: ProductivityWorkerKind, delta: number): void {
  activeJobs[kind] = Math.max(0, activeJobs[kind] + delta);
}

export function recordProductivityLeaseRenewalFailure(kind: ProductivityWorkerKind): void {
  renewalFailures[kind] += 1;
}

export function recordResolvedPreviewWaiters(count: number): void {
  resolvedPreviewWaiters += Math.max(0, count);
}

export function recordHeartbeatCacheDatabaseError(): void {
  heartbeatCacheDatabaseErrors += 1;
}

export async function productivityMetrics(sql: SQL): Promise<string> {
  let oldestFanoutSeconds = 0;
  try {
    const schema = (await sql`
      SELECT to_regclass('public.link_preview_cache_entries') IS NOT NULL AS present`)[0];
    if (schema?.present) {
      const row = (await sql`
        SELECT COALESCE(
          EXTRACT(EPOCH FROM now() - min(COALESCE(fetched_at, updated_at))),
          0
        ) AS age
        FROM link_preview_cache_entries WHERE fanout_pending`)[0];
      oldestFanoutSeconds = Math.max(0, Number(row?.age ?? 0));
    }
  } catch {
    // Metrics must remain scrapeable during partial deploys and transient database failures.
  }
  return [
    "# HELP toj_productivity_active_jobs Active jobs by worker kind.",
    "# TYPE toj_productivity_active_jobs gauge",
    `toj_productivity_active_jobs{worker_kind="scheduled_delivery"} ${activeJobs.scheduled_delivery}`,
    `toj_productivity_active_jobs{worker_kind="link_preview"} ${activeJobs.link_preview}`,
    "# HELP toj_productivity_lease_renewal_failures_total Token-owned lease renewals that lost ownership.",
    "# TYPE toj_productivity_lease_renewal_failures_total counter",
    `toj_productivity_lease_renewal_failures_total{worker_kind="scheduled_delivery"} ${renewalFailures.scheduled_delivery}`,
    `toj_productivity_lease_renewal_failures_total{worker_kind="link_preview"} ${renewalFailures.link_preview}`,
    "# HELP toj_link_preview_resolved_waiters_total Preview waiters resolved or discarded by bounded fanout.",
    "# TYPE toj_link_preview_resolved_waiters_total counter",
    `toj_link_preview_resolved_waiters_total ${resolvedPreviewWaiters}`,
    "# HELP toj_link_preview_oldest_fanout_seconds Age of the oldest cache entry with unfinished fanout.",
    "# TYPE toj_link_preview_oldest_fanout_seconds gauge",
    `toj_link_preview_oldest_fanout_seconds ${oldestFanoutSeconds}`,
    "# HELP toj_productivity_heartbeat_cache_database_errors_total Heartbeat snapshot database failures.",
    "# TYPE toj_productivity_heartbeat_cache_database_errors_total counter",
    `toj_productivity_heartbeat_cache_database_errors_total ${heartbeatCacheDatabaseErrors}`,
    "",
  ].join("\n");
}
