import type { SQL } from "bun";

export type DialogPreferenceSchemaState = {
  ready: boolean;
  missingTables: string[];
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

  let eventConstraintValidated = false;
  let migrationCompleted = false;
  let reconciliationBacklog = -1;
  if (missingTables.length === 0) {
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
      && eventConstraintValidated
      && migrationCompleted
      && reconciliationBacklog === 0,
    missingTables,
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
