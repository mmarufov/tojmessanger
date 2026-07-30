-- Run only while messages_is_forwarded_v1 is incomplete. Normal migration reruns skip this file,
-- so a completed deployment never rebuilds/scans messages for a temporary index.
CREATE INDEX CONCURRENTLY IF NOT EXISTS messages_forward_marker_backfill_idx
  ON messages(dialog_id, msg_id)
  WHERE is_forwarded IS NOT TRUE
    AND forwarded_from_dialog_id IS NOT NULL
    AND forwarded_from_msg_id IS NOT NULL;
