-- Expand phase: each ADD takes only a short metadata lock and does not scan the dialogs table.
SET lock_timeout = '5s';

DO $$ BEGIN
  ALTER TABLE dialogs ADD CONSTRAINT dialogs_type_check_saved_expand
    CHECK (type IN ('direct','group','saved')) NOT VALID;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  ALTER TABLE dialogs ADD CONSTRAINT dialogs_saved_owner_check
    CHECK (type <> 'saved' OR created_by IS NOT NULL) NOT VALID;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
