import { createHash } from "node:crypto";
import type { SQL } from "bun";

export type CloudProductivitySchemaState = {
  ready: boolean;
  missingTables: string[];
  missingIndexes: string[];
  missingMigrations: string[];
  eventConstraintReady: boolean;
};

const REQUIRED_TABLES = [
  "account_chat_folder_states",
  "chat_folders",
  "chat_folder_dialog_rules",
  "chat_folder_mutation_requests",
  "chat_folder_action_budgets",
  "account_scheduled_delivery_states",
  "scheduled_deliveries",
  "scheduled_delivery_items",
  "scheduled_delivery_mutation_requests",
  "scheduled_delivery_action_budgets",
  "worker_heartbeats",
  "link_preview_cache_entries",
  "link_preview_snapshots",
  "message_link_previews",
  "link_preview_waiters",
  "link_preview_assets",
  "link_preview_action_budgets",
] as const;

const REQUIRED_INDEXES = [
  "chat_folder_rules_dialog_idx",
  "scheduled_deliveries_due_idx",
  "scheduled_deliveries_account_idx",
  "scheduled_deliveries_account_delivery_idx",
  "scheduled_delivery_items_media_idx",
  "worker_heartbeats_kind_idx",
  "link_preview_cache_ready_idx",
  "message_link_previews_snapshot_idx",
  "link_preview_waiters_message_idx",
] as const;

const REQUIRED_MIGRATIONS = [
  "cloud-productivity-expand-v1",
  "cloud-productivity-indexes-v1",
  "cloud-productivity-contract-v1",
  "account-private-cleanup-v2",
] as const;

const REQUIRED_EVENT_TYPES = [
  "chat_folders.updated",
  "scheduled.created",
  "scheduled.updated",
  "scheduled.canceled",
  "scheduled.failed",
  "message.preview_updated",
] as const;

type CacheEntry = { expiresAt: number; value: CloudProductivitySchemaState };
const cache = new WeakMap<object, CacheEntry>();

export function clearCloudProductivityReadinessCache(sql?: SQL): void {
  if (sql) cache.delete(sql as unknown as object);
}

export async function cloudProductivitySchemaState(
  sql: SQL,
  options: { bypassCache?: boolean } = {},
): Promise<CloudProductivitySchemaState> {
  const key = sql as unknown as object;
  const cached = cache.get(key);
  if (!options.bypassCache && cached && cached.expiresAt > Date.now()) return cached.value;

  const tableRows = await sql`
    SELECT required.name,
           to_regclass('public.' || required.name) IS NOT NULL AS present
    FROM unnest(${sql.array([...REQUIRED_TABLES], "text")}::text[]) required(name)`;
  const missingTables = tableRows
    .filter((row: any) => !row.present)
    .map((row: any) => String(row.name));

  const indexRows = await sql`
    SELECT required.name,
           COALESCE(index_row.indisvalid AND index_row.indisready AND index_row.indislive, FALSE)
             AS present
    FROM unnest(${sql.array([...REQUIRED_INDEXES], "text")}::text[]) required(name)
    LEFT JOIN pg_class index_class ON index_class.relname = required.name
    LEFT JOIN pg_namespace index_namespace
      ON index_namespace.oid = index_class.relnamespace
     AND index_namespace.nspname = 'public'
    LEFT JOIN pg_index index_row ON index_row.indexrelid = index_class.oid`;
  const missingIndexes = indexRows
    .filter((row: any) => !row.present)
    .map((row: any) => String(row.name));

  const migrationRows = await sql`
    SELECT required.name, migration.name IS NOT NULL AS present
    FROM unnest(${sql.array([...REQUIRED_MIGRATIONS], "text")}::text[]) required(name)
    LEFT JOIN schema_migrations migration ON migration.name = required.name`;
  const missingMigrations = migrationRows
    .filter((row: any) => !row.present)
    .map((row: any) => String(row.name));

  const constraint = (await sql`
    SELECT convalidated, pg_get_constraintdef(oid, TRUE) AS definition
    FROM pg_constraint
    WHERE conrelid = 'public.account_events'::regclass
      AND conname = 'account_events_type_check'
      AND contype = 'c'`)[0];
  const definition = String(constraint?.definition ?? "");
  const eventConstraintReady = Boolean(constraint?.convalidated)
    && REQUIRED_EVENT_TYPES.every((type) => definition.includes(`'${type}'`));

  const value = {
    ready: missingTables.length === 0
      && missingIndexes.length === 0
      && missingMigrations.length === 0
      && eventConstraintReady,
    missingTables,
    missingIndexes,
    missingMigrations,
    eventConstraintReady,
  };
  cache.set(key, { expiresAt: Date.now() + 2_000, value });
  return value;
}

function configured(prefix: string): boolean {
  return process.env[`${prefix}_ENABLED`] === "1";
}

function accountInRollout(prefix: string, accountId: string): boolean {
  const allowlist = new Set(
    String(process.env[`${prefix}_ALLOWLIST`] ?? "")
      .split(",")
      .map((item) => item.trim().toLowerCase())
      .filter(Boolean),
  );
  if (allowlist.has(accountId.toLowerCase())) return true;
  const percent = Math.max(
    0,
    Math.min(100, Number(process.env[`${prefix}_ROLLOUT_PERCENT`] ?? 0)),
  );
  if (percent <= 0) return false;
  if (percent >= 100) return true;
  const digest = createHash("sha256").update(`${prefix}|${accountId}`).digest();
  return digest.readUInt32BE(0) % 10_000 < Math.floor(percent * 100);
}

export function chatFoldersEnabledForAccount(accountId: string): boolean {
  return configured("TOJ_CHAT_FOLDERS_V1")
    && accountInRollout("TOJ_CHAT_FOLDERS", accountId);
}

export function scheduledDeliveryEnabledForAccount(accountId: string): boolean {
  return (configured("TOJ_SCHEDULED_DELIVERY_V1")
      || process.env.TOJ_SCHEDULED_DELIVERY_V1_ACCEPTING === "1")
    && accountInRollout("TOJ_SCHEDULED_DELIVERY", accountId);
}

export function linkPreviewsEnabledForAccount(accountId: string): boolean {
  return configured("TOJ_LINK_PREVIEWS_V1")
    && accountInRollout("TOJ_LINK_PREVIEWS", accountId);
}

export async function workerHeartbeatFresh(
  sql: SQL,
  kind: "scheduled_delivery" | "link_preview",
  maxAgeSeconds = 30,
): Promise<boolean> {
  const row = (await sql`
    SELECT EXISTS (
      SELECT 1 FROM worker_heartbeats
      WHERE worker_kind = ${kind}
        AND last_seen_at >= now() - (${maxAgeSeconds}::text || ' seconds')::interval
    ) AS fresh`)[0];
  return Boolean(row?.fresh);
}

export async function touchWorkerHeartbeat(
  sql: SQL,
  kind: "scheduled_delivery" | "link_preview",
  workerId: string,
): Promise<void> {
  await sql`
    INSERT INTO worker_heartbeats (worker_kind, worker_id, last_seen_at, metadata)
    VALUES (${kind}, ${workerId}, now(), '{}'::jsonb)
    ON CONFLICT (worker_kind, worker_id) DO UPDATE SET
      last_seen_at = excluded.last_seen_at,
      metadata = excluded.metadata`;
}
