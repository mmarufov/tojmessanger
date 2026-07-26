import type { SQL } from "bun";

export type DialogPreferenceSchemaState = {
  ready: boolean;
  missingTables: string[];
  missingColumns: string[];
  eventConstraintValidated: boolean;
  migrationCompleted: boolean;
  reconciliationBacklog: number;
};

const REQUIRED_TABLES = [
  "dialog_preferences",
  "dialog_preference_requests",
  "dialog_preference_action_budgets",
  "dialog_preference_legacy_reconciliation",
  "online_migration_cursors",
  "bootstrap_snapshot_dialogs",
  "account_events",
] as const;

// These columns are referenced by the running binary even when capability advertisement and
// preference-authored behavior are disabled. In particular, ordinary direct-dialog creation and
// fanout join dialog_preferences, while every bootstrap captures and reads the snapshot columns.
// getDifference reads the resulting account_events payload and has no additional preference join.
const REQUIRED_COLUMNS = [
  ["dialog_preferences", "dialog_id"],
  ["dialog_preferences", "account_id"],
  ["dialog_preferences", "is_pinned"],
  ["dialog_preferences", "pinned_at"],
  ["dialog_preferences", "is_muted"],
  ["dialog_preferences", "is_archived"],
  ["dialog_preferences", "updated_at"],
  ["dialog_preference_requests", "account_id"],
  ["dialog_preference_requests", "client_mutation_id"],
  ["dialog_preference_requests", "dialog_id"],
  ["dialog_preference_requests", "fingerprint"],
  ["dialog_preference_requests", "status"],
  ["dialog_preference_requests", "result_pts"],
  ["dialog_preference_requests", "result_json"],
  ["dialog_preference_requests", "created_at"],
  ["dialog_preference_action_budgets", "account_id"],
  ["dialog_preference_action_budgets", "bucket_started"],
  ["dialog_preference_action_budgets", "mutation_count"],
  ["dialog_preference_action_budgets", "updated_at"],
  ["dialog_preference_legacy_reconciliation", "dialog_id"],
  ["dialog_preference_legacy_reconciliation", "account_id"],
  ["dialog_preference_legacy_reconciliation", "created_at"],
  ["online_migration_cursors", "migration_name"],
  ["online_migration_cursors", "last_dialog_id"],
  ["online_migration_cursors", "last_account_id"],
  ["online_migration_cursors", "rows_processed"],
  ["online_migration_cursors", "completed_at"],
  ["online_migration_cursors", "updated_at"],
  ["bootstrap_snapshot_dialogs", "preferences_captured"],
  ["bootstrap_snapshot_dialogs", "preference_is_pinned"],
  ["bootstrap_snapshot_dialogs", "preference_pinned_at"],
  ["bootstrap_snapshot_dialogs", "preference_is_muted"],
  ["bootstrap_snapshot_dialogs", "preference_is_archived"],
  ["bootstrap_snapshot_dialogs", "preference_updated_at"],
  ["account_events", "type"],
  ["account_events", "data"],
] as const;

type CachedState = { expiresAt: number; value: DialogPreferenceSchemaState };
const cache = new WeakMap<object, CachedState>();

export function clearDialogPreferenceReadinessCache(sql?: SQL): void {
  if (sql) cache.delete(sql as unknown as object);
}

export async function dialogPreferenceSchemaState(
  sql: SQL,
  options: { bypassCache?: boolean } = {},
): Promise<DialogPreferenceSchemaState> {
  const cacheKey = sql as unknown as object;
  const now = Date.now();
  const cached = cache.get(cacheKey);
  if (!options.bypassCache && cached && cached.expiresAt > now) return cached.value;

  const tables = await sql`
    SELECT required.name,
           to_regclass('public.' || required.name) IS NOT NULL AS present
    FROM unnest(${sql.array([...REQUIRED_TABLES], "text")}::text[]) AS required(name)`;
  const missingTables = tables
    .filter((row: any) => !row.present)
    .map((row: any) => String(row.name));
  const columns = await sql`
    SELECT required.table_name, required.column_name,
           columns.column_name IS NOT NULL AS present
    FROM unnest(
      ${sql.array(REQUIRED_COLUMNS.map(([table]) => table), "text")}::text[],
      ${sql.array(REQUIRED_COLUMNS.map(([, column]) => column), "text")}::text[]
    ) AS required(table_name, column_name)
    LEFT JOIN information_schema.columns columns
      ON columns.table_schema = 'public'
     AND columns.table_name = required.table_name
     AND columns.column_name = required.column_name
    WHERE to_regclass('public.' || required.table_name) IS NOT NULL`;
  const missingColumns = columns
    .filter((row: any) => !row.present)
    .map((row: any) => `${row.table_name}.${row.column_name}`);

  let eventConstraintValidated = false;
  let migrationCompleted = false;
  let reconciliationBacklog = -1;
  if (missingTables.length === 0 && missingColumns.length === 0) {
    const state = (await sql`
      SELECT
        EXISTS (
          SELECT 1
          FROM pg_constraint
          WHERE conrelid = 'account_events'::regclass
            AND conname = 'account_events_type_check'
            AND convalidated
            AND pg_get_constraintdef(oid) LIKE '%dialog.preferences_updated%'
        ) AS event_constraint_validated,
        COALESCE((
          SELECT completed_at IS NOT NULL
          FROM online_migration_cursors
          WHERE migration_name = 'dialog_preferences_v1'
        ), FALSE) AS migration_completed,
        (SELECT count(*)::int FROM dialog_preference_legacy_reconciliation)
          AS reconciliation_backlog`)[0];
    eventConstraintValidated = Boolean(state?.event_constraint_validated);
    migrationCompleted = Boolean(state?.migration_completed);
    reconciliationBacklog = Number(state?.reconciliation_backlog ?? -1);
  }

  const value = {
    ready: missingTables.length === 0
      && missingColumns.length === 0
      && eventConstraintValidated
      && migrationCompleted
      && reconciliationBacklog === 0,
    missingTables,
    missingColumns,
    eventConstraintValidated,
    migrationCompleted,
    reconciliationBacklog,
  };
  const ttlMs = Math.max(
    0,
    Number(process.env.TOJ_DIALOG_PREFERENCE_READINESS_CACHE_MS ?? 5_000),
  );
  cache.set(cacheKey, { expiresAt: now + ttlMs, value });
  return value;
}

export async function dialogPreferenceBehaviorAvailable(sql: SQL): Promise<boolean> {
  if (process.env.TOJ_DIALOG_PREFERENCES_BEHAVIOR_ENABLED === "0") return false;
  return (await dialogPreferenceSchemaState(sql)).ready;
}
