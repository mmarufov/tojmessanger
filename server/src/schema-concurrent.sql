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
    'dialogs_one_saved_per_account_idx',
    'messages_forward_provenance_idx',
    'messages_reply_target_idx',
    'messages_forward_marker_backfill_idx',
    'message_mentions_account_idx',
    'messages_media_group_idx',
    'account_events_retention_idx',
    'account_events_lifecycle_lookup_idx',
    'media_objects_expiry_idx',
    'media_objects_orphan_expiry_idx',
    'draft_mutation_requests_expiry_idx',
    'draft_mutation_tombstones_dialog_idx',
    'media_group_send_requests_expiry_idx',
    'media_group_send_tombstones_dialog_idx',
    'group_action_budgets_account_idx',
    'group_action_budgets_target_idx',
    'accounts_profile_photo_media_idx'
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

CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS dialogs_one_saved_per_account_idx
  ON dialogs(created_by)
  WHERE type = 'saved';

CREATE INDEX CONCURRENTLY IF NOT EXISTS messages_forward_provenance_idx
  ON messages(forwarded_from_dialog_id, forwarded_from_msg_id)
  WHERE forwarded_from_dialog_id IS NOT NULL AND forwarded_from_msg_id IS NOT NULL;

CREATE INDEX CONCURRENTLY IF NOT EXISTS messages_reply_target_idx
  ON messages(dialog_id, reply_to_msg_id)
  WHERE reply_to_msg_id IS NOT NULL;

CREATE INDEX CONCURRENTLY IF NOT EXISTS message_mentions_account_idx
  ON message_mentions(account_id, dialog_id, msg_id);

CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS messages_media_group_idx
  ON messages(dialog_id, media_group_id, media_group_index)
  WHERE media_group_id IS NOT NULL;

CREATE INDEX CONCURRENTLY IF NOT EXISTS account_events_retention_idx
  ON account_events(created_at, account_id, pts);

CREATE INDEX CONCURRENTLY IF NOT EXISTS account_events_lifecycle_lookup_idx
  ON account_events(account_id, dialog_id, pts DESC)
  WHERE type IN ('dialog.created', 'dialog.access_revoked');

CREATE INDEX CONCURRENTLY IF NOT EXISTS media_objects_expiry_idx
  ON media_objects(expires_at, id)
  WHERE status IN ('uploading','rejected');

CREATE INDEX CONCURRENTLY IF NOT EXISTS media_objects_orphan_expiry_idx
  ON media_objects(GREATEST(completed_at, last_accessed_at), id)
  WHERE status = 'ready';

CREATE INDEX CONCURRENTLY IF NOT EXISTS draft_mutation_requests_expiry_idx
  ON draft_mutation_requests(created_at, account_id, operation_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS draft_mutation_tombstones_dialog_idx
  ON draft_mutation_tombstones(account_id, dialog_id, resulting_revision DESC);

CREATE INDEX CONCURRENTLY IF NOT EXISTS media_group_send_requests_expiry_idx
  ON media_group_send_requests(created_at, sender_account_id, client_group_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS media_group_send_tombstones_dialog_idx
  ON media_group_send_tombstones(sender_account_id, dialog_id, sender_pts DESC);

CREATE INDEX CONCURRENTLY IF NOT EXISTS group_action_budgets_account_idx
  ON group_action_budgets(account_id, action, created_at DESC);

CREATE INDEX CONCURRENTLY IF NOT EXISTS group_action_budgets_target_idx
  ON group_action_budgets(target_account_id, action, created_at DESC)
  WHERE target_account_id IS NOT NULL;
CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS accounts_username_active_unique_idx
  ON accounts (lower(username)) WHERE username IS NOT NULL AND status IN ('active','limited');

-- PostgreSQL does not index referencing FK columns automatically. This keeps media authorization,
-- reaping, and account-photo replacement from scanning every account.
CREATE INDEX CONCURRENTLY IF NOT EXISTS accounts_profile_photo_media_idx
  ON accounts(profile_photo_media_id)
  WHERE profile_photo_media_id IS NOT NULL;
