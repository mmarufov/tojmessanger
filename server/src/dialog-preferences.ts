import { createHash } from "node:crypto";
import type { SQL } from "bun";
import { requireActiveDevice } from "./auth";
import { lockDialogForMutation } from "./dialog-access";
import { lockAccountMutations } from "./locks";
import { notifySyncWakeups, type Push } from "./sync";

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

const n = (value: unknown) => Number(value as any);
const iso = (value: unknown): string | null => {
  if (value == null) return null;
  return value instanceof Date ? value.toISOString() : String(value);
};

export class DialogPreferenceError extends Error {
  constructor(
    message: string,
    readonly code: string,
    readonly status = 400,
    readonly retryAfter?: number,
  ) {
    super(message);
    this.name = "DialogPreferenceError";
  }
}

export function dialogPreferencesEntrypointEnabled(): boolean {
  return process.env.TOJ_DIALOG_PREFERENCES_V1_ENABLED === "1";
}

export function dialogPreferencesServerBehaviorEnabled(): boolean {
  return process.env.TOJ_DIALOG_PREFERENCES_BEHAVIOR_ENABLED !== "0";
}

export function dialogPreferencesCapabilityEnabled(): boolean {
  return dialogPreferencesEntrypointEnabled() && dialogPreferencesServerBehaviorEnabled();
}

export type DialogPreferencesDTO = {
  dialogId: string;
  pinned: boolean;
  pinnedAt: string | null;
  muted: boolean;
  archived: boolean;
  updatedAt: string;
};

export type DialogPreferencePatch = {
  pinned?: boolean;
  muted?: boolean;
  archived?: boolean;
};

export type DialogPreferenceResult = {
  preferences: DialogPreferencesDTO;
  changedFields: Array<keyof DialogPreferencePatch>;
  pts: number;
  duplicate: boolean;
  pushes: Push[];
};

function requireUUID(value: unknown, field: string): string {
  const result = String(value ?? "").toLowerCase();
  if (!UUID_PATTERN.test(result)) {
    throw new DialogPreferenceError(`${field} must be a UUID`, "invalid_request");
  }
  return result;
}

function normalizedPatch(value: unknown): DialogPreferencePatch {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new DialogPreferenceError("preference patch required", "invalid_request");
  }
  const input = value as Record<string, unknown>;
  const allowedFields = new Set(["clientMutationId", "pinned", "muted", "archived"]);
  const unknownField = Object.keys(input).find((field) => !allowedFields.has(field));
  if (unknownField) {
    throw new DialogPreferenceError(
      "unknown preference field",
      "invalid_request",
    );
  }
  const result: DialogPreferencePatch = {};
  for (const field of ["pinned", "muted", "archived"] as const) {
    if (!Object.prototype.hasOwnProperty.call(input, field)) continue;
    if (typeof input[field] !== "boolean") {
      throw new DialogPreferenceError(`${field} must be a boolean`, "invalid_request");
    }
    result[field] = input[field];
  }
  if (Object.keys(result).length === 0) {
    throw new DialogPreferenceError(
      "at least one preference field is required",
      "invalid_request",
    );
  }
  return result;
}

function dto(row: any): DialogPreferencesDTO {
  return {
    dialogId: String(row.dialog_id),
    pinned: Boolean(row.is_pinned),
    pinnedAt: iso(row.pinned_at),
    muted: Boolean(row.is_muted),
    archived: Boolean(row.is_archived),
    updatedAt: iso(row.updated_at)!,
  };
}

function storedDTO(value: unknown): DialogPreferencesDTO {
  if (typeof value === "string") return JSON.parse(value) as DialogPreferencesDTO;
  return value as DialogPreferencesDTO;
}

function sameBuffer(left: unknown, right: Buffer): boolean {
  return Buffer.from(left as Uint8Array).equals(right);
}

export async function updateDialogPreferences(
  sql: SQL,
  input: {
    accountId: string;
    deviceId: string;
    dialogId: unknown;
    clientMutationId: unknown;
    patch: unknown;
  },
): Promise<DialogPreferenceResult> {
  const dialogId = requireUUID(input.dialogId, "dialogId");
  const mutationId = requireUUID(input.clientMutationId, "clientMutationId");
  const patch = normalizedPatch(input.patch);
  const patchFields = Object.keys(patch).sort() as Array<keyof DialogPreferencePatch>;
  const fingerprint = createHash("sha256")
    .update(JSON.stringify([dialogId, patchFields.map((field) => [field, patch[field]])]))
    .digest();

  return sql.begin(async (tx) => {
    const inserted = await tx`
      INSERT INTO dialog_preference_requests (
        account_id, client_mutation_id, dialog_id, fingerprint, status
      ) VALUES (
        ${input.accountId}, ${mutationId}, ${dialogId}, ${fingerprint}, 'pending'
      )
      ON CONFLICT (account_id, client_mutation_id) DO NOTHING
      RETURNING client_mutation_id`;
    if (inserted.length === 0) {
      const existing = (await tx`
        SELECT dialog_id, fingerprint, status, result_pts, result_json
        FROM dialog_preference_requests
        WHERE account_id = ${input.accountId} AND client_mutation_id = ${mutationId}
        FOR UPDATE`)[0];
      if (
        !existing
        || String(existing.dialog_id) !== dialogId
        || !sameBuffer(existing.fingerprint, fingerprint)
      ) {
        throw new DialogPreferenceError(
          "mutation id was reused with different details",
          "idempotency_conflict",
          409,
        );
      }
      if (existing.status !== "completed" || existing.result_json == null) {
        throw new DialogPreferenceError(
          "preference mutation is already in progress",
          "mutation_in_progress",
          409,
        );
      }
      return {
        preferences: storedDTO(existing.result_json),
        changedFields: patchFields,
        pts: n(existing.result_pts),
        duplicate: true,
        pushes: [],
      };
    }

    await lockAccountMutations(tx, [input.accountId]);
    await requireActiveDevice(tx, input.accountId, input.deviceId);
    const access = await lockDialogForMutation(tx, input.accountId, dialogId);

    const budget = await tx`
      INSERT INTO dialog_preference_action_budgets (
        account_id, bucket_started, mutation_count
      )
      VALUES (
        ${input.accountId}, date_trunc('hour', now()), 1
      )
      ON CONFLICT (account_id, bucket_started) DO UPDATE SET
        mutation_count = dialog_preference_action_budgets.mutation_count + 1,
        updated_at = now()
      WHERE dialog_preference_action_budgets.mutation_count < 240
      RETURNING mutation_count`;
    if (budget.length === 0) {
      throw new DialogPreferenceError(
        "dialog preference rate limit reached",
        "rate_limited",
        429,
        3600,
      );
    }
    await tx`
      INSERT INTO dialog_preferences (
        dialog_id, account_id, is_muted
      ) VALUES (
        ${dialogId}, ${input.accountId}, ${access.notificationMode === "muted"}
      )
      ON CONFLICT (dialog_id, account_id) DO NOTHING`;

    const before = (await tx`
      SELECT dialog_id, account_id, is_pinned, pinned_at, is_muted, is_archived, updated_at
      FROM dialog_preferences
      WHERE dialog_id = ${dialogId} AND account_id = ${input.accountId}
      FOR UPDATE`)[0];
    const changedFields = patchFields.filter((field) => {
      const column = field === "pinned"
        ? "is_pinned"
        : field === "muted" ? "is_muted" : "is_archived";
      return Boolean(before[column]) !== patch[field];
    });
    const hasPinned = patch.pinned !== undefined;
    const hasMuted = patch.muted !== undefined;
    const hasArchived = patch.archived !== undefined;
    if (changedFields.length === 0) {
      const preferences = dto(before);
      const currentPts = n((await tx`
        SELECT pts
        FROM account_sync_states
        WHERE account_id = ${input.accountId}`)[0]?.pts);
      await tx`
        UPDATE dialog_preference_requests
        SET status = 'completed',
            result_pts = ${currentPts},
            result_json = ${JSON.stringify(preferences)}::text::jsonb
        WHERE account_id = ${input.accountId} AND client_mutation_id = ${mutationId}`;
      return {
        preferences,
        changedFields: [],
        pts: currentPts,
        duplicate: false,
        pushes: [],
      };
    }

    const preferenceRow = (await tx`
      UPDATE dialog_preferences
      SET
        pinned_at = CASE
          WHEN NOT ${hasPinned}::boolean THEN pinned_at
          WHEN NOT ${patch.pinned ?? false}::boolean THEN NULL
          WHEN is_pinned THEN pinned_at
          ELSE GREATEST(
            statement_timestamp(),
            COALESCE(
              (
                SELECT MAX(existing.pinned_at) + interval '1 millisecond'
                FROM dialog_preferences existing
                WHERE existing.account_id = ${input.accountId}
                  AND existing.is_pinned = TRUE
              ),
              statement_timestamp()
            )
          )
        END,
        is_pinned = CASE
          WHEN ${hasPinned}::boolean THEN ${patch.pinned ?? false}::boolean
          ELSE is_pinned
        END,
        is_muted = CASE
          WHEN ${hasMuted}::boolean THEN ${patch.muted ?? false}::boolean
          ELSE is_muted
        END,
        is_archived = CASE
          WHEN ${hasArchived}::boolean THEN ${patch.archived ?? false}::boolean
          ELSE is_archived
        END,
        updated_at = statement_timestamp()
      WHERE dialog_id = ${dialogId} AND account_id = ${input.accountId}
      RETURNING dialog_id, account_id, is_pinned, pinned_at, is_muted, is_archived, updated_at`)[0];

    if (hasMuted) {
      await tx`
        UPDATE dialog_members
        SET notification_mode = ${patch.muted ? "muted" : "all"}
        WHERE dialog_id = ${dialogId} AND account_id = ${input.accountId}`;
    }

    const preferences = dto(preferenceRow);
    const state = (await tx`
      UPDATE account_sync_states
      SET pts = pts + 1, updated_at = now()
      WHERE account_id = ${input.accountId}
      RETURNING pts`)[0];
    if (!state) {
      throw new DialogPreferenceError("unknown account", "account_unavailable", 404);
    }
    const pts = n(state.pts);
    const eventData = {
      preferences,
      changed_fields: changedFields,
      client_mutation_id: mutationId,
    };
    await tx`
      INSERT INTO account_events (
        account_id, pts, type, dialog_id, actor_account_id, data
      ) VALUES (
        ${input.accountId}, ${pts}, 'dialog.preferences_updated',
        ${dialogId}, ${input.accountId}, ${JSON.stringify(eventData)}::text::jsonb
      )`;
    await tx`
      INSERT INTO push_deliveries (account_id, pts, device_id, alert)
      SELECT ${input.accountId}, ${pts}, device.id, FALSE
      FROM devices device
      WHERE device.account_id = ${input.accountId}
        AND device.id <> ${input.deviceId}
        AND device.platform = 'ios'
        AND device.revoked_at IS NULL
        AND device.push_token_hash IS NOT NULL
        AND device.push_token_ciphertext IS NOT NULL
      ON CONFLICT (account_id, pts, device_id) DO NOTHING`;
    await tx`
      UPDATE dialog_preference_requests
      SET status = 'completed',
          result_pts = ${pts},
          result_json = ${JSON.stringify(preferences)}::text::jsonb
      WHERE account_id = ${input.accountId} AND client_mutation_id = ${mutationId}`;

    const pushes = [{ accountId: input.accountId, pts, ptsCount: 1 }];
    await notifySyncWakeups(tx, pushes);
    return { preferences, changedFields, pts, duplicate: false, pushes };
  });
}
