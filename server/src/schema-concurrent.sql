-- Operations that cannot safely run inside schema.sql's transaction on populated deployments.
-- Repair invalid shells left by an interrupted CREATE INDEX CONCURRENTLY before retrying.
SET lock_timeout = '5s';

SELECT format('DROP INDEX CONCURRENTLY IF EXISTS %I.%I', namespace.nspname, class.relname)
FROM pg_index AS idx
JOIN pg_class AS class ON class.oid = idx.indexrelid
JOIN pg_namespace AS namespace ON namespace.oid = class.relnamespace
WHERE namespace.nspname = 'public'
  AND class.relname IN ('devices_voip_push_token_active_idx', 'messages_call_eligibility_idx')
  AND NOT idx.indisvalid
\gexec

CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS devices_voip_push_token_active_idx
  ON devices(voip_push_environment, voip_push_token_hash)
  WHERE voip_push_token_hash IS NOT NULL AND revoked_at IS NULL;

CREATE INDEX CONCURRENTLY IF NOT EXISTS messages_call_eligibility_idx
  ON messages(dialog_id, sender_account_id)
  WHERE state = 'visible' AND kind <> 'service';
