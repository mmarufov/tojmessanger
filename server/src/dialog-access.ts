import type { SQL } from "bun";

export class DialogAccessError extends Error {
  constructor(
    message: string,
    readonly code: string,
    readonly status = 403,
  ) {
    super(message);
    this.name = "DialogAccessError";
  }
}

export type DialogAccess = {
  dialogId: string;
  type: "direct" | "group" | "saved";
  revision: number;
  lastMsgId: number;
  closed: boolean;
  role: "owner" | "admin" | "member";
  notificationMode: "all" | "muted";
};

const n = (value: unknown) => Number(value as any);

function accessFromRow(row: any): DialogAccess {
  return {
    dialogId: row.id,
    type: row.type,
    revision: n(row.revision),
    lastMsgId: n(row.last_msg_id),
    closed: row.closed_at != null,
    role: row.role,
    notificationMode: row.notification_mode,
  };
}

function missingAccess(row: any, hadMembership: boolean): never {
  if (hadMembership && row?.type === "group") {
    throw new DialogAccessError("group access revoked", "group_access_revoked", 410);
  }
  throw new DialogAccessError("not a member of this dialog", "not_group_member", 403);
}

/** Read-side authorization deliberately takes no dialog lock. */
export async function requireDialogReadAccess(
  sql: SQL,
  accountId: string,
  dialogId: string,
): Promise<DialogAccess> {
  const row = (await sql`
    SELECT d.id, d.type, d.revision, d.last_msg_id, d.closed_at,
           dm.role, dm.notification_mode, dm.left_at
    FROM dialogs d
    LEFT JOIN dialog_members dm
      ON dm.dialog_id = d.id AND dm.account_id = ${accountId}
    WHERE d.id = ${dialogId}`)[0];
  if (!row) throw new DialogAccessError("dialog not found", "group_not_found", 404);
  if (row.left_at != null || row.role == null || row.closed_at != null) {
    return missingAccess(row, row.role != null);
  }
  return accessFromRow(row);
}

/**
 * The dialog row is the membership/message linearization point. Callers must acquire media locks,
 * if any, before this helper to preserve the global order.
 */
export async function lockDialogForMutation(
  sql: SQL,
  accountId: string,
  dialogId: string,
): Promise<DialogAccess> {
  const dialog = (await sql`
    SELECT id, type, revision, last_msg_id, closed_at
    FROM dialogs WHERE id = ${dialogId}
    FOR UPDATE`)[0];
  if (!dialog) throw new DialogAccessError("dialog not found", "group_not_found", 404);
  const member = (await sql`
    SELECT role, notification_mode, left_at
    FROM dialog_members
    WHERE dialog_id = ${dialogId} AND account_id = ${accountId}
    FOR UPDATE`)[0];
  if (!member || member.left_at != null || dialog.closed_at != null) {
    return missingAccess(dialog, member != null);
  }
  return accessFromRow({ ...dialog, ...member });
}

export function requireGroupRole(
  access: DialogAccess,
  allowed: Array<DialogAccess["role"]>,
): void {
  if (access.type !== "group") {
    throw new DialogAccessError("group not found", "group_not_found", 404);
  }
  if (!allowed.includes(access.role)) {
    throw new DialogAccessError("insufficient group role", "insufficient_group_role", 403);
  }
}
