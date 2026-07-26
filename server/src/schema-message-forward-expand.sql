-- Expand phase for mixed old/new message writers. All DDL is metadata-only and lock bounded.
SET lock_timeout = '5s';

ALTER TABLE messages
  ADD COLUMN IF NOT EXISTS is_forwarded BOOLEAN NOT NULL DEFAULT FALSE;

CREATE TABLE IF NOT EXISTS schema_migration_progress (
  migration_name   TEXT PRIMARY KEY,
  cursor_dialog_id UUID,
  cursor_msg_id    BIGINT,
  rows_processed  BIGINT NOT NULL DEFAULT 0,
  completed_at    TIMESTAMPTZ,
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK ((cursor_dialog_id IS NULL) = (cursor_msg_id IS NULL)),
  CHECK (rows_processed >= 0)
);

INSERT INTO schema_migration_progress (migration_name)
VALUES ('messages_is_forwarded_v1')
ON CONFLICT (migration_name) DO NOTHING;

CREATE OR REPLACE FUNCTION toj_messages_derive_forward_marker()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.forwarded_from_dialog_id IS NOT NULL
     AND NEW.forwarded_from_msg_id IS NOT NULL THEN
    NEW.is_forwarded := TRUE;
  ELSIF NEW.is_forwarded IS NULL THEN
    NEW.is_forwarded := FALSE;
  END IF;
  RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS messages_derive_forward_marker ON messages;
CREATE TRIGGER messages_derive_forward_marker
BEFORE INSERT OR UPDATE OF forwarded_from_dialog_id, forwarded_from_msg_id, is_forwarded
ON messages
FOR EACH ROW EXECUTE FUNCTION toj_messages_derive_forward_marker();

DO $$ BEGIN
  ALTER TABLE messages ADD CONSTRAINT messages_forward_marker_check
    CHECK (
      forwarded_from_dialog_id IS NULL
      OR forwarded_from_msg_id IS NULL
      OR is_forwarded = TRUE
    ) NOT VALID;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- Saved access/deletion invariants are installed separately after this forwarding-marker expand.
