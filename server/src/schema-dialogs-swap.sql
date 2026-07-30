-- Contract phase: validation already completed. Hold ACCESS EXCLUSIVE only for this short name swap.
BEGIN;
SET LOCAL lock_timeout = '5s';
ALTER TABLE dialogs DROP CONSTRAINT IF EXISTS dialogs_type_check;
DO $$ BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'dialogs'::regclass
      AND conname = 'dialogs_type_check_saved_expand'
  ) THEN
    ALTER TABLE dialogs
      RENAME CONSTRAINT dialogs_type_check_saved_expand TO dialogs_type_check;
  END IF;
END $$;
COMMIT;
