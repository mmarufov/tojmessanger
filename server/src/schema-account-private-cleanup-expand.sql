\set ON_ERROR_STOP on

-- Account rows are privacy-anonymized rather than deleted, so FK cascades are not a lifecycle
-- boundary. Install one database-owned boundary that both current binaries and the existing
-- mixed-version status trigger can call.
BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '30s';

CREATE OR REPLACE FUNCTION public.toj_cleanup_account_private_state_v1(
  target_account_id UUID
)
RETURNS void
LANGUAGE plpgsql
SET search_path = pg_catalog, public, pg_temp
AS $$
BEGIN
  -- Saved cleanup must run first: it emits ordered revocations for any corrupt legacy members,
  -- detaches immutable forwarding provenance, and preserves media still referenced by a forward.
  PERFORM public.toj_cleanup_saved_messages_for_account(target_account_id);

  -- Durable draft/album replay records and rate-limit receipts are account-private. They cannot
  -- rely on ON DELETE CASCADE because the account row remains as a Deleted Account tombstone.
  DELETE FROM public.draft_mutation_budgets
  WHERE account_id = target_account_id;
  DELETE FROM public.draft_mutation_requests
  WHERE account_id = target_account_id;
  DELETE FROM public.draft_mutation_tombstones
  WHERE account_id = target_account_id;
  DELETE FROM public.media_group_send_budgets
  WHERE account_id = target_account_id;
  DELETE FROM public.media_group_send_requests
  WHERE sender_account_id = target_account_id;
  DELETE FROM public.media_group_send_tombstones
  WHERE sender_account_id = target_account_id;
  DELETE FROM public.account_dialog_drafts
  WHERE account_id = target_account_id;

  -- Reconciliation rows can legitimately outlive their canonical preference after a mixed-node
  -- retry. Delete by account rather than joining through dialog_preferences, otherwise that
  -- already-orphaned queue row would survive account deletion.
  DELETE FROM public.dialog_preference_legacy_reconciliation
  WHERE account_id = target_account_id;
  DELETE FROM public.dialog_preferences
  WHERE account_id = target_account_id;
  DELETE FROM public.dialog_preference_requests
  WHERE account_id = target_account_id;
  DELETE FROM public.dialog_preference_action_budgets
  WHERE account_id = target_account_id;

  -- Push rows cascade from these private sync events. Message/group lifecycle history belonging to
  -- peers remains intact; only draft and preference presentation state is removed.
  DELETE FROM public.account_events
  WHERE account_id = target_account_id
    AND type IN ('draft.updated', 'dialog.preferences_updated');
  DELETE FROM public.bootstrap_snapshots
  WHERE account_id = target_account_id;

  -- Remove uploads owned by the deleted account only when no surviving message, dialog photo, or
  -- draft references them. media_chunks cascade from media_objects. This deliberately preserves
  -- shared forwarded media and newer legitimate references owned by another account.
  DELETE FROM public.media_objects AS media
  WHERE media.owner_account_id = target_account_id
    AND NOT EXISTS (
      SELECT 1 FROM public.messages AS message
      WHERE message.media_id = media.id
    )
    AND NOT EXISTS (
      SELECT 1 FROM public.dialogs AS dialog
      WHERE dialog.photo_media_id = media.id
    )
    AND NOT EXISTS (
      SELECT 1 FROM public.draft_attachments AS attachment
      WHERE attachment.media_id = media.id
    );
END
$$;

CREATE OR REPLACE FUNCTION public.toj_cleanup_saved_messages_before_account_delete()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public, pg_temp
AS $$
BEGIN
  IF OLD.status <> 'deleted' AND NEW.status = 'deleted' THEN
    PERFORM public.toj_cleanup_account_private_state_v1(OLD.id);
  END IF;
  RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS accounts_cleanup_saved_messages ON public.accounts;
CREATE TRIGGER accounts_cleanup_saved_messages
BEFORE UPDATE OF status ON public.accounts
FOR EACH ROW
WHEN (OLD.status IS DISTINCT FROM NEW.status)
EXECUTE FUNCTION public.toj_cleanup_saved_messages_before_account_delete();

COMMIT;
