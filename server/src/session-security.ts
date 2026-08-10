import type { SQL } from "bun";
import { randomBytes } from "node:crypto";
import { Client } from "pg";
import { AuthError } from "./auth-error";
import { hashToken, open, seal, sessionRotationAAD } from "./crypto";

export const ACCESS_TOKEN_TTL_MS = 15 * 60_000;
export const SESSION_IDLE_TTL_MS = 30 * 24 * 60 * 60_000;
export const SESSION_ABSOLUTE_TTL_MS = 180 * 24 * 60 * 60_000;
export const ROTATION_RECEIPT_TTL_MS = 5 * 60_000;
const SESSION_REVOCATION_CHANNEL = "toj_session_revocations";
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export type AuthV2Session = {
  accountId: string;
  deviceId: string;
  accessToken: string;
  accessTokenExpiresAt: string;
  refreshToken: string;
  sessionExpiresAt: string;
  tokenVersion: 2;
};

type DeviceRegistration = {
  accountId: string;
  platform: string;
  deviceName?: string | null;
  existingDeviceId?: string;
  now?: Date;
};

function token(): string {
  return randomBytes(32).toString("base64url");
}

function date(value: unknown): Date {
  return value instanceof Date ? value : new Date(String(value));
}

function responseFromRow(row: any, accessToken: string, refreshToken: string): AuthV2Session {
  return {
    accountId: String(row.account_id),
    deviceId: String(row.device_id),
    accessToken,
    accessTokenExpiresAt: date(row.access_expires_at).toISOString(),
    refreshToken,
    sessionExpiresAt: date(row.absolute_expires_at).toISOString(),
    tokenVersion: 2,
  };
}

/** Issue a v2 device grant. Callers may pass a transaction for atomic login completion. */
export async function issueV2Session(sql: SQL, registration: DeviceRegistration): Promise<AuthV2Session> {
  const now = registration.now ?? new Date();
  const accessToken = token();
  const refreshToken = token();
  const accessExpiresAt = new Date(now.getTime() + ACCESS_TOKEN_TTL_MS);
  const absoluteExpiresAt = new Date(now.getTime() + SESSION_ABSOLUTE_TTL_MS);
  let deviceId = registration.existingDeviceId;
  if (deviceId) {
    const updated = await sql`
      UPDATE devices SET auth_scheme = 'v2', auth_token_hash = ${hashToken(token())}, last_seen_at = ${now}
      WHERE id = ${deviceId} AND account_id = ${registration.accountId} AND revoked_at IS NULL
      RETURNING id`;
    if (!updated.length) throw new AuthError("device is no longer active", 401, undefined, "device_revoked");
  } else {
    const inserted = await sql`
      INSERT INTO devices (account_id, platform, device_name, auth_token_hash, auth_scheme, last_seen_at)
      VALUES (
        ${registration.accountId}, ${registration.platform}, ${registration.deviceName ?? null},
        ${hashToken(token())}, 'v2', ${now}
      ) RETURNING id`;
    deviceId = String(inserted[0].id);
  }

  const session = (await sql`
    INSERT INTO device_sessions (device_id, refresh_token_hash, last_activity_at, absolute_expires_at)
    VALUES (${deviceId}, ${hashToken(refreshToken)}, ${now}, ${absoluteExpiresAt})
    ON CONFLICT (device_id) DO UPDATE SET
      refresh_token_hash = EXCLUDED.refresh_token_hash,
      rotation_generation = device_sessions.rotation_generation + 1,
      last_activity_at = EXCLUDED.last_activity_at,
      absolute_expires_at = EXCLUDED.absolute_expires_at,
      revoked_at = NULL,
      revocation_reason = NULL
    RETURNING id, device_id, absolute_expires_at`)[0];
  await sql`
    INSERT INTO session_access_tokens (token_digest, session_id, expires_at)
    VALUES (${hashToken(accessToken)}, ${session.id}, ${accessExpiresAt})`;
  return responseFromRow({
    account_id: registration.accountId,
    device_id: deviceId,
    access_expires_at: accessExpiresAt,
    absolute_expires_at: session.absolute_expires_at,
  }, accessToken, refreshToken);
}

export async function upgradeLegacySession(
  sql: SQL,
  accountId: string,
  deviceId: string,
): Promise<AuthV2Session> {
  return await sql.begin(async (tx) => issueV2Session(tx, {
    accountId, deviceId, existingDeviceId: deviceId, platform: "ios",
  }));
}

export async function resolveV2Access(
  sql: SQL,
  accessToken: string,
): Promise<{ accountId: string; deviceId: string; accessExpiresAt: Date } | null> {
  const digest = hashToken(accessToken);
  const result = await sql.begin(async (tx) => {
    const row = (await tx`
      SELECT access.expires_at AS access_expires_at,
             session.id AS session_id, session.last_activity_at,
             session.absolute_expires_at, session.revoked_at, session.revocation_reason,
             device.id AS device_id, device.account_id, device.revoked_at AS device_revoked_at,
             account.status AS account_status
      FROM session_access_tokens access
      JOIN device_sessions session ON session.id = access.session_id
      JOIN devices device ON device.id = session.device_id
      JOIN accounts account ON account.id = device.account_id
      WHERE access.token_digest = ${digest}
      FOR UPDATE OF session, device`)[0];
    if (!row) return null;
    const now = new Date();
    if (row.revoked_at || row.device_revoked_at) {
      throw new AuthError(
        "device is no longer active", 401, undefined,
        row.revocation_reason === "refresh_reuse_detected" ? "refresh_reuse_detected" : "device_revoked",
      );
    }
    if (!["active", "limited"].includes(String(row.account_status))) {
      throw new AuthError("account unavailable", 403, undefined, "device_revoked");
    }
    const idleExpired = date(row.last_activity_at).getTime() + SESSION_IDLE_TTL_MS <= now.getTime();
    const absoluteExpired = date(row.absolute_expires_at) <= now;
    if (idleExpired || absoluteExpired) {
      await revokeSessionRows(tx, String(row.session_id), String(row.device_id), "session_expired", now);
      return new AuthError("session expired", 401, undefined, "session_expired");
    }
    if (date(row.access_expires_at) <= now) {
      return new AuthError("access token expired", 401, undefined, "access_token_expired");
    }
    await tx`UPDATE device_sessions SET last_activity_at = ${now} WHERE id = ${row.session_id}`;
    await tx`UPDATE devices SET last_seen_at = ${now} WHERE id = ${row.device_id}`;
    return {
      accountId: String(row.account_id),
      deviceId: String(row.device_id),
      accessExpiresAt: date(row.access_expires_at),
    };
  });
  if (result instanceof AuthError) throw result;
  return result;
}

export async function refreshV2Session(
  sql: SQL,
  refreshToken: string,
  rotationId: string,
): Promise<AuthV2Session> {
  if (!/^[0-9a-f-]{36}$/i.test(rotationId)) {
    throw new AuthError("valid rotationId required", 400, undefined, "invalid_rotation_id");
  }
  const requestDigest = hashToken(refreshToken);
  const outcome = await sql.begin(async (tx) => {
    const current = (await tx`
      SELECT session.*, device.account_id, device.id AS device_id, device.revoked_at AS device_revoked_at
      FROM device_sessions session
      JOIN devices device ON device.id = session.device_id
      WHERE session.refresh_token_hash = ${requestDigest}
      FOR UPDATE OF session, device`)[0];
    if (!current) {
      const used = (await tx`
        SELECT history.session_id
        FROM session_refresh_token_history history
        WHERE history.token_digest = ${requestDigest}`)[0];
      if (!used) return new AuthError("invalid refresh token", 401, undefined, "device_revoked");
      const receipt = (await tx`
        SELECT response_ciphertext, response_nonce, response_key_id
        FROM session_rotation_receipts
        WHERE session_id = ${used.session_id} AND rotation_id = ${rotationId}
          AND request_token_digest = ${requestDigest} AND expires_at > now()`)[0];
      if (receipt) {
        const plaintext = open({
          ciphertext: Buffer.from(receipt.response_ciphertext),
          nonce: Buffer.from(receipt.response_nonce),
          keyId: String(receipt.response_key_id),
        }, sessionRotationAAD(String(used.session_id), rotationId));
        return JSON.parse(plaintext.toString("utf8")) as AuthV2Session;
      }
      const session = (await tx`SELECT device_id FROM device_sessions WHERE id = ${used.session_id} FOR UPDATE`)[0];
      if (session) {
        await revokeSessionRows(
          tx, String(used.session_id), String(session.device_id), "refresh_reuse_detected", new Date(),
        );
      }
      return new AuthError("refresh token reuse detected", 401, undefined, "refresh_reuse_detected");
    }

    const now = new Date();
    if (current.revoked_at || current.device_revoked_at) {
      return new AuthError("device is no longer active", 401, undefined, "device_revoked");
    }
    if (
      date(current.absolute_expires_at) <= now
      || date(current.last_activity_at).getTime() + SESSION_IDLE_TTL_MS <= now.getTime()
    ) {
      await revokeSessionRows(tx, String(current.id), String(current.device_id), "session_expired", now);
      return new AuthError("session expired", 401, undefined, "session_expired");
    }

    const nextAccess = token();
    const nextRefresh = token();
    const accessExpiresAt = new Date(now.getTime() + ACCESS_TOKEN_TTL_MS);
    await tx`
      INSERT INTO session_refresh_token_history (token_digest, session_id)
      VALUES (${requestDigest}, ${current.id})`;
    await tx`
      UPDATE device_sessions SET
        refresh_token_hash = ${hashToken(nextRefresh)},
        rotation_generation = rotation_generation + 1,
        last_activity_at = ${now}
      WHERE id = ${current.id}`;
    await tx`
      INSERT INTO session_access_tokens (token_digest, session_id, expires_at)
      VALUES (${hashToken(nextAccess)}, ${current.id}, ${accessExpiresAt})`;
    const response = responseFromRow({
      account_id: current.account_id,
      device_id: current.device_id,
      access_expires_at: accessExpiresAt,
      absolute_expires_at: current.absolute_expires_at,
    }, nextAccess, nextRefresh);
    const sealed = seal(JSON.stringify(response), sessionRotationAAD(String(current.id), rotationId));
    await tx`
      INSERT INTO session_rotation_receipts
        (session_id, rotation_id, request_token_digest, response_ciphertext,
         response_nonce, response_key_id, expires_at)
      VALUES (
        ${current.id}, ${rotationId}, ${requestDigest}, ${sealed.ciphertext},
        ${sealed.nonce}, ${sealed.keyId}, ${new Date(now.getTime() + ROTATION_RECEIPT_TTL_MS)}
      )`;
    return response;
  });
  if (outcome instanceof AuthError) throw outcome;
  return outcome;
}

export async function revokeV2SessionForDevice(
  sql: SQL,
  accountId: string,
  deviceId: string,
  reason = "device_revoked",
): Promise<void> {
  await sql.begin(async (tx) => {
    const row = (await tx`
      SELECT session.id
      FROM device_sessions session
      JOIN devices device ON device.id = session.device_id
      WHERE device.id = ${deviceId} AND device.account_id = ${accountId}
      FOR UPDATE OF session, device`)[0];
    if (row) await revokeSessionRows(tx, String(row.id), deviceId, reason, new Date());
  });
}

async function revokeSessionRows(
  sql: SQL,
  sessionId: string,
  deviceId: string,
  reason: string,
  now: Date,
): Promise<void> {
  await sql`
    UPDATE device_sessions SET revoked_at = COALESCE(revoked_at, ${now}), revocation_reason = ${reason}
    WHERE id = ${sessionId}`;
  const devices = await sql`
    UPDATE devices SET
      revoked_at = COALESCE(revoked_at, ${now}),
      push_token_hash = NULL, push_token_ciphertext = NULL, push_token_nonce = NULL,
      push_token_key_id = NULL, push_environment = NULL, push_updated_at = ${now},
      voip_push_token_hash = NULL, voip_push_token_ciphertext = NULL,
      voip_push_token_nonce = NULL, voip_push_token_key_id = NULL,
      voip_push_environment = NULL, voip_push_updated_at = ${now}
    WHERE id = ${deviceId}
    RETURNING account_id`;
  if (devices[0]?.account_id) {
    const payload = JSON.stringify({
      accountId: String(devices[0].account_id),
      deviceId,
      reason,
    });
    // PostgreSQL delivers NOTIFY only if this transaction commits, so a remote process can
    // never close a socket for a revocation that later rolls back.
    await sql`SELECT pg_notify(${SESSION_REVOCATION_CHANNEL}, ${payload})`;
  }
}

export type SessionRevocationWakeup = {
  accountId: string;
  deviceId: string;
  reason: string;
};

/** Reconnectable, hint-only listener used to close revoked device sockets across instances. */
export function startSessionRevocationListener(
  databaseUrl: string | null,
  onRevocation: (wakeup: SessionRevocationWakeup) => void | Promise<void>,
): () => void {
  if (!databaseUrl) return () => {};
  let stopped = false;
  let client: Client | null = null;
  let retry: ReturnType<typeof setTimeout> | null = null;
  let attempts = 0;

  const schedule = () => {
    if (stopped || retry) return;
    const delay = Math.min(30_000, 500 * 2 ** Math.min(attempts, 6));
    attempts += 1;
    retry = setTimeout(() => { retry = null; void connect(); }, delay);
    retry.unref?.();
  };
  const connect = async () => {
    if (stopped) return;
    const next = new Client({
      connectionString: databaseUrl,
      application_name: "toj-session-revocation-notify",
    });
    client = next;
    next.on("notification", (notification) => {
      if (notification.channel !== SESSION_REVOCATION_CHANNEL || !notification.payload) return;
      try {
        const wakeup = JSON.parse(notification.payload) as SessionRevocationWakeup;
        if (!UUID_PATTERN.test(wakeup.accountId) || !UUID_PATTERN.test(wakeup.deviceId)) return;
        if (!["device_revoked", "session_expired", "refresh_reuse_detected", "security_change"]
          .includes(wakeup.reason)) return;
        void onRevocation(wakeup);
      } catch { /* notification hints are never authoritative */ }
    });
    let handledDisconnect = false;
    const disconnected = () => {
      if (handledDisconnect) return;
      handledDisconnect = true;
      if (client !== next) return;
      client = null;
      schedule();
    };
    next.once("error", disconnected);
    next.once("end", disconnected);
    try {
      await next.connect();
      await next.query(`LISTEN ${SESSION_REVOCATION_CHANNEL}`);
      attempts = 0;
    } catch {
      try { await next.end(); } catch { /* already closed */ }
      disconnected();
    }
  };
  void connect();
  return () => {
    stopped = true;
    if (retry) clearTimeout(retry);
    retry = null;
    if (client) void client.end().catch(() => {});
    client = null;
  };
}
