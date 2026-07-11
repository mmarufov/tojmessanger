import type { SQL } from "bun";
import {
  connect,
  constants,
  type ClientHttp2Session,
  type IncomingHttpHeaders,
} from "node:http2";
import { createPrivateKey, sign } from "node:crypto";
import { hashToken, open, pushTokenAAD, seal } from "./crypto";

export type PushEnvironment = "sandbox" | "production";

export class PushError extends Error {}

const TOKEN_MIN_BYTES = 16;
const TOKEN_MAX_BYTES = 512;
const MAX_ATTEMPTS = 8;
const CLAIM_TIMEOUT_SECONDS = 5 * 60;

function normalizeDeviceToken(value: string): string {
  const token = value.trim().toLowerCase();
  if (!/^[0-9a-f]+$/.test(token) || token.length % 2 !== 0) {
    throw new PushError("invalid APNs device token");
  }
  const bytes = token.length / 2;
  if (bytes < TOKEN_MIN_BYTES || bytes > TOKEN_MAX_BYTES) {
    throw new PushError("invalid APNs device token length");
  }
  return token;
}

function validateEnvironment(value: string): PushEnvironment {
  if (value === "sandbox" || value === "production") return value;
  throw new PushError("invalid APNs environment");
}

export async function registerPushToken(
  sql: SQL,
  deviceId: string,
  rawToken: string,
  rawEnvironment: string,
): Promise<{ registered: true }> {
  const token = normalizeDeviceToken(rawToken);
  const environment = validateEnvironment(rawEnvironment);
  const tokenHash = hashToken(`apns|${environment}|${token}`);
  const registrationLock = tokenHash.readBigInt64BE(0);
  const sealed = seal(token, pushTokenAAD(deviceId));

  await sql.begin(async (tx) => {
    // Serialize ownership changes for this token, then lock every affected device in stable UUID
    // order. The ordering also prevents two concurrent token swaps from deadlocking.
    await tx`SELECT pg_advisory_xact_lock(${registrationLock})`;
    const devices = await tx`
      SELECT id, platform, revoked_at FROM devices
      WHERE id = ${deviceId}
         OR (push_environment = ${environment} AND push_token_hash = ${tokenHash})
      ORDER BY id
      FOR UPDATE`;
    const device = devices.find((row) => row.id === deviceId);
    if (!device || device.platform !== "ios" || device.revoked_at) {
      throw new PushError("active iOS device required");
    }

    // APNs can reassign a token after restore/reinstall. Transfer ownership atomically instead of
    // letting a stale device keep receiving another installation's notifications.
    await tx`
      UPDATE devices SET
        push_token_hash = NULL,
        push_token_ciphertext = NULL,
        push_token_nonce = NULL,
        push_token_key_id = NULL,
        push_environment = NULL,
        push_updated_at = now()
      WHERE id <> ${deviceId}
        AND push_environment = ${environment}
        AND push_token_hash = ${tokenHash}`;

    await tx`
      UPDATE devices SET
        push_token_hash = ${tokenHash},
        push_token_ciphertext = ${sealed.ciphertext},
        push_token_nonce = ${sealed.nonce},
        push_token_key_id = ${sealed.keyId},
        push_environment = ${environment},
        push_updated_at = now()
      WHERE id = ${deviceId}`;
  });
  return { registered: true };
}

export async function unregisterPushToken(sql: SQL, deviceId: string): Promise<{ registered: false }> {
  await sql`
    UPDATE devices SET
      push_token_hash = NULL,
      push_token_ciphertext = NULL,
      push_token_nonce = NULL,
      push_token_key_id = NULL,
      push_environment = NULL,
      push_updated_at = now()
    WHERE id = ${deviceId}`;
  return { registered: false };
}

/** Called inside the message transaction, after account_events is inserted. */
export async function enqueuePushDeliveries(sql: SQL, p: {
  accountId: string;
  pts: number;
  senderAccountId: string;
  sourceDeviceId?: string | null;
}): Promise<void> {
  await sql`
    INSERT INTO push_deliveries (account_id, pts, device_id, alert)
    SELECT ${p.accountId}, ${p.pts}, d.id, ${p.accountId !== p.senderAccountId}
    FROM devices d
    WHERE d.account_id = ${p.accountId}
      AND d.platform = 'ios'
      AND d.revoked_at IS NULL
      AND d.push_token_hash IS NOT NULL
      AND d.push_token_ciphertext IS NOT NULL
      AND (${p.sourceDeviceId ?? null}::uuid IS NULL OR d.id <> ${p.sourceDeviceId ?? null})
    ON CONFLICT (account_id, pts, device_id) DO NOTHING`;
}

export type APNsSendRequest = {
  token: string;
  environment: PushEnvironment;
  pts: number;
  alert: boolean;
};

export type APNsSendResult = { status: number; reason?: string; apnsId?: string };

export interface PushSender {
  send(request: APNsSendRequest): Promise<APNsSendResult>;
  close?(): void;
}

export function buildAPNsPayload(request: Pick<APNsSendRequest, "pts" | "alert">): Record<string, unknown> {
  return request.alert
    ? {
        aps: {
          alert: { title: "Toj", body: "New message" },
          sound: "default",
          "content-available": 1,
        },
        toj: { pts: request.pts },
      }
    : { aps: { "content-available": 1 }, toj: { pts: request.pts } };
}

type APNsConfig = {
  teamId: string;
  keyId: string;
  topic: string;
  privateKey: ReturnType<typeof createPrivateKey>;
};

function base64url(value: string | Buffer): string {
  return Buffer.from(value).toString("base64url");
}

export class APNsClient implements PushSender {
  private readonly sessions = new Map<PushEnvironment, ClientHttp2Session>();
  private jwt?: { value: string; issuedAt: number };

  constructor(private readonly config: APNsConfig) {}

  static fromEnvironment(): APNsClient | null {
    const teamId = process.env.TOJ_APNS_TEAM_ID;
    const keyId = process.env.TOJ_APNS_KEY_ID;
    const keyBase64 = process.env.TOJ_APNS_PRIVATE_KEY_BASE64;
    const configured = [teamId, keyId, keyBase64].filter(Boolean).length;
    if (configured === 0) return null;
    if (configured !== 3) {
      throw new PushError("TOJ_APNS_TEAM_ID, TOJ_APNS_KEY_ID, and TOJ_APNS_PRIVATE_KEY_BASE64 must be set together");
    }
    const pem = Buffer.from(keyBase64!, "base64").toString("utf8");
    return new APNsClient({
      teamId: teamId!,
      keyId: keyId!,
      topic: process.env.TOJ_APNS_TOPIC ?? "com.toj.Toj",
      privateKey: createPrivateKey(pem),
    });
  }

  async send(request: APNsSendRequest): Promise<APNsSendResult> {
    const session = this.session(request.environment);
    const payload = buildAPNsPayload(request);

    const response = await new Promise<{ headers: IncomingHttpHeaders; body: string }>((resolve, reject) => {
      const stream = session.request({
        [constants.HTTP2_HEADER_METHOD]: "POST",
        [constants.HTTP2_HEADER_PATH]: `/3/device/${request.token}`,
        authorization: `bearer ${this.providerToken()}`,
        "apns-topic": this.config.topic,
        "apns-push-type": request.alert ? "alert" : "background",
        "apns-priority": request.alert ? "10" : "5",
        "apns-collapse-id": "sync",
        "apns-expiration": String(Math.floor(Date.now() / 1000) + 24 * 60 * 60),
      });
      let headers: IncomingHttpHeaders = {};
      let body = "";
      stream.setEncoding("utf8");
      stream.on("response", (value) => { headers = value; });
      stream.on("data", (chunk) => { body += String(chunk); });
      stream.on("end", () => resolve({ headers, body }));
      stream.on("error", reject);
      stream.setTimeout(10_000, () => stream.destroy(new Error("APNs request timed out")));
      stream.end(JSON.stringify(payload));
    });

    const status = Number(response.headers[constants.HTTP2_HEADER_STATUS] ?? 0);
    let reason: string | undefined;
    if (response.body) {
      try { reason = JSON.parse(response.body).reason; } catch { reason = response.body.slice(0, 200); }
    }
    const apnsId = String(response.headers["apns-id"] ?? "") || undefined;
    return { status, reason, apnsId };
  }

  close(): void {
    for (const session of this.sessions.values()) session.close();
    this.sessions.clear();
  }

  private session(environment: PushEnvironment): ClientHttp2Session {
    const existing = this.sessions.get(environment);
    if (existing && !existing.closed && !existing.destroyed) return existing;
    const origin = environment === "production"
      ? "https://api.push.apple.com"
      : "https://api.sandbox.push.apple.com";
    const session = connect(origin);
    this.sessions.set(environment, session);
    const discard = () => {
      if (this.sessions.get(environment) === session) this.sessions.delete(environment);
    };
    session.on("error", discard);
    session.on("goaway", () => { discard(); session.close(); });
    session.on("close", discard);
    return session;
  }

  private providerToken(): string {
    const now = Math.floor(Date.now() / 1000);
    if (this.jwt && now - this.jwt.issuedAt < 50 * 60) return this.jwt.value;
    const header = base64url(JSON.stringify({ alg: "ES256", kid: this.config.keyId }));
    const claims = base64url(JSON.stringify({ iss: this.config.teamId, iat: now }));
    const input = `${header}.${claims}`;
    const signature = sign("sha256", Buffer.from(input), {
      key: this.config.privateKey,
      dsaEncoding: "ieee-p1363",
    });
    const value = `${input}.${signature.toString("base64url")}`;
    this.jwt = { value, issuedAt: now };
    return value;
  }
}

type ClaimedDelivery = {
  id: string;
  device_id: string;
  pts: number | bigint;
  alert: boolean;
  attempts: number;
  expires_at: Date | string;
  push_token_ciphertext: Uint8Array | null;
  push_token_nonce: Uint8Array | null;
  push_token_key_id: string | null;
  push_environment: PushEnvironment | null;
};

async function claimDeliveries(sql: SQL, limit: number): Promise<ClaimedDelivery[]> {
  await sql`
    UPDATE push_deliveries SET status = 'dead', last_error = 'expired'
    WHERE status IN ('pending','sending') AND expires_at <= now()`;
  return await sql`
    WITH picked AS (
      SELECT id FROM push_deliveries
      WHERE expires_at > now()
        AND (
          (status = 'pending' AND available_at <= now())
          OR (status = 'sending' AND claimed_at < now() - (${CLAIM_TIMEOUT_SECONDS} * interval '1 second'))
        )
      ORDER BY available_at, created_at
      FOR UPDATE SKIP LOCKED
      LIMIT ${limit}
    )
    UPDATE push_deliveries pd SET status = 'sending', claimed_at = now()
    FROM picked, devices d
    WHERE pd.id = picked.id AND d.id = pd.device_id
    RETURNING pd.id, pd.device_id, pd.pts, pd.alert, pd.attempts, pd.expires_at,
              d.push_token_ciphertext, d.push_token_nonce, d.push_token_key_id,
              d.push_environment` as ClaimedDelivery[];
}

function retryable(status: number, reason?: string): boolean {
  return status === 0
    || status === 429
    || status >= 500
    || (status === 403 && ["ExpiredProviderToken", "InvalidProviderToken", "MissingProviderToken"].includes(reason ?? ""))
    || reason === "DeviceTokenNotForTopic";
}

function invalidDeviceToken(status: number, reason?: string): boolean {
  return status === 410 || reason === "BadDeviceToken" || reason === "Unregistered";
}

function cleanError(value: unknown): string {
  const message = value instanceof Error ? value.message : String(value);
  return message.replace(/[\r\n]+/g, " ").slice(0, 500);
}

async function retryOrKill(sql: SQL, delivery: ClaimedDelivery, error: string): Promise<void> {
  const attempts = Number(delivery.attempts) + 1;
  const expired = new Date(delivery.expires_at).getTime() <= Date.now();
  if (attempts >= MAX_ATTEMPTS || expired) {
    await sql`
      UPDATE push_deliveries
      SET status = 'dead', attempts = ${attempts}, last_error = ${error}, claimed_at = NULL
      WHERE id = ${delivery.id}`;
    return;
  }
  const delaySeconds = Math.min(5 * 60, 2 ** Math.min(attempts, 8));
  await sql`
    UPDATE push_deliveries
    SET status = 'pending', attempts = ${attempts}, last_error = ${error}, claimed_at = NULL,
        available_at = now() + (${delaySeconds} * interval '1 second')
    WHERE id = ${delivery.id}`;
}

export async function processPushBatch(sql: SQL, sender: PushSender, limit = 50): Promise<number> {
  const deliveries = await claimDeliveries(sql, limit);
  for (const delivery of deliveries) {
    if (!delivery.push_token_ciphertext || !delivery.push_token_nonce
      || !delivery.push_token_key_id || !delivery.push_environment) {
      await sql`
        UPDATE push_deliveries SET status = 'dead', last_error = 'device token unavailable', claimed_at = NULL
        WHERE id = ${delivery.id}`;
      continue;
    }

    let token: string;
    try {
      token = open({
        keyId: delivery.push_token_key_id,
        nonce: Buffer.from(delivery.push_token_nonce),
        ciphertext: Buffer.from(delivery.push_token_ciphertext),
      }, pushTokenAAD(delivery.device_id)).toString("utf8");
    } catch (error) {
      await sql`
        UPDATE push_deliveries SET status = 'dead', last_error = ${cleanError(error)}, claimed_at = NULL
        WHERE id = ${delivery.id}`;
      continue;
    }

    try {
      const result = await sender.send({
        token,
        environment: delivery.push_environment,
        pts: Number(delivery.pts),
        alert: delivery.alert,
      });
      if (result.status === 200) {
        await sql`
          UPDATE push_deliveries
          SET status = 'sent', sent_at = now(), apns_id = ${result.apnsId ?? null},
              last_error = NULL, claimed_at = NULL
          WHERE id = ${delivery.id}`;
      } else if (invalidDeviceToken(result.status, result.reason)) {
        const sentTokenHash = hashToken(`apns|${delivery.push_environment}|${token}`);
        await sql.begin(async (tx) => {
          // APNs may answer after iOS has already rotated this device to a new token. Only clear
          // the token that produced this response; a stale Unregistered response must not erase
          // the replacement registration.
          await tx`
            UPDATE devices SET
              push_token_hash = NULL, push_token_ciphertext = NULL, push_token_nonce = NULL,
              push_token_key_id = NULL, push_environment = NULL, push_updated_at = now()
            WHERE id = ${delivery.device_id} AND push_token_hash = ${sentTokenHash}`;
          await tx`
            UPDATE push_deliveries
            SET status = 'dead', attempts = attempts + 1,
                last_error = ${cleanError(result.reason ?? `APNs ${result.status}`)}, claimed_at = NULL
            WHERE id = ${delivery.id}`;
        });
      } else if (retryable(result.status, result.reason)) {
        await retryOrKill(sql, delivery, cleanError(result.reason ?? `APNs ${result.status}`));
      } else {
        await sql`
          UPDATE push_deliveries
          SET status = 'dead', attempts = attempts + 1,
              last_error = ${cleanError(result.reason ?? `APNs ${result.status}`)}, claimed_at = NULL
          WHERE id = ${delivery.id}`;
      }
    } catch (error) {
      await retryOrKill(sql, delivery, cleanError(error));
    }
  }
  return deliveries.length;
}

export function startPushWorker(sql: SQL, sender: PushSender | null, intervalMs = 2_000): () => void {
  if (!sender) return () => {};
  let running = false;
  const tick = async () => {
    if (running) return;
    running = true;
    try {
      while (await processPushBatch(sql, sender) > 0) { /* drain ready work */ }
    } catch (error) {
      console.error(new Date().toISOString(), "push.worker.error", cleanError(error));
    } finally {
      running = false;
    }
  };
  void tick();
  const timer = setInterval(() => { void tick(); }, intervalMs);
  timer.unref?.();
  return () => { clearInterval(timer); sender.close?.(); };
}
