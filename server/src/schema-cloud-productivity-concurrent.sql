\set ON_ERROR_STOP on

CREATE INDEX CONCURRENTLY IF NOT EXISTS chat_folder_rules_dialog_idx
  ON chat_folder_dialog_rules(account_id, dialog_id, folder_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS scheduled_deliveries_due_idx
  ON scheduled_deliveries(deliver_at, id)
  WHERE state IN ('scheduled','processing');
CREATE INDEX CONCURRENTLY IF NOT EXISTS scheduled_deliveries_account_idx
  ON scheduled_deliveries(account_id, state, deliver_at, id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS scheduled_delivery_items_media_idx
  ON scheduled_delivery_items(media_id) WHERE media_id IS NOT NULL;
CREATE INDEX CONCURRENTLY IF NOT EXISTS worker_heartbeats_kind_idx
  ON worker_heartbeats(worker_kind, last_seen_at DESC);
CREATE INDEX CONCURRENTLY IF NOT EXISTS link_preview_cache_ready_idx
  ON link_preview_cache_entries(available_at, created_at)
  WHERE state IN ('pending','fetching');
CREATE INDEX CONCURRENTLY IF NOT EXISTS message_link_previews_snapshot_idx
  ON message_link_previews(snapshot_id) WHERE snapshot_id IS NOT NULL;
CREATE INDEX CONCURRENTLY IF NOT EXISTS link_preview_waiters_message_idx
  ON link_preview_waiters(dialog_id, msg_id);

INSERT INTO schema_migrations(name) VALUES ('cloud-productivity-indexes-v1')
ON CONFLICT DO NOTHING;
