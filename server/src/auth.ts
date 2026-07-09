import type { SQL } from "bun";
import { randomBytes } from "node:crypto";
import {
  seal, PHONE_AAD, phoneLookupHash, codeHash, hashToken, normalizePhone, constantTimeEqual,
} from "./crypto";

export class AuthError extends Error {}

/** Dev: returns the OTP code so local/tests can log in. Prod SMS is not wired yet. */
export async function startVerification(sql: SQL, phone: string): Promise<{ code?: string }> {
  const lookup = phoneLookupHash(phone);
  const code = String(Math.floor(100000 + Math.random() * 900000));
  const expires = new Date(Date.now() + 5 * 60_000);
  await sql`UPDATE otp_challenges SET consumed_at = now() WHERE phone_lookup_hash = ${lookup} AND consumed_at IS NULL`;
  await sql`INSERT INTO otp_challenges (phone_lookup_hash, code_hash, expires_at) VALUES (${lookup}, ${codeHash(code)}, ${expires})`;
  if (process.env.NODE_ENV !== "production" || process.env.TOJ_RETURN_OTP === "1") return { code };
  return {};
}

export type Session = { accountId: string; deviceId: string; token: string };

export async function checkVerification(
  sql: SQL, phone: string, code: string, platform = "ios", deviceName?: string, displayName?: string,
): Promise<Session> {
  const lookup = phoneLookupHash(phone);
  const rows = await sql`
    SELECT id, code_hash, attempts FROM otp_challenges
    WHERE phone_lookup_hash = ${lookup} AND consumed_at IS NULL AND expires_at > now()
    ORDER BY created_at DESC LIMIT 1`;
  if (rows.length === 0) throw new AuthError("no active verification code");
  const ch = rows[0];
  if (ch.attempts >= 5) throw new AuthError("too many attempts");
  if (!constantTimeEqual(Buffer.from(ch.code_hash), codeHash(code))) {
    await sql`UPDATE otp_challenges SET attempts = attempts + 1 WHERE id = ${ch.id}`;
    throw new AuthError("incorrect code");
  }
  await sql`UPDATE otp_challenges SET consumed_at = now() WHERE id = ${ch.id}`;

  // find-or-create, conflict-safe: two concurrent first-logins for the same phone can't both insert.
  const accountId: string = await sql.begin(async (tx) => {
    const sealed = seal(normalizePhone(phone), PHONE_AAD);
    const created = await tx`
      INSERT INTO accounts (phone_lookup_hash, phone_e164_ciphertext, phone_nonce, phone_key_id, display_name)
      VALUES (${lookup}, ${sealed.ciphertext}, ${sealed.nonce}, ${sealed.keyId}, ${displayName ?? ""})
      ON CONFLICT (phone_lookup_hash) DO NOTHING
      RETURNING id`;
    if (created.length) {
      await tx`INSERT INTO account_sync_states (account_id) VALUES (${created[0].id}) ON CONFLICT DO NOTHING`;
      return created[0].id;
    }
    return (await tx`SELECT id FROM accounts WHERE phone_lookup_hash = ${lookup}`)[0].id;
  });

  const token = randomBytes(32).toString("base64url");
  const dev = await sql`
    INSERT INTO devices (account_id, platform, device_name, auth_token_hash)
    VALUES (${accountId}, ${platform}, ${deviceName ?? null}, ${hashToken(token)})
    RETURNING id`;
  return { accountId, deviceId: dev[0].id, token };
}

/** Contact discovery: resolve a phone number to an account so the client can open a direct dialog.
 *  Uses the HMAC lookup hash — the server never scans plaintext numbers. */
export async function lookupAccountByPhone(
  sql: SQL, phone: string,
): Promise<{ accountId: string; displayName: string } | null> {
  const r = (await sql`
    SELECT id, display_name FROM accounts
    WHERE phone_lookup_hash = ${phoneLookupHash(phone)} AND status <> 'deleted'`)[0];
  return r ? { accountId: r.id, displayName: r.display_name } : null;
}

export async function resolveDevice(sql: SQL, token: string): Promise<{ accountId: string; deviceId: string }> {
  const rows = await sql`
    SELECT id, account_id FROM devices
    WHERE auth_token_hash = ${hashToken(token)} AND revoked_at IS NULL`;
  if (rows.length === 0) throw new AuthError("invalid device token");
  await sql`UPDATE devices SET last_seen_at = now() WHERE id = ${rows[0].id}`;
  return { accountId: rows[0].account_id, deviceId: rows[0].id };
}
