\set ON_ERROR_STOP on

BEGIN;
SET LOCAL lock_timeout = '2s';
SET LOCAL statement_timeout = '30s';

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'account_events'::regclass
      AND conname = 'account_events_type_check_v6'
      AND convalidated
  ) THEN
    ALTER TABLE account_events DROP CONSTRAINT account_events_type_check;
    ALTER TABLE account_events
      RENAME CONSTRAINT account_events_type_check_v6 TO account_events_type_check;
  END IF;
END;
$$;

INSERT INTO schema_migrations(name) VALUES ('cloud-productivity-contract-v1')
ON CONFLICT DO NOTHING;

COMMIT;
