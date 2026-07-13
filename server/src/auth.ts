import type { SQL } from "bun";
import { randomBytes, randomInt } from "node:crypto";
import {
  seal, open, PHONE_AAD, phoneLookupHash, codeHash, hashToken, normalizePhone, constantTimeEqual,
} from "./crypto";

const OTP_TTL_MS = 5 * 60_000;
const OTP_RESEND_COOLDOWN_SECONDS = 30;
const OTP_PHONE_WINDOW_LIMIT = 5;
const OTP_NETWORK_WINDOW_LIMIT = 20;
const OTP_WINDOW_MINUTES = 15;
const OTP_MAX_ATTEMPTS = 5;
const CONTACT_LOOKUP_WINDOW_MINUTES = 15;
const CONTACT_LOOKUP_WINDOW_LIMIT = 20;
const CONTACT_LOOKUP_DAILY_LIMIT = 100;
const ALLOWED_PLATFORMS = new Set(["ios", "android", "web", "desktop"]);
type OTPPurpose = "login" | "account_deletion";

export class AuthError extends Error {
  constructor(message: string, readonly status = 401, readonly retryAfter?: number) {
    super(message);
  }
}

export interface OTPDelivery {
  send(phone: string, code: string, purpose: OTPPurpose): Promise<void>;
}

class WebhookOTPDelivery implements OTPDelivery {
  constructor(private readonly url: URL, private readonly bearerToken: string) {}

  async send(phone: string, code: string, purpose: OTPPurpose): Promise<void> {
    const response = await fetch(this.url, {
      method: "POST",
      headers: {
        "authorization": `Bearer ${this.bearerToken}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({ phone, code, purpose, service: "Toj" }),
      signal: AbortSignal.timeout(10_000),
    });
    if (!response.ok) throw new Error(`SMS delivery returned HTTP ${response.status}`);
  }
}

export function otpDeliveryFromEnvironment(): OTPDelivery | null {
  const rawUrl = process.env.TOJ_SMS_WEBHOOK_URL;
  const token = process.env.TOJ_SMS_WEBHOOK_TOKEN;
  if (!rawUrl && !token) return null;
  if (!rawUrl || !token) {
    throw new Error("TOJ_SMS_WEBHOOK_URL and TOJ_SMS_WEBHOOK_TOKEN must be set together");
  }
  const url = new URL(rawUrl);
  if (process.env.NODE_ENV === "production" && url.protocol !== "https:") {
    throw new Error("TOJ_SMS_WEBHOOK_URL must use HTTPS in production");
  }
  return new WebhookOTPDelivery(url, token);
}

type StartVerificationOptions = {
  networkKey?: string | null;
  delivery?: OTPDelivery | null;
  purpose?: OTPPurpose;
};

function privateBetaOTPAllowed(normalizedPhone: string): boolean {
  if (process.env.TOJ_RETURN_OTP !== "1") return false;
  if (process.env.NODE_ENV !== "production") return true;
  return (process.env.TOJ_DEV_OTP_ALLOWLIST ?? "")
    .split(",")
    .map((value) => value.trim())
    .filter((value) => /^\+[1-9]\d{7,14}$/.test(value))
    .includes(normalizedPhone);
}

/** Used only for provider-readiness reporting; it never exposes the allowlisted values. */
export function privateBetaOTPConfigured(): boolean {
  if (process.env.TOJ_RETURN_OTP !== "1") return false;
  if (process.env.NODE_ENV !== "production") return true;
  return (process.env.TOJ_DEV_OTP_ALLOWLIST ?? "")
    .split(",")
    .some((value) => /^\+[1-9]\d{7,14}$/.test(value.trim()));
}

function validPhone(phone: string): string {
  if (/[A-Za-z]/.test(phone)) {
    throw new AuthError("enter a valid international phone number", 400);
  }
  const normalized = normalizePhone(phone.trim());
  if (!/^\+[1-9]\d{7,14}$/.test(normalized)) {
    throw new AuthError("enter a valid international phone number", 400);
  }
  return normalized;
}

function cleanLabel(value: string | undefined, maxLength: number): string | null {
  const trimmed = value?.trim() ?? "";
  if (!trimmed) return null;
  return trimmed.slice(0, maxLength);
}

/** Issues a short-lived OTP. Production returns codes only for explicitly allowlisted beta phones. */
export async function startVerification(
  sql: SQL,
  phone: string,
  options: StartVerificationOptions = {},
): Promise<{ code?: string; retryAfter?: number }> {
  const normalizedPhone = validPhone(phone);
  const purpose = options.purpose ?? "login";
  const lookup = phoneLookupHash(normalizedPhone);
  const networkHash = options.networkKey ? hashToken(`otp-network|${options.networkKey}`) : null;
  const production = process.env.NODE_ENV === "production";
  const returnOTP = !production || privateBetaOTPAllowed(normalizedPhone);
  const delivery = options.delivery ?? null;
  if (production && !delivery && !returnOTP) {
    throw new AuthError("verification service temporarily unavailable", 503);
  }

  const code = randomInt(0, 1_000_000).toString().padStart(6, "0");
  const salt = randomBytes(16);
  const expires = new Date(Date.now() + OTP_TTL_MS);
  const phoneLock = lookup.readBigInt64BE(0);
  const networkLock = networkHash?.readBigInt64BE(0);

  const challengeId: string = await sql.begin(async (tx) => {
    const locks = [phoneLock, networkLock].filter((value): value is bigint => value !== undefined)
      .sort((a, b) => a < b ? -1 : a > b ? 1 : 0);
    for (const lock of locks) await tx`SELECT pg_advisory_xact_lock(${lock})`;

    const latest = (await tx`
      SELECT created_at FROM otp_challenges
      WHERE phone_lookup_hash = ${lookup} AND purpose = ${purpose}
      ORDER BY created_at DESC LIMIT 1`)[0];
    if (latest) {
      const ageSeconds = Math.floor((Date.now() - new Date(latest.created_at).getTime()) / 1000);
      if (ageSeconds < OTP_RESEND_COOLDOWN_SECONDS) {
        throw new AuthError(
          "please wait before requesting another code",
          429,
          OTP_RESEND_COOLDOWN_SECONDS - ageSeconds,
        );
      }
    }

    const phoneCount = Number((await tx`
      SELECT count(*) AS count FROM otp_challenges
      WHERE phone_lookup_hash = ${lookup}
        AND created_at > now() - (${OTP_WINDOW_MINUTES} * interval '1 minute')`)[0].count);
    if (phoneCount >= OTP_PHONE_WINDOW_LIMIT) {
      throw new AuthError("too many verification requests; try again later", 429, OTP_WINDOW_MINUTES * 60);
    }

    if (networkHash) {
      const networkCount = Number((await tx`
        SELECT count(*) AS count FROM otp_challenges
        WHERE network_hash = ${networkHash}
          AND created_at > now() - (${OTP_WINDOW_MINUTES} * interval '1 minute')`)[0].count);
      if (networkCount >= OTP_NETWORK_WINDOW_LIMIT) {
        throw new AuthError("too many verification requests; try again later", 429, OTP_WINDOW_MINUTES * 60);
      }
    }

    await tx`
      UPDATE otp_challenges SET consumed_at = now()
      WHERE phone_lookup_hash = ${lookup} AND consumed_at IS NULL`;
    return (await tx`
      INSERT INTO otp_challenges
        (phone_lookup_hash, code_hash, code_salt, network_hash, purpose, expires_at)
      VALUES (${lookup}, ${codeHash(code, salt)}, ${salt}, ${networkHash}, ${purpose}, ${expires})
      RETURNING id`)[0].id;
  });

  if (delivery) {
    try {
      await delivery.send(normalizedPhone, code, purpose);
    } catch (error) {
      await sql`UPDATE otp_challenges SET consumed_at = now() WHERE id = ${challengeId}`;
      console.error(new Date().toISOString(), "auth.otp.delivery_failed",
        error instanceof Error ? error.message.replace(/[\r\n]+/g, " ").slice(0, 200) : "unknown error");
      throw new AuthError("verification service temporarily unavailable", 503);
    }
  }

  return production && !returnOTP ? {} : { code, retryAfter: OTP_RESEND_COOLDOWN_SECONDS };
}

export type Session = { accountId: string; deviceId: string; token: string };

export async function checkVerification(
  sql: SQL, phone: string, code: string, platform = "ios", deviceName?: string, displayName?: string,
): Promise<Session> {
  const normalizedPhone = validPhone(phone);
  if (!/^\d{6}$/.test(code)) throw new AuthError("enter the 6-digit code", 400);
  if (!ALLOWED_PLATFORMS.has(platform)) throw new AuthError("unsupported device platform", 400);
  const lookup = phoneLookupHash(normalizedPhone);
  const token = randomBytes(32).toString("base64url");

  const result: Session | AuthError = await sql.begin(async (tx) => {
    const rows = await tx`
      SELECT id, code_hash, code_salt, attempts FROM otp_challenges
      WHERE phone_lookup_hash = ${lookup} AND purpose = 'login'
        AND consumed_at IS NULL AND expires_at > now()
      ORDER BY created_at DESC LIMIT 1
      FOR UPDATE`;
    if (rows.length === 0) throw new AuthError("no active verification code");
    const challenge = rows[0];
    if (challenge.attempts >= OTP_MAX_ATTEMPTS) throw new AuthError("too many attempts; request a new code", 429);
    const expected = codeHash(code, challenge.code_salt ? Buffer.from(challenge.code_salt) : undefined);
    if (!constantTimeEqual(Buffer.from(challenge.code_hash), expected)) {
      await tx`UPDATE otp_challenges SET attempts = attempts + 1 WHERE id = ${challenge.id}`;
      return new AuthError("incorrect code");
    }
    const claimed = await tx`
      UPDATE otp_challenges SET consumed_at = now()
      WHERE id = ${challenge.id} AND consumed_at IS NULL
      RETURNING id`;
    if (claimed.length === 0) throw new AuthError("verification code already used");

    const sealed = seal(normalizedPhone, PHONE_AAD);
    const name = cleanLabel(displayName, 80) ?? "";
    const created = await tx`
      INSERT INTO accounts (phone_lookup_hash, phone_e164_ciphertext, phone_nonce, phone_key_id, display_name)
      VALUES (${lookup}, ${sealed.ciphertext}, ${sealed.nonce}, ${sealed.keyId}, ${name})
      ON CONFLICT (phone_lookup_hash) DO NOTHING
      RETURNING id`;
    let accountId: string;
    if (created.length) {
      accountId = created[0].id;
      await tx`INSERT INTO account_sync_states (account_id) VALUES (${accountId}) ON CONFLICT DO NOTHING`;
    } else {
      const existing = (await tx`
        SELECT id, status FROM accounts WHERE phone_lookup_hash = ${lookup}
        FOR UPDATE`)[0];
      if (!existing || existing.status === "banned" || existing.status === "deleted") {
        return new AuthError("account unavailable", 403);
      }
      accountId = existing.id;
      if (name) await tx`UPDATE accounts SET display_name = ${name}, updated_at = now() WHERE id = ${accountId}`;
    }

    const device = await tx`
      INSERT INTO devices (account_id, platform, device_name, auth_token_hash, last_seen_at)
      VALUES (${accountId}, ${platform}, ${cleanLabel(deviceName, 120)}, ${hashToken(token)}, now())
      RETURNING id`;
    return { accountId, deviceId: device[0].id, token };
  });
  if (result instanceof AuthError) throw result;
  return result;
}

/** Contact discovery: resolve a phone number to an account so the client can open a direct dialog. */
export async function lookupAccountByPhone(
  sql: SQL, requesterAccountId: string, phone: string,
): Promise<{ accountId: string; displayName: string } | null> {
  const normalizedPhone = validPhone(phone);
  const targetHash = phoneLookupHash(normalizedPhone);
  return await sql.begin(async (tx) => {
    await tx`SELECT pg_advisory_xact_lock(hashtextextended(${`contact-lookup:${requesterAccountId}`}, 0))`;
    const requester = await tx`
      SELECT id FROM accounts WHERE id = ${requesterAccountId} AND status IN ('active','limited')`;
    if (!requester.length) throw new AuthError("account unavailable", 403);

    // Network retries and reopening the same contact do not burn more discovery budget.
    const repeated = await tx`
      SELECT 1 FROM contact_lookup_attempts
      WHERE requester_account_id = ${requesterAccountId} AND target_phone_hash = ${targetHash}
        AND created_at > now() - (${CONTACT_LOOKUP_WINDOW_MINUTES} * interval '1 minute')
      LIMIT 1`;
    if (!repeated.length) {
      const counts = (await tx`
        SELECT
          count(*) FILTER (WHERE created_at > now() - (${CONTACT_LOOKUP_WINDOW_MINUTES} * interval '1 minute')) AS recent,
          count(*) FILTER (WHERE created_at > now() - interval '24 hours') AS daily
        FROM contact_lookup_attempts WHERE requester_account_id = ${requesterAccountId}`)[0];
      if (Number(counts.recent) >= CONTACT_LOOKUP_WINDOW_LIMIT || Number(counts.daily) >= CONTACT_LOOKUP_DAILY_LIMIT) {
        throw new AuthError("contact discovery limit reached; try again later", 429, CONTACT_LOOKUP_WINDOW_MINUTES * 60);
      }
    }

    const row = (await tx`
      SELECT id, display_name FROM accounts
      WHERE phone_lookup_hash = ${targetHash} AND status IN ('active','limited')`)[0];
    if (!repeated.length) {
      await tx`
        INSERT INTO contact_lookup_attempts (requester_account_id, target_phone_hash)
        VALUES (${requesterAccountId}, ${targetHash})`;
    }
    return row ? { accountId: row.id, displayName: row.display_name } : null;
  });
}

export async function resolveDevice(sql: SQL, token: string): Promise<{ accountId: string; deviceId: string }> {
  const rows = await sql`
    SELECT d.id, d.account_id FROM devices d
    JOIN accounts a ON a.id = d.account_id
    WHERE d.auth_token_hash = ${hashToken(token)}
      AND d.revoked_at IS NULL
      AND a.status IN ('active','limited')`;
  if (rows.length === 0) throw new AuthError("invalid device token");
  await sql`UPDATE devices SET last_seen_at = now() WHERE id = ${rows[0].id}`;
  return { accountId: rows[0].account_id, deviceId: rows[0].id };
}

/**
 * Revalidates a device while holding a row lock for the lifetime of a mutation transaction.
 * This closes the gap between HTTP authentication and a slow request body finishing after the
 * device was revoked.
 */
export async function requireActiveDevice(
  sql: SQL,
  accountId: string,
  deviceId: string,
): Promise<void> {
  const rows = await sql`
    SELECT id FROM devices
    WHERE id = ${deviceId} AND account_id = ${accountId} AND revoked_at IS NULL
    FOR SHARE`;
  if (!rows.length) throw new AuthError("device is no longer active", 401);
}

export async function revokeDevice(
  sql: SQL,
  accountId: string,
  deviceId: string,
): Promise<{ revoked: true }> {
  const rows = await sql`
    UPDATE devices SET
      revoked_at = COALESCE(revoked_at, now()),
      push_token_hash = NULL,
      push_token_ciphertext = NULL,
      push_token_nonce = NULL,
      push_token_key_id = NULL,
      push_environment = NULL,
      push_updated_at = now()
    WHERE id = ${deviceId} AND account_id = ${accountId}
    RETURNING id`;
  if (rows.length === 0) throw new AuthError("device not found", 404);
  return { revoked: true };
}

type AccountDeletionStartOptions = {
  networkKey?: string | null;
  delivery?: OTPDelivery | null;
};

export async function startAccountDeletion(
  sql: SQL,
  accountId: string,
  options: AccountDeletionStartOptions = {},
): Promise<{ code?: string; retryAfter?: number }> {
  const account = (await sql`
    SELECT phone_e164_ciphertext, phone_nonce, phone_key_id, status
    FROM accounts WHERE id = ${accountId}`)[0];
  if (!account || !["active", "limited"].includes(account.status)) {
    throw new AuthError("account unavailable", 403);
  }
  let phone: string;
  try {
    phone = open({
      keyId: account.phone_key_id,
      nonce: Buffer.from(account.phone_nonce),
      ciphertext: Buffer.from(account.phone_e164_ciphertext),
    }, PHONE_AAD).toString("utf8");
  } catch {
    throw new AuthError("account unavailable", 403);
  }
  return await startVerification(sql, phone, {
    networkKey: options.networkKey,
    delivery: options.delivery,
    purpose: "account_deletion",
  });
}

export async function deleteAccount(
  sql: SQL,
  accountId: string,
  code: string,
): Promise<{ deleted: true }> {
  if (!/^\d{6}$/.test(code)) throw new AuthError("enter the 6-digit code", 400);
  const result: { deleted: true } | AuthError = await sql.begin(async (tx) => {
    const identity = (await tx`
      SELECT phone_lookup_hash FROM accounts
      WHERE id = ${accountId} AND status IN ('active','limited')`)[0];
    if (!identity) return new AuthError("account unavailable", 403);
    const originalLookup = Buffer.from(identity.phone_lookup_hash);

    // OTP challenge is locked before the account row, matching login verification order.
    const challenge = (await tx`
      SELECT id, code_hash, code_salt, attempts
      FROM otp_challenges
      WHERE phone_lookup_hash = ${originalLookup} AND purpose = 'account_deletion'
        AND consumed_at IS NULL AND expires_at > now()
      ORDER BY created_at DESC LIMIT 1
      FOR UPDATE`)[0];
    if (!challenge) return new AuthError("no active deletion code", 400);
    if (challenge.attempts >= OTP_MAX_ATTEMPTS) {
      return new AuthError("too many attempts; request a new code", 429);
    }
    const expected = codeHash(code, challenge.code_salt ? Buffer.from(challenge.code_salt) : undefined);
    if (!constantTimeEqual(Buffer.from(challenge.code_hash), expected)) {
      await tx`UPDATE otp_challenges SET attempts = attempts + 1 WHERE id = ${challenge.id}`;
      return new AuthError("incorrect code", 400);
    }

    const account = (await tx`
      SELECT status FROM accounts WHERE id = ${accountId} FOR UPDATE`)[0];
    if (!account || !["active", "limited"].includes(account.status)) {
      return new AuthError("account unavailable", 403);
    }
    const anonymizedPhone = seal(`deleted:${accountId}`, PHONE_AAD);
    const anonymizedLookup = randomBytes(32);
    await tx`
      UPDATE accounts SET
        phone_lookup_hash = ${anonymizedLookup},
        phone_e164_ciphertext = ${anonymizedPhone.ciphertext},
        phone_nonce = ${anonymizedPhone.nonce},
        phone_key_id = ${anonymizedPhone.keyId},
        display_name = 'Deleted Account',
        status = 'deleted',
        updated_at = now()
      WHERE id = ${accountId}`;
    await tx`
      UPDATE push_deliveries SET status = 'dead', claimed_at = NULL,
        last_error = 'account deleted'
      WHERE account_id = ${accountId} AND status IN ('pending','sending')`;
    await tx`
      UPDATE devices SET
        device_name = NULL,
        auth_token_hash = digest(id::text || gen_random_uuid()::text, 'sha256'),
        revoked_at = COALESCE(revoked_at, now()),
        push_token_hash = NULL,
        push_token_ciphertext = NULL,
        push_token_nonce = NULL,
        push_token_key_id = NULL,
        push_environment = NULL,
        push_updated_at = now()
      WHERE account_id = ${accountId}`;
    await tx`DELETE FROM otp_challenges WHERE phone_lookup_hash = ${originalLookup}`;
    return { deleted: true };
  });
  if (result instanceof AuthError) throw result;
  return result;
}

export type DeviceSummary = {
  id: string;
  platform: string;
  deviceName: string | null;
  createdAt: string;
  lastSeenAt: string | null;
  current: boolean;
};

export async function listDevices(
  sql: SQL,
  accountId: string,
  currentDeviceId: string,
): Promise<{ devices: DeviceSummary[] }> {
  const rows = await sql`
    SELECT id, platform,
           device_name AS "deviceName",
           created_at AS "createdAt",
           last_seen_at AS "lastSeenAt",
           (id = ${currentDeviceId}) AS current
    FROM devices
    WHERE account_id = ${accountId} AND revoked_at IS NULL
    ORDER BY (id = ${currentDeviceId}) DESC, COALESCE(last_seen_at, created_at) DESC`;
  return { devices: rows as DeviceSummary[] };
}
