-- Toj M3 cloud store schema. Idempotent (safe to re-run).
-- Reflects .context/m3-cloud-data-model-and-sync.md + the B1–B4/cleanup fixes in
-- .context/m3-review-and-corrections.md. TEXT+CHECK instead of enums (C5, no ALTER TYPE friction).

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ============ identity ============
CREATE TABLE IF NOT EXISTS accounts (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  phone_lookup_hash     BYTEA NOT NULL UNIQUE,       -- HMAC-SHA256(E.164, server pepper) — enumerable otherwise
  phone_e164_ciphertext BYTEA NOT NULL,              -- AEAD-encrypted phone (server can decrypt; never plaintext at rest)
  phone_nonce           BYTEA NOT NULL,
  phone_key_id          TEXT  NOT NULL,
  display_name          TEXT  NOT NULL DEFAULT '',
  status                TEXT  NOT NULL DEFAULT 'active'
                          CHECK (status IN ('active','limited','banned','deleted')),
  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- The sync cursor per account. NO `seq` (I1: redundant with pts). pruned_through_pts (B3) is the
-- floor below which events are gone -> get_difference must answer difference_too_long.
CREATE TABLE IF NOT EXISTS account_sync_states (
  account_id         UUID PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
  pts                BIGINT NOT NULL DEFAULT 0,       -- last assigned event number
  pruned_through_pts BIGINT NOT NULL DEFAULT 0,       -- oldest retained pts - 1
  updated_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS devices (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id            UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  platform              TEXT NOT NULL CHECK (platform IN ('ios','android','web','desktop')),
  device_name           TEXT,
  auth_token_hash       BYTEA NOT NULL UNIQUE,        -- SHA-256 of the bearer token
  push_token_hash       BYTEA,
  push_token_ciphertext BYTEA,
  push_token_nonce      BYTEA,
  push_token_key_id     TEXT,
  push_environment      TEXT CHECK (push_environment IN ('sandbox','production')),
  push_updated_at       TIMESTAMPTZ,
  last_seen_at          TIMESTAMPTZ,
  revoked_at            TIMESTAMPTZ,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT now()
);
-- Existing M3 deployments already have devices.push_token_ciphertext, so M4 adds the remaining
-- token metadata with idempotent ALTERs. The token itself is never stored as plaintext.
ALTER TABLE devices ADD COLUMN IF NOT EXISTS push_token_hash BYTEA;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS push_token_nonce BYTEA;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS push_token_key_id TEXT;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS push_environment TEXT;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS push_updated_at TIMESTAMPTZ;
DO $$ BEGIN
  ALTER TABLE devices ADD CONSTRAINT devices_push_environment_check
    CHECK (push_environment IN ('sandbox','production'));
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
CREATE INDEX IF NOT EXISTS devices_account_active_idx ON devices(account_id) WHERE revoked_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS devices_push_token_active_idx
  ON devices(push_environment, push_token_hash)
  WHERE push_token_hash IS NOT NULL AND revoked_at IS NULL;

CREATE TABLE IF NOT EXISTS otp_challenges (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  phone_lookup_hash BYTEA NOT NULL,
  code_hash         BYTEA NOT NULL,                   -- HMAC of the 6-digit code
  code_salt         BYTEA,
  network_hash      BYTEA,
  purpose           TEXT NOT NULL DEFAULT 'login'
                      CHECK (purpose IN ('login','account_deletion')),
  attempts          INT NOT NULL DEFAULT 0,
  expires_at        TIMESTAMPTZ NOT NULL,
  consumed_at       TIMESTAMPTZ,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE otp_challenges ADD COLUMN IF NOT EXISTS code_salt BYTEA;
ALTER TABLE otp_challenges ADD COLUMN IF NOT EXISTS network_hash BYTEA;
ALTER TABLE otp_challenges ADD COLUMN IF NOT EXISTS purpose TEXT NOT NULL DEFAULT 'login';
DO $$ BEGIN
  ALTER TABLE otp_challenges ADD CONSTRAINT otp_challenges_purpose_check
    CHECK (purpose IN ('login','account_deletion'));
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
CREATE INDEX IF NOT EXISTS otp_active_idx ON otp_challenges(phone_lookup_hash, expires_at) WHERE consumed_at IS NULL;
CREATE INDEX IF NOT EXISTS otp_phone_requests_idx ON otp_challenges(phone_lookup_hash, created_at DESC);
CREATE INDEX IF NOT EXISTS otp_network_requests_idx ON otp_challenges(network_hash, created_at DESC)
  WHERE network_hash IS NOT NULL;

-- ============ conversations ============
CREATE TABLE IF NOT EXISTS dialogs (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  type        TEXT NOT NULL CHECK (type IN ('direct','group')),
  title       TEXT,
  created_by  UUID REFERENCES accounts(id),
  last_msg_id BIGINT NOT NULL DEFAULT 0,              -- per-dialog message counter
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- One direct dialog per unordered pair (idempotent 1:1 creation).
CREATE TABLE IF NOT EXISTS direct_dialog_pairs (
  dialog_id    UUID PRIMARY KEY REFERENCES dialogs(id) ON DELETE CASCADE,
  account_low  UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  account_high UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  CHECK (account_low < account_high),
  UNIQUE (account_low, account_high)
);

CREATE TABLE IF NOT EXISTS dialog_members (
  dialog_id        UUID NOT NULL REFERENCES dialogs(id) ON DELETE CASCADE,
  account_id       UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  role             TEXT NOT NULL DEFAULT 'member' CHECK (role IN ('owner','admin','member')),
  last_read_msg_id BIGINT NOT NULL DEFAULT 0,
  joined_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  left_at          TIMESTAMPTZ,
  PRIMARY KEY (dialog_id, account_id)
);
CREATE INDEX IF NOT EXISTS dialog_members_account_active_idx ON dialog_members(account_id) WHERE left_at IS NULL;

-- ============ messages (encrypted-at-rest) ============
CREATE TABLE IF NOT EXISTS messages (
  dialog_id         UUID NOT NULL REFERENCES dialogs(id) ON DELETE CASCADE,
  msg_id            BIGINT NOT NULL,                  -- per-dialog monotonic (ordering key)
  sender_account_id UUID NOT NULL REFERENCES accounts(id),
  sender_device_id  UUID REFERENCES devices(id),
  client_msg_id     UUID NOT NULL,
  kind              TEXT NOT NULL DEFAULT 'text' CHECK (kind IN ('text','photo','video','file','service')),
  body_key_id       TEXT  NOT NULL,
  body_nonce        BYTEA NOT NULL,
  body_ciphertext   BYTEA NOT NULL,                   -- AEAD; AAD binds dialog_id‖msg_id‖sender (S1)
  reply_to_msg_id   BIGINT,
  edit_version      INT NOT NULL DEFAULT 0,
  state             TEXT NOT NULL DEFAULT 'visible' CHECK (state IN ('visible','deleted_for_all')),
  server_ts         TIMESTAMPTZ NOT NULL DEFAULT now(),
  edited_at         TIMESTAMPTZ,
  deleted_at        TIMESTAMPTZ,
  PRIMARY KEY (dialog_id, msg_id),
  UNIQUE (sender_account_id, client_msg_id)           -- belt-and-suspenders vs send_requests
);
DO $$ BEGIN
  ALTER TABLE messages ADD CONSTRAINT messages_reply_target_fk
    FOREIGN KEY (dialog_id, reply_to_msg_id) REFERENCES messages(dialog_id, msg_id);
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
-- No separate DESC index (C1): the PK (dialog_id, msg_id) serves ORDER BY msg_id DESC via reverse scan.

-- ============ the sync log (crown jewel) ============
CREATE TABLE IF NOT EXISTS account_events (
  account_id        UUID   NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  pts               BIGINT NOT NULL,
  type              TEXT   NOT NULL CHECK (type IN
                       ('message.new','message.edited','message.deleted','read.updated',
                        'dialog.created','member.added','member.removed')),
  dialog_id         UUID,
  msg_id            BIGINT,
  actor_account_id  UUID REFERENCES accounts(id),
  data              JSONB NOT NULL DEFAULT '{}'::jsonb,   -- variable extras only (no dup of typed cols, C4)
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (account_id, pts)                            -- serves get_difference: WHERE account_id=? AND pts>? ORDER BY pts
);

-- ============ idempotency (B2): claimed BEFORE any msg_id is allocated ============
CREATE TABLE IF NOT EXISTS send_requests (
  sender_account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  client_msg_id     UUID NOT NULL,
  dialog_id         UUID NOT NULL,
  status            TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','completed')),
  msg_id            BIGINT,                            -- filled on completion
  sender_pts        BIGINT,                            -- filled on completion (retry must echo this)
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (sender_account_id, client_msg_id)
);

-- Edit/delete retries use a client-generated mutation id just like sends use client_msg_id.
-- The claim is taken before locking the message so a timed-out request can safely be repeated.
CREATE TABLE IF NOT EXISTS message_mutation_requests (
  actor_account_id  UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  client_mutation_id UUID NOT NULL,
  operation         TEXT NOT NULL CHECK (operation IN ('edit','delete')),
  dialog_id         UUID NOT NULL,
  msg_id            BIGINT NOT NULL,
  status            TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','completed')),
  actor_pts         BIGINT,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (actor_account_id, client_mutation_id)
);
-- Early development versions briefly added this FK. The idempotency row must be claimable before
-- the message row is locked (global lock order), so validation happens transactionally in sync.ts.
ALTER TABLE message_mutation_requests
  DROP CONSTRAINT IF EXISTS message_mutation_requests_dialog_id_msg_id_fkey;

-- ============ APNs durable outbox (M4.1) ============
-- APNs is only a wake-up hint. The authoritative update remains account_events + get_difference.
-- Rows are created in the same transaction as message.new, so a process crash cannot lose the hint.
CREATE TABLE IF NOT EXISTS push_deliveries (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id   UUID NOT NULL,
  pts          BIGINT NOT NULL,
  device_id    UUID NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  alert        BOOLEAN NOT NULL,
  status       TEXT NOT NULL DEFAULT 'pending'
                 CHECK (status IN ('pending','sending','sent','dead')),
  attempts     INT NOT NULL DEFAULT 0,
  available_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  claimed_at   TIMESTAMPTZ,
  expires_at   TIMESTAMPTZ NOT NULL DEFAULT (now() + interval '24 hours'),
  apns_id      TEXT,
  last_error   TEXT,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  sent_at      TIMESTAMPTZ,
  FOREIGN KEY (account_id, pts) REFERENCES account_events(account_id, pts) ON DELETE CASCADE,
  UNIQUE (account_id, pts, device_id)
);
CREATE INDEX IF NOT EXISTS push_deliveries_ready_idx
  ON push_deliveries(available_at, created_at)
  WHERE status IN ('pending','sending');

-- ============ resumable bootstrap (B1/I2): snapshot token + per-dialog ceilings ============
CREATE TABLE IF NOT EXISTS bootstrap_snapshots (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id   UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  snapshot_pts BIGINT NOT NULL,
  expires_at   TIMESTAMPTZ NOT NULL DEFAULT (now() + interval '30 minutes'),
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS bootstrap_snapshots_account_active_idx
  ON bootstrap_snapshots(account_id, expires_at);

CREATE TABLE IF NOT EXISTS bootstrap_snapshot_dialogs (
  snapshot_id     UUID NOT NULL REFERENCES bootstrap_snapshots(id) ON DELETE CASCADE,
  dialog_id       UUID NOT NULL REFERENCES dialogs(id) ON DELETE CASCADE,
  ceiling_msg_id  BIGINT NOT NULL,
  sort_updated_at TIMESTAMPTZ NOT NULL,
  PRIMARY KEY (snapshot_id, dialog_id)
);
CREATE INDEX IF NOT EXISTS bootstrap_snapshot_dialogs_page_idx
  ON bootstrap_snapshot_dialogs(snapshot_id, sort_updated_at DESC, dialog_id DESC);

-- ============ compliance (append-only audit) ============
CREATE TABLE IF NOT EXISTS content_access_audit (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  actor_kind  TEXT NOT NULL,                          -- 'system'|'support'|'legal'|'moderation'
  actor_id    TEXT,
  account_id  UUID,
  dialog_id   UUID,
  msg_id      BIGINT,
  reason      TEXT NOT NULL,
  request_id  TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS user_reports (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  reporter_account_id         UUID NOT NULL REFERENCES accounts(id),
  reported_account_id         UUID REFERENCES accounts(id),
  dialog_id                   UUID,
  msg_id                      BIGINT,
  reason                      TEXT NOT NULL,
  message_snapshot_key_id     TEXT,
  message_snapshot_nonce      BYTEA,
  message_snapshot_ciphertext BYTEA,                  -- copy of reported msg so moderation needs no inbox access
  created_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),
  resolved_at                 TIMESTAMPTZ
);
