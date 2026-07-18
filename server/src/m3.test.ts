import { beforeEach, describe, expect, test } from "bun:test";
import { makeSql } from "./db";
import {
  startVerification,
  checkVerification,
  lookupAccountByPhone,
  getProfile,
  updateProfile,
  startAccountDeletion,
  deleteAccount,
  resolveDevice,
  revokeDevice,
  AuthError,
  type OTPDelivery,
} from "./auth";
import { bodyAAD, hashToken, mediaFileNameAAD, open, pushTokenAAD } from "./crypto";
import { CLOUD_CAPABILITIES, startCloudServer } from "./cloud";
import { cleanupExpiredData, OperationalMetrics, requestIdFrom, safeRoute } from "./ops";
import {
  buildAPNsPayload,
  processPushBatch,
  registerPushToken,
  type APNsSendRequest,
  type APNsSendResult,
  type PushSender,
} from "./push";
import {
  getBootstrapDialogsPage,
  getDifference,
  getHistory,
  getOrCreateDirectDialog,
  readHistory,
  sendMessage,
  editMessage,
  deleteMessage,
  setReaction,
  startBootstrap,
} from "./sync";
import {
  cancelMediaUpload,
  completeMediaUpload,
  createMediaUpload,
  downloadMediaChunk,
  DEFAULT_MEDIA_CHUNK_BYTES,
  getMediaUpload,
  MEDIA_PART_SIZE,
  mediaLimits,
  MediaError,
  uploadMediaChunk,
  uploadMediaPart,
  uploadMediaThumbnail,
} from "./media";
import { createHash } from "node:crypto";

const TEST_URL = process.env.TEST_DATABASE_URL ?? "postgres://localhost:5432/toj_test";
const db = makeSql(TEST_URL);

async function resetDb() {
  await db`
    TRUNCATE
      user_reports,
      content_access_audit,
      bootstrap_snapshot_dialogs,
      bootstrap_snapshots,
      message_mutation_requests,
      message_reactions,
      send_requests,
      push_deliveries,
      account_events,
      messages,
      media_chunks,
      media_objects,
      media_upload_attempts,
      contact_lookup_attempts,
      dialog_members,
      direct_dialog_pairs,
      dialogs,
      devices,
      account_sync_states,
      accounts,
      otp_challenges
    RESTART IDENTITY CASCADE`;
}

async function makeAccount(phone: string, name: string) {
  const { code } = await startVerification(db, phone);
  return await checkVerification(db, phone, code, "ios", "Test iPhone", name);
}

function testPhone(suffix: number): string {
  return ["+", "1650", "555", String(suffix).padStart(4, "0")].join("");
}

function tinyJpeg(width = 1, height = 1): Buffer {
  return Buffer.from([
    0xff, 0xd8,
    0xff, 0xc0, 0x00, 0x11, 0x08,
    (height >>> 8) & 0xff, height & 0xff,
    (width >>> 8) & 0xff, width & 0xff,
    0x03, 0x01, 0x11, 0x00, 0x02, 0x11, 0x00, 0x03, 0x11, 0x00,
    0xff, 0xd9,
  ]);
}

function tinyPng(width = 1, height = 1): Buffer {
  const bytes = Buffer.alloc(24);
  Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]).copy(bytes, 0);
  bytes.writeUInt32BE(13, 8);
  bytes.write("IHDR", 12, "ascii");
  bytes.writeUInt32BE(width, 16);
  bytes.writeUInt32BE(height, 20);
  return bytes;
}

async function addIOSDevice(accountId: string): Promise<{ deviceId: string }> {
  const authTokenHash = hashToken(crypto.randomUUID());
  const row = (await db`
    INSERT INTO devices (account_id, platform, device_name, auth_token_hash)
    VALUES (${accountId}, 'ios', 'Test iPhone', ${authTokenHash})
    RETURNING id`)[0];
  return { deviceId: row.id };
}

class StubPushSender implements PushSender {
  requests: APNsSendRequest[] = [];

  constructor(private readonly responses: APNsSendResult[]) {}

  async send(request: APNsSendRequest): Promise<APNsSendResult> {
    this.requests.push(request);
    return this.responses.shift() ?? { status: 200 };
  }
}

class RotatingPushSender implements PushSender {
  constructor(
    private readonly rotate: () => Promise<void>,
    private readonly response: APNsSendResult,
  ) {}

  async send(_request: APNsSendRequest): Promise<APNsSendResult> {
    await this.rotate();
    return this.response;
  }
}

class FailingOTPDelivery implements OTPDelivery {
  async send(_phone: string, _code: string, _purpose: "login" | "account_deletion"): Promise<void> {
    throw new Error("provider unavailable");
  }
}

async function makePair() {
  const alice = await makeAccount("+16505550100", "Alice");
  const bob = await makeAccount("+16505550101", "Bob");
  const direct = await getOrCreateDirectDialog(db, alice.accountId, bob.accountId);
  return { alice, bob, dialogId: direct.dialogId };
}

describe("M3 cloud sync", () => {
  test("media uploads default to one-megabyte WAN chunks", () => {
    expect(DEFAULT_MEDIA_CHUNK_BYTES).toBe(1024 * 1024);
  });

  beforeEach(resetDb);

  test("phone OTP creates an account, device, and sync state", async () => {
    const alice = await makeAccount("+16505550110", "Alice");
    expect(alice.accountId).toBeString();
    expect(alice.deviceId).toBeString();
    expect(alice.token.length).toBeGreaterThan(20);

    const state = (await db`SELECT pts, pruned_through_pts FROM account_sync_states WHERE account_id = ${alice.accountId}`)[0];
    expect(Number(state.pts)).toBe(0);
    expect(Number(state.pruned_through_pts)).toBe(0);
  });

  test("OTP requests enforce cooldown and store a per-challenge salt", async () => {
    const phone = testPhone(120);
    const first = await startVerification(db, phone, { networkKey: "test-network" });
    expect(first.code).toMatch(/^\d{6}$/);
    expect(first.retryAfter).toBe(30);
    const stored = (await db`
      SELECT code_salt, network_hash FROM otp_challenges`)[0];
    expect(Buffer.from(stored.code_salt)).toHaveLength(16);
    expect(stored.network_hash).not.toBeNull();

    let error: unknown;
    try {
      await startVerification(db, phone, { networkKey: "test-network" });
    } catch (value) {
      error = value;
    }
    expect(error).toBeInstanceOf(AuthError);
    expect((error as AuthError).status).toBe(429);
    expect((error as AuthError).retryAfter).toBeGreaterThan(0);
  });

  test("OTP request windows cap phone and network abuse", async () => {
    const phone = testPhone(130);
    for (let request = 0; request < 5; request += 1) {
      await startVerification(db, phone, { networkKey: "phone-limit-network" });
      await db`
        UPDATE otp_challenges SET created_at = created_at - interval '31 seconds'
        WHERE id = (SELECT id FROM otp_challenges ORDER BY created_at DESC LIMIT 1)`;
    }
    let phoneError: unknown;
    try { await startVerification(db, phone, { networkKey: "phone-limit-network" }); }
    catch (value) { phoneError = value; }
    expect(phoneError).toBeInstanceOf(AuthError);
    expect((phoneError as AuthError).status).toBe(429);

    await resetDb();
    for (let request = 0; request < 20; request += 1) {
      await startVerification(db, testPhone(200 + request), { networkKey: "shared-network" });
    }
    let networkError: unknown;
    try { await startVerification(db, testPhone(220), { networkKey: "shared-network" }); }
    catch (value) { networkError = value; }
    expect(networkError).toBeInstanceOf(AuthError);
    expect((networkError as AuthError).status).toBe(429);
  });

  test("production refuses to issue an OTP without a delivery adapter", async () => {
    const previous = process.env.NODE_ENV;
    const previousReturnOTP = process.env.TOJ_RETURN_OTP;
    process.env.NODE_ENV = "production";
    delete process.env.TOJ_RETURN_OTP;
    let error: unknown;
    try { await startVerification(db, testPhone(131)); }
    catch (value) { error = value; }
    finally {
      if (previous === undefined) delete process.env.NODE_ENV;
      else process.env.NODE_ENV = previous;
      if (previousReturnOTP === undefined) delete process.env.TOJ_RETURN_OTP;
      else process.env.TOJ_RETURN_OTP = previousReturnOTP;
    }
    expect(error).toBeInstanceOf(AuthError);
    expect((error as AuthError).status).toBe(503);
    expect(await db`SELECT id FROM otp_challenges`).toHaveLength(0);
  });

  test("private-beta OTP return requires the explicit switch and production phone allowlist", async () => {
    const previousNodeEnv = process.env.NODE_ENV;
    const previousReturnOTP = process.env.TOJ_RETURN_OTP;
    const previousAllowlist = process.env.TOJ_DEV_OTP_ALLOWLIST;
    process.env.NODE_ENV = "production";
    process.env.TOJ_RETURN_OTP = "1";
    delete process.env.TOJ_DEV_OTP_ALLOWLIST;
    const phone = testPhone(132);
    try {
      await expect(startVerification(db, phone)).rejects.toMatchObject({ status: 503 });
      process.env.TOJ_DEV_OTP_ALLOWLIST = phone;
      const issued = await startVerification(db, phone);
      expect(issued.code).toMatch(/^\d{6}$/);
      expect(issued.retryAfter).toBe(30);
    } finally {
      if (previousNodeEnv === undefined) delete process.env.NODE_ENV;
      else process.env.NODE_ENV = previousNodeEnv;
      if (previousReturnOTP === undefined) delete process.env.TOJ_RETURN_OTP;
      else process.env.TOJ_RETURN_OTP = previousReturnOTP;
      if (previousAllowlist === undefined) delete process.env.TOJ_DEV_OTP_ALLOWLIST;
      else process.env.TOJ_DEV_OTP_ALLOWLIST = previousAllowlist;
    }
  });

  test("wrong OTP attempts persist and lock the challenge", async () => {
    const phone = testPhone(121);
    const { code } = await startVerification(db, phone);
    const wrongCode = code === "000000" ? "000001" : "000000";
    for (let attempt = 0; attempt < 5; attempt += 1) {
      try { await checkVerification(db, phone, wrongCode); } catch { /* expected */ }
    }
    expect(Number((await db`SELECT attempts FROM otp_challenges`)[0].attempts)).toBe(5);
    let error: unknown;
    try { await checkVerification(db, phone, code!); } catch (value) { error = value; }
    expect(error).toBeInstanceOf(AuthError);
    expect((error as AuthError).status).toBe(429);
  });

  test("a verification code can create only one session under concurrency", async () => {
    const phone = testPhone(122);
    const { code } = await startVerification(db, phone);
    const results = await Promise.allSettled([
      checkVerification(db, phone, code!),
      checkVerification(db, phone, code!),
    ]);
    expect(results.filter((result) => result.status === "fulfilled")).toHaveLength(1);
    expect(results.filter((result) => result.status === "rejected")).toHaveLength(1);
    expect(await db`SELECT id FROM devices`).toHaveLength(1);
  });

  test("account deletion requires a purpose-bound fresh code and erases identity", async () => {
    const phone = testPhone(133);
    const alice = await makeAccount(phone, "Alice Personal Name");
    const bob = await makeAccount(testPhone(134), "Bob");
    const secondDevice = await addIOSDevice(alice.accountId);
    await registerPushToken(db, secondDevice.deviceId, "88".repeat(32), "sandbox");
    const dialog = await getOrCreateDirectDialog(db, alice.accountId, bob.accountId);
    await sendMessage(db, {
      senderAccountId: alice.accountId,
      senderDeviceId: alice.deviceId,
      dialogId: dialog.dialogId,
      clientMsgId: crypto.randomUUID(),
      body: "history remains for the other participant",
    });

    const original = (await db`
      SELECT phone_lookup_hash, phone_e164_ciphertext FROM accounts WHERE id = ${alice.accountId}`)[0];
    const deletion = await startAccountDeletion(db, alice.accountId);
    expect(deletion.code).toMatch(/^\d{6}$/);
    const activeChallenge = (await db`
      SELECT purpose FROM otp_challenges WHERE consumed_at IS NULL`)[0];
    expect(activeChallenge.purpose).toBe("account_deletion");

    let loginError: unknown;
    try { await checkVerification(db, phone, deletion.code!, "ios", "Wrong purpose", "Alice"); }
    catch (error) { loginError = error; }
    expect(loginError).toBeInstanceOf(AuthError);
    expect(await db`SELECT id FROM devices WHERE account_id = ${alice.accountId}`).toHaveLength(2);

    const result = await deleteAccount(db, alice.accountId, deletion.code!);
    expect(result).toEqual({ deleted: true });
    const deleted = (await db`
      SELECT phone_lookup_hash, phone_e164_ciphertext, display_name, status
      FROM accounts WHERE id = ${alice.accountId}`)[0];
    expect(deleted.status).toBe("deleted");
    expect(deleted.display_name).toBe("Deleted Account");
    expect(Buffer.from(deleted.phone_lookup_hash).equals(Buffer.from(original.phone_lookup_hash))).toBe(false);
    expect(Buffer.from(deleted.phone_e164_ciphertext).includes(Buffer.from(phone))).toBe(false);
    expect(await db`
      SELECT id FROM devices WHERE account_id = ${alice.accountId} AND revoked_at IS NULL`).toHaveLength(0);
    const erasedDevice = (await db`
      SELECT push_token_hash, device_name FROM devices WHERE id = ${secondDevice.deviceId}`)[0];
    expect(erasedDevice.push_token_hash).toBeNull();
    expect(erasedDevice.device_name).toBeNull();
    expect(await db`SELECT id FROM otp_challenges WHERE phone_lookup_hash = ${Buffer.from(original.phone_lookup_hash)}`)
      .toHaveLength(0);
    expect(await lookupAccountByPhone(db, bob.accountId, phone)).toBeNull();
    await expect(resolveDevice(db, alice.token)).rejects.toBeInstanceOf(AuthError);
    await expect(sendMessage(db, {
      senderAccountId: alice.accountId,
      senderDeviceId: alice.deviceId,
      dialogId: dialog.dialogId,
      clientMsgId: crypto.randomUUID(),
      body: "must not send after deletion",
    })).rejects.toThrow("account unavailable");
    expect((await getHistory(db, bob.accountId, dialog.dialogId)).messages.map((message) => message.text))
      .toContain("history remains for the other participant");

    const replacement = await makeAccount(phone, "New Alice");
    expect(replacement.accountId).not.toBe(alice.accountId);
  });

  test("concurrent account deletion consumes one code once and never partially deletes", async () => {
    const phone = testPhone(135);
    const account = await makeAccount(phone, "Concurrency");
    const { code } = await startAccountDeletion(db, account.accountId);
    const wrong = code === "000000" ? "000001" : "000000";
    let wrongError: unknown;
    try { await deleteAccount(db, account.accountId, wrong); } catch (error) { wrongError = error; }
    expect(wrongError).toBeInstanceOf(AuthError);
    expect((wrongError as AuthError).status).toBe(400);
    expect(Number((await db`
      SELECT attempts FROM otp_challenges WHERE purpose = 'account_deletion'`)[0].attempts)).toBe(1);
    expect((await db`SELECT status FROM accounts WHERE id = ${account.accountId}`)[0].status).toBe("active");

    const results = await Promise.allSettled([
      deleteAccount(db, account.accountId, code!),
      deleteAccount(db, account.accountId, code!),
    ]);
    expect(results.filter((result) => result.status === "fulfilled")).toHaveLength(1);
    expect(results.filter((result) => result.status === "rejected")).toHaveLength(1);
    expect((await db`SELECT status FROM accounts WHERE id = ${account.accountId}`)[0].status).toBe("deleted");
    expect(await db`
      SELECT id FROM devices WHERE account_id = ${account.accountId} AND revoked_at IS NULL`).toHaveLength(0);
  });

  test("account deletion HTTP flow requires auth and invalidates the session", async () => {
    const server = startCloudServer(0, db, null, null);
    const base = `http://127.0.0.1:${server.port}`;
    try {
      const account = await makeAccount(testPhone(136), "HTTP Delete");
      const unauthorized = await fetch(`${base}/v1/account/deletion/start`, { method: "POST" });
      expect(unauthorized.status).toBe(401);
      const started = await fetch(`${base}/v1/account/deletion/start`, {
        method: "POST",
        headers: { authorization: `Bearer ${account.token}` },
      });
      expect(started.status).toBe(200);
      const { code } = await started.json() as { code: string };
      const deleted = await fetch(`${base}/v1/account`, {
        method: "DELETE",
        headers: { authorization: `Bearer ${account.token}`, "content-type": "application/json" },
        body: JSON.stringify({ code }),
      });
      expect(deleted.status).toBe(200);
      expect(await deleted.json()).toEqual({ deleted: true });
      const oldSession = await fetch(`${base}/v1/devices`, {
        headers: { authorization: `Bearer ${account.token}` },
      });
      expect(oldSession.status).toBe(401);
    } finally {
      await server.stop(true);
    }
  });

  test("cloud auth maps throttles and accepts WebSocket bearer tokens only in headers", async () => {
    const server = startCloudServer(0, db, null, null);
    const base = `http://127.0.0.1:${server.port}`;
    try {
      const invalid = await fetch(`${base}/v1/auth/start`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ phone: "invalid" }),
      });
      expect(invalid.status).toBe(400);
      expect(invalid.headers.get("cache-control")).toBe("no-store");

      const session = await makeAccount(testPhone(124), "Alice");
      const extraDevice = await addIOSDevice(session.accountId);
      const queryToken = await fetch(`${base}/v1/ws?token=${encodeURIComponent(session.token)}`);
      expect(queryToken.status).toBe(401);
      let legacyQueryToken: Response;
      try {
        process.env.TOJ_ALLOW_LEGACY_WS_QUERY_TOKEN = "1";
        legacyQueryToken = await fetch(`${base}/v1/ws?token=${encodeURIComponent(session.token)}`);
      } finally {
        delete process.env.TOJ_ALLOW_LEGACY_WS_QUERY_TOKEN;
      }
      expect(legacyQueryToken.status).toBe(400);
      const headerToken = await fetch(`${base}/v1/ws`, {
        headers: { authorization: `Bearer ${session.token}` },
      });
      expect(headerToken.status).toBe(400);

      const devices = await fetch(`${base}/v1/devices`, {
        headers: { authorization: `Bearer ${session.token}` },
      });
      expect(devices.status).toBe(200);
      const deviceBody = await devices.json() as { devices: Array<{ id: string; current: boolean }> };
      expect(deviceBody.devices).toHaveLength(2);
      expect(deviceBody.devices.find((device) => device.id === session.deviceId)?.current).toBe(true);

      const revokeOther = await fetch(`${base}/v1/devices/${extraDevice.deviceId}`, {
        method: "DELETE",
        headers: { authorization: `Bearer ${session.token}` },
      });
      expect(revokeOther.status).toBe(200);
      expect((await db`SELECT revoked_at FROM devices WHERE id = ${extraDevice.deviceId}`)[0].revoked_at).not.toBeNull();

      const revoked = await fetch(`${base}/v1/session`, {
        method: "DELETE",
        headers: { authorization: `Bearer ${session.token}` },
      });
      expect(revoked.status).toBe(200);
      expect(await revoked.json()).toEqual({ revoked: true });
      const afterRevoke = await fetch(`${base}/v1/sync/state`, {
        headers: { authorization: `Bearer ${session.token}` },
      });
      expect(afterRevoke.status).toBe(401);
      expect((await db`SELECT revoked_at FROM devices WHERE id = ${session.deviceId}`)[0].revoked_at).not.toBeNull();
    } finally {
      await server.stop(true);
    }
  });

  test("operations endpoints expose safe readiness, correlation IDs, and protected metrics", async () => {
    const previousMetricsToken = process.env.TOJ_METRICS_TOKEN;
    const previousReturnOTP = process.env.TOJ_RETURN_OTP;
    process.env.TOJ_METRICS_TOKEN = "test-metrics-token";
    delete process.env.TOJ_RETURN_OTP;
    const server = startCloudServer(0, db, null, null);
    const base = `http://127.0.0.1:${server.port}`;
    try {
      const ready = await fetch(`${base}/ready`, { headers: { "x-request-id": "client-request-123" } });
      expect(ready.status).toBe(200);
      expect(ready.headers.get("x-request-id")).toBe("client-request-123");
      expect(await ready.json()).toMatchObject({
        status: "ready", database: "ready", providers: { sms: "disabled", push: "disabled" },
      });

      const unauthorized = await fetch(`${base}/metrics`);
      expect(unauthorized.status).toBe(401);
      expect(await unauthorized.text()).not.toContain("test-metrics-token");

      const metrics = await fetch(`${base}/metrics`, {
        headers: { authorization: "Bearer test-metrics-token" },
      });
      expect(metrics.status).toBe(200);
      const text = await metrics.text();
      expect(text).toContain("toj_http_requests_total");
      expect(text).toContain('route="/ready"');
      expect(text).not.toContain("client-request-123");
    } finally {
      await server.stop(true);
      if (previousMetricsToken === undefined) delete process.env.TOJ_METRICS_TOKEN;
      else process.env.TOJ_METRICS_TOKEN = previousMetricsToken;
      if (previousReturnOTP === undefined) delete process.env.TOJ_RETURN_OTP;
      else process.env.TOJ_RETURN_OTP = previousReturnOTP;
    }
  });

  test("operations sanitize request metadata and cleanup only bounded expired data", async () => {
    const malformed = new Request("https://example.test/v1/devices/private", {
      headers: { "x-request-id": "bad id with spaces" },
    });
    expect(requestIdFrom(malformed)).toMatch(/^[0-9a-f-]{36}$/);
    expect(safeRoute("/v1/devices/00000000-0000-0000-0000-000000000000")).toBe("/v1/devices/:id");
    expect(safeRoute("/private/phone-number")).toBe("unmatched");
    const metrics = new OperationalMetrics();
    metrics.record("GET", "unmatched", 404, 1);
    expect(metrics.render()).not.toContain("phone-number");

    await startVerification(db, testPhone(125));
    await db`UPDATE otp_challenges SET expires_at = now() - interval '25 hours'`;
    const account = await makeAccount(testPhone(126), "Cleanup");
    await startBootstrap(db, account.accountId);
    await db`UPDATE bootstrap_snapshots SET expires_at = now() - interval '1 minute'`;
    await createMediaUpload(db, account.accountId, account.deviceId, {
      kind: "file", contentType: "application/octet-stream", fileName: "expired.bin",
      byteSize: 4, sha256: createHash("sha256").update("test").digest("hex"),
    });
    await db`UPDATE media_objects SET expires_at = now() - interval '1 minute' WHERE status = 'uploading'`;

    const deleted = await cleanupExpiredData(db, 1);
    expect(deleted).toMatchObject({ otp: 1, snapshots: 1, pushDeliveries: 0, mediaUploads: 1 });
    expect(await db`SELECT id FROM bootstrap_snapshots`).toHaveLength(0);
    expect(await db`SELECT id FROM media_objects WHERE status = 'uploading'`).toHaveLength(0);
  });

  test("failed OTP delivery consumes the unusable challenge", async () => {
    let error: unknown;
    const originalConsoleError = console.error;
    const logged: string[] = [];
    console.error = (...parts: unknown[]) => logged.push(parts.map(String).join(" "));
    try {
      await startVerification(db, testPhone(123), { delivery: new FailingOTPDelivery() });
    } catch (value) {
      error = value;
    } finally {
      console.error = originalConsoleError;
    }
    expect(error).toBeInstanceOf(AuthError);
    expect((error as AuthError).status).toBe(503);
    expect((await db`SELECT consumed_at FROM otp_challenges`)[0].consumed_at).not.toBeNull();
    expect(logged.join(" ")).not.toContain("provider unavailable");
    expect(logged.join(" ")).toContain("Error");
  });

  test("APNs token registration encrypts at rest and transfers a reused token", async () => {
    const { alice: first } = await makePair();
    const token = "ab".repeat(32);
    await registerPushToken(db, first.deviceId, token, "sandbox");

    const stored = (await db`
      SELECT push_token_hash, push_token_ciphertext, push_token_nonce, push_token_key_id, push_environment
      FROM devices WHERE id = ${first.deviceId}`)[0];
    expect(stored.push_token_hash).not.toBeNull();
    expect(Buffer.from(stored.push_token_ciphertext).includes(Buffer.from(token))).toBe(false);
    expect(open({
      keyId: stored.push_token_key_id,
      nonce: Buffer.from(stored.push_token_nonce),
      ciphertext: Buffer.from(stored.push_token_ciphertext),
    }, pushTokenAAD(first.deviceId)).toString("utf8")).toBe(token);

    const second = await addIOSDevice(first.accountId);
    await registerPushToken(db, second.deviceId, token.toUpperCase(), "sandbox");
    const rows = await db`
      SELECT id, push_token_hash FROM devices
      WHERE account_id = ${first.accountId} ORDER BY created_at`;
    expect(rows).toHaveLength(2);
    expect(rows.find((row) => row.id === first.deviceId)?.push_token_hash).toBeNull();
    expect(rows.find((row) => row.id === second.deviceId)?.push_token_hash).not.toBeNull();

    let rejected = false;
    try {
      await registerPushToken(db, second.deviceId, "not-a-device-token", "sandbox");
    } catch {
      rejected = true;
    }
    expect(rejected).toBe(true);
  });

  test("concurrent APNs registrations serialize token ownership without a server error", async () => {
    const { alice: first } = await makePair();
    const second = await addIOSDevice(first.accountId);
    const third = await addIOSDevice(first.accountId);
    const token = "cd".repeat(32);

    await Promise.all([
      registerPushToken(db, first.deviceId, token, "sandbox"),
      registerPushToken(db, second.deviceId, token, "sandbox"),
      registerPushToken(db, third.deviceId, token, "sandbox"),
    ]);

    const owners = await db`
      SELECT id FROM devices
      WHERE account_id = ${first.accountId} AND push_token_hash IS NOT NULL`;
    expect(owners).toHaveLength(1);
  });

  test("APNs payload is a generic sync hint with no message metadata", () => {
    const alert = buildAPNsPayload({ pts: 42, alert: true });
    const silent = buildAPNsPayload({ pts: 43, alert: false });
    expect(alert).toEqual({
      aps: {
        alert: { title: "Toj", body: "New message" },
        sound: "default",
        "content-available": 1,
      },
      toj: { pts: 42 },
    });
    expect(silent).toEqual({ aps: { "content-available": 1 }, toj: { pts: 43 } });
    const serialized = JSON.stringify([alert, silent]);
    expect(serialized).not.toContain("dialog");
    expect(serialized).not.toContain("sender");
    expect(serialized).not.toContain("phone");
  });

  test("message commit queues recipient alerts and silent sender-device catch-up", async () => {
    const { alice, bob, dialogId } = await makePair();
    const aliceSecond = await addIOSDevice(alice.accountId);
    await registerPushToken(db, alice.deviceId, "11".repeat(32), "sandbox");
    await registerPushToken(db, aliceSecond.deviceId, "22".repeat(32), "sandbox");
    await registerPushToken(db, bob.deviceId, "33".repeat(32), "sandbox");

    await sendMessage(db, {
      senderAccountId: alice.accountId,
      senderDeviceId: alice.deviceId,
      dialogId,
      clientMsgId: crypto.randomUUID(),
      body: "push me",
    });

    const deliveries = await db`
      SELECT account_id, device_id, alert, status FROM push_deliveries ORDER BY alert, device_id`;
    expect(deliveries).toHaveLength(2);
    expect(deliveries.find((row) => row.device_id === alice.deviceId)).toBeUndefined();
    expect(deliveries.find((row) => row.device_id === aliceSecond.deviceId)?.alert).toBe(false);
    expect(deliveries.find((row) => row.device_id === bob.deviceId)?.alert).toBe(true);
    expect(deliveries.every((row) => row.status === "pending")).toBe(true);
  });

  test("a revoked device cannot commit a message after sign-out", async () => {
    const { alice, dialogId } = await makePair();
    await revokeDevice(db, alice.accountId, alice.deviceId);
    await expect(sendMessage(db, {
      senderAccountId: alice.accountId, senderDeviceId: alice.deviceId,
      dialogId, clientMsgId: crypto.randomUUID(), body: "must not send",
    })).rejects.toThrow("sending device is no longer active");
    expect(await db`SELECT msg_id FROM messages WHERE dialog_id = ${dialogId}`).toHaveLength(0);
  });

  test("push worker marks success and removes an unregistered device token", async () => {
    const { alice, bob, dialogId } = await makePair();
    await registerPushToken(db, bob.deviceId, "44".repeat(32), "sandbox");

    await sendMessage(db, {
      senderAccountId: alice.accountId,
      senderDeviceId: alice.deviceId,
      dialogId,
      clientMsgId: crypto.randomUUID(),
      body: "first",
    });
    const success = new StubPushSender([{ status: 200, apnsId: "apns-ok" }]);
    expect(await processPushBatch(db, success)).toBe(1);
    expect(success.requests).toEqual([{
      token: "44".repeat(32), environment: "sandbox", pts: expect.any(Number), alert: true,
    }]);
    expect((await db`SELECT status, apns_id FROM push_deliveries`)[0]).toMatchObject({
      status: "sent", apns_id: "apns-ok",
    });

    await sendMessage(db, {
      senderAccountId: alice.accountId,
      senderDeviceId: alice.deviceId,
      dialogId,
      clientMsgId: crypto.randomUUID(),
      body: "second",
    });
    const invalid = new StubPushSender([{ status: 410, reason: "Unregistered" }]);
    expect(await processPushBatch(db, invalid)).toBe(1);
    expect((await db`SELECT push_token_hash FROM devices WHERE id = ${bob.deviceId}`)[0].push_token_hash).toBeNull();
    expect((await db`
      SELECT status, last_error FROM push_deliveries ORDER BY created_at DESC LIMIT 1`)[0]).toMatchObject({
      status: "dead", last_error: "Unregistered",
    });
  });

  test("stale APNs rejection cannot erase a rotated token or newer delivery", async () => {
    const { alice, bob, dialogId } = await makePair();
    const oldToken = "66".repeat(32);
    const newToken = "77".repeat(32);
    await registerPushToken(db, bob.deviceId, oldToken, "sandbox");

    await sendMessage(db, {
      senderAccountId: alice.accountId,
      senderDeviceId: alice.deviceId,
      dialogId,
      clientMsgId: crypto.randomUUID(),
      body: "old token delivery",
    });

    const sender = new RotatingPushSender(async () => {
      await registerPushToken(db, bob.deviceId, newToken, "sandbox");
      await sendMessage(db, {
        senderAccountId: alice.accountId,
        senderDeviceId: alice.deviceId,
        dialogId,
        clientMsgId: crypto.randomUUID(),
        body: "new token delivery",
      });
    }, { status: 410, reason: "Unregistered" });

    expect(await processPushBatch(db, sender, 1)).toBe(1);
    const device = (await db`
      SELECT push_token_ciphertext, push_token_nonce, push_token_key_id
      FROM devices WHERE id = ${bob.deviceId}`)[0];
    expect(open({
      keyId: device.push_token_key_id,
      nonce: Buffer.from(device.push_token_nonce),
      ciphertext: Buffer.from(device.push_token_ciphertext),
    }, pushTokenAAD(bob.deviceId)).toString("utf8")).toBe(newToken);

    const deliveries = await db`
      SELECT status, last_error FROM push_deliveries ORDER BY created_at`;
    expect(deliveries).toHaveLength(2);
    expect(deliveries[0]).toMatchObject({ status: "dead", last_error: "Unregistered" });
    expect(deliveries[1]).toMatchObject({ status: "pending", last_error: null });
  });

  test("push worker retries transient APNs failures without dropping the delivery", async () => {
    const { alice, bob, dialogId } = await makePair();
    await registerPushToken(db, bob.deviceId, "55".repeat(32), "production");
    await sendMessage(db, {
      senderAccountId: alice.accountId,
      senderDeviceId: alice.deviceId,
      dialogId,
      clientMsgId: crypto.randomUUID(),
      body: "retry",
    });

    const throttled = new StubPushSender([{ status: 429, reason: "TooManyRequests" }]);
    expect(await processPushBatch(db, throttled)).toBe(1);
    const row = (await db`SELECT status, attempts, available_at, last_error FROM push_deliveries`)[0];
    expect(row.status).toBe("pending");
    expect(Number(row.attempts)).toBe(1);
    expect(new Date(row.available_at).getTime()).toBeGreaterThan(Date.now());
    expect(row.last_error).toBe("TooManyRequests");

    await db`
      UPDATE push_deliveries
      SET status = 'sending', claimed_at = now() - interval '10 minutes', available_at = now()`;
    const recovered = new StubPushSender([{ status: 200 }]);
    expect(await processPushBatch(db, recovered)).toBe(1);
    expect((await db`SELECT status FROM push_deliveries`)[0].status).toBe("sent");
  });

  test("send retries are idempotent and do not burn message ids", async () => {
    const { alice, dialogId } = await makePair();
    const clientMsgId = crypto.randomUUID();

    const first = await sendMessage(db, {
      senderAccountId: alice.accountId,
      senderDeviceId: alice.deviceId,
      dialogId,
      clientMsgId,
      body: "retry once",
    });
    const second = await sendMessage(db, {
      senderAccountId: alice.accountId,
      senderDeviceId: alice.deviceId,
      dialogId,
      clientMsgId,
      body: "retry once",
    });

    expect(first.duplicate).toBe(false);
    expect(second.duplicate).toBe(true);
    expect(second.msgId).toBe(first.msgId);
    expect(second.senderPts).toBe(first.senderPts);
    expect(second.text).toBe("retry once");

    const counts = (await db`
      SELECT d.last_msg_id, count(m.*)::int AS message_count
      FROM dialogs d
      LEFT JOIN messages m ON m.dialog_id = d.id
      WHERE d.id = ${dialogId}
      GROUP BY d.last_msg_id`)[0];
    expect(Number(counts.last_msg_id)).toBe(1);
    expect(Number(counts.message_count)).toBe(1);
  });

  test("replies survive difference, history, and bootstrap contracts", async () => {
    const { alice, bob, dialogId } = await makePair();
    const original = await sendMessage(db, {
      senderAccountId: bob.accountId,
      senderDeviceId: bob.deviceId,
      dialogId,
      clientMsgId: crypto.randomUUID(),
      body: "original",
    });
    const reply = await sendMessage(db, {
      senderAccountId: alice.accountId,
      senderDeviceId: alice.deviceId,
      dialogId,
      clientMsgId: crypto.randomUUID(),
      body: "reply",
      replyToMsgId: original.msgId,
    });

    const difference = await getDifference(db, bob.accountId, 0);
    const replyUpdate = difference.updates.find((update) => update.message?.msg_id === reply.msgId);
    expect(replyUpdate?.message?.reply_to_msg_id).toBe(original.msgId);

    const history = await getHistory(db, alice.accountId, dialogId);
    expect(history.messages.map((message) => [message.text, message.reply_to_msg_id])).toEqual([
      ["original", null],
      ["reply", original.msgId],
    ]);

    const bootstrap = await startBootstrap(db, bob.accountId);
    const page = await getBootstrapDialogsPage(db, bob.accountId, bootstrap.token, { previewMessages: 10 });
    expect(page.dialogs[0].messages.at(-1)?.reply_to_msg_id).toBe(original.msgId);
  });

  test("reactions are idempotent, replaceable, removable, and sync as full message state", async () => {
    const { alice, bob, dialogId } = await makePair();
    const sent = await sendMessage(db, {
      senderAccountId: alice.accountId,
      senderDeviceId: alice.deviceId,
      dialogId,
      clientMsgId: crypto.randomUUID(),
      body: "react to this",
    });
    const mutationId = crypto.randomUUID();
    const [first, retry] = await Promise.all([
      setReaction(db, {
        actorAccountId: bob.accountId,
        actorDeviceId: bob.deviceId,
        dialogId,
        msgId: sent.msgId,
        clientMutationId: mutationId,
        emoji: "❤️",
      }),
      setReaction(db, {
        actorAccountId: bob.accountId,
        actorDeviceId: bob.deviceId,
        dialogId,
        msgId: sent.msgId,
        clientMutationId: mutationId,
        emoji: "❤️",
      }),
    ]);
    expect([first.duplicate, retry.duplicate].sort()).toEqual([false, true]);
    expect(first.actorPts).toBe(retry.actorPts);
    expect(first.message.reactions).toEqual([{ account_id: bob.accountId, emoji: "❤️" }]);

    const replacement = await setReaction(db, {
      actorAccountId: bob.accountId,
      actorDeviceId: bob.deviceId,
      dialogId,
      msgId: sent.msgId,
      clientMutationId: crypto.randomUUID(),
      emoji: "👍",
    });
    expect(replacement.message.reactions).toEqual([{ account_id: bob.accountId, emoji: "👍" }]);

    const difference = await getDifference(db, alice.accountId, 0);
    const reactionUpdates = difference.updates.filter((update) => update.type === "reaction.updated");
    expect(reactionUpdates).toHaveLength(2);
    expect(reactionUpdates.at(-1)?.message?.reactions).toEqual([{ account_id: bob.accountId, emoji: "👍" }]);

    const history = await getHistory(db, alice.accountId, dialogId);
    expect(history.messages[0].reactions).toEqual([{ account_id: bob.accountId, emoji: "👍" }]);
    const bootstrap = await startBootstrap(db, bob.accountId);
    const page = await getBootstrapDialogsPage(db, bob.accountId, bootstrap.token, { previewMessages: 10 });
    expect(page.dialogs[0].messages[0].reactions).toEqual([{ account_id: bob.accountId, emoji: "👍" }]);

    const removed = await setReaction(db, {
      actorAccountId: bob.accountId,
      actorDeviceId: bob.deviceId,
      dialogId,
      msgId: sent.msgId,
      clientMutationId: crypto.randomUUID(),
      emoji: null,
    });
    expect(removed.message.reactions).toEqual([]);
    await revokeDevice(db, bob.accountId, bob.deviceId);
    await expect(setReaction(db, {
      actorAccountId: bob.accountId,
      actorDeviceId: bob.deviceId,
      dialogId,
      msgId: sent.msgId,
      clientMutationId: crypto.randomUUID(),
      emoji: "🔥",
    })).rejects.toMatchObject({ status: 401 });
  });

  test("reactions require membership and a visible message", async () => {
    const { alice, bob, dialogId } = await makePair();
    const charlie = await makeAccount(testPhone(777), "Charlie");
    const sent = await sendMessage(db, {
      senderAccountId: alice.accountId,
      senderDeviceId: alice.deviceId,
      dialogId,
      clientMsgId: crypto.randomUUID(),
      body: "private message",
    });
    await expect(setReaction(db, {
      actorAccountId: charlie.accountId,
      actorDeviceId: charlie.deviceId,
      dialogId,
      msgId: sent.msgId,
      clientMutationId: crypto.randomUUID(),
      emoji: "👀",
    })).rejects.toThrow("not a member");

    await deleteMessage(db, {
      actorAccountId: alice.accountId,
      actorDeviceId: alice.deviceId,
      dialogId,
      msgId: sent.msgId,
      clientMutationId: crypto.randomUUID(),
    });
    await expect(setReaction(db, {
      actorAccountId: bob.accountId,
      actorDeviceId: bob.deviceId,
      dialogId,
      msgId: sent.msgId,
      clientMutationId: crypto.randomUUID(),
      emoji: "👀",
    })).rejects.toThrow("message not found");
  });

  test("forwarding copies authorized visible text with immutable provenance and idempotency", async () => {
    const { alice, bob, dialogId: sourceDialogId } = await makePair();
    const charlie = await makeAccount(testPhone(778), "Charlie");
    const target = await getOrCreateDirectDialog(db, alice.accountId, charlie.accountId);
    const source = await sendMessage(db, {
      senderAccountId: bob.accountId,
      senderDeviceId: bob.deviceId,
      dialogId: sourceDialogId,
      clientMsgId: crypto.randomUUID(),
      body: "useful source text",
    });
    const clientMsgId = crypto.randomUUID();
    const forwarded = await sendMessage(db, {
      senderAccountId: alice.accountId,
      senderDeviceId: alice.deviceId,
      dialogId: target.dialogId,
      clientMsgId,
      forwardedFrom: { dialogId: sourceDialogId, msgId: source.msgId },
    });
    const retry = await sendMessage(db, {
      senderAccountId: alice.accountId,
      senderDeviceId: alice.deviceId,
      dialogId: target.dialogId,
      clientMsgId,
      forwardedFrom: { dialogId: sourceDialogId, msgId: source.msgId },
    });
    expect(forwarded.text).toBe("useful source text");
    expect(retry.duplicate).toBe(true);
    expect(retry.msgId).toBe(forwarded.msgId);

    await editMessage(db, {
      actorAccountId: bob.accountId,
      actorDeviceId: bob.deviceId,
      dialogId: sourceDialogId,
      msgId: source.msgId,
      clientMutationId: crypto.randomUUID(),
      expectedEditVersion: 0,
      body: "changed later",
    });
    const history = await getHistory(db, charlie.accountId, target.dialogId);
    expect(history.messages[0]).toMatchObject({ text: "useful source text", forwarded: true });
    expect(history.messages[0]).not.toHaveProperty("forwarded_from_account_id");
    expect(history.messages[0]).not.toHaveProperty("forwarded_from_dialog_id");
    const provenance = (await db`
      SELECT forwarded_from_account_id, forwarded_from_dialog_id, forwarded_from_msg_id
      FROM messages WHERE dialog_id = ${target.dialogId} AND msg_id = ${forwarded.msgId}`)[0];
    expect(provenance).toMatchObject({
      forwarded_from_account_id: bob.accountId,
      forwarded_from_dialog_id: sourceDialogId,
    });
    expect(Number(provenance.forwarded_from_msg_id)).toBe(source.msgId);
  });

  test("forwarding rejects inaccessible or deleted source messages", async () => {
    const { alice, bob, dialogId: sourceDialogId } = await makePair();
    const charlie = await makeAccount(testPhone(779), "Charlie");
    const target = await getOrCreateDirectDialog(db, charlie.accountId, bob.accountId);
    const source = await sendMessage(db, {
      senderAccountId: alice.accountId,
      senderDeviceId: alice.deviceId,
      dialogId: sourceDialogId,
      clientMsgId: crypto.randomUUID(),
      body: "not Charlie's message",
    });
    await expect(sendMessage(db, {
      senderAccountId: charlie.accountId,
      senderDeviceId: charlie.deviceId,
      dialogId: target.dialogId,
      clientMsgId: crypto.randomUUID(),
      forwardedFrom: { dialogId: sourceDialogId, msgId: source.msgId },
    })).rejects.toThrow("not a member");

    await deleteMessage(db, {
      actorAccountId: alice.accountId,
      actorDeviceId: alice.deviceId,
      dialogId: sourceDialogId,
      msgId: source.msgId,
      clientMutationId: crypto.randomUUID(),
    });
    await expect(sendMessage(db, {
      senderAccountId: bob.accountId,
      senderDeviceId: bob.deviceId,
      dialogId: target.dialogId,
      clientMsgId: crypto.randomUUID(),
      forwardedFrom: { dialogId: sourceDialogId, msgId: source.msgId },
    })).rejects.toThrow("forward source not found");
  });

  test("edits and deletions are idempotent tombstones that sync to every member", async () => {
    const { alice, bob, dialogId } = await makePair();
    const sent = await sendMessage(db, {
      senderAccountId: alice.accountId,
      senderDeviceId: alice.deviceId,
      dialogId,
      clientMsgId: crypto.randomUUID(),
      body: "sensitive original",
    });
    const mutationId = crypto.randomUUID();
    const [firstEdit, retryEdit] = await Promise.all([
      editMessage(db, {
        actorAccountId: alice.accountId,
        actorDeviceId: alice.deviceId,
        dialogId,
        msgId: sent.msgId,
        clientMutationId: mutationId,
        expectedEditVersion: 0,
        body: "corrected",
      }),
      editMessage(db, {
        actorAccountId: alice.accountId,
        actorDeviceId: alice.deviceId,
        dialogId,
        msgId: sent.msgId,
        clientMutationId: mutationId,
        expectedEditVersion: 0,
        body: "corrected",
      }),
    ]);
    expect(firstEdit.actorPts).toBe(retryEdit.actorPts);
    expect([firstEdit.duplicate, retryEdit.duplicate].sort()).toEqual([false, true]);
    expect(firstEdit.message.text).toBe("corrected");
    expect(firstEdit.message.edit_version).toBe(1);

    const deletion = await deleteMessage(db, {
      actorAccountId: alice.accountId,
      actorDeviceId: alice.deviceId,
      dialogId,
      msgId: sent.msgId,
      clientMutationId: crypto.randomUUID(),
    });
    expect(deletion.message.state).toBe("deleted_for_all");
    expect(deletion.message.text).toBe("");

    const bobDifference = await getDifference(db, bob.accountId, 0);
    expect(bobDifference.updates.map((update) => update.type)).toContain("message.edited");
    const tombstone = bobDifference.updates.find((update) => update.type === "message.deleted");
    expect(tombstone?.message?.state).toBe("deleted_for_all");
    expect(tombstone?.message?.text).toBe("");

    const row = (await db`
      SELECT body_key_id, body_nonce, body_ciphertext, sender_account_id
      FROM messages WHERE dialog_id = ${dialogId} AND msg_id = ${sent.msgId}`)[0];
    const liveBody = open({
      keyId: row.body_key_id,
      nonce: Buffer.from(row.body_nonce),
      ciphertext: Buffer.from(row.body_ciphertext),
    }, bodyAAD(dialogId, sent.msgId, row.sender_account_id)).toString("utf8");
    expect(liveBody).toBe("");
  });

  test("only a message sender can edit or delete and stale edits are rejected", async () => {
    const { alice, bob, dialogId } = await makePair();
    const sent = await sendMessage(db, {
      senderAccountId: alice.accountId,
      senderDeviceId: alice.deviceId,
      dialogId,
      clientMsgId: crypto.randomUUID(),
      body: "owned by Alice",
    });

    await expect(editMessage(db, {
      actorAccountId: bob.accountId,
      actorDeviceId: bob.deviceId,
      dialogId,
      msgId: sent.msgId,
      clientMutationId: crypto.randomUUID(),
      expectedEditVersion: 0,
      body: "hijacked",
    })).rejects.toThrow("only the sender");

    await editMessage(db, {
      actorAccountId: alice.accountId,
      actorDeviceId: alice.deviceId,
      dialogId,
      msgId: sent.msgId,
      clientMutationId: crypto.randomUUID(),
      expectedEditVersion: 0,
      body: "version one",
    });
    await expect(editMessage(db, {
      actorAccountId: alice.accountId,
      actorDeviceId: alice.deviceId,
      dialogId,
      msgId: sent.msgId,
      clientMutationId: crypto.randomUUID(),
      expectedEditVersion: 0,
      body: "stale overwrite",
    })).rejects.toThrow("another device");
    await expect(deleteMessage(db, {
      actorAccountId: bob.accountId,
      actorDeviceId: bob.deviceId,
      dialogId,
      msgId: sent.msgId,
      clientMutationId: crypto.randomUUID(),
    })).rejects.toThrow("only the sender");
  });

  test("get_difference catches up in pts order and respects byte slicing", async () => {
    const { alice, bob, dialogId } = await makePair();
    for (let i = 0; i < 4; i++) {
      await sendMessage(db, {
        senderAccountId: alice.accountId,
        senderDeviceId: alice.deviceId,
        dialogId,
        clientMsgId: crypto.randomUUID(),
        body: `message ${i} ${"x".repeat(600)}`,
      });
    }

    const firstSlice = await getDifference(db, bob.accountId, 1, { maxEvents: 20, maxBytes: 900 });
    expect(firstSlice.kind).toBe("difference_slice");
    expect(firstSlice.updates.length).toBeGreaterThanOrEqual(1);

    const rest = await getDifference(db, bob.accountId, firstSlice.state.pts, { maxEvents: 20, maxBytes: 4096 });
    expect(rest.kind).toBe("difference");
    expect(rest.state.pts).toBeGreaterThan(firstSlice.state.pts);
    expect(firstSlice.updates[0].pts).toBeLessThan(rest.updates.at(-1).pts);
  });

  test("a 200-event difference page uses at most four SQL calls", async () => {
    const { alice, bob, dialogId } = await makePair();
    for (let i = 0; i < 200; i++) {
      await sendMessage(db, {
        senderAccountId: alice.accountId,
        senderDeviceId: alice.deviceId,
        dialogId,
        clientMsgId: crypto.randomUUID(),
        body: `bulk message ${i}`,
      });
    }

    let calls = 0;
    const countedDB = new Proxy(db, {
      apply(target, _thisArg, argumentsList) {
        calls += 1;
        return Reflect.apply(target, target, argumentsList);
      },
    });
    const difference = await getDifference(
      countedDB,
      bob.accountId,
      1,
      { maxEvents: 200, maxBytes: 512 * 1024 },
    );

    expect(difference.updates).toHaveLength(200);
    expect(calls).toBeLessThanOrEqual(4);
  });

  test("pruned event floor returns difference_too_long instead of a fake partial catch-up", async () => {
    const { alice, bob, dialogId } = await makePair();
    await sendMessage(db, {
      senderAccountId: alice.accountId,
      senderDeviceId: alice.deviceId,
      dialogId,
      clientMsgId: crypto.randomUUID(),
      body: "old event",
    });
    await db`UPDATE account_sync_states SET pruned_through_pts = 2 WHERE account_id = ${bob.accountId}`;

    const diff = await getDifference(db, bob.accountId, 1);
    expect(diff.kind).toBe("difference_too_long");
  });

  test("bootstrap snapshot does not duplicate or swallow messages sent during onboarding", async () => {
    const { alice, bob, dialogId } = await makePair();
    const aliceCreation = await getDifference(db, alice.accountId, 0);
    const bobCreation = await getDifference(db, bob.accountId, 0);
    expect(aliceCreation.updates.find((u) => u.type === "dialog.created")?.dialog_title).toBe("Bob");
    expect(bobCreation.updates.find((u) => u.type === "dialog.created")?.dialog_title).toBe("Alice");
    await sendMessage(db, {
      senderAccountId: alice.accountId,
      senderDeviceId: alice.deviceId,
      dialogId,
      clientMsgId: crypto.randomUUID(),
      body: "before snapshot",
    });

    const bootstrap = await startBootstrap(db, bob.accountId);

    await sendMessage(db, {
      senderAccountId: alice.accountId,
      senderDeviceId: alice.deviceId,
      dialogId,
      clientMsgId: crypto.randomUUID(),
      body: "after snapshot",
    });

    const page = await getBootstrapDialogsPage(db, bob.accountId, bootstrap.token, { previewMessages: 10 });
    expect(page.state.pts).toBe(bootstrap.state.pts);
    expect(page.dialogs).toHaveLength(1);
    expect(page.dialogs[0].title).toBe("Alice");
    expect(page.dialogs[0].messages.map((m) => m.text)).toEqual(["before snapshot"]);
    expect(page.dialogs[0].unread_count).toBe(1);

    const diff = await getDifference(db, bob.accountId, bootstrap.state.pts);
    expect(diff.kind).toBe("difference");
    expect(diff.updates.map((u) => u.message?.text).filter(Boolean)).toEqual(["after snapshot"]);
  });

  test("history pages load locally decryptable message bodies", async () => {
    const { alice, bob, dialogId } = await makePair();
    await sendMessage(db, {
      senderAccountId: alice.accountId,
      senderDeviceId: alice.deviceId,
      dialogId,
      clientMsgId: crypto.randomUUID(),
      body: "one",
    });
    await sendMessage(db, {
      senderAccountId: bob.accountId,
      senderDeviceId: bob.deviceId,
      dialogId,
      clientMsgId: crypto.randomUUID(),
      body: "two",
    });

    const page = await getHistory(db, alice.accountId, dialogId, { limit: 50 });
    expect(page.messages.map((m) => m.text)).toEqual(["one", "two"]);

    const forwardPage = await getHistory(db, alice.accountId, dialogId, {
      afterMsgId: page.messages[0].msg_id,
      limit: 1,
    });
    expect(forwardPage.messages.map((m) => m.text)).toEqual(["two"]);
    expect(forwardPage.nextBeforeMsgId).toBeUndefined();
  });

  test("read receipts advance member state and emit sync updates", async () => {
    const { alice, bob, dialogId } = await makePair();
    const sent = await sendMessage(db, {
      senderAccountId: alice.accountId,
      senderDeviceId: alice.deviceId,
      dialogId,
      clientMsgId: crypto.randomUUID(),
      body: "read me",
    });

    const read = await readHistory(db, { accountId: bob.accountId, dialogId, maxReadMsgId: sent.msgId });
    expect(read.maxReadMsgId).toBe(sent.msgId);
    expect(read.unreadCount).toBe(0);

    const diff = await getDifference(db, alice.accountId, sent.senderPts);
    expect(diff.kind).toBe("difference");
    expect(diff.updates.some((u) => u.type === "read.updated"
      && u.max_read_msg_id === sent.msgId && u.unread_count === 0)).toBe(true);

    const repeat = await readHistory(db, { accountId: bob.accountId, dialogId, maxReadMsgId: sent.msgId });
    expect(repeat.pushes).toHaveLength(0);
    expect(repeat.unreadCount).toBe(0);
    const afterRepeat = await getDifference(db, alice.accountId, diff.state.pts);
    expect(afterRepeat.kind).toBe("difference");
    expect(afterRepeat.updates).toEqual([]);
  });

  test("message plaintext is not stored on disk", async () => {
    const { alice, dialogId } = await makePair();
    const body = "plaintext must not appear here";
    await sendMessage(db, {
      senderAccountId: alice.accountId,
      senderDeviceId: alice.deviceId,
      dialogId,
      clientMsgId: crypto.randomUUID(),
      body,
    });

    const row = (await db`SELECT encode(body_ciphertext, 'escape') AS ciphertext FROM messages LIMIT 1`)[0];
    expect(String(row.ciphertext)).not.toContain(body);
  });

  test("resumable media is encrypted at rest, idempotent, and downloadable only by members", async () => {
    const { alice, bob, dialogId } = await makePair();
    const outsider = await makeAccount(testPhone(901), "Outsider");
    const bytes = Buffer.from("private-media-payload-that-must-not-be-visible-on-disk");
    const created = await createMediaUpload(db, alice.accountId, alice.deviceId, {
      kind: "file", contentType: "application/octet-stream", fileName: "safe.bin",
      byteSize: bytes.length, sha256: createHash("sha256").update(bytes).digest("hex"),
    });
    const first = bytes.subarray(0, 20);
    const second = bytes.subarray(20);
    expect((await uploadMediaChunk(db, alice.accountId, alice.deviceId, created.mediaId, 0, first)).uploadOffset).toBe(20);
    const retry = await uploadMediaChunk(db, alice.accountId, alice.deviceId, created.mediaId, 0, first);
    expect(retry).toMatchObject({ uploadOffset: 20, duplicate: true });
    await uploadMediaChunk(db, alice.accountId, alice.deviceId, created.mediaId, 20, second);
    await expect(uploadMediaThumbnail(
      db, alice.accountId, alice.deviceId, created.mediaId, "image/jpeg", tinyJpeg(3_000, 3_000),
    )).rejects.toMatchObject({ status: 413 });
    await uploadMediaThumbnail(db, alice.accountId, alice.deviceId, created.mediaId, "image/jpeg", tinyJpeg());

    const stored = await db`SELECT ciphertext, plain_sha256 FROM media_chunks WHERE media_id = ${created.mediaId}`;
    expect(Buffer.concat(stored.map((row) => Buffer.from(row.ciphertext))).includes(bytes)).toBe(false);
    expect(Buffer.from(stored[0].plain_sha256).equals(createHash("sha256").update(first).digest())).toBe(false);
    const fingerprint = (await db`SELECT expected_sha256 FROM media_objects WHERE id = ${created.mediaId}`)[0];
    expect(Buffer.from(fingerprint.expected_sha256).equals(createHash("sha256").update(bytes).digest())).toBe(false);
    expect(await completeMediaUpload(db, alice.accountId, alice.deviceId, created.mediaId)).toMatchObject({ ready: true, duplicate: false });
    expect(await completeMediaUpload(db, alice.accountId, alice.deviceId, created.mediaId)).toMatchObject({ ready: true, duplicate: true });

    const sent = await sendMessage(db, {
      senderAccountId: alice.accountId, senderDeviceId: alice.deviceId, dialogId,
      clientMsgId: crypto.randomUUID(), body: "attached", mediaId: created.mediaId,
    });
    const history = await getHistory(db, bob.accountId, dialogId);
    expect(history.messages[0].media).toMatchObject({
      id: created.mediaId, kind: "file", byte_size: bytes.length, has_thumbnail: true,
    });
    const downloaded = await downloadMediaChunk(db, bob.accountId, created.mediaId, 0);
    const [parallelA, parallelB] = await Promise.all([
      downloadMediaChunk(db, bob.accountId, created.mediaId, 0),
      downloadMediaChunk(db, bob.accountId, created.mediaId, 0),
    ]);
    expect(parallelA.bytes).toEqual(first);
    expect(parallelB.bytes).toEqual(first);
    const downloadedSecond = await downloadMediaChunk(db, bob.accountId, created.mediaId, downloaded.nextOffset);
    expect(Buffer.concat([downloaded.bytes, downloadedSecond.bytes])).toEqual(bytes);
    await expect(downloadMediaChunk(db, outsider.accountId, created.mediaId, 0))
      .rejects.toMatchObject({ status: 404 });

    await deleteMessage(db, {
      actorAccountId: alice.accountId, actorDeviceId: alice.deviceId, dialogId,
      msgId: sent.msgId, clientMutationId: crypto.randomUUID(),
    });
    await expect(downloadMediaChunk(db, bob.accountId, created.mediaId, 0))
      .rejects.toMatchObject({ status: 404 });
    expect(await db`SELECT id FROM media_objects WHERE id = ${created.mediaId}`).toHaveLength(0);
  });

  test("multipart v2 accepts encrypted out-of-order parts and resumes only missing parts", async () => {
    const { alice } = await makePair();
    const bytes = Buffer.alloc(MEDIA_PART_SIZE * 2 + 31);
    bytes.fill(0x41, 0, MEDIA_PART_SIZE);
    bytes.fill(0x42, MEDIA_PART_SIZE, MEDIA_PART_SIZE * 2);
    bytes.fill(0x43, MEDIA_PART_SIZE * 2);
    const created = await createMediaUpload(db, alice.accountId, alice.deviceId, {
      kind: "file", contentType: "application/octet-stream", fileName: "multipart.bin",
      byteSize: bytes.length, sha256: createHash("sha256").update(bytes).digest("hex"),
      uploadProtocol: "parts_v2",
    });
    expect(created).toMatchObject({
      uploadProtocol: "parts_v2", partSize: MEDIA_PART_SIZE, totalParts: 3, receivedParts: [],
    });

    const part0 = bytes.subarray(0, MEDIA_PART_SIZE);
    const part1 = bytes.subarray(MEDIA_PART_SIZE, MEDIA_PART_SIZE * 2);
    const part2 = bytes.subarray(MEDIA_PART_SIZE * 2);
    await expect(uploadMediaChunk(db, alice.accountId, alice.deviceId, created.mediaId, 0, part0))
      .rejects.toMatchObject({ status: 409, code: "media_protocol_mismatch" });
    await uploadMediaPart(db, alice.accountId, alice.deviceId, created.mediaId, 2, part2);
    await uploadMediaPart(db, alice.accountId, alice.deviceId, created.mediaId, 0, part0);
    expect(await uploadMediaPart(db, alice.accountId, alice.deviceId, created.mediaId, 0, part0))
      .toMatchObject({ duplicate: true, partIndex: 0 });
    const conflicting = Buffer.from(part0);
    conflicting[0] ^= 0xff;
    await expect(uploadMediaPart(db, alice.accountId, alice.deviceId, created.mediaId, 0, conflicting))
      .rejects.toMatchObject({ status: 409, code: "media_part_conflict" });

    expect(await getMediaUpload(db, alice.accountId, created.mediaId)).toMatchObject({
      uploadProtocol: "parts_v2", receivedParts: [0, 2], uploadOffset: MEDIA_PART_SIZE + 31,
    });
    await expect(completeMediaUpload(db, alice.accountId, alice.deviceId, created.mediaId))
      .rejects.toMatchObject({ status: 409 });
    await uploadMediaPart(db, alice.accountId, alice.deviceId, created.mediaId, 1, part1);
    expect(await completeMediaUpload(db, alice.accountId, alice.deviceId, created.mediaId))
      .toMatchObject({ ready: true, duplicate: false });

    const stored = await db`
      SELECT ciphertext FROM media_chunks WHERE media_id = ${created.mediaId} ORDER BY chunk_offset`;
    expect(Buffer.concat(stored.map((row) => Buffer.from(row.ciphertext))).includes(part0)).toBe(false);
  });

  test("media HTTP routes bound binary bodies and round-trip authorized chunks", async () => {
    const { alice, bob, dialogId } = await makePair();
    const server = startCloudServer(0, db, null, null);
    try {
      const base = `http://127.0.0.1:${server.port}`;
      const bytes = Buffer.from("http-media-round-trip");
      const createdResponse = await fetch(`${base}/v1/media/uploads`, {
        method: "POST",
        headers: { authorization: `Bearer ${alice.token}`, "content-type": "application/json" },
        body: JSON.stringify({
          kind: "file", contentType: "application/octet-stream", fileName: "round-trip.bin",
          byteSize: bytes.length, sha256: createHash("sha256").update(bytes).digest("hex"),
        }),
      });
      expect(createdResponse.status).toBe(201);
      const created = await createdResponse.json() as { mediaId: string };

      const missingOffset = await fetch(`${base}/v1/media/uploads/${created.mediaId}/chunks`, {
        method: "PUT",
        headers: { authorization: `Bearer ${alice.token}` },
        body: bytes,
      });
      expect(missingOffset.status).toBe(400);

      const oversized = await fetch(`${base}/v1/media/uploads/${created.mediaId}/chunks`, {
        method: "PUT",
        headers: { authorization: `Bearer ${alice.token}`, "upload-offset": "0" },
        body: Buffer.alloc(mediaLimits().chunkBytes + 1),
      });
      expect(oversized.status).toBe(413);
      expect(Number((await db`SELECT uploaded_bytes FROM media_objects WHERE id = ${created.mediaId}`)[0].uploaded_bytes))
        .toBe(0);

      const chunk = await fetch(`${base}/v1/media/uploads/${created.mediaId}/chunks`, {
        method: "PUT",
        headers: { authorization: `Bearer ${alice.token}`, "upload-offset": "0" },
        body: bytes,
      });
      expect(chunk.status).toBe(200);
      expect(chunk.headers.get("upload-offset")).toBe(String(bytes.length));
      const completed = await fetch(`${base}/v1/media/uploads/${created.mediaId}/complete`, {
        method: "POST", headers: { authorization: `Bearer ${alice.token}` },
      });
      expect(completed.status).toBe(200);
      await sendMessage(db, {
        senderAccountId: alice.accountId, senderDeviceId: alice.deviceId, dialogId,
        clientMsgId: crypto.randomUUID(), mediaId: created.mediaId, body: "",
      });

      const downloaded = await fetch(`${base}/v1/media/${created.mediaId}/chunks?offset=0`, {
        headers: { authorization: `Bearer ${bob.token}` },
      });
      expect(downloaded.status).toBe(200);
      expect(Buffer.from(await downloaded.arrayBuffer())).toEqual(bytes);
      expect(downloaded.headers.get("x-media-next-offset")).toBe(String(bytes.length));

      const abandonedBytes = Buffer.from("abandoned route upload");
      const abandonedResponse = await fetch(`${base}/v1/media/uploads`, {
        method: "POST",
        headers: { authorization: `Bearer ${alice.token}`, "content-type": "application/json" },
        body: JSON.stringify({
          kind: "file", contentType: "application/octet-stream", fileName: "cancel.bin",
          byteSize: abandonedBytes.length,
          sha256: createHash("sha256").update(abandonedBytes).digest("hex"),
        }),
      });
      expect(abandonedResponse.status).toBe(201);
      const abandoned = await abandonedResponse.json() as { mediaId: string };
      const cancelled = await fetch(`${base}/v1/media/uploads/${abandoned.mediaId}`, {
        method: "DELETE", headers: { authorization: `Bearer ${alice.token}` },
      });
      expect(cancelled.status).toBe(200);
      expect(await cancelled.json()).toEqual({ mediaId: abandoned.mediaId, cancelled: true });
      const cancelledState = await fetch(`${base}/v1/media/uploads/${abandoned.mediaId}`, {
        headers: { authorization: `Bearer ${alice.token}` },
      });
      expect(cancelledState.status).toBe(404);
    } finally {
      server.stop(true);
    }
  });

  test("multipart v2 HTTP route reports capabilities, acknowledgements, and stable errors", async () => {
    const { alice } = await makePair();
    const server = startCloudServer(0, db, null, null);
    try {
      const base = `http://127.0.0.1:${server.port}`;
      const bytes = tinyJpeg(7, 9);
      const createdResponse = await fetch(`${base}/v1/media/uploads`, {
        method: "POST",
        headers: { authorization: `Bearer ${alice.token}`, "content-type": "application/json" },
        body: JSON.stringify({
          kind: "photo", contentType: "image/jpeg", fileName: "photo.jpg",
          byteSize: bytes.length, sha256: createHash("sha256").update(bytes).digest("hex"),
          width: 7, height: 9, uploadProtocol: "parts_v2",
        }),
      });
      expect(createdResponse.status).toBe(201);
      const created = await createdResponse.json() as {
        mediaId: string; uploadProtocol: string; partSize: number; totalParts: number;
      };
      expect(created).toMatchObject({ uploadProtocol: "parts_v2", partSize: MEDIA_PART_SIZE, totalParts: 1 });

      const part = await fetch(`${base}/v1/media/uploads/${created.mediaId}/parts/0`, {
        method: "PUT", headers: { authorization: `Bearer ${alice.token}` }, body: bytes,
      });
      expect(part.status).toBe(200);
      expect(await part.json()).toMatchObject({ partIndex: 0, complete: true, duplicate: false });
      expect(safeRoute(`/v1/media/uploads/${created.mediaId}/parts/0`))
        .toBe("/v1/media/uploads/:id/parts/:part");

      const completed = await fetch(`${base}/v1/media/uploads/${created.mediaId}/complete`, {
        method: "POST", headers: { authorization: `Bearer ${alice.token}` },
      });
      expect(completed.status).toBe(200);

      const invalid = await fetch(`${base}/v1/media/uploads`, {
        method: "POST",
        headers: { authorization: `Bearer ${alice.token}`, "content-type": "application/json" },
        body: JSON.stringify({
          kind: "file", contentType: "application/octet-stream", byteSize: 1,
          sha256: createHash("sha256").update(Buffer.from([1])).digest("hex"),
          uploadProtocol: "unknown",
        }),
      });
      expect(invalid.status).toBe(400);
      expect(await invalid.json()).toMatchObject({ code: "unsupported_upload_protocol" });
    } finally {
      server.stop(true);
    }
  });

  test("media completion rejects gaps and checksum mismatches without publishing a message", async () => {
    const { alice, dialogId } = await makePair();
    const bytes = Buffer.from("checksum-test");
    const created = await createMediaUpload(db, alice.accountId, alice.deviceId, {
      kind: "voice", contentType: "audio/mp4", byteSize: bytes.length,
      sha256: "00".repeat(32), durationMs: 850,
    });
    await expect(uploadMediaChunk(db, alice.accountId, alice.deviceId, created.mediaId, 4, bytes))
      .rejects.toMatchObject({ status: 409 });
    await uploadMediaChunk(db, alice.accountId, alice.deviceId, created.mediaId, 0, bytes);
    await expect(completeMediaUpload(db, alice.accountId, alice.deviceId, created.mediaId))
      .rejects.toThrow("checksum mismatch");
    await expect(completeMediaUpload(db, alice.accountId, alice.deviceId, created.mediaId))
      .rejects.toThrow("upload unavailable");
    expect(await db`SELECT media_id FROM media_chunks WHERE media_id = ${created.mediaId}`).toHaveLength(0);
    expect((await db`SELECT status FROM media_objects WHERE id = ${created.mediaId}`)[0].status).toBe("rejected");
    await expect(sendMessage(db, {
      senderAccountId: alice.accountId, senderDeviceId: alice.deviceId, dialogId,
      clientMsgId: crypto.randomUUID(), body: "", mediaId: created.mediaId,
    })).rejects.toThrow("media upload is incomplete");

    const expired = await createMediaUpload(db, alice.accountId, alice.deviceId, {
      kind: "file", contentType: "application/octet-stream", byteSize: bytes.length,
      sha256: createHash("sha256").update(bytes).digest("hex"),
    });
    await uploadMediaChunk(db, alice.accountId, alice.deviceId, expired.mediaId, 0, bytes);
    await db`UPDATE media_objects SET expires_at = now() - interval '1 second' WHERE id = ${expired.mediaId}`;
    await expect(completeMediaUpload(db, alice.accountId, alice.deviceId, expired.mediaId))
      .rejects.toMatchObject({ status: 410 });
  });

  test("media completion rejects content that does not match its declared type", async () => {
    const { alice } = await makePair();
    const bytes = Buffer.from("this is not an image");
    const created = await createMediaUpload(db, alice.accountId, alice.deviceId, {
      kind: "photo", contentType: "image/jpeg", fileName: "fake.jpg",
      byteSize: bytes.length, sha256: createHash("sha256").update(bytes).digest("hex"), width: 1, height: 1,
    });
    await uploadMediaChunk(db, alice.accountId, alice.deviceId, created.mediaId, 0, bytes);
    await expect(completeMediaUpload(db, alice.accountId, alice.deviceId, created.mediaId))
      .rejects.toMatchObject({ status: 415 });
  });

  test.each([
    ["image/jpeg", tinyJpeg(1_284, 2_778)],
    ["image/png", tinyPng(1_284, 2_778)],
  ])("media completion accepts a valid %s photo with matching dimensions", async (contentType, bytes) => {
    const { alice } = await makePair();
    const created = await createMediaUpload(db, alice.accountId, alice.deviceId, {
      kind: "photo", contentType, fileName: "valid-photo",
      byteSize: bytes.length, sha256: createHash("sha256").update(bytes).digest("hex"),
      width: 1_284, height: 2_778,
    });
    await uploadMediaChunk(db, alice.accountId, alice.deviceId, created.mediaId, 0, bytes);
    await expect(completeMediaUpload(db, alice.accountId, alice.deviceId, created.mediaId))
      .resolves.toMatchObject({ ready: true, duplicate: false });
  });

  test("owners can cancel abandoned uploads but cannot cancel delivered media", async () => {
    const { alice, bob, dialogId } = await makePair();
    const bytes = Buffer.from("abandoned encrypted upload");
    const abandoned = await createMediaUpload(db, alice.accountId, alice.deviceId, {
      kind: "file", contentType: "application/octet-stream", fileName: "private.txt",
      byteSize: bytes.length, sha256: createHash("sha256").update(bytes).digest("hex"),
    });
    await uploadMediaChunk(db, alice.accountId, alice.deviceId, abandoned.mediaId, 0, bytes);
    await expect(cancelMediaUpload(db, bob.accountId, bob.deviceId, abandoned.mediaId)).rejects.toMatchObject({ status: 404 });
    expect(await cancelMediaUpload(db, alice.accountId, alice.deviceId, abandoned.mediaId)).toEqual({
      mediaId: abandoned.mediaId, cancelled: true,
    });

    const delivered = await createMediaUpload(db, alice.accountId, alice.deviceId, {
      kind: "file", contentType: "application/octet-stream", fileName: "delivered.txt",
      byteSize: bytes.length, sha256: createHash("sha256").update(bytes).digest("hex"),
    });
    await uploadMediaChunk(db, alice.accountId, alice.deviceId, delivered.mediaId, 0, bytes);
    await completeMediaUpload(db, alice.accountId, alice.deviceId, delivered.mediaId);
    await sendMessage(db, {
      senderAccountId: alice.accountId, senderDeviceId: alice.deviceId, dialogId,
      clientMsgId: crypto.randomUUID(), body: "", mediaId: delivered.mediaId,
    });
    await expect(cancelMediaUpload(db, alice.accountId, alice.deviceId, delivered.mediaId)).rejects.toMatchObject({ status: 409 });
  });

  test("deleting a source keeps forwarded media until the final visible copy is deleted", async () => {
    const { alice, bob, dialogId: sourceDialogId } = await makePair();
    const charlie = await makeAccount(testPhone(902), "Charlie");
    const destination = await getOrCreateDirectDialog(db, bob.accountId, charlie.accountId);
    const bytes = Buffer.from("forwarded encrypted media");
    const created = await createMediaUpload(db, alice.accountId, alice.deviceId, {
      kind: "file", contentType: "application/octet-stream", fileName: "forward.bin",
      byteSize: bytes.length, sha256: createHash("sha256").update(bytes).digest("hex"),
    });
    await uploadMediaChunk(db, alice.accountId, alice.deviceId, created.mediaId, 0, bytes);
    await completeMediaUpload(db, alice.accountId, alice.deviceId, created.mediaId);
    const source = await sendMessage(db, {
      senderAccountId: alice.accountId, senderDeviceId: alice.deviceId,
      dialogId: sourceDialogId, clientMsgId: crypto.randomUUID(), body: "", mediaId: created.mediaId,
    });
    const forwarded = await sendMessage(db, {
      senderAccountId: bob.accountId, senderDeviceId: bob.deviceId,
      dialogId: destination.dialogId, clientMsgId: crypto.randomUUID(),
      forwardedFrom: { dialogId: sourceDialogId, msgId: source.msgId },
    });
    await deleteMessage(db, {
      actorAccountId: alice.accountId, actorDeviceId: alice.deviceId,
      dialogId: sourceDialogId, msgId: source.msgId, clientMutationId: crypto.randomUUID(),
    });
    expect((await downloadMediaChunk(db, charlie.accountId, created.mediaId, 0)).bytes).toEqual(bytes);
    await deleteMessage(db, {
      actorAccountId: bob.accountId, actorDeviceId: bob.deviceId,
      dialogId: destination.dialogId, msgId: forwarded.msgId, clientMutationId: crypto.randomUUID(),
    });
    await expect(downloadMediaChunk(db, charlie.accountId, created.mediaId, 0))
      .rejects.toMatchObject({ status: 404 });
    expect(await db`SELECT id FROM media_objects WHERE id = ${created.mediaId}`).toHaveLength(0);
  });

  test("media creation reserves quota atomically and sanitizes file names", async () => {
    const { alice } = await makePair();
    await expect(createMediaUpload(db, alice.accountId, alice.deviceId, {
      kind: "voice", contentType: "image/jpeg", byteSize: 4, sha256: "11".repeat(32),
    })).rejects.toThrow("audio content type required");
    await expect(createMediaUpload(db, alice.accountId, alice.deviceId, {
      kind: "photo", contentType: "image/jpeg", byteSize: 4, sha256: "11".repeat(32), width: 0,
    })).rejects.toThrow("invalid media dimensions");
    const oldQuota = process.env.TOJ_MEDIA_ACCOUNT_QUOTA_BYTES;
    process.env.TOJ_MEDIA_ACCOUNT_QUOTA_BYTES = "1024";
    try {
      const bytes = Buffer.alloc(700, 1);
      const first = await createMediaUpload(db, alice.accountId, alice.deviceId, {
        kind: "file", contentType: "application/pdf", fileName: "folder/statement.pdf",
        byteSize: bytes.length, sha256: createHash("sha256").update(bytes).digest("hex"),
      });
      const metadata = (await db`
        SELECT file_name, file_name_key_id, file_name_nonce, file_name_ciphertext
        FROM media_objects WHERE id = ${first.mediaId}`)[0];
      expect(metadata.file_name).toBeNull();
      expect(Buffer.from(metadata.file_name_ciphertext).includes(Buffer.from("statement.pdf"))).toBe(false);
      expect(open({
        keyId: metadata.file_name_key_id,
        nonce: Buffer.from(metadata.file_name_nonce),
        ciphertext: Buffer.from(metadata.file_name_ciphertext),
      }, mediaFileNameAAD(first.mediaId)).toString("utf8")).toBe("statement.pdf");
      await expect(createMediaUpload(db, alice.accountId, alice.deviceId, {
        kind: "file", contentType: "application/pdf", byteSize: 400, sha256: "11".repeat(32),
      })).rejects.toEqual(expect.objectContaining<Partial<MediaError>>({ status: 413 }));
    } finally {
      if (oldQuota == null) delete process.env.TOJ_MEDIA_ACCOUNT_QUOTA_BYTES;
      else process.env.TOJ_MEDIA_ACCOUNT_QUOTA_BYTES = oldQuota;
    }
  });

  test("media mutations revalidate the device and cap active upload rows", async () => {
    const { alice } = await makePair();
    const oldActiveLimit = process.env.TOJ_MEDIA_MAX_ACTIVE_UPLOADS;
    process.env.TOJ_MEDIA_MAX_ACTIVE_UPLOADS = "2";
    try {
      for (let index = 0; index < 2; index += 1) {
        await createMediaUpload(db, alice.accountId, alice.deviceId, {
          kind: "file", contentType: "application/octet-stream", byteSize: 1,
          sha256: createHash("sha256").update(Buffer.from([index])).digest("hex"),
        });
      }
      await expect(createMediaUpload(db, alice.accountId, alice.deviceId, {
        kind: "file", contentType: "application/octet-stream", byteSize: 1,
        sha256: createHash("sha256").update(Buffer.from([2])).digest("hex"),
      })).rejects.toMatchObject({ status: 429 });
      await revokeDevice(db, alice.accountId, alice.deviceId);
      await expect(createMediaUpload(db, alice.accountId, alice.deviceId, {
        kind: "file", contentType: "application/octet-stream", byteSize: 1,
        sha256: createHash("sha256").update(Buffer.from([3])).digest("hex"),
      })).rejects.toMatchObject({ status: 401 });
    } finally {
      if (oldActiveLimit == null) delete process.env.TOJ_MEDIA_MAX_ACTIVE_UPLOADS;
      else process.env.TOJ_MEDIA_MAX_ACTIVE_UPLOADS = oldActiveLimit;
    }
  });

  test("concurrent sends with the same client_msg_id collapse to one message (B2 race)", async () => {
    const { alice, dialogId } = await makePair();
    const params = {
      senderAccountId: alice.accountId, senderDeviceId: alice.deviceId,
      dialogId, clientMsgId: crypto.randomUUID(), body: "race",
    };
    const [a, b] = await Promise.all([sendMessage(db, params), sendMessage(db, params)]);
    expect(a.msgId).toBe(b.msgId);
    expect(a.senderPts).toBe(b.senderPts);
    expect([a.duplicate, b.duplicate].sort()).toEqual([false, true]);
    const count = (await db`SELECT count(*)::int AS c FROM messages WHERE dialog_id = ${dialogId}`)[0];
    expect(Number(count.c)).toBe(1);
  });

  test("contact lookup resolves a phone to an account and null for unknown", async () => {
    const { code } = await startVerification(db, "+16505550140");
    const session = await checkVerification(db, "+16505550140", code, "ios", "iPhone", "Muhammad");
    const requester = await makeAccount(testPhone(141), "Requester");
    const found = await lookupAccountByPhone(db, requester.accountId, "+16505550140");
    expect(found?.accountId).toBe(session.accountId);
    expect(found?.displayName).toBe("Muhammad");
    expect(await lookupAccountByPhone(db, requester.accountId, "+16505559999")).toBeNull();
  });

  test("profile updates persist and sync to every active chat partner", async () => {
    const owner = await makeAccount(testPhone(145), "Old Name");
    const requester = await makeAccount(testPhone(146), "Requester");
    const direct = await getOrCreateDirectDialog(db, owner.accountId, requester.accountId);
    const requesterPts = Number((await db`
      SELECT pts FROM account_sync_states WHERE account_id = ${requester.accountId}`)[0].pts);
    const result = await updateProfile(db, owner.accountId, owner.deviceId, {
      firstName: "New", lastName: "Name", bio: "Building Toj",
      birthday: "1995-04-18", colorIndex: 4,
    });
    expect(result.profile).toMatchObject({
      accountId: owner.accountId, firstName: "New", lastName: "Name",
      displayName: "New Name", bio: "Building Toj", birthday: "1995-04-18", colorIndex: 4,
    });
    expect(await getProfile(db, owner.accountId)).toEqual(result.profile);
    expect((await lookupAccountByPhone(db, requester.accountId, testPhone(145)))?.displayName)
      .toBe("New Name");

    const difference = await getDifference(db, requester.accountId, requesterPts);
    expect(difference.kind).toBe("difference");
    if (difference.kind === "difference") {
      expect(difference.updates).toContainEqual(expect.objectContaining({
        type: "profile.updated", subject_account_id: owner.accountId,
        display_name: "New Name", bio: "Building Toj", birthday: "1995-04-18", color_index: 4,
        shared_dialog_ids: [direct.dialogId],
      }));
    }
    const snapshot = await startBootstrap(db, requester.accountId);
    const page = await getBootstrapDialogsPage(db, requester.accountId, snapshot.token);
    expect(page.dialogs[0].profiles).toContainEqual(expect.objectContaining({
      accountId: owner.accountId, displayName: "New Name", colorIndex: 4,
    }));

    await revokeDevice(db, owner.accountId, owner.deviceId);
    await expect(updateProfile(db, owner.accountId, owner.deviceId, {
      firstName: "Another", lastName: "Name", bio: "", birthday: null, colorIndex: 0,
    }))
      .rejects.toMatchObject({ status: 401 });
  });

  test("contact discovery is persistently bounded per authenticated account", async () => {
    const requester = await makeAccount(testPhone(142), "Requester");
    for (let index = 0; index < 20; index += 1) {
      expect(await lookupAccountByPhone(db, requester.accountId, testPhone(2_000 + index))).toBeNull();
    }
    await expect(lookupAccountByPhone(db, requester.accountId, testPhone(2_100)))
      .rejects.toMatchObject({ status: 429 });
    // A retry for an already-budgeted number remains usable and does not consume another slot.
    expect(await lookupAccountByPhone(db, requester.accountId, testPhone(2_000))).toBeNull();
  });
});
  test("capability contract is public, cache-safe, and advertises shipped messaging features", async () => {
    const port = 53_000 + Math.floor(Math.random() * 1_000);
    const server = startCloudServer(port, db, null, null);
    try {
      const response = await fetch(`http://127.0.0.1:${port}/v1/capabilities`);
      expect(response.status).toBe(200);
      expect(response.headers.get("cache-control")).toBe("no-store");
      expect(await response.json()).toEqual(CLOUD_CAPABILITIES);
      expect(safeRoute("/v1/capabilities")).toBe("/v1/capabilities");
    } finally {
      server.stop(true);
    }
  });
