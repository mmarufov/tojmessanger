-- Additive presence storage. No historical device activity is copied into last_seen_at: only
-- foreground presence leases introduced by presence_v1 are authoritative.
CREATE TABLE IF NOT EXISTS account_presence (
  account_id   UUID PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
  last_seen_at TIMESTAMPTZ,
  revision     BIGINT NOT NULL DEFAULT 0 CHECK (revision >= 0),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS device_presence_leases (
  device_id          UUID PRIMARY KEY REFERENCES devices(id) ON DELETE CASCADE,
  account_id         UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  connection_id      UUID NOT NULL,
  last_heartbeat_at  TIMESTAMPTZ NOT NULL,
  expires_at         TIMESTAMPTZ NOT NULL,
  CHECK (expires_at > last_heartbeat_at)
);

CREATE INDEX IF NOT EXISTS device_presence_leases_account_expiry_idx
  ON device_presence_leases(account_id, expires_at);
CREATE INDEX IF NOT EXISTS device_presence_leases_expiry_idx
  ON device_presence_leases(expires_at, account_id);

INSERT INTO schema_migrations(name)
VALUES ('presence-v1-expand')
ON CONFLICT (name) DO NOTHING;
