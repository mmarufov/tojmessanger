import { createCipheriv, createDecipheriv, createHmac, randomBytes, timingSafeEqual } from "node:crypto";

// Encryption-at-rest for cloud message bodies (Company A: server CAN decrypt, but disk is never
// plaintext). AES-256-GCM, key_id + random 96-bit nonce + MANDATORY AAD binding the ciphertext to
// its (dialog, msg, sender) slot so rows can't be relocated (review S1).
// M3 dev: one key from env; production replaces with a KMS + per-account wrapping.

const KEY_ID = "dev-v1";
const TAG_LEN = 16;

function requireOrDev(envName: string, devByte: number): Buffer {
  const b64 = process.env[envName];
  if (b64) return Buffer.from(b64, "base64");
  if (process.env.NODE_ENV === "production") throw new Error(`${envName} required in production`);
  return Buffer.alloc(32, devByte); // deterministic dev-only key; NEVER ships to prod
}

const MESSAGE_KEYS: Record<string, Buffer> = { [KEY_ID]: requireOrDev("TOJ_MESSAGE_KEY", 0x07) };
const HMAC_KEY = requireOrDev("TOJ_HMAC_KEY", 0x0b);

export type Sealed = { keyId: string; nonce: Buffer; ciphertext: Buffer };

export function seal(plaintext: Buffer | string, aad: Buffer): Sealed {
  const key = MESSAGE_KEYS[KEY_ID];
  const nonce = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", key, nonce);
  cipher.setAAD(aad);
  const pt = typeof plaintext === "string" ? Buffer.from(plaintext, "utf8") : plaintext;
  const enc = Buffer.concat([cipher.update(pt), cipher.final()]);
  return { keyId: KEY_ID, nonce, ciphertext: Buffer.concat([enc, cipher.getAuthTag()]) };
}

export function open(sealed: Sealed, aad: Buffer): Buffer {
  const key = MESSAGE_KEYS[sealed.keyId];
  if (!key) throw new Error(`unknown key_id ${sealed.keyId}`);
  const { ciphertext, nonce } = sealed;
  const tag = ciphertext.subarray(ciphertext.length - TAG_LEN);
  const enc = ciphertext.subarray(0, ciphertext.length - TAG_LEN);
  const d = createDecipheriv("aes-256-gcm", key, nonce);
  d.setAAD(aad);
  d.setAuthTag(tag);
  return Buffer.concat([d.update(enc), d.final()]);
}

/** Binds a message body to its exact slot; any mismatch fails GCM verification. */
export function bodyAAD(dialogId: string, msgId: number | bigint, senderId: string): Buffer {
  return Buffer.from(`toj/msg|${dialogId}|${msgId}|${senderId}`, "utf8");
}
export const PHONE_AAD = Buffer.from("toj/phone", "utf8");

export function normalizePhone(p: string): string {
  return p.replace(/[^\d+]/g, "");
}
export function phoneLookupHash(e164: string): Buffer {
  return createHmac("sha256", HMAC_KEY).update(normalizePhone(e164)).digest();
}
export function codeHash(code: string): Buffer {
  return createHmac("sha256", HMAC_KEY).update(code).digest();
}
export function hashToken(token: string): Buffer {
  return createHmac("sha256", HMAC_KEY).update(token).digest();
}
export function constantTimeEqual(a: Buffer, b: Buffer): boolean {
  return a.length === b.length && timingSafeEqual(a, b);
}
