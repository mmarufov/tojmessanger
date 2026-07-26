-- Saved-dialog access and deletion are database invariants, not application conventions.
SET lock_timeout = '5s';

INSERT INTO schema_migration_progress (migration_name)
VALUES ('saved_dialog_membership_v1')
ON CONFLICT (migration_name) DO NOTHING;

CREATE OR REPLACE FUNCTION toj_enforce_saved_dialog_member()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  saved_owner UUID;
BEGIN
  IF NEW.left_at IS NOT NULL THEN
    RETURN NEW;
  END IF;

  SELECT created_by
  INTO saved_owner
  FROM dialogs
  WHERE id = NEW.dialog_id AND type = 'saved';

  IF FOUND AND (NEW.account_id <> saved_owner OR NEW.role <> 'owner') THEN
    RAISE EXCEPTION 'active Saved Messages membership must belong to its owner'
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS dialog_members_enforce_saved_owner ON dialog_members;
CREATE TRIGGER dialog_members_enforce_saved_owner
BEFORE INSERT OR UPDATE OF dialog_id, account_id, role, left_at
ON dialog_members
FOR EACH ROW EXECUTE FUNCTION toj_enforce_saved_dialog_member();

CREATE OR REPLACE FUNCTION toj_enforce_saved_dialog_shape()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.type = 'saved' AND EXISTS (
    SELECT 1
    FROM dialog_members member
    WHERE member.dialog_id = NEW.id
      AND member.left_at IS NULL
      AND (member.account_id <> NEW.created_by OR member.role <> 'owner')
  ) THEN
    RAISE EXCEPTION 'Saved Messages dialog contains an active non-owner membership'
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS dialogs_enforce_saved_owner ON dialogs;
CREATE TRIGGER dialogs_enforce_saved_owner
BEFORE UPDATE OF type, created_by
ON dialogs
FOR EACH ROW EXECUTE FUNCTION toj_enforce_saved_dialog_shape();

-- One transactionally authoritative cleanup path is called by the current application and by the
-- status trigger used by mixed-version nodes. Revocation events, silent pushes, and wakeups are
-- appended before the corrupt membership row is removed.
CREATE OR REPLACE FUNCTION toj_cleanup_saved_messages_for_account(target_account_id UUID)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  revoked RECORD;
  next_pts BIGINT;
BEGIN
  FOR revoked IN
    SELECT dialog.id AS dialog_id, member.account_id
    FROM dialogs dialog
    JOIN dialog_members member ON member.dialog_id = dialog.id
    WHERE dialog.type = 'saved'
      AND dialog.created_by = target_account_id
      AND member.account_id <> target_account_id
      AND member.left_at IS NULL
    ORDER BY dialog.id, member.account_id
    FOR UPDATE OF member
  LOOP
    UPDATE account_sync_states
    SET pts = pts + 1, updated_at = now()
    WHERE account_id = revoked.account_id
    RETURNING pts INTO STRICT next_pts;

    INSERT INTO account_events (
      account_id, pts, type, dialog_id, actor_account_id, data
    ) VALUES (
      revoked.account_id, next_pts, 'dialog.access_revoked', revoked.dialog_id,
      target_account_id, '{"dialog_type":"saved"}'::jsonb
    );

    INSERT INTO push_deliveries (account_id, pts, device_id, alert)
    SELECT revoked.account_id, next_pts, device.id, false
    FROM devices device
    WHERE device.account_id = revoked.account_id
      AND device.platform = 'ios'
      AND device.revoked_at IS NULL
      AND device.push_token_hash IS NOT NULL
      AND device.push_token_ciphertext IS NOT NULL
    ON CONFLICT (account_id, pts, device_id) DO NOTHING;

    PERFORM pg_notify(
      'toj_sync_events',
      json_build_object(
        'accountId', revoked.account_id,
        'pts', next_pts,
        'ptsCount', 1
      )::text
    );

    DELETE FROM dialog_members
    WHERE dialog_id = revoked.dialog_id AND account_id = revoked.account_id;
  END LOOP;

  UPDATE messages AS copy
  SET is_forwarded = TRUE,
      forwarded_from_account_id = NULL,
      forwarded_from_dialog_id = NULL,
      forwarded_from_msg_id = NULL
  FROM dialogs AS source
  WHERE copy.forwarded_from_dialog_id = source.id
    AND copy.forwarded_from_msg_id IS NOT NULL
    AND source.type = 'saved'
    AND source.created_by = target_account_id;

  DELETE FROM dialogs
  WHERE type = 'saved' AND created_by = target_account_id;

  -- media_chunks cascades from media_objects. Any message reference, including a tombstone, keeps
  -- the object alive; forwarded destination rows therefore retain their shared encrypted media.
  DELETE FROM media_objects AS media
  WHERE media.owner_account_id = target_account_id
    AND media.purpose = 'message'
    AND NOT EXISTS (
      SELECT 1 FROM messages message WHERE message.media_id = media.id
    );
END
$$;

DROP TRIGGER IF EXISTS accounts_cleanup_saved_messages ON accounts;
CREATE OR REPLACE FUNCTION toj_cleanup_saved_messages_before_account_delete()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF OLD.status <> 'deleted' AND NEW.status = 'deleted' THEN
    PERFORM toj_cleanup_saved_messages_for_account(OLD.id);
  END IF;
  RETURN NEW;
END
$$;

CREATE TRIGGER accounts_cleanup_saved_messages
BEFORE UPDATE OF status ON accounts
FOR EACH ROW
WHEN (OLD.status IS DISTINCT FROM NEW.status)
EXECUTE FUNCTION toj_cleanup_saved_messages_before_account_delete();
