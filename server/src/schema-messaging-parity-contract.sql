\set ON_ERROR_STOP on

BEGIN;
SET LOCAL lock_timeout = '2s';
SET LOCAL statement_timeout = '30s';

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'messages'::regclass
      AND conname = 'messages_kind_check_v3'
      AND convalidated
  ) THEN
    ALTER TABLE messages DROP CONSTRAINT IF EXISTS messages_kind_check;
    ALTER TABLE messages RENAME CONSTRAINT messages_kind_check_v3 TO messages_kind_check;
  END IF;
  IF EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'messages'::regclass
      AND conname = 'messages_service_type_check_v3'
      AND convalidated
  ) THEN
    ALTER TABLE messages DROP CONSTRAINT IF EXISTS messages_service_type_check;
    ALTER TABLE messages
      RENAME CONSTRAINT messages_service_type_check_v3 TO messages_service_type_check;
  END IF;
  IF EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'account_events'::regclass
      AND conname = 'account_events_type_check_v7'
      AND convalidated
  ) THEN
    ALTER TABLE account_events DROP CONSTRAINT IF EXISTS account_events_type_check;
    ALTER TABLE account_events
      RENAME CONSTRAINT account_events_type_check_v7 TO account_events_type_check;
  END IF;
END;
$$;

DO $$
DECLARE
  message_kind_definition TEXT;
  service_definition TEXT;
  event_definition TEXT;
  binding_constraint_ready BOOLEAN;
  send_fingerprint_constraint_ready BOOLEAN;
BEGIN
  SELECT pg_get_constraintdef(oid, TRUE) INTO message_kind_definition
  FROM pg_constraint
  WHERE conrelid = 'messages'::regclass AND conname = 'messages_kind_check' AND convalidated;
  SELECT pg_get_constraintdef(oid, TRUE) INTO service_definition
  FROM pg_constraint
  WHERE conrelid = 'messages'::regclass AND conname = 'messages_service_type_check' AND convalidated;
  SELECT pg_get_constraintdef(oid, TRUE) INTO event_definition
  FROM pg_constraint
  WHERE conrelid = 'account_events'::regclass AND conname = 'account_events_type_check' AND convalidated;
  SELECT convalidated INTO binding_constraint_ready
  FROM pg_constraint
  WHERE conrelid = 'push_account_bindings'::regclass
    AND conname = 'push_account_bindings_enabled_check';
  SELECT convalidated INTO send_fingerprint_constraint_ready
  FROM pg_constraint
  WHERE conrelid = 'send_requests'::regclass
    AND conname = 'send_requests_fingerprint_size_check';

  IF message_kind_definition IS NULL
     OR position('poll' IN message_kind_definition) = 0
     OR position('sticker' IN message_kind_definition) = 0
     OR position('external_media' IN message_kind_definition) = 0 THEN
    RAISE EXCEPTION 'messaging message-kind contract is incomplete';
  END IF;
  IF service_definition IS NULL
     OR position('message.pinned' IN service_definition) = 0
     OR position('dialog.auto_delete_changed' IN service_definition) = 0
     OR position('poll.closed' IN service_definition) = 0 THEN
    RAISE EXCEPTION 'messaging service-type contract is incomplete';
  END IF;
  IF event_definition IS NULL
     OR position('security.changed' IN event_definition) = 0
     OR position('message.preview_updated' IN event_definition) = 0
     OR position('scheduled.created' IN event_definition) = 0
     OR position('message.expired' IN event_definition) = 0
     OR position('poll.updated' IN event_definition) = 0 THEN
    RAISE EXCEPTION 'combined account-event contract is incomplete';
  END IF;
  IF binding_constraint_ready IS DISTINCT FROM TRUE THEN
    RAISE EXCEPTION 'push binding kind contract is incomplete';
  END IF;
  IF send_fingerprint_constraint_ready IS DISTINCT FROM TRUE THEN
    RAISE EXCEPTION 'send fingerprint contract is incomplete';
  END IF;
END;
$$;

INSERT INTO schema_migrations(name) VALUES ('messages-domain-constraints-v3')
ON CONFLICT (name) DO NOTHING;
INSERT INTO schema_migrations(name) VALUES ('account-events-type-v7')
ON CONFLICT (name) DO NOTHING;
INSERT INTO schema_migrations(name) VALUES ('messaging-parity-contract-v1')
ON CONFLICT (name) DO NOTHING;

COMMIT;
