-- Operations that cannot safely run inside schema.sql's transaction on populated deployments.
-- Repair invalid shells left by an interrupted CREATE INDEX CONCURRENTLY before retrying.
SET lock_timeout = '5s';

SELECT format('DROP INDEX CONCURRENTLY IF EXISTS %I.%I', namespace.nspname, class.relname)
FROM pg_index AS idx
JOIN pg_class AS class ON class.oid = idx.indexrelid
JOIN pg_namespace AS namespace ON namespace.oid = class.relnamespace
WHERE namespace.nspname = 'public'
  AND class.relname IN (
    'devices_voip_push_token_active_idx',
    'messages_call_eligibility_idx',
    'dialog_members_active_owner_idx',
    'dialog_members_active_page_idx',
    'message_mentions_account_idx',
    'messages_media_group_idx',
    'account_events_retention_idx',
    'media_objects_expiry_idx',
    'media_objects_orphan_expiry_idx',
    'draft_mutation_requests_expiry_idx',
    'media_group_send_requests_expiry_idx',
    'group_action_budgets_account_idx',
    'group_action_budgets_target_idx'
  )
  AND NOT idx.indisvalid
\gexec

CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS devices_voip_push_token_active_idx
  ON devices(voip_push_environment, voip_push_token_hash)
  WHERE voip_push_token_hash IS NOT NULL AND revoked_at IS NULL;

CREATE INDEX CONCURRENTLY IF NOT EXISTS messages_call_eligibility_idx
  ON messages(dialog_id, sender_account_id)
  WHERE state = 'visible' AND kind <> 'service';

CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS dialog_members_active_owner_idx
  ON dialog_members(dialog_id)
  WHERE role = 'owner' AND left_at IS NULL;

CREATE INDEX CONCURRENTLY IF NOT EXISTS dialog_members_active_page_idx
  ON dialog_members(dialog_id, joined_at, account_id)
  WHERE left_at IS NULL;

CREATE INDEX CONCURRENTLY IF NOT EXISTS message_mentions_account_idx
  ON message_mentions(account_id, dialog_id, msg_id);

CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS messages_media_group_idx
  ON messages(dialog_id, media_group_id, media_group_index)
  WHERE media_group_id IS NOT NULL;

CREATE INDEX CONCURRENTLY IF NOT EXISTS account_events_retention_idx
  ON account_events(created_at, account_id, pts);

CREATE INDEX CONCURRENTLY IF NOT EXISTS media_objects_expiry_idx
  ON media_objects(expires_at, id)
  WHERE status IN ('uploading','rejected');

CREATE INDEX CONCURRENTLY IF NOT EXISTS media_objects_orphan_expiry_idx
  ON media_objects(GREATEST(completed_at, last_accessed_at), id)
  WHERE status = 'ready';

CREATE INDEX CONCURRENTLY IF NOT EXISTS draft_mutation_requests_expiry_idx
  ON draft_mutation_requests(created_at, account_id, operation_id);

CREATE INDEX CONCURRENTLY IF NOT EXISTS media_group_send_requests_expiry_idx
  ON media_group_send_requests(created_at, sender_account_id, client_group_id);

CREATE INDEX CONCURRENTLY IF NOT EXISTS group_action_budgets_account_idx
  ON group_action_budgets(account_id, action, created_at DESC);

CREATE INDEX CONCURRENTLY IF NOT EXISTS group_action_budgets_target_idx
  ON group_action_budgets(target_account_id, action, created_at DESC)
  WHERE target_account_id IS NOT NULL;
