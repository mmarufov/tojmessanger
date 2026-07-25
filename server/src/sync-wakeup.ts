import type { SQL } from "bun";

export type SyncPush = {
  accountId: string;
  pts: number;
  ptsCount: number;
};

export const SYNC_NOTIFY_CHANNEL = "toj_sync_events";

/**
 * PostgreSQL delivers notifications only when the surrounding transaction commits. Keeping this
 * beside the account-event write prevents a successful mutation from returning before its
 * cross-process wake-up is durable.
 */
export async function notifySyncWakeups(sql: SQL, pushes: SyncPush[]): Promise<void> {
  for (const push of pushes) {
    const payload = JSON.stringify(push);
    await sql`SELECT pg_notify(${SYNC_NOTIFY_CHANNEL}, ${payload})`;
  }
}

export function isSyncWakeupChannel(channel: string): boolean {
  return channel === SYNC_NOTIFY_CHANNEL;
}
