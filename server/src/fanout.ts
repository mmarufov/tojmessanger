import type { SQL } from "bun";

export type FanoutPush = { accountId: string; pts: number; ptsCount: number };

type FanoutOptions = {
  dialogId: string;
  type: string;
  actorAccountId: string;
  sourceDeviceId?: string | null;
  msgId?: number | null;
  data?: Record<string, unknown>;
  alertRecipients?: boolean;
  recipientAccountIds?: string[];
};

const n = (value: unknown) => Number(value as any);

/**
 * Appends an event for any number of recipients with bounded database round trips. Row locks for
 * account_sync_states are acquired in account UUID order before the set-based update.
 */
export async function fanoutDialogEvent(sql: SQL, options: FanoutOptions): Promise<FanoutPush[]> {
  const selected = options.recipientAccountIds
    ? await sql`
        SELECT dm.account_id,
               (dm.notification_mode <> 'muted') AS alert
        FROM dialog_members dm
        WHERE dm.dialog_id = ${options.dialogId}
          AND dm.left_at IS NULL
          AND dm.account_id = ANY(${sql.array(options.recipientAccountIds, "uuid")}::uuid[])
        ORDER BY dm.account_id`
    : await sql`
        SELECT dm.account_id,
               (dm.notification_mode <> 'muted') AS alert
        FROM dialog_members dm
        WHERE dm.dialog_id = ${options.dialogId} AND dm.left_at IS NULL
        ORDER BY dm.account_id`;
  if (selected.length === 0) return [];

  const accountIds = selected.map((row: any) => String(row.account_id));
  const events = await sql`
    WITH locked AS MATERIALIZED (
      SELECT account_id
      FROM account_sync_states
      WHERE account_id = ANY(${sql.array(accountIds, "uuid")}::uuid[])
      ORDER BY account_id
      FOR NO KEY UPDATE
    ), bumped AS (
      UPDATE account_sync_states AS state
      SET pts = state.pts + 1, updated_at = now()
      FROM locked
      WHERE state.account_id = locked.account_id
      RETURNING state.account_id, state.pts
    )
    INSERT INTO account_events (
      account_id, pts, type, dialog_id, msg_id, actor_account_id, data
    )
    SELECT account_id, pts, ${options.type}, ${options.dialogId},
           ${options.msgId ?? null}, ${options.actorAccountId},
           ${JSON.stringify(options.data ?? {})}::jsonb
    FROM bumped
    ORDER BY account_id
    RETURNING account_id, pts`;

  const eventByAccount = new Map(events.map((row: any) => [String(row.account_id), n(row.pts)]));
  const ptsList = accountIds.map((id) => eventByAccount.get(id)!);
  const alerts = selected.map((row: any) =>
    options.alertRecipients === false ? false : Boolean(row.alert)
  );
  const sourceDeviceId = options.sourceDeviceId ?? null;
  await sql`
    INSERT INTO push_deliveries (account_id, pts, device_id, alert)
    SELECT event.account_id, event.pts, device.id,
           (event.alert AND event.account_id <> ${options.actorAccountId})
    FROM unnest(
      ${sql.array(accountIds, "uuid")}::uuid[],
      ${sql.array(ptsList, "int8")}::bigint[],
      ${sql.array(alerts, "bool")}::boolean[]
    ) AS event(account_id, pts, alert)
    JOIN devices device ON device.account_id = event.account_id
    WHERE device.platform = 'ios'
      AND device.revoked_at IS NULL
      AND device.push_token_hash IS NOT NULL
      AND device.push_token_ciphertext IS NOT NULL
      AND (${sourceDeviceId}::uuid IS NULL OR device.id <> ${sourceDeviceId}::uuid)
    ON CONFLICT (account_id, pts, device_id) DO NOTHING`;

  return accountIds.map((accountId) => ({
    accountId,
    pts: eventByAccount.get(accountId)!,
    ptsCount: 1,
  }));
}
