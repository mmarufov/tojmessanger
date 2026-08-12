import type { SQL } from "bun";
import { randomBytes, randomInt } from "node:crypto";
import {
  seal, open, PHONE_AAD, phoneLookupHash, codeHash, hashToken, normalizePhone, constantTimeEqual,
} from "./crypto";
import { enqueuePushDeliveries } from "./push";
import { notifySyncWakeups } from "./sync-wakeup";
import { COMMON_PASSWORDS_V1 } from "./common-passwords-v1";
import { AuthError } from "./auth-error";
export { AuthError } from "./auth-error";
import {
  isV2AccessToken,
  issueV2Session,
  notifySessionRevocation,
  resolveV2Access,
  type AuthV2Session,
} from "./session-security";

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
type OTPPurpose = "login" | "account_deletion" | "security_change";
export type SecurityChangeEvent = "two_factor_enabled" | "two_factor_changed" | "two_factor_disabled";

export interface OTPDelivery {
  send(phone: string, code: string, purpose: OTPPurpose): Promise<void>;
  sendSecurityAlert?(phone: string, event: SecurityChangeEvent): Promise<void>;
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

  async sendSecurityAlert(phone: string, event: SecurityChangeEvent): Promise<void> {
    const response = await fetch(this.url, {
      method: "POST",
      headers: {
        "authorization": `Bearer ${this.bearerToken}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({ phone, event, kind: "security_alert", service: "Toj" }),
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
        error instanceof Error ? error.name : "UnknownError");
      throw new AuthError("verification service temporarily unavailable", 503);
    }
  }

  return production && !returnOTP ? {} : { code, retryAfter: OTP_RESEND_COOLDOWN_SECONDS };
}

export type Session = { accountId: string; deviceId: string; token: string };

export type ProfileDTO = {
  accountId: string;
  username: string | null;
  firstName: string;
  lastName: string;
  displayName: string;
  bio: string;
  birthday: string | null;
  colorIndex: number;
  updatedAt: string;
};

export type UsernameLookupDTO = {
  accountId: string;
  username: string;
  firstName: string;
  lastName: string;
  displayName: string;
  colorIndex: number;
  updatedAt: string;
};

type ProfilePush = { accountId: string; pts: number; ptsCount: number };

const profileDate = (value: unknown): string | null => {
  if (value == null || value === "") return null;
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value)) {
    throw new AuthError("invalid birthday", 400);
  }
  const parsed = new Date(`${value}T00:00:00.000Z`);
  if (Number.isNaN(parsed.getTime()) || parsed.toISOString().slice(0, 10) !== value) {
    throw new AuthError("invalid birthday", 400);
  }
  const today = new Date().toISOString().slice(0, 10);
  const oldest = new Date();
  oldest.setUTCFullYear(oldest.getUTCFullYear() - 120);
  if (value > today || value < oldest.toISOString().slice(0, 10)) {
    throw new AuthError("invalid birthday", 400);
  }
  return value;
};

function profileDTO(row: any): ProfileDTO {
  const birthday = birthdayString(row.birthday);
  return {
    accountId: row.id,
    username: row.username ?? null,
    firstName: row.first_name,
    lastName: row.last_name,
    displayName: row.display_name,
    bio: row.bio,
    birthday,
    colorIndex: Number(row.profile_color),
    updatedAt: row.updated_at instanceof Date ? row.updated_at.toISOString() : String(row.updated_at),
  };
}

function birthdayString(value: unknown): string | null {
  if (value == null) return null;
  return value instanceof Date ? value.toISOString().slice(0, 10) : String(value).slice(0, 10);
}

export async function checkVerification(
  sql: SQL, phone: string, code: string, platform = "ios", deviceName?: string, displayName?: string,
): Promise<Session> {
  const token = randomBytes(32).toString("base64url");
  return await completePhoneVerification(sql, phone, code, displayName, async (tx, accountId) => {
    const factor = await tx`SELECT account_id FROM account_two_factor WHERE account_id = ${accountId}`;
    if (factor.length) {
      throw new AuthError(
        "update Toj to sign in with two-step verification", 426, undefined, "two_factor_client_required",
      );
    }
    const device = await tx`
      INSERT INTO devices (account_id, platform, device_name, auth_token_hash, last_seen_at)
      VALUES (${accountId}, ${platform}, ${cleanLabel(deviceName, 120)}, ${hashToken(token)}, now())
      RETURNING id`;
    return { accountId, deviceId: String(device[0].id), token };
  }, platform);
}

export type AuthV2CheckResponse =
  | { state: "authenticated"; session: AuthV2Session }
  | { state: "two_factor_required"; challengeId: string; expiresAt: string };

export async function checkVerificationV2(
  sql: SQL,
  phone: string,
  code: string,
  platform = "ios",
  deviceName?: string,
  displayName?: string,
): Promise<AuthV2CheckResponse> {
  return await completePhoneVerification(sql, phone, code, displayName, async (tx, accountId) => {
    const factor = await tx`SELECT account_id FROM account_two_factor WHERE account_id = ${accountId}`;
    if (factor.length) {
      const expiresAt = new Date(Date.now() + 5 * 60_000);
      const challenge = (await tx`
        INSERT INTO two_factor_login_challenges
          (account_id, platform, device_name, display_name, expires_at)
        VALUES (
          ${accountId}, ${platform}, ${cleanLabel(deviceName, 120)},
          ${cleanLabel(displayName, 80)}, ${expiresAt}
        ) RETURNING id`)[0];
      return {
        state: "two_factor_required" as const,
        challengeId: String(challenge.id),
        expiresAt: expiresAt.toISOString(),
      };
    }
    const session = await issueV2Session(tx, {
      accountId,
      platform,
      deviceName: cleanLabel(deviceName, 120),
    });
    return { state: "authenticated" as const, session };
  }, platform);
}

async function completePhoneVerification<T>(
  sql: SQL,
  phone: string,
  code: string,
  displayName: string | undefined,
  finish: (tx: SQL, accountId: string) => Promise<T>,
  platform: string,
): Promise<T> {
  const normalizedPhone = validPhone(phone);
  if (!/^\d{6}$/.test(code)) throw new AuthError("enter the 6-digit code", 400);
  if (!ALLOWED_PLATFORMS.has(platform)) throw new AuthError("unsupported device platform", 400);
  const lookup = phoneLookupHash(normalizedPhone);
  const result: T | AuthError = await sql.begin(async (tx) => {
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
      INSERT INTO accounts (phone_lookup_hash, phone_e164_ciphertext, phone_nonce, phone_key_id, first_name, display_name)
      VALUES (${lookup}, ${sealed.ciphertext}, ${sealed.nonce}, ${sealed.keyId}, ${name}, ${name})
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
      if (name) await tx`
        UPDATE accounts
        SET first_name = CASE WHEN first_name = '' AND last_name = '' THEN ${name} ELSE first_name END,
            display_name = CASE WHEN first_name = '' AND last_name = '' THEN ${name} ELSE display_name END,
            updated_at = now()
        WHERE id = ${accountId}`;
    }

    return await finish(tx, String(accountId));
  });
  if (result instanceof AuthError) throw result;
  return result;
}

const TWO_FACTOR_MAX_ATTEMPTS = 5;
const TWO_FACTOR_ACCOUNT_WINDOW_LIMIT = 20;
const TWO_FACTOR_NETWORK_WINDOW_LIMIT = 50;
const RECOVERY_ALPHABET = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ";

export type TwoFactorLoginResponse = {
  session: AuthV2Session;
  recoveryCodes?: string[];
};

function validateTwoFactorPassword(password: unknown): string {
  if (typeof password !== "string") throw new AuthError("password required", 400);
  const length = Array.from(password).length;
  if (length < 8 || length > 128) {
    throw new AuthError("password must contain 8 to 128 characters", 400);
  }
  if (COMMON_PASSWORDS_V1.has(password.toLocaleLowerCase("en-US"))) {
    throw new AuthError("choose a less common password", 400);
  }
  return password;
}

async function passwordHash(password: string): Promise<string> {
  return await Bun.password.hash(password, {
    algorithm: "argon2id",
    memoryCost: 19_456,
    timeCost: 2,
  });
}

function recoveryCode(): string {
  const bytes = randomBytes(10);
  let bits = 0;
  let value = 0;
  let output = "";
  for (const byte of bytes) {
    value = (value << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      output += RECOVERY_ALPHABET[(value >>> (bits - 5)) & 31];
      bits -= 5;
    }
  }
  return output.match(/.{1,4}/g)!.join("-");
}

function normalizedRecoveryCode(value: unknown): string {
  if (typeof value !== "string") return "";
  return value.toUpperCase().replace(/[^2-9A-HJ-NP-Z]/g, "");
}

function recoveryCodeHash(accountId: string, value: string): Buffer {
  return hashToken(`toj/recovery/v1|${accountId}|${value}`);
}

async function replaceRecoveryCodes(sql: SQL, accountId: string): Promise<string[]> {
  const codes = Array.from({ length: 10 }, recoveryCode);
  await sql`DELETE FROM two_factor_recovery_codes WHERE account_id = ${accountId}`;
  for (const code of codes) {
    await sql`
      INSERT INTO two_factor_recovery_codes (account_id, code_hash)
      VALUES (${accountId}, ${recoveryCodeHash(accountId, normalizedRecoveryCode(code))})`;
  }
  return codes;
}

async function revokeOtherAccountDevices(sql: SQL, accountId: string, keepDeviceId?: string): Promise<string[]> {
  const rows = await sql`
    UPDATE devices SET
      revoked_at = COALESCE(revoked_at, now()),
      push_token_hash = NULL, push_token_ciphertext = NULL, push_token_nonce = NULL,
      push_token_key_id = NULL, push_environment = NULL, push_updated_at = now(),
      voip_push_token_hash = NULL, voip_push_token_ciphertext = NULL,
      voip_push_token_nonce = NULL, voip_push_token_key_id = NULL,
      voip_push_environment = NULL, voip_push_updated_at = now()
    WHERE account_id = ${accountId} AND revoked_at IS NULL
      AND (${keepDeviceId ?? null}::uuid IS NULL OR id <> ${keepDeviceId ?? null}::uuid)
    RETURNING id`;
  if (rows.length) await sql`
    UPDATE device_sessions SET revoked_at = COALESCE(revoked_at, now()), revocation_reason = 'security_change'
    WHERE device_id IN ${sql(rows.map((row) => String(row.id)))}`;
  for (const row of rows) {
    await notifySessionRevocation(sql, accountId, String(row.id), "security_change");
  }
  return rows.map((row) => String(row.id));
}

export async function completeTwoFactorLogin(
  sql: SQL,
  input: {
    challengeId: string;
    password?: string;
    recoveryCode?: string;
    newPassword?: string;
    networkKey?: string | null;
  },
): Promise<TwoFactorLoginResponse> {
  const result = await sql.begin(async (tx) => {
    const challenge = (await tx`
      SELECT * FROM two_factor_login_challenges
      WHERE id = ${input.challengeId} AND consumed_at IS NULL AND expires_at > now()
      FOR UPDATE`)[0];
    if (!challenge) return new AuthError("two-step challenge expired", 401, undefined, "challenge_expired");
    if (Number(challenge.attempts) >= TWO_FACTOR_MAX_ATTEMPTS) {
      return new AuthError("too many attempts; request a new SMS code", 429, undefined, "challenge_locked");
    }
    const accountId = String(challenge.account_id);
    const accountBudgetHash = hashToken(`two-factor-account|${accountId}`);
    await tx`SELECT pg_advisory_xact_lock(${accountBudgetHash.readBigInt64BE(0)})`;
    const networkHash = input.networkKey
      ? hashToken(`two-factor-network|${input.networkKey}`)
      : null;
    if (networkHash) await tx`SELECT pg_advisory_xact_lock(${networkHash.readBigInt64BE(0)})`;
    const accountAttempts = Number((await tx`
      SELECT count(*) AS count FROM two_factor_attempt_budgets
      WHERE account_id = ${accountId} AND accepted_at > now() - interval '15 minutes'`)[0].count);
    if (accountAttempts >= TWO_FACTOR_ACCOUNT_WINDOW_LIMIT) {
      return new AuthError("too many two-step attempts; try again later", 429, 900, "challenge_locked");
    }
    if (networkHash) {
      const networkAttempts = Number((await tx`
        SELECT count(*) AS count FROM two_factor_attempt_budgets
        WHERE network_hash = ${networkHash} AND accepted_at > now() - interval '15 minutes'`)[0].count);
      if (networkAttempts >= TWO_FACTOR_NETWORK_WINDOW_LIMIT) {
        return new AuthError("too many two-step attempts; try again later", 429, 900, "challenge_locked");
      }
    }
    await tx`
      INSERT INTO two_factor_attempt_budgets (account_id, network_hash)
      VALUES (${accountId}, ${networkHash})`;
    const factor = (await tx`
      SELECT password_hash FROM account_two_factor WHERE account_id = ${accountId} FOR UPDATE`)[0];
    if (!factor) return new AuthError("two-step verification is no longer enabled", 409, undefined, "factor_changed");

    let recoveryCodes: string[] | undefined;
    let accepted = false;
    if (input.password !== undefined) {
      accepted = await Bun.password.verify(input.password, String(factor.password_hash));
    } else {
      const normalized = normalizedRecoveryCode(input.recoveryCode);
      const recovery = normalized.length === 16 ? (await tx`
        SELECT id FROM two_factor_recovery_codes
        WHERE account_id = ${accountId}
          AND code_hash = ${recoveryCodeHash(accountId, normalized)}
          AND consumed_at IS NULL
        FOR UPDATE`)[0] : null;
      if (recovery) {
        const replacement = validateTwoFactorPassword(input.newPassword);
        const nextHash = await passwordHash(replacement);
        await tx`UPDATE two_factor_recovery_codes SET consumed_at = now() WHERE id = ${recovery.id}`;
        await tx`
          UPDATE account_two_factor SET password_hash = ${nextHash}, updated_at = now()
          WHERE account_id = ${accountId}`;
        recoveryCodes = await replaceRecoveryCodes(tx, accountId);
        await revokeOtherAccountDevices(tx, accountId);
        accepted = true;
      }
    }
    if (!accepted) {
      await tx`
        UPDATE two_factor_login_challenges SET attempts = attempts + 1
        WHERE id = ${challenge.id}`;
      if (Number(challenge.attempts) + 1 >= TWO_FACTOR_MAX_ATTEMPTS) {
        return new AuthError("too many attempts; request a new SMS code", 429, undefined, "challenge_locked");
      }
      return new AuthError("incorrect password or recovery code", 401, undefined, "incorrect_second_factor");
    }
    const claimed = await tx`
      UPDATE two_factor_login_challenges SET consumed_at = now()
      WHERE id = ${challenge.id} AND consumed_at IS NULL RETURNING id`;
    if (!claimed.length) return new AuthError("two-step challenge already used", 401, undefined, "challenge_used");
    const session = await issueV2Session(tx, {
      accountId,
      platform: String(challenge.platform),
      deviceName: challenge.device_name ? String(challenge.device_name) : null,
    });
    return { session, ...(recoveryCodes ? { recoveryCodes } : {}) };
  });
  if (result instanceof AuthError) throw result;
  return result;
}

export async function twoFactorStatus(sql: SQL, accountId: string): Promise<{ enabled: boolean; recoveryCodesRemaining: number }> {
  const row = (await sql`
    SELECT factor.account_id,
           count(code.id) FILTER (WHERE code.consumed_at IS NULL) AS remaining
    FROM account_two_factor factor
    LEFT JOIN two_factor_recovery_codes code ON code.account_id = factor.account_id
    WHERE factor.account_id = ${accountId}
    GROUP BY factor.account_id`)[0];
  return { enabled: Boolean(row), recoveryCodesRemaining: row ? Number(row.remaining) : 0 };
}

export async function startSecurityChange(
  sql: SQL,
  accountId: string,
  options: StartVerificationOptions = {},
): Promise<{ code?: string; retryAfter?: number }> {
  const account = (await sql`
    SELECT phone_e164_ciphertext, phone_nonce, phone_key_id, status
    FROM accounts WHERE id = ${accountId}`)[0];
  if (!account || !["active", "limited"].includes(String(account.status))) {
    throw new AuthError("account unavailable", 403);
  }
  const phone = open({
    ciphertext: Buffer.from(account.phone_e164_ciphertext),
    nonce: Buffer.from(account.phone_nonce),
    keyId: String(account.phone_key_id),
  }, PHONE_AAD).toString("utf8");
  return await startVerification(sql, phone, { ...options, purpose: "security_change" });
}

export async function completeSecurityStepUp(
  sql: SQL,
  accountId: string,
  code: string,
): Promise<{ stepUpToken: string; expiresAt: string }> {
  if (!/^\d{6}$/.test(code)) throw new AuthError("enter the 6-digit code", 400);
  const account = (await sql`
    SELECT phone_e164_ciphertext, phone_nonce, phone_key_id
    FROM accounts WHERE id = ${accountId}`)[0];
  if (!account) throw new AuthError("account unavailable", 403);
  const phone = open({
    ciphertext: Buffer.from(account.phone_e164_ciphertext), nonce: Buffer.from(account.phone_nonce),
    keyId: String(account.phone_key_id),
  }, PHONE_AAD).toString("utf8");
  const lookup = phoneLookupHash(phone);
  const ticket = randomBytes(32).toString("base64url");
  const expiresAt = new Date(Date.now() + 10 * 60_000);
  const result = await sql.begin(async (tx) => {
    const challenge = (await tx`
      SELECT id, code_hash, code_salt, attempts FROM otp_challenges
      WHERE phone_lookup_hash = ${lookup} AND purpose = 'security_change'
        AND consumed_at IS NULL AND expires_at > now()
      ORDER BY created_at DESC LIMIT 1 FOR UPDATE`)[0];
    if (!challenge) return new AuthError("no active security code", 401);
    if (Number(challenge.attempts) >= TWO_FACTOR_MAX_ATTEMPTS) {
      return new AuthError(
        "too many attempts; request a new security code",
        429,
        undefined,
        "challenge_locked",
      );
    }
    const expected = codeHash(code, challenge.code_salt ? Buffer.from(challenge.code_salt) : undefined);
    if (!constantTimeEqual(Buffer.from(challenge.code_hash), expected)) {
      await tx`UPDATE otp_challenges SET attempts = attempts + 1 WHERE id = ${challenge.id}`;
      if (Number(challenge.attempts) + 1 >= TWO_FACTOR_MAX_ATTEMPTS) {
        return new AuthError(
          "too many attempts; request a new security code",
          429,
          undefined,
          "challenge_locked",
        );
      }
      return new AuthError("incorrect code", 401);
    }
    await tx`UPDATE otp_challenges SET consumed_at = now() WHERE id = ${challenge.id}`;
    await tx`
      INSERT INTO security_step_up_tickets (account_id, token_hash, expires_at)
      VALUES (${accountId}, ${hashToken(ticket)}, ${expiresAt})`;
    return { stepUpToken: ticket, expiresAt: expiresAt.toISOString() };
  });
  if (result instanceof AuthError) throw result;
  return result;
}

async function requireStepUp(
  sql: SQL,
  accountId: string,
  tokenValue: unknown,
): Promise<{ id: string } | AuthError> {
  if (typeof tokenValue !== "string") {
    return new AuthError("security verification required", 401, undefined, "step_up_expired");
  }
  const ticket = (await sql`
    SELECT id, attempts FROM security_step_up_tickets
    WHERE account_id = ${accountId} AND token_hash = ${hashToken(tokenValue)}
      AND consumed_at IS NULL AND expires_at > now()
    FOR UPDATE`)[0];
  if (!ticket) return new AuthError("security verification expired", 401, undefined, "step_up_expired");
  if (Number(ticket.attempts) >= TWO_FACTOR_MAX_ATTEMPTS) {
    return new AuthError("too many attempts; request a new security code", 429, undefined, "challenge_locked");
  }
  return { id: String(ticket.id) };
}

async function verifyCurrentFactor(
  sql: SQL,
  accountId: string,
  credential: unknown,
): Promise<boolean> {
  const factor = (await sql`
    SELECT password_hash FROM account_two_factor WHERE account_id = ${accountId} FOR UPDATE`)[0];
  if (!factor) return true;
  if (typeof credential === "string" && await Bun.password.verify(credential, String(factor.password_hash))) {
    return true;
  }
  const normalized = normalizedRecoveryCode(credential);
  const recovered = normalized.length === 16 ? await sql`
    UPDATE two_factor_recovery_codes SET consumed_at = now()
    WHERE account_id = ${accountId} AND code_hash = ${recoveryCodeHash(accountId, normalized)}
      AND consumed_at IS NULL RETURNING id` : [];
  return recovered.length > 0;
}

export async function configureTwoFactor(
  sql: SQL,
  input: {
    accountId: string;
    currentDeviceId: string;
    stepUpToken: string;
    password: string;
    currentCredential?: string;
  },
): Promise<{ enabled: true; recoveryCodes: string[]; session: AuthV2Session; revokedDeviceIds: string[] }> {
  const nextPassword = validateTwoFactorPassword(input.password);
  const result = await sql.begin(async (tx) => {
    const ticket = await requireStepUp(tx, input.accountId, input.stepUpToken);
    if (ticket instanceof AuthError) return ticket;
    if (!await verifyCurrentFactor(tx, input.accountId, input.currentCredential)) {
      await tx`UPDATE security_step_up_tickets SET attempts = attempts + 1 WHERE id = ${ticket.id}`;
      return new AuthError(
        "current password or recovery code is incorrect",
        401,
        undefined,
        "incorrect_second_factor",
      );
    }
    const nextHash = await passwordHash(nextPassword);
    await tx`UPDATE security_step_up_tickets SET consumed_at = now() WHERE id = ${ticket.id}`;
    await tx`
      INSERT INTO account_two_factor (account_id, password_hash)
      VALUES (${input.accountId}, ${nextHash})
      ON CONFLICT (account_id) DO UPDATE SET password_hash = EXCLUDED.password_hash, updated_at = now()`;
    const recoveryCodes = await replaceRecoveryCodes(tx, input.accountId);
    const revokedDeviceIds = await revokeOtherAccountDevices(tx, input.accountId, input.currentDeviceId);
    const session = await issueV2Session(tx, {
      accountId: input.accountId, platform: "ios", existingDeviceId: input.currentDeviceId,
    });
    return { enabled: true as const, recoveryCodes, session, revokedDeviceIds };
  });
  if (result instanceof AuthError) throw result;
  return result;
}

export async function regenerateTwoFactorRecoveryCodes(
  sql: SQL,
  input: {
    accountId: string;
    currentDeviceId: string;
    stepUpToken: string;
    currentCredential: string;
  },
): Promise<{ enabled: true; recoveryCodes: string[]; session: AuthV2Session; revokedDeviceIds: string[] }> {
  const result = await sql.begin(async (tx) => {
    const ticket = await requireStepUp(tx, input.accountId, input.stepUpToken);
    if (ticket instanceof AuthError) return ticket;
    const factor = await tx`
      SELECT account_id FROM account_two_factor WHERE account_id = ${input.accountId} FOR UPDATE`;
    if (!factor.length) {
      return new AuthError("two-step verification is not enabled", 409, undefined, "factor_changed");
    }
    if (!await verifyCurrentFactor(tx, input.accountId, input.currentCredential)) {
      await tx`UPDATE security_step_up_tickets SET attempts = attempts + 1 WHERE id = ${ticket.id}`;
      return new AuthError(
        "current password or recovery code is incorrect",
        401,
        undefined,
        "incorrect_second_factor",
      );
    }
    await tx`UPDATE security_step_up_tickets SET consumed_at = now() WHERE id = ${ticket.id}`;
    const recoveryCodes = await replaceRecoveryCodes(tx, input.accountId);
    const revokedDeviceIds = await revokeOtherAccountDevices(tx, input.accountId, input.currentDeviceId);
    const session = await issueV2Session(tx, {
      accountId: input.accountId, platform: "ios", existingDeviceId: input.currentDeviceId,
    });
    return { enabled: true as const, recoveryCodes, session, revokedDeviceIds };
  });
  if (result instanceof AuthError) throw result;
  return result;
}

export async function disableTwoFactor(
  sql: SQL,
  input: { accountId: string; currentDeviceId: string; stepUpToken: string; currentCredential: string },
): Promise<{ enabled: false; session: AuthV2Session; revokedDeviceIds: string[] }> {
  const result = await sql.begin(async (tx) => {
    const ticket = await requireStepUp(tx, input.accountId, input.stepUpToken);
    if (ticket instanceof AuthError) return ticket;
    if (!await verifyCurrentFactor(tx, input.accountId, input.currentCredential)) {
      await tx`UPDATE security_step_up_tickets SET attempts = attempts + 1 WHERE id = ${ticket.id}`;
      return new AuthError(
        "current password or recovery code is incorrect",
        401,
        undefined,
        "incorrect_second_factor",
      );
    }
    await tx`UPDATE security_step_up_tickets SET consumed_at = now() WHERE id = ${ticket.id}`;
    await tx`DELETE FROM two_factor_recovery_codes WHERE account_id = ${input.accountId}`;
    await tx`DELETE FROM account_two_factor WHERE account_id = ${input.accountId}`;
    const revokedDeviceIds = await revokeOtherAccountDevices(tx, input.accountId, input.currentDeviceId);
    const session = await issueV2Session(tx, {
      accountId: input.accountId, platform: "ios", existingDeviceId: input.currentDeviceId,
    });
    return { enabled: false as const, session, revokedDeviceIds };
  });
  if (result instanceof AuthError) throw result;
  return result;
}

/** Best-effort non-secret alert. Provider failure never rolls back the committed security change. */
export async function sendSecurityChangeAlert(
  sql: SQL,
  accountId: string,
  event: SecurityChangeEvent,
  delivery: OTPDelivery | null,
): Promise<void> {
  try {
    await sql.begin(async (tx) => {
      const state = (await tx`
        UPDATE account_sync_states SET pts = pts + 1, updated_at = now()
        WHERE account_id = ${accountId}
        RETURNING pts`)[0];
      if (!state) return;
      const pts = Number(state.pts);
      await tx`
        INSERT INTO account_events (account_id, pts, type, actor_account_id, data)
        VALUES (
          ${accountId}, ${pts}, 'security.changed', ${accountId},
          ${JSON.stringify({ event })}::jsonb
        )`;
      await enqueuePushDeliveries(tx, {
        accountId,
        pts,
        senderAccountId: accountId,
        forceAlert: true,
      });
      await notifySyncWakeups(tx, [{ accountId, pts, ptsCount: 1 }]);
    });
  } catch (error) {
    console.error(new Date().toISOString(), "auth.security_alert.push_failed",
      error instanceof Error ? error.name : "UnknownError");
  }

  if (!delivery?.sendSecurityAlert) return;
  try {
    const account = (await sql`
      SELECT phone_e164_ciphertext, phone_nonce, phone_key_id
      FROM accounts WHERE id = ${accountId}`)[0];
    if (!account) return;
    const phone = open({
      ciphertext: Buffer.from(account.phone_e164_ciphertext),
      nonce: Buffer.from(account.phone_nonce),
      keyId: String(account.phone_key_id),
    }, PHONE_AAD).toString("utf8");
    await delivery.sendSecurityAlert(phone, event);
  } catch (error) {
    console.error(new Date().toISOString(), "auth.security_alert.sms_failed",
      error instanceof Error ? error.name : "UnknownError");
  }
}

/** Contact discovery: resolve a phone number to an account so the client can open a direct dialog. */
export async function lookupAccountByPhone(
  sql: SQL, requesterAccountId: string, phone: string,
): Promise<ProfileDTO | null> {
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
      SELECT id, username, first_name, last_name, display_name, bio, birthday, profile_color, updated_at FROM accounts
      WHERE phone_lookup_hash = ${targetHash} AND status IN ('active','limited')`)[0];
    if (!repeated.length) {
      await tx`
        INSERT INTO contact_lookup_attempts (requester_account_id, target_phone_hash)
        VALUES (${requesterAccountId}, ${targetHash})`;
    }
    return row ? profileDTO(row) : null;
  });
}

/** Return the canonical account profile for this authenticated account. */
export async function getProfile(sql: SQL, accountId: string): Promise<ProfileDTO> {
  const row = (await sql`
    SELECT id, username, first_name, last_name, display_name, bio, birthday, profile_color, updated_at
    FROM accounts WHERE id = ${accountId} AND status IN ('active','limited')`)[0];
  if (!row) throw new AuthError("account unavailable", 403);
  return profileDTO(row);
}

/** Persist a profile and fan a silent sync event out to every device and active chat partner. */
export async function updateProfile(
  sql: SQL,
  accountId: string,
  deviceId: string,
  input: { username?: unknown; firstName?: unknown; lastName?: unknown; bio?: unknown; birthday?: unknown; colorIndex?: unknown },
): Promise<{ profile: ProfileDTO; pushes: ProfilePush[] }> {
  const hasUsername = Object.prototype.hasOwnProperty.call(input, "username");
  if (hasUsername && input.username !== null && typeof input.username !== "string") {
    throw new AuthError("username must be a string or null", 400);
  }
  const requestedUsername = hasUsername
    ? (typeof input.username === "string" ? input.username.trim().toLowerCase() : "") || null
    : undefined;
  if (requestedUsername && (!/^[a-z][a-z0-9_]{4,31}$/.test(requestedUsername)
    || new Set(["admin", "support", "settings", "login", "tojapp"]).has(requestedUsername))) {
    throw new AuthError("username must start with a letter and contain 5-32 letters, numbers, or underscores", 400);
  }
  const firstName = typeof input.firstName === "string" ? input.firstName.trim().slice(0, 48) : "";
  const lastName = typeof input.lastName === "string" ? input.lastName.trim().slice(0, 48) : "";
  const bio = typeof input.bio === "string" ? input.bio.trim().slice(0, 120) : "";
  const birthday = profileDate(input.birthday);
  const colorIndex = Number(input.colorIndex);
  if (!firstName) throw new AuthError("first name required", 400);
  if (!Number.isSafeInteger(colorIndex) || colorIndex < 0 || colorIndex > 7) {
    throw new AuthError("invalid profile color", 400);
  }
  const displayName = [firstName, lastName].filter(Boolean).join(" ");
  try {
    return await sql.begin(async (tx) => {
    const current = (await tx`
      SELECT id, username, first_name, last_name, display_name, bio, birthday, profile_color, updated_at
      FROM accounts WHERE id = ${accountId} AND status IN ('active','limited') FOR UPDATE`)[0];
    if (!current) throw new AuthError("account unavailable", 403);
    await requireActiveDevice(tx, accountId, deviceId);
    // Username was added after the profile endpoint shipped. Older clients omit the key, so
    // absence must mean "preserve"; explicit null/empty string remains the clear operation.
    const username = requestedUsername === undefined
      ? (current.username == null ? null : String(current.username))
      : requestedUsername;
    const currentBirthday = birthdayString(current.birthday);
    const changed = (current.username ?? null) !== username
      || current.first_name !== firstName || current.last_name !== lastName
      || current.bio !== bio || currentBirthday !== birthday || Number(current.profile_color) !== colorIndex;
    if (!changed) return { profile: profileDTO(current), pushes: [] };

    const updated = (await tx`
      UPDATE accounts SET username = ${username}, first_name = ${firstName}, last_name = ${lastName},
        display_name = ${displayName}, bio = ${bio}, birthday = ${birthday}::date,
        profile_color = ${colorIndex}, updated_at = now()
      WHERE id = ${accountId}
      RETURNING id, username, first_name, last_name, display_name, bio, birthday, profile_color, updated_at`)[0];

    const recipientRows = await tx`
      SELECT DISTINCT peer.account_id
      FROM dialog_members mine
      JOIN dialog_members peer ON peer.dialog_id = mine.dialog_id AND peer.left_at IS NULL
      WHERE mine.account_id = ${accountId} AND mine.left_at IS NULL
      UNION SELECT ${accountId}::uuid AS account_id`;
    const recipients = recipientRows.map((row) => String(row.account_id)).sort();
    const profile = profileDTO(updated);
    const baseData = {
      subject_account_id: profile.accountId,
      username: profile.username,
      first_name: profile.firstName,
      last_name: profile.lastName,
      display_name: profile.displayName,
      bio: profile.bio,
      birthday: profile.birthday,
      color_index: profile.colorIndex,
      updated_at: profile.updatedAt,
    };
    const pushes: ProfilePush[] = [];
    for (const recipient of recipients) {
      const sharedRows = recipient === accountId ? [] : await tx`
        SELECT mine.dialog_id
        FROM dialog_members mine
        JOIN dialog_members peer ON peer.dialog_id = mine.dialog_id
        JOIN dialogs d ON d.id = mine.dialog_id AND d.type = 'direct'
        WHERE mine.account_id = ${accountId} AND mine.left_at IS NULL
          AND peer.account_id = ${recipient} AND peer.left_at IS NULL
        ORDER BY mine.dialog_id`;
      const data = JSON.stringify({
        ...baseData,
        shared_dialog_ids: sharedRows.map((row) => String(row.dialog_id)),
      });
      const state = (await tx`
        UPDATE account_sync_states SET pts = pts + 1, updated_at = now()
        WHERE account_id = ${recipient} RETURNING pts`)[0];
      const pts = Number(state.pts);
      await tx`
        INSERT INTO account_events (account_id, pts, type, actor_account_id, data)
        VALUES (${recipient}, ${pts}, 'profile.updated', ${accountId}, ${data}::jsonb)`;
      await enqueuePushDeliveries(tx, {
        accountId: recipient, pts, senderAccountId: accountId,
        sourceDeviceId: deviceId, alertRecipients: false,
      });
      pushes.push({ accountId: recipient, pts, ptsCount: 1 });
    }
    return { profile, pushes };
    });
  } catch (error: any) {
    const duplicateCode = error?.code === "23505" || error?.errno === "23505";
    const duplicateUsername = `${error?.constraint ?? ""} ${error?.message ?? ""}`.includes("username");
    if (duplicateCode && duplicateUsername) {
      throw new AuthError("username is already taken", 409);
    }
    throw error;
  }
}

/** Public-handle lookup with the same abuse budget as contact discovery. */
export async function lookupAccountByUsername(
  sql: SQL, requesterAccountId: string, value: unknown,
): Promise<UsernameLookupDTO | null> {
  const username = typeof value === "string" ? value.trim().toLowerCase().replace(/^@/, "") : "";
  if (!/^[a-z][a-z0-9_]{4,31}$/.test(username)) return null;
  const targetHash = hashToken(`username:${username}`);
  return await sql.begin(async (tx) => {
    await tx`SELECT pg_advisory_xact_lock(hashtextextended(${`contact-lookup:${requesterAccountId}`}, 0))`;
    const repeated = await tx`
      SELECT 1 FROM contact_lookup_attempts
      WHERE requester_account_id = ${requesterAccountId} AND target_phone_hash = ${targetHash}
        AND created_at > now() - (${CONTACT_LOOKUP_WINDOW_MINUTES} * interval '1 minute') LIMIT 1`;
    if (!repeated.length) {
      const counts = (await tx`
        SELECT count(*) FILTER (WHERE created_at > now() - (${CONTACT_LOOKUP_WINDOW_MINUTES} * interval '1 minute')) AS recent,
          count(*) FILTER (WHERE created_at > now() - interval '24 hours') AS daily
        FROM contact_lookup_attempts WHERE requester_account_id = ${requesterAccountId}`)[0];
      if (Number(counts.recent) >= CONTACT_LOOKUP_WINDOW_LIMIT || Number(counts.daily) >= CONTACT_LOOKUP_DAILY_LIMIT) {
        throw new AuthError("contact discovery limit reached; try again later", 429, CONTACT_LOOKUP_WINDOW_MINUTES * 60);
      }
      await tx`INSERT INTO contact_lookup_attempts (requester_account_id, target_phone_hash)
        VALUES (${requesterAccountId}, ${targetHash})`;
    }
    const row = (await tx`
      SELECT id, username, first_name, last_name, display_name, profile_color, updated_at
      FROM accounts WHERE lower(username) = ${username} AND status IN ('active','limited')`)[0];
    if (!row) return null;
    return {
      accountId: row.id,
      username: row.username,
      firstName: row.first_name,
      lastName: row.last_name,
      displayName: row.display_name,
      colorIndex: Number(row.profile_color),
      updatedAt: row.updated_at instanceof Date ? row.updated_at.toISOString() : String(row.updated_at),
    };
  });
}

export async function resolveDevice(
  sql: SQL,
  token: string,
): Promise<{ accountId: string; deviceId: string; accessExpiresAt?: string }> {
  if (isV2AccessToken(token)) {
    const v2 = await resolveV2Access(sql, token);
    if (!v2) throw new AuthError("invalid device token", 401, undefined, "device_revoked");
    return {
      accountId: v2.accountId,
      deviceId: v2.deviceId,
      accessExpiresAt: v2.accessExpiresAt.toISOString(),
    };
  }
  const rows = await sql`
    SELECT d.id, d.account_id FROM devices d
    JOIN accounts a ON a.id = d.account_id
    WHERE d.auth_token_hash = ${hashToken(token)}
      AND d.revoked_at IS NULL
      AND a.status IN ('active','limited')`;
  if (rows.length === 0) throw new AuthError("invalid device token", 401, undefined, "device_revoked");
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
  // Account deletion locks the account before revoking devices. Take the same explicit order here:
  // a joined FOR SHARE can lock the device first and deadlock with deletion (account -> device).
  const accounts = await sql`
    SELECT id FROM accounts
    WHERE id = ${accountId} AND status IN ('active','limited')
    FOR SHARE`;
  if (!accounts.length) throw new AuthError("device is no longer active", 401);

  const devices = await sql`
    SELECT id FROM devices
    WHERE id = ${deviceId} AND account_id = ${accountId} AND revoked_at IS NULL
    FOR SHARE`;
  if (!devices.length) throw new AuthError("device is no longer active", 401);
}

export async function revokeDevice(
  sql: SQL,
  accountId: string,
  deviceId: string,
  options: { beforeCommit?: (tx: SQL) => Promise<void> } = {},
): Promise<{ revoked: true }> {
  return await sql.begin(async (tx) => {
    const rows = await tx`
      UPDATE devices SET
        revoked_at = COALESCE(revoked_at, now()),
        push_token_hash = NULL,
        push_token_ciphertext = NULL,
        push_token_nonce = NULL,
        push_token_key_id = NULL,
        push_environment = NULL,
        push_updated_at = now(),
        voip_push_token_hash = NULL,
        voip_push_token_ciphertext = NULL,
        voip_push_token_nonce = NULL,
        voip_push_token_key_id = NULL,
        voip_push_environment = NULL,
        voip_push_updated_at = now()
      WHERE id = ${deviceId} AND account_id = ${accountId}
      RETURNING id`;
    if (rows.length === 0) throw new AuthError("device not found", 404);
    await tx`
      UPDATE device_sessions SET revoked_at = COALESCE(revoked_at, now()), revocation_reason = 'device_revoked'
      WHERE device_id = ${deviceId}`;
    await notifySessionRevocation(tx, accountId, deviceId, "device_revoked");
    await options.beforeCommit?.(tx);
    return { revoked: true };
  });
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
  options: { beforeCommit?: (tx: SQL) => Promise<void> } = {},
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
    // This database-boundary function is also called by the account-status trigger used by old
    // binaries. Keeping current and mixed-node deletion on one path prevents semantic drift.
    await tx`SELECT public.toj_cleanup_account_private_state_v1(${accountId})`;
    const anonymizedPhone = seal(`deleted:${accountId}`, PHONE_AAD);
    const anonymizedLookup = randomBytes(32);
    await tx`
      UPDATE accounts SET
        username = NULL,
        phone_lookup_hash = ${anonymizedLookup},
        phone_e164_ciphertext = ${anonymizedPhone.ciphertext},
        phone_nonce = ${anonymizedPhone.nonce},
        phone_key_id = ${anonymizedPhone.keyId},
        first_name = 'Deleted Account',
        last_name = '',
        display_name = 'Deleted Account',
        bio = '',
        birthday = NULL,
        profile_color = 0,
        status = 'deleted',
        updated_at = now()
      WHERE id = ${accountId}`;
    await tx`
      UPDATE push_deliveries SET status = 'dead', claimed_at = NULL,
        last_error = 'account deleted'
      WHERE account_id = ${accountId} AND status IN ('pending','sending')`;
    const revokedDevices = await tx`
      UPDATE devices SET
        device_name = NULL,
        auth_token_hash = digest(id::text || gen_random_uuid()::text, 'sha256'),
        revoked_at = COALESCE(revoked_at, now()),
        push_token_hash = NULL,
        push_token_ciphertext = NULL,
        push_token_nonce = NULL,
        push_token_key_id = NULL,
        push_environment = NULL,
        push_updated_at = now(),
        voip_push_token_hash = NULL,
        voip_push_token_ciphertext = NULL,
        voip_push_token_nonce = NULL,
        voip_push_token_key_id = NULL,
        voip_push_environment = NULL,
        voip_push_updated_at = now()
      WHERE account_id = ${accountId}
      RETURNING id`;
    for (const device of revokedDevices) {
      // Account deletion must close authenticated sockets on every server process, not only the
      // node that handled the request. NOTIFY is transaction-bound and therefore cannot escape a
      // later rollback.
      await notifySessionRevocation(tx, accountId, String(device.id), "device_revoked");
    }
    // Device rows are revoked and locked before call rows, matching call-mutation lock order.
    // The injected call cleanup therefore commits atomically with account deletion without letting
    // an in-flight device mutation recreate state after the termination scan.
    await options.beforeCommit?.(tx);
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
  sessionExpiresAt: string | null;
  current: boolean;
};

export async function listDevices(
  sql: SQL,
  accountId: string,
  currentDeviceId: string,
): Promise<{ devices: DeviceSummary[] }> {
  const rows = await sql`
    SELECT device.id, device.platform,
           device.device_name AS "deviceName",
           device.created_at AS "createdAt",
           device.last_seen_at AS "lastSeenAt",
           session.absolute_expires_at AS "sessionExpiresAt",
           (device.id = ${currentDeviceId}) AS current
    FROM devices device
    LEFT JOIN device_sessions session ON session.device_id = device.id AND session.revoked_at IS NULL
    WHERE device.account_id = ${accountId} AND device.revoked_at IS NULL
    ORDER BY (device.id = ${currentDeviceId}) DESC,
             COALESCE(device.last_seen_at, device.created_at) DESC`;
  return { devices: rows as DeviceSummary[] };
}
