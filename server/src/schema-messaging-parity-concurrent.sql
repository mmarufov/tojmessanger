-- Run outside a transaction after schema-messaging-parity-expand.sql.
CREATE INDEX CONCURRENTLY IF NOT EXISTS messages_visible_expiry_idx
  ON messages(expires_at, dialog_id, msg_id)
  WHERE expires_at IS NOT NULL AND state = 'visible';

CREATE INDEX CONCURRENTLY IF NOT EXISTS message_pins_dialog_latest_idx
  ON message_pins(dialog_id, created_at DESC, msg_id DESC);

CREATE INDEX CONCURRENTLY IF NOT EXISTS poll_votes_poll_idx
  ON poll_votes(dialog_id, msg_id, updated_at DESC);

CREATE INDEX CONCURRENTLY IF NOT EXISTS stickers_search_idx
  ON stickers USING gin ((emoji || tags));

CREATE INDEX CONCURRENTLY IF NOT EXISTS account_sticker_recents_latest_idx
  ON account_sticker_recents(account_id, last_used_at DESC);

CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS push_installations_normal_token_active_idx
  ON push_installations(normal_environment, normal_token_hash)
  WHERE normal_token_hash IS NOT NULL;

CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS push_installations_voip_token_active_idx
  ON push_installations(voip_environment, voip_token_hash)
  WHERE voip_token_hash IS NOT NULL;

CREATE INDEX CONCURRENTLY IF NOT EXISTS push_account_bindings_account_active_idx
  ON push_account_bindings(account_id, installation_id)
  WHERE active;

CREATE INDEX CONCURRENTLY IF NOT EXISTS messaging_feature_mutations_cleanup_idx
  ON messaging_feature_mutations(created_at)
  WHERE completed_at IS NOT NULL;

CREATE INDEX CONCURRENTLY IF NOT EXISTS messaging_feature_mutations_pending_cleanup_idx
  ON messaging_feature_mutations(created_at)
  WHERE completed_at IS NULL;

INSERT INTO schema_migrations(name) VALUES ('messaging-parity-indexes-v1')
ON CONFLICT (name) DO NOTHING;
