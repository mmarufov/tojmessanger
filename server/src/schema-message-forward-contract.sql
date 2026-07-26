-- Contract only after the bounded keyset worker reports no remaining legacy markers.
SET lock_timeout = '5s';

ALTER TABLE messages VALIDATE CONSTRAINT messages_forward_marker_check;

DO $$
BEGIN
  -- Branch on the durable completion marker before referencing messages. This is intentionally
  -- procedural: a non-correlated NOT EXISTS subquery may be initialized even when a completed
  -- progress row would make an UPDATE a no-op, causing normal migration reruns to scan messages.
  IF EXISTS (
    SELECT 1 FROM schema_migration_progress
    WHERE migration_name = 'messages_is_forwarded_v1' AND completed_at IS NOT NULL
  ) THEN
    RETURN;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM messages
    WHERE is_forwarded IS NOT TRUE
      AND forwarded_from_dialog_id IS NOT NULL
      AND forwarded_from_msg_id IS NOT NULL
    LIMIT 1
  ) THEN
    RAISE EXCEPTION 'messages_is_forwarded_v1 backfill is incomplete';
  END IF;

  UPDATE schema_migration_progress
  SET completed_at = now(), updated_at = now()
  WHERE migration_name = 'messages_is_forwarded_v1';
END
$$;

-- The partial backfill index is empty at this point. Permanent provenance/reply indexes remain.
DROP INDEX CONCURRENTLY IF EXISTS messages_forward_marker_backfill_idx;
