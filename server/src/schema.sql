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
  first_name            TEXT  NOT NULL DEFAULT '',
  last_name             TEXT  NOT NULL DEFAULT '',
  display_name          TEXT  NOT NULL DEFAULT '',
  bio                   TEXT  NOT NULL DEFAULT '',
  birthday              DATE,
  profile_color         INT   NOT NULL DEFAULT 0 CHECK (profile_color BETWEEN 0 AND 7),
  status                TEXT  NOT NULL DEFAULT 'active'
                          CHECK (status IN ('active','limited','banned','deleted')),
  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS first_name TEXT NOT NULL DEFAULT '';
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS last_name TEXT NOT NULL DEFAULT '';
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS bio TEXT NOT NULL DEFAULT '';
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS birthday DATE;
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS profile_color INT NOT NULL DEFAULT 0;
DO $$ BEGIN
  ALTER TABLE accounts ADD CONSTRAINT accounts_profile_color_check
    CHECK (profile_color BETWEEN 0 AND 7);
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
UPDATE accounts
SET first_name = display_name
WHERE first_name = '' AND last_name = '' AND display_name <> '';

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
-- PushKit uses a different APNs token and topic from ordinary notifications. Keep the
-- registrations separate so an Unregistered response for one topic cannot erase the other.
ALTER TABLE devices ADD COLUMN IF NOT EXISTS voip_push_token_hash BYTEA;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS voip_push_token_ciphertext BYTEA;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS voip_push_token_nonce BYTEA;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS voip_push_token_key_id TEXT;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS voip_push_environment TEXT;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS voip_push_updated_at TIMESTAMPTZ;
-- Call capabilities are device-scoped. Legacy registrations intentionally reset these
-- values to profile 1 so a stale profile-2 advertisement cannot survive an app downgrade.
ALTER TABLE devices ADD COLUMN IF NOT EXISTS supported_call_protocol_versions INT[] NOT NULL DEFAULT ARRAY[1]::INT[];
ALTER TABLE devices ADD COLUMN IF NOT EXISTS supported_call_media_profile_versions INT[] NOT NULL DEFAULT ARRAY[1]::INT[];
ALTER TABLE devices ADD COLUMN IF NOT EXISTS call_view_version INT NOT NULL DEFAULT 1;
DO $$ BEGIN
  ALTER TABLE devices ADD CONSTRAINT devices_push_environment_check
    CHECK (push_environment IN ('sandbox','production'));
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
DO $$ BEGIN
  ALTER TABLE devices ADD CONSTRAINT devices_voip_push_environment_check
    CHECK (voip_push_environment IN ('sandbox','production')) NOT VALID;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
CREATE INDEX IF NOT EXISTS devices_account_active_idx ON devices(account_id) WHERE revoked_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS devices_push_token_active_idx
  ON devices(push_environment, push_token_hash)
  WHERE push_token_hash IS NOT NULL AND revoked_at IS NULL;
-- The VoIP token index is built concurrently by schema-concurrent.sql because devices may already
-- be large in production.

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

-- Persisted, per-account discovery budget. This makes phone enumeration expensive even across
-- server restarts and multiple app processes; repeated lookups of the same contact are idempotent
-- within the window so normal retries do not consume the budget.
CREATE TABLE IF NOT EXISTS contact_lookup_attempts (
  id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  requester_account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  target_phone_hash    BYTEA NOT NULL,
  created_at           TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE contact_lookup_attempts DROP COLUMN IF EXISTS found;
CREATE INDEX IF NOT EXISTS contact_lookup_attempts_requester_idx
  ON contact_lookup_attempts(requester_account_id, created_at DESC);

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

-- ============ encrypted resumable media ============
-- Private-beta storage is provider-free: each independently resumable chunk is AEAD encrypted
-- before PostgreSQL persists it. The API is deliberately storage-adapter shaped so object storage
-- can replace this table later without changing clients or message history.
CREATE TABLE IF NOT EXISTS media_objects (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_account_id      UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  kind                  TEXT NOT NULL CHECK (kind IN ('photo','video','file','voice')),
  content_type          TEXT NOT NULL,
  file_name             TEXT,                           -- legacy only; new writes keep this NULL
  file_name_key_id      TEXT,
  file_name_nonce       BYTEA,
  file_name_ciphertext  BYTEA,
  byte_size             BIGINT NOT NULL CHECK (byte_size > 0),
  expected_sha256       BYTEA NOT NULL CHECK (octet_length(expected_sha256) = 32), -- HMAC(raw SHA-256)
  uploaded_bytes        BIGINT NOT NULL DEFAULT 0 CHECK (uploaded_bytes >= 0),
  upload_protocol       TEXT NOT NULL DEFAULT 'offset_v1'
                          CHECK (upload_protocol IN ('offset_v1','parts_v2')),
  part_size             INT CHECK (part_size IS NULL OR part_size > 0),
  total_parts           INT CHECK (total_parts IS NULL OR total_parts > 0),
  duration_ms           BIGINT CHECK (duration_ms IS NULL OR duration_ms >= 0),
  width                 INT CHECK (width IS NULL OR width > 0),
  height                INT CHECK (height IS NULL OR height > 0),
  status                TEXT NOT NULL DEFAULT 'uploading'
                          CHECK (status IN ('uploading','ready','rejected','deleted')),
  thumbnail_key_id      TEXT,
  thumbnail_nonce       BYTEA,
  thumbnail_ciphertext  BYTEA,
  thumbnail_byte_size   INT CHECK (thumbnail_byte_size IS NULL OR thumbnail_byte_size > 0),
  thumbnail_content_type TEXT,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  completed_at          TIMESTAMPTZ,
  expires_at            TIMESTAMPTZ NOT NULL DEFAULT now() + interval '24 hours',
  last_accessed_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (uploaded_bytes <= byte_size),
  CHECK ((thumbnail_ciphertext IS NULL) = (thumbnail_nonce IS NULL)),
  CHECK ((file_name_ciphertext IS NULL) = (file_name_nonce IS NULL))
);
ALTER TABLE media_objects ADD COLUMN IF NOT EXISTS file_name_key_id TEXT;
ALTER TABLE media_objects ADD COLUMN IF NOT EXISTS file_name_nonce BYTEA;
ALTER TABLE media_objects ADD COLUMN IF NOT EXISTS file_name_ciphertext BYTEA;
ALTER TABLE media_objects ADD COLUMN IF NOT EXISTS upload_protocol TEXT NOT NULL DEFAULT 'offset_v1';
ALTER TABLE media_objects ADD COLUMN IF NOT EXISTS part_size INT;
ALTER TABLE media_objects ADD COLUMN IF NOT EXISTS total_parts INT;
ALTER TABLE media_objects DROP CONSTRAINT IF EXISTS media_objects_upload_protocol_check;
ALTER TABLE media_objects ADD CONSTRAINT media_objects_upload_protocol_check CHECK (
  (upload_protocol = 'offset_v1' AND part_size IS NULL AND total_parts IS NULL) OR
  (upload_protocol = 'parts_v2' AND part_size > 0 AND total_parts > 0)
);
ALTER TABLE media_objects DROP CONSTRAINT IF EXISTS media_objects_status_check;
ALTER TABLE media_objects ADD CONSTRAINT media_objects_status_check
  CHECK (status IN ('uploading','ready','rejected','deleted'));
CREATE INDEX IF NOT EXISTS media_objects_owner_quota_idx
  ON media_objects(owner_account_id, status, created_at);

-- Kept separately from media_objects so create/cancel loops cannot evade per-account rate limits.
CREATE TABLE IF NOT EXISTS media_upload_attempts (
  id         BIGSERIAL PRIMARY KEY,
  account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS media_upload_attempts_account_created_idx
  ON media_upload_attempts(account_id, created_at DESC);

CREATE TABLE IF NOT EXISTS media_chunks (
  media_id       UUID NOT NULL REFERENCES media_objects(id) ON DELETE CASCADE,
  chunk_offset   BIGINT NOT NULL CHECK (chunk_offset >= 0),
  plain_size     INT NOT NULL CHECK (plain_size > 0),
  plain_sha256   BYTEA NOT NULL CHECK (octet_length(plain_sha256) = 32),
  key_id         TEXT NOT NULL,
  nonce          BYTEA NOT NULL,
  ciphertext     BYTEA NOT NULL,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (media_id, chunk_offset)
);

-- ============ messages (encrypted-at-rest) ============
CREATE TABLE IF NOT EXISTS messages (
  dialog_id         UUID NOT NULL REFERENCES dialogs(id) ON DELETE CASCADE,
  msg_id            BIGINT NOT NULL,                  -- per-dialog monotonic (ordering key)
  sender_account_id UUID NOT NULL REFERENCES accounts(id),
  sender_device_id  UUID REFERENCES devices(id),
  client_msg_id     UUID NOT NULL,
  kind              TEXT NOT NULL DEFAULT 'text' CHECK (kind IN ('text','photo','video','file','voice','service')),
  body_key_id       TEXT  NOT NULL,
  body_nonce        BYTEA NOT NULL,
  body_ciphertext   BYTEA NOT NULL,                   -- AEAD; AAD binds dialog_id‖msg_id‖sender (S1)
  reply_to_msg_id   BIGINT,
  forwarded_from_account_id UUID REFERENCES accounts(id),
  forwarded_from_dialog_id UUID,
  forwarded_from_msg_id BIGINT,
  media_id          UUID REFERENCES media_objects(id),
  edit_version      INT NOT NULL DEFAULT 0,
  state             TEXT NOT NULL DEFAULT 'visible' CHECK (state IN ('visible','deleted_for_all')),
  server_ts         TIMESTAMPTZ NOT NULL DEFAULT now(),
  edited_at         TIMESTAMPTZ,
  deleted_at        TIMESTAMPTZ,
  PRIMARY KEY (dialog_id, msg_id),
  UNIQUE (sender_account_id, client_msg_id)           -- belt-and-suspenders vs send_requests
);
ALTER TABLE messages ADD COLUMN IF NOT EXISTS forwarded_from_account_id UUID REFERENCES accounts(id);
ALTER TABLE messages ADD COLUMN IF NOT EXISTS forwarded_from_dialog_id UUID;
ALTER TABLE messages ADD COLUMN IF NOT EXISTS forwarded_from_msg_id BIGINT;
ALTER TABLE messages ADD COLUMN IF NOT EXISTS media_id UUID REFERENCES media_objects(id);
ALTER TABLE messages DROP CONSTRAINT IF EXISTS messages_kind_check;
ALTER TABLE messages ADD CONSTRAINT messages_kind_check
  CHECK (kind IN ('text','photo','video','file','voice','service'));
CREATE INDEX IF NOT EXISTS messages_media_idx ON messages(media_id) WHERE media_id IS NOT NULL;
-- The call-eligibility index is built concurrently by schema-concurrent.sql because messages is an
-- existing, high-write table.
DO $$ BEGIN
  ALTER TABLE messages ADD CONSTRAINT messages_reply_target_fk
    FOREIGN KEY (dialog_id, reply_to_msg_id) REFERENCES messages(dialog_id, msg_id);
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
DO $$ BEGIN
  ALTER TABLE messages ADD CONSTRAINT messages_forward_source_fk
    FOREIGN KEY (forwarded_from_dialog_id, forwarded_from_msg_id) REFERENCES messages(dialog_id, msg_id);
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

CREATE TABLE IF NOT EXISTS message_reactions (
  dialog_id  UUID NOT NULL,
  msg_id     BIGINT NOT NULL,
  account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  emoji      TEXT NOT NULL CHECK (char_length(emoji) BETWEEN 1 AND 16),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (dialog_id, msg_id, account_id),
  FOREIGN KEY (dialog_id, msg_id) REFERENCES messages(dialog_id, msg_id) ON DELETE CASCADE
);
-- No separate DESC index (C1): the PK (dialog_id, msg_id) serves ORDER BY msg_id DESC via reverse scan.

-- ============ the sync log (crown jewel) ============
CREATE TABLE IF NOT EXISTS account_events (
  account_id        UUID   NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  pts               BIGINT NOT NULL,
  type              TEXT   NOT NULL CHECK (type IN
                       ('message.new','message.edited','message.deleted','reaction.updated','read.updated',
                        'dialog.created','member.added','member.removed','profile.updated')),
  dialog_id         UUID,
  msg_id            BIGINT,
  actor_account_id  UUID REFERENCES accounts(id),
  data              JSONB NOT NULL DEFAULT '{}'::jsonb,   -- variable extras only (no dup of typed cols, C4)
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (account_id, pts)                            -- serves get_difference: WHERE account_id=? AND pts>? ORDER BY pts
);
ALTER TABLE account_events DROP CONSTRAINT IF EXISTS account_events_type_check;
ALTER TABLE account_events ADD CONSTRAINT account_events_type_check CHECK (type IN
  ('message.new','message.edited','message.deleted','reaction.updated','read.updated',
   'dialog.created','member.added','member.removed','profile.updated'));

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
  operation         TEXT NOT NULL CHECK (operation IN ('edit','delete','reaction')),
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
ALTER TABLE message_mutation_requests DROP CONSTRAINT IF EXISTS message_mutation_requests_operation_check;
ALTER TABLE message_mutation_requests ADD CONSTRAINT message_mutation_requests_operation_check
  CHECK (operation IN ('edit','delete','reaction'));

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

-- ============ one-to-one E2EE voice-call control plane ============
-- The server stores lifecycle metadata, public key-agreement material, and opaque encrypted
-- signaling only. It never receives the derived call key, plaintext SDP/ICE, or media.
CREATE TABLE IF NOT EXISTS account_blocks (
  blocker_account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  blocked_account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (blocker_account_id, blocked_account_id),
  CHECK (blocker_account_id <> blocked_account_id)
);
CREATE INDEX IF NOT EXISTS account_blocks_blocked_idx ON account_blocks(blocked_account_id, blocker_account_id);

CREATE TABLE IF NOT EXISTS calls (
  id                        UUID PRIMARY KEY,
  dialog_id                 UUID NOT NULL REFERENCES dialogs(id),
  caller_account_id         UUID NOT NULL REFERENCES accounts(id),
  caller_device_id          UUID NOT NULL REFERENCES devices(id),
  callee_account_id         UUID NOT NULL REFERENCES accounts(id),
  state                     TEXT NOT NULL DEFAULT 'requested'
                              CHECK (state IN ('requested','accepted','key_exchange','active','ended')),
  supported_protocols       INT[] NOT NULL,
  offered_media_profiles    INT[] NOT NULL,
  initial_kind              TEXT NOT NULL DEFAULT 'voice'
                              CHECK (initial_kind IN ('voice','video')),
  selectable_media_profiles INT[] NOT NULL DEFAULT ARRAY[1]::INT[],
  protocol_version          INT,
  media_profile_version     INT,
  caller_commitment         BYTEA NOT NULL CHECK (octet_length(caller_commitment) = 32),
  callee_commitment         BYTEA CHECK (callee_commitment IS NULL OR octet_length(callee_commitment) = 32),
  caller_fingerprint        BYTEA CHECK (caller_fingerprint IS NULL OR octet_length(caller_fingerprint) = 32),
  accepted_device_id        UUID REFERENCES devices(id),
  callee_public_key         BYTEA CHECK (callee_public_key IS NULL OR octet_length(callee_public_key) = 32),
  callee_nonce              BYTEA CHECK (callee_nonce IS NULL OR octet_length(callee_nonce) = 32),
  callee_fingerprint        BYTEA CHECK (callee_fingerprint IS NULL OR octet_length(callee_fingerprint) = 32),
  caller_public_key         BYTEA CHECK (caller_public_key IS NULL OR octet_length(caller_public_key) = 32),
  caller_nonce              BYTEA CHECK (caller_nonce IS NULL OR octet_length(caller_nonce) = 32),
  caller_confirmation       BYTEA CHECK (caller_confirmation IS NULL OR octet_length(caller_confirmation) = 32),
  callee_confirmation       BYTEA CHECK (callee_confirmation IS NULL OR octet_length(callee_confirmation) = 32),
  latest_event_seq          BIGINT NOT NULL DEFAULT 0,
  created_at                TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at                TIMESTAMPTZ NOT NULL DEFAULT now() + interval '30 seconds',
  accepted_at               TIMESTAMPTZ,
  confirmed_at              TIMESTAMPTZ,
  ended_at                  TIMESTAMPTZ,
  end_reason                TEXT,
  CHECK (caller_account_id <> callee_account_id)
);
ALTER TABLE calls ADD COLUMN IF NOT EXISTS initial_kind TEXT NOT NULL DEFAULT 'voice';
ALTER TABLE calls ADD COLUMN IF NOT EXISTS selectable_media_profiles INT[];
ALTER TABLE calls ALTER COLUMN selectable_media_profiles SET DEFAULT ARRAY[1]::INT[];
DO $$ BEGIN
  ALTER TABLE calls ADD CONSTRAINT calls_initial_kind_check CHECK (initial_kind IN ('voice','video'));
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
DO $$ BEGIN
  ALTER TABLE calls ADD CONSTRAINT calls_selectable_media_profiles_not_null
    CHECK (selectable_media_profiles IS NOT NULL) NOT VALID;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
CREATE INDEX IF NOT EXISTS calls_caller_active_idx ON calls(caller_account_id, created_at DESC)
  WHERE state <> 'ended';
CREATE INDEX IF NOT EXISTS calls_callee_active_idx ON calls(callee_account_id, created_at DESC)
  WHERE state <> 'ended';
CREATE INDEX IF NOT EXISTS calls_expiry_idx ON calls(expires_at) WHERE state <> 'ended';
CREATE INDEX IF NOT EXISTS calls_ended_retention_idx ON calls(ended_at) WHERE state = 'ended';

-- At most one active call can hold an account lease. Acquiring both leases in account UUID order
-- makes simultaneous cross-calls deterministic and prevents double CallKit sessions.
CREATE TABLE IF NOT EXISTS call_participant_leases (
  account_id UUID PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
  call_id    UUID NOT NULL REFERENCES calls(id) ON DELETE CASCADE,
  expires_at TIMESTAMPTZ NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (call_id, account_id)
);
CREATE INDEX IF NOT EXISTS call_participant_leases_expiry_idx ON call_participant_leases(expires_at);

CREATE TABLE IF NOT EXISTS call_ring_targets (
  call_id     UUID NOT NULL REFERENCES calls(id) ON DELETE CASCADE,
  device_id   UUID NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  status      TEXT NOT NULL DEFAULT 'ringing'
                CHECK (status IN ('ringing','accepted','declined','answered_elsewhere','expired','ended')),
  selectable_protocols INT[] NOT NULL DEFAULT ARRAY[1]::INT[],
  selectable_media_profiles INT[] NOT NULL DEFAULT ARRAY[1]::INT[],
  call_view_version INT NOT NULL DEFAULT 1,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  responded_at TIMESTAMPTZ,
  PRIMARY KEY (call_id, device_id)
);
ALTER TABLE call_ring_targets ADD COLUMN IF NOT EXISTS selectable_protocols INT[] NOT NULL DEFAULT ARRAY[1]::INT[];
ALTER TABLE call_ring_targets ADD COLUMN IF NOT EXISTS selectable_media_profiles INT[] NOT NULL DEFAULT ARRAY[1]::INT[];
ALTER TABLE call_ring_targets ADD COLUMN IF NOT EXISTS call_view_version INT NOT NULL DEFAULT 1;
CREATE INDEX IF NOT EXISTS call_ring_targets_device_idx ON call_ring_targets(device_id, created_at DESC);

CREATE TABLE IF NOT EXISTS call_events (
  call_id          UUID NOT NULL REFERENCES calls(id) ON DELETE CASCADE,
  event_seq        BIGINT NOT NULL CHECK (event_seq > 0),
  event_type       TEXT NOT NULL CHECK (event_type IN ('requested','accepted','revealed','confirmed','encrypted','ended')),
  sender_account_id UUID REFERENCES accounts(id),
  sender_device_id UUID REFERENCES devices(id),
  sender_sequence  BIGINT CHECK (sender_sequence IS NULL OR sender_sequence > 0),
  signal_version   INT,
  signal_kind      TEXT CHECK (signal_kind IS NULL OR signal_kind IN
                       ('offer','answer','ice_candidate','ice_restart','hangup','control')),
  envelope_expires_at TIMESTAMPTZ,
  ciphertext       BYTEA CHECK (ciphertext IS NULL OR octet_length(ciphertext) BETWEEN 1 AND 65564),
  data             JSONB,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at       TIMESTAMPTZ NOT NULL DEFAULT now() + interval '24 hours',
  PRIMARY KEY (call_id, event_seq),
  CHECK ((event_type = 'encrypted' AND ciphertext IS NOT NULL AND data IS NULL AND sender_sequence IS NOT NULL
          AND signal_version IS NOT NULL AND signal_kind IS NOT NULL AND envelope_expires_at IS NOT NULL)
      OR (event_type <> 'encrypted' AND ciphertext IS NULL AND data IS NOT NULL AND sender_sequence IS NULL
          AND signal_version IS NULL AND signal_kind IS NULL AND envelope_expires_at IS NULL))
);
CREATE INDEX IF NOT EXISTS call_events_expiry_idx ON call_events(expires_at);
CREATE UNIQUE INDEX IF NOT EXISTS call_events_sender_sequence_idx
  ON call_events(call_id, sender_device_id, sender_sequence) WHERE sender_sequence IS NOT NULL;

-- One active call is allowed per account, and each owning device gets a small rolling signaling
-- budget. This bounds database/WAL/NOTIFY amplification without inspecting encrypted SDP or ICE.
CREATE TABLE IF NOT EXISTS call_signal_budgets (
  call_id                 UUID NOT NULL REFERENCES calls(id) ON DELETE CASCADE,
  sender_device_id        UUID NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  window_started_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  event_count             INT NOT NULL DEFAULT 0 CHECK (event_count >= 0),
  ciphertext_bytes        BIGINT NOT NULL DEFAULT 0 CHECK (ciphertext_bytes >= 0),
  negotiation_event_count INT NOT NULL DEFAULT 0 CHECK (negotiation_event_count >= 0),
  PRIMARY KEY (call_id, sender_device_id)
);

CREATE TABLE IF NOT EXISTS call_telemetry_reports (
  call_id    UUID NOT NULL REFERENCES calls(id) ON DELETE CASCADE,
  device_id  UUID NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (call_id, device_id)
);

-- The call row and its user-visible history row must survive independent process/database failures.
-- A terminal transition inserts this record in the same transaction; a retrying worker delivers the
-- service message with the original caller identity as its stable idempotency owner.
CREATE TABLE IF NOT EXISTS call_history_outbox (
  call_id            UUID PRIMARY KEY REFERENCES calls(id) ON DELETE CASCADE,
  history_client_msg_id UUID NOT NULL DEFAULT gen_random_uuid(),
  dialog_id          UUID NOT NULL REFERENCES dialogs(id),
  caller_account_id  UUID NOT NULL REFERENCES accounts(id),
  initial_kind       TEXT NOT NULL DEFAULT 'voice'
                       CHECK (initial_kind IN ('voice','video')),
  outcome            TEXT NOT NULL CHECK (outcome IN ('completed','declined','missed','busy','cancelled','failed')),
  duration_seconds   INT NOT NULL DEFAULT 0 CHECK (duration_seconds >= 0),
  status             TEXT NOT NULL DEFAULT 'pending'
                       CHECK (status IN ('pending','sending','delivered')),
  attempts           INT NOT NULL DEFAULT 0,
  available_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  claimed_at         TIMESTAMPTZ,
  last_error         TEXT,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  delivered_at       TIMESTAMPTZ
);
ALTER TABLE call_history_outbox ADD COLUMN IF NOT EXISTS initial_kind TEXT NOT NULL DEFAULT 'voice';
DO $$ BEGIN
  ALTER TABLE call_history_outbox ADD CONSTRAINT call_history_outbox_initial_kind_check
    CHECK (initial_kind IN ('voice','video'));
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
ALTER TABLE call_history_outbox ADD COLUMN IF NOT EXISTS history_client_msg_id UUID DEFAULT gen_random_uuid();
UPDATE call_history_outbox SET history_client_msg_id = gen_random_uuid()
WHERE history_client_msg_id IS NULL;
ALTER TABLE call_history_outbox ALTER COLUMN history_client_msg_id SET NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS call_history_outbox_client_msg_idx
  ON call_history_outbox(caller_account_id, history_client_msg_id);
CREATE INDEX IF NOT EXISTS call_history_outbox_ready_idx
  ON call_history_outbox(available_at, created_at) WHERE status IN ('pending','sending');

-- Attempts survive cancelled/expired call cleanup so repeated invite/cancel loops remain limited.
CREATE TABLE IF NOT EXISTS call_invite_attempts (
  id                BIGSERIAL PRIMARY KEY,
  caller_account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  callee_account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  caller_device_id  UUID NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  network_hash      BYTEA,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS call_invite_attempts_caller_idx
  ON call_invite_attempts(caller_account_id, created_at DESC);
CREATE INDEX IF NOT EXISTS call_invite_attempts_callee_idx
  ON call_invite_attempts(callee_account_id, created_at DESC);
CREATE INDEX IF NOT EXISTS call_invite_attempts_network_idx
  ON call_invite_attempts(network_hash, created_at DESC) WHERE network_hash IS NOT NULL;
CREATE INDEX IF NOT EXISTS call_invite_attempts_retention_idx ON call_invite_attempts(created_at);

CREATE TABLE IF NOT EXISTS voip_push_deliveries (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  call_id           UUID NOT NULL REFERENCES calls(id) ON DELETE CASCADE,
  caller_account_id UUID NOT NULL REFERENCES accounts(id),
  initial_kind      TEXT NOT NULL DEFAULT 'voice'
                      CHECK (initial_kind IN ('voice','video')),
  device_id         UUID NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  status            TEXT NOT NULL DEFAULT 'pending'
                      CHECK (status IN ('pending','sending','sent','dead')),
  attempts          INT NOT NULL DEFAULT 0,
  available_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  claimed_at        TIMESTAMPTZ,
  expires_at        TIMESTAMPTZ NOT NULL,
  apns_id           TEXT,
  last_error        TEXT,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  sent_at           TIMESTAMPTZ,
  UNIQUE (call_id, device_id)
);
ALTER TABLE voip_push_deliveries ADD COLUMN IF NOT EXISTS initial_kind TEXT NOT NULL DEFAULT 'voice';
DO $$ BEGIN
  ALTER TABLE voip_push_deliveries ADD CONSTRAINT voip_push_deliveries_initial_kind_check
    CHECK (initial_kind IN ('voice','video'));
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
CREATE INDEX IF NOT EXISTS voip_push_deliveries_ready_idx
  ON voip_push_deliveries(available_at, created_at) WHERE status IN ('pending','sending');
CREATE INDEX IF NOT EXISTS voip_push_deliveries_retention_idx
  ON voip_push_deliveries(created_at) WHERE status IN ('sent','dead');

-- Credential secrets are never stored. This table is a short-lived allocation/abuse audit only.
CREATE TABLE IF NOT EXISTS turn_allocations (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  call_id    UUID NOT NULL REFERENCES calls(id) ON DELETE CASCADE,
  account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  username   TEXT NOT NULL,
  expires_at TIMESTAMPTZ NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (call_id, account_id, username)
);
CREATE INDEX IF NOT EXISTS turn_allocations_expiry_idx ON turn_allocations(expires_at);
CREATE INDEX IF NOT EXISTS turn_allocations_account_expiry_idx
  ON turn_allocations(account_id, expires_at);

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
