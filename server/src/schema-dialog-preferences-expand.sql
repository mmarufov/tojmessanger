\set ON_ERROR_STOP on

-- EXPAND: every table/column is additive. Keep this transaction deliberately short; the
-- production migration runner supplies a bounded lock timeout before loading this file.
BEGIN;
SET LOCAL lock_timeout = '2s';
SET LOCAL statement_timeout = '30s';

CREATE TABLE IF NOT EXISTS dialog_preferences (
  dialog_id   UUID NOT NULL,
  account_id  UUID NOT NULL,
  is_pinned   BOOLEAN NOT NULL DEFAULT FALSE,
  pinned_at   TIMESTAMPTZ,
  is_muted    BOOLEAN NOT NULL DEFAULT FALSE,
  is_archived BOOLEAN NOT NULL DEFAULT FALSE,
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (dialog_id, account_id),
  FOREIGN KEY (dialog_id, account_id)
    REFERENCES dialog_members(dialog_id, account_id) ON DELETE CASCADE,
  CHECK (is_pinned OR pinned_at IS NULL)
);

CREATE TABLE IF NOT EXISTS dialog_preference_requests (
  account_id         UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  client_mutation_id UUID NOT NULL,
  dialog_id          UUID NOT NULL,
  fingerprint        BYTEA NOT NULL,
  status             TEXT NOT NULL DEFAULT 'pending'
                       CHECK (status IN ('pending','completed')),
  result_pts         BIGINT,
  result_json        JSONB,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (account_id, client_mutation_id)
);

CREATE TABLE IF NOT EXISTS dialog_preference_action_budgets (
  account_id     UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  bucket_started TIMESTAMPTZ NOT NULL,
  mutation_count INTEGER NOT NULL DEFAULT 0 CHECK (mutation_count >= 0),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (account_id, bucket_started)
);

CREATE TABLE IF NOT EXISTS dialog_preference_legacy_reconciliation (
  dialog_id  UUID NOT NULL,
  account_id UUID NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (dialog_id, account_id),
  FOREIGN KEY (dialog_id, account_id)
    REFERENCES dialog_preferences(dialog_id, account_id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS online_migration_cursors (
  migration_name TEXT PRIMARY KEY,
  last_dialog_id UUID,
  last_account_id UUID,
  rows_processed BIGINT NOT NULL DEFAULT 0,
  completed_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (
    (last_dialog_id IS NULL AND last_account_id IS NULL)
    OR (last_dialog_id IS NOT NULL AND last_account_id IS NOT NULL)
  )
);
INSERT INTO online_migration_cursors (migration_name)
VALUES ('dialog_preferences_v1')
ON CONFLICT (migration_name) DO NOTHING;

ALTER TABLE bootstrap_snapshot_dialogs
  ADD COLUMN IF NOT EXISTS preferences_captured BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE bootstrap_snapshot_dialogs
  ADD COLUMN IF NOT EXISTS preference_is_pinned BOOLEAN;
ALTER TABLE bootstrap_snapshot_dialogs
  ADD COLUMN IF NOT EXISTS preference_pinned_at TIMESTAMPTZ;
ALTER TABLE bootstrap_snapshot_dialogs
  ADD COLUMN IF NOT EXISTS preference_is_muted BOOLEAN;
ALTER TABLE bootstrap_snapshot_dialogs
  ADD COLUMN IF NOT EXISTS preference_is_archived BOOLEAN;
ALTER TABLE bootstrap_snapshot_dialogs
  ADD COLUMN IF NOT EXISTS preference_updated_at TIMESTAMPTZ;

-- Add the replacement without scanning account_events or dropping the live constraint.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conrelid = 'account_events'::regclass
      AND conname = 'account_events_type_check'
      AND pg_get_constraintdef(oid) LIKE '%dialog.preferences_updated%'
  ) THEN
    RETURN;
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conrelid = 'account_events'::regclass
      AND conname = 'account_events_type_check_v5'
  ) THEN
    ALTER TABLE account_events
      ADD CONSTRAINT account_events_type_check_v5 CHECK (type IN
        ('message.new','message.edited','message.deleted','reaction.updated','read.updated',
         'dialog.created','member.added','member.removed','member.role_changed','member.left',
         'dialog.profile_updated','dialog.closed','dialog.access_revoked',
         'dialog.preferences_updated','profile.updated'))
      NOT VALID;
  END IF;
END;
$$;

-- During the backfill, protect rows inserted or muted by an old server. This version only mirrors
-- state: it cannot emit the new event until the replacement account_events constraint is live.
CREATE OR REPLACE FUNCTION mirror_dialog_notification_mode_to_preferences()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  INSERT INTO dialog_preferences (dialog_id, account_id, is_muted)
  VALUES (NEW.dialog_id, NEW.account_id, NEW.notification_mode = 'muted')
  ON CONFLICT (dialog_id, account_id) DO UPDATE SET
    is_muted = EXCLUDED.is_muted,
    updated_at = statement_timestamp()
  WHERE dialog_preferences.is_muted IS DISTINCT FROM EXCLUDED.is_muted;
  IF TG_OP = 'INSERT' THEN
    RETURN NEW;
  END IF;
  IF FOUND THEN
    INSERT INTO dialog_preference_legacy_reconciliation (dialog_id, account_id)
    VALUES (NEW.dialog_id, NEW.account_id)
    ON CONFLICT (dialog_id, account_id) DO UPDATE SET created_at = statement_timestamp();
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS dialog_members_notification_mode_mirror ON dialog_members;
CREATE TRIGGER dialog_members_notification_mode_mirror
AFTER INSERT OR UPDATE OF notification_mode ON dialog_members
FOR EACH ROW
EXECUTE FUNCTION mirror_dialog_notification_mode_to_preferences();

COMMIT;
