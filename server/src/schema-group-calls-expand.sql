-- Expand the device capability contract outside schema.sql's large transaction. Each ALTER is a
-- separate autocommit statement, so a lock timeout rolls back only that column addition and a busy
-- production devices table never holds ACCESS EXCLUSIVE until the rest of the schema completes.
SET lock_timeout = '5s';

ALTER TABLE IF EXISTS public.devices
  ADD COLUMN IF NOT EXISTS supported_group_call_versions INT[] NOT NULL DEFAULT ARRAY[]::INT[];
ALTER TABLE IF EXISTS public.devices
  ADD COLUMN IF NOT EXISTS group_call_view_version INT NOT NULL DEFAULT 0;
ALTER TABLE IF EXISTS public.devices
  ADD COLUMN IF NOT EXISTS supports_group_screen_share BOOLEAN NOT NULL DEFAULT FALSE;

-- The SFU state table exists only when upgrading an earlier group-call preview. Fresh databases
-- create the final shape in schema.sql after this expand phase.
ALTER TABLE IF EXISTS public.group_call_sfu_participant_states
  ADD COLUMN IF NOT EXISTS media_allowed BOOLEAN;
ALTER TABLE IF EXISTS public.group_call_sfu_participant_states
  ADD COLUMN IF NOT EXISTS applied_status TEXT;
ALTER TABLE IF EXISTS public.group_call_sfu_participant_states
  ADD COLUMN IF NOT EXISTS applied_media_allowed BOOLEAN;
ALTER TABLE IF EXISTS public.group_call_sfu_participant_states
  ADD COLUMN IF NOT EXISTS applied_camera_allowed BOOLEAN;
ALTER TABLE IF EXISTS public.group_call_sfu_participant_states
  ADD COLUMN IF NOT EXISTS applied_screen_share_allowed BOOLEAN;
ALTER TABLE IF EXISTS public.group_call_sfu_participant_states
  ADD COLUMN IF NOT EXISTS token_not_before BIGINT NOT NULL DEFAULT 0;
