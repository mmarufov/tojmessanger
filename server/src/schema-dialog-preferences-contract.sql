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
CREATE OR REPLACE FUNCTION mirror_dialog_notification_mode_to_preferences_v1_final()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  next_pts BIGINT;
  preference_row dialog_preferences%ROWTYPE;
  account_status TEXT;
  budget_count INTEGER;
BEGIN
  -- Serialize with the account row update used by deletion. If deletion won, rejecting here rolls
  -- back both the old-node dialog_members write and every compatibility side effect.
  SELECT status INTO account_status
  FROM accounts
  WHERE id = NEW.account_id
  FOR KEY SHARE;
  IF account_status IS NULL OR account_status NOT IN ('active', 'limited') THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0001',
      MESSAGE = 'dialog_preference_account_unavailable';
  END IF;

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

  INSERT INTO dialog_preference_action_budgets (
    account_id, bucket_started, mutation_count
  ) VALUES (
    NEW.account_id, date_trunc('hour', now()), 1
  )
  ON CONFLICT (account_id, bucket_started) DO UPDATE SET
    mutation_count = dialog_preference_action_budgets.mutation_count + 1,
    updated_at = now()
  WHERE dialog_preference_action_budgets.mutation_count < 240
  RETURNING mutation_count INTO budget_count;
  IF budget_count IS NULL THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0001',
      MESSAGE = 'dialog_preference_rate_limited';
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

DROP TRIGGER IF EXISTS dialog_members_notification_mode_mirror ON dialog_members;
CREATE TRIGGER dialog_members_notification_mode_mirror
AFTER INSERT OR UPDATE OF notification_mode ON dialog_members
FOR EACH ROW
EXECUTE FUNCTION mirror_dialog_notification_mode_to_preferences_v1_final();

-- The marker and final trigger become visible in the same commit. Readiness requires both, so no
-- process can advertise the contracted schema while staging behavior is still attached.
DO $$
BEGIN
  UPDATE online_migration_cursors
  SET contract_version = 1,
      contract_completed_at = statement_timestamp(),
      updated_at = statement_timestamp()
  WHERE migration_name = 'dialog_preferences_v1';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'dialog_preferences_v1 migration marker is missing';
  END IF;
END;
$$;

-- Remove the pre-versioned implementation after its trigger dependency has moved. The versioned
-- staging function remains available for a future expand rerun without replacing the final body.
DROP FUNCTION IF EXISTS mirror_dialog_notification_mode_to_preferences();

COMMIT;
