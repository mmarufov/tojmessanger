\set ON_ERROR_STOP on
SET lock_timeout = '2s';
SET statement_timeout = '30min';

SELECT format('DROP INDEX CONCURRENTLY IF EXISTS %I.%I', namespace.nspname, class.relname)
FROM pg_index AS idx
JOIN pg_class AS class ON class.oid = idx.indexrelid
JOIN pg_namespace AS namespace ON namespace.oid = class.relnamespace
WHERE namespace.nspname = 'public'
  AND class.relname IN (
    'dialog_preferences_account_idx',
    'dialog_preferences_pinned_order_idx',
    'dialog_preference_requests_retention_idx',
    'dialog_preference_action_budgets_account_idx',
    'dialog_preference_reconciliation_account_idx'
  )
  AND NOT idx.indisvalid
\gexec

CREATE INDEX CONCURRENTLY IF NOT EXISTS dialog_preferences_account_idx
  ON dialog_preferences(account_id, dialog_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS dialog_preferences_pinned_order_idx
  ON dialog_preferences(account_id, pinned_at DESC)
  WHERE is_pinned = TRUE;
CREATE INDEX CONCURRENTLY IF NOT EXISTS dialog_preference_requests_retention_idx
  ON dialog_preference_requests(created_at);
CREATE INDEX CONCURRENTLY IF NOT EXISTS dialog_preference_action_budgets_account_idx
  ON dialog_preference_action_budgets(updated_at);
CREATE INDEX CONCURRENTLY IF NOT EXISTS dialog_preference_reconciliation_account_idx
  ON dialog_preference_legacy_reconciliation(account_id, dialog_id);
