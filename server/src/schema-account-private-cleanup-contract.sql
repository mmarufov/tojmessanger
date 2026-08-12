\set ON_ERROR_STOP on

BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '30s';

-- The runner reconciles deleted accounts after installing the trigger. Do not publish the marker
-- unless every account-private row that this contract owns is gone.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.accounts AS account
    WHERE account.status = 'deleted'
      AND (
        EXISTS (
          SELECT 1 FROM public.account_dialog_drafts AS draft
          WHERE draft.account_id = account.id
        )
        OR EXISTS (
          SELECT 1 FROM public.draft_mutation_requests AS request
          WHERE request.account_id = account.id
        )
        OR EXISTS (
          SELECT 1 FROM public.draft_mutation_tombstones AS tombstone
          WHERE tombstone.account_id = account.id
        )
        OR EXISTS (
          SELECT 1 FROM public.draft_mutation_budgets AS budget
          WHERE budget.account_id = account.id
        )
        OR EXISTS (
          SELECT 1 FROM public.media_group_send_requests AS request
          WHERE request.sender_account_id = account.id
        )
        OR EXISTS (
          SELECT 1 FROM public.media_group_send_tombstones AS tombstone
          WHERE tombstone.sender_account_id = account.id
        )
        OR EXISTS (
          SELECT 1 FROM public.media_group_send_budgets AS budget
          WHERE budget.account_id = account.id
        )
        OR EXISTS (
          SELECT 1 FROM public.dialog_preferences AS preference
          WHERE preference.account_id = account.id
        )
        OR EXISTS (
          SELECT 1 FROM public.dialog_preference_requests AS request
          WHERE request.account_id = account.id
        )
        OR EXISTS (
          SELECT 1 FROM public.dialog_preference_action_budgets AS budget
          WHERE budget.account_id = account.id
        )
        OR EXISTS (
          SELECT 1
          FROM public.dialog_preference_legacy_reconciliation AS reconciliation
          WHERE reconciliation.account_id = account.id
        )
        OR EXISTS (
          SELECT 1 FROM public.chat_folders AS folder
          WHERE folder.account_id = account.id
        )
        OR EXISTS (
          SELECT 1 FROM public.chat_folder_mutation_requests AS request
          WHERE request.account_id = account.id
        )
        OR EXISTS (
          SELECT 1 FROM public.chat_folder_action_budgets AS budget
          WHERE budget.account_id = account.id
        )
        OR EXISTS (
          SELECT 1 FROM public.scheduled_deliveries AS delivery
          WHERE delivery.account_id = account.id
        )
        OR EXISTS (
          SELECT 1 FROM public.scheduled_delivery_mutation_requests AS request
          WHERE request.account_id = account.id
        )
        OR EXISTS (
          SELECT 1 FROM public.scheduled_delivery_action_budgets AS budget
          WHERE budget.account_id = account.id
        )
        OR EXISTS (
          SELECT 1 FROM public.link_preview_action_budgets AS budget
          WHERE budget.account_id = account.id
        )
        OR EXISTS (
          SELECT 1 FROM public.account_two_factor AS factor
          WHERE factor.account_id = account.id
        )
        OR EXISTS (
          SELECT 1 FROM public.device_sessions AS session
          JOIN public.devices AS device ON device.id = session.device_id
          WHERE device.account_id = account.id
        )
        OR EXISTS (
          SELECT 1 FROM public.messaging_feature_mutations AS mutation
          WHERE mutation.actor_account_id = account.id
        )
        OR EXISTS (
          SELECT 1 FROM public.poll_votes AS vote
          WHERE vote.voter_account_id = account.id
        )
        OR EXISTS (
          SELECT 1 FROM public.account_sticker_packs AS preference
          WHERE preference.account_id = account.id
        )
        OR EXISTS (
          SELECT 1 FROM public.account_sticker_favorites AS preference
          WHERE preference.account_id = account.id
        )
        OR EXISTS (
          SELECT 1 FROM public.account_sticker_recents AS preference
          WHERE preference.account_id = account.id
        )
        OR EXISTS (
          SELECT 1 FROM public.push_account_bindings AS binding
          WHERE binding.account_id = account.id
        )
        OR EXISTS (
          SELECT 1 FROM public.account_events AS event
          WHERE event.account_id = account.id
            AND event.type IN (
              'draft.updated', 'dialog.preferences_updated', 'chat_folders.updated',
              'scheduled.created', 'scheduled.updated', 'scheduled.canceled', 'scheduled.failed',
              'security.changed', 'sticker_preferences.updated'
            )
        )
        OR EXISTS (
          SELECT 1 FROM public.bootstrap_snapshots AS snapshot
          WHERE snapshot.account_id = account.id
        )
        OR EXISTS (
          SELECT 1
          FROM public.media_objects AS media
          WHERE media.owner_account_id = account.id
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
            )
        )
      )
  ) THEN
    RAISE EXCEPTION
      'account-private cleanup reconciliation is incomplete';
  END IF;
END
$$;

INSERT INTO public.schema_migrations(name)
VALUES ('account-private-cleanup-v1')
ON CONFLICT (name) DO NOTHING;
INSERT INTO public.schema_migrations(name)
VALUES ('account-private-cleanup-v2')
ON CONFLICT (name) DO NOTHING;

COMMIT;
