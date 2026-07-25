\set ON_ERROR_STOP on

-- CONTRACT: validation ran before this file. The old constraint remains authoritative until this
-- short lock-timeout transaction swaps names, so writers never see an unconstrained table.
BEGIN;
SET LOCAL lock_timeout = '2s';
SET LOCAL statement_timeout = '30s';

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'account_events'::regclass
      AND conname = 'account_events_type_check_v5'
  ) THEN
    ALTER TABLE account_events DROP CONSTRAINT account_events_type_check;
    ALTER TABLE account_events
      RENAME CONSTRAINT account_events_type_check_v5 TO account_events_type_check;
  END IF;
END;
$$;

-- Upgrade the rolling-deploy mirror. A legacy server writes dialog_members only; this trigger now
-- gives that account a canonical snapshot, one PTS event, durable silent pushes, and a pg_notify
-- wake-up. New preference-service writes update the canonical row first, so the mirror's
-- conditional upsert returns no row and cannot duplicate that service-authored event.
CREATE OR REPLACE FUNCTION mirror_dialog_notification_mode_to_preferences()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  next_pts BIGINT;
  preference_row dialog_preferences%ROWTYPE;
BEGIN
  INSERT INTO dialog_preferences (dialog_id, account_id, is_muted)
  VALUES (NEW.dialog_id, NEW.account_id, NEW.notification_mode = 'muted')
  ON CONFLICT (dialog_id, account_id) DO UPDATE SET
    is_muted = EXCLUDED.is_muted,
    updated_at = statement_timestamp()
  WHERE dialog_preferences.is_muted IS DISTINCT FROM EXCLUDED.is_muted
  RETURNING * INTO preference_row;

  IF TG_OP = 'INSERT'
     OR preference_row.dialog_id IS NULL THEN
    RETURN NEW;
  END IF;

  UPDATE account_sync_states
  SET pts = pts + 1, updated_at = now()
  WHERE account_id = NEW.account_id
  RETURNING pts INTO next_pts;

  INSERT INTO account_events (
    account_id, pts, type, dialog_id, actor_account_id, data
  ) VALUES (
    NEW.account_id,
    next_pts,
    'dialog.preferences_updated',
    NEW.dialog_id,
    NEW.account_id,
    jsonb_build_object(
      'preferences', jsonb_build_object(
        'dialogId', preference_row.dialog_id,
        'pinned', preference_row.is_pinned,
        'pinnedAt', preference_row.pinned_at,
        'muted', preference_row.is_muted,
        'archived', preference_row.is_archived,
        'updatedAt', preference_row.updated_at
      ),
      'changed_fields', jsonb_build_array('muted'),
      'legacy_reconciled', TRUE
    )
  );

  INSERT INTO push_deliveries (account_id, pts, device_id, alert)
  SELECT NEW.account_id, next_pts, device.id, FALSE
  FROM devices device
  WHERE device.account_id = NEW.account_id
    AND device.platform = 'ios'
    AND device.revoked_at IS NULL
    AND device.push_token_hash IS NOT NULL
    AND device.push_token_ciphertext IS NOT NULL
  ON CONFLICT (account_id, pts, device_id) DO NOTHING;

  PERFORM pg_notify(
    'toj_sync_events',
    json_build_object(
      'accountId', NEW.account_id,
      'pts', next_pts,
      'ptsCount', 1
    )::text
  );
  DELETE FROM dialog_preference_legacy_reconciliation
  WHERE dialog_id = NEW.dialog_id AND account_id = NEW.account_id;
  RETURN NEW;
END;
$$;

COMMIT;
