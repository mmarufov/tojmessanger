import { beforeEach, describe, expect, test } from "bun:test";
import { makeSql } from "./db";
import { checkVerification, revokeDevice, startAccountDeletion, startVerification } from "./auth";
import { hashToken, open, pushTokenAAD, voipPushTokenAAD } from "./crypto";
import { getHistory, getOrCreateDirectDialog, sendMessage } from "./sync";
import { lockAccountMutations } from "./locks";
import {
  acceptCall,
  blockAccount,
  cancelCall,
  cleanupCallData,
  calleeCommitmentV1,
  callerCommitmentV1,
  CallError,
  confirmCallKey,
  createCall,
  declineCall,
  deleteAccountAndTerminateCalls,
  endCall,
  getIceConfig,
  getCallEvents,
  processCallHistoryOutbox,
  recordCallTelemetry,
  revokeDeviceAndTerminateCalls,
  revealCallKey,
  sendEncryptedCallEvent,
  voiceCallsConfigured,
  type CallCommitmentContextV1,
  type CallKeyMaterialV1,
} from "./calls";
import {
  buildAPNsHeaders,
  buildVoIPAPNsPayload,
  processVoIPPushBatch,
  registerVoIPPushToken,
  type APNsSendRequest,
  type APNsSendResult,
  type PushSender,
} from "./push";
import { startCloudServer } from "./cloud";

const TEST_URL = process.env.TEST_DATABASE_URL ?? "postgres://localhost:5432/toj_test";
const db = makeSql(TEST_URL);
const lockObserver = makeSql(TEST_URL);

const bytes = (start: number): Buffer => Buffer.from(Array.from({ length: 32 }, (_, index) => start + index));

async function resetDb() {
  await db`TRUNCATE accounts, otp_challenges RESTART IDENTITY CASCADE`;
}

async function account(phone: string, name: string) {
  const { code } = await startVerification(db, phone);
  return await checkVerification(db, phone, code, "ios", `${name} iPhone`, name);
}

async function addDevice(accountId: string): Promise<string> {
  return (await db`
    INSERT INTO devices (account_id, platform, device_name, auth_token_hash)
    VALUES (${accountId}, 'ios', 'Second iPhone', ${hashToken(crypto.randomUUID())}) RETURNING id`)[0].id;
}

async function pair() {
  const alice = await account("+16505551100", "Alice");
  const bob = await account("+16505551101", "Bob");
  const { dialogId } = await getOrCreateDirectDialog(db, alice.accountId, bob.accountId);
  await sendMessage(db, {
    senderAccountId: alice.accountId, senderDeviceId: alice.deviceId, dialogId,
    clientMsgId: crypto.randomUUID(), body: "hello",
  });
  await sendMessage(db, {
    senderAccountId: bob.accountId, senderDeviceId: bob.deviceId, dialogId,
    clientMsgId: crypto.randomUUID(), body: "hello back",
  });
  return { alice, bob, dialogId };
}

async function waitForAdvisoryWaiters(minimum: number): Promise<void> {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    const count = Number((await lockObserver`
      SELECT count(*) AS count FROM pg_locks
      WHERE locktype = 'advisory' AND granted = false`)[0].count);
    if (count >= minimum) return;
    await Bun.sleep(10);
  }
  throw new Error(`timed out waiting for ${minimum} advisory-lock waiters`);
}

function context(callId: string, dialogId: string, alice: any, bob: any): CallCommitmentContextV1 {
  return {
    callId, dialogId,
    callerAccountId: alice.accountId,
    callerDeviceId: alice.deviceId,
    calleeAccountId: bob.accountId,
    offeredProtocolVersions: [1],
    offeredMediaProfileVersions: [1],
  };
}

class StubSender implements PushSender {
  readonly requests: APNsSendRequest[] = [];
  async send(request: APNsSendRequest): Promise<APNsSendResult> {
    this.requests.push(request);
    return { status: 200, apnsId: crypto.randomUUID() };
  }
}

class PausingSender implements PushSender {
  readonly requests: APNsSendRequest[] = [];
  readonly started: Promise<void>;
  private readonly releasePromise: Promise<void>;
  private signalStarted!: () => void;
  private signalRelease!: () => void;

  constructor() {
    this.started = new Promise((resolve) => { this.signalStarted = resolve; });
    this.releasePromise = new Promise((resolve) => { this.signalRelease = resolve; });
  }

  async send(request: APNsSendRequest): Promise<APNsSendResult> {
    this.requests.push(request);
    this.signalStarted();
    await this.releasePromise;
    return { status: 200, apnsId: crypto.randomUUID() };
  }

  release() { this.signalRelease(); }
}

class ConcurrentPausingSender implements PushSender {
  readonly requests: APNsSendRequest[] = [];
  readonly multipleStarted: Promise<void>;
  private readonly releasePromise: Promise<void>;
  private signalMultipleStarted!: () => void;
  private signalRelease!: () => void;

  constructor() {
    this.multipleStarted = new Promise((resolve) => { this.signalMultipleStarted = resolve; });
    this.releasePromise = new Promise((resolve) => { this.signalRelease = resolve; });
  }

  async send(request: APNsSendRequest): Promise<APNsSendResult> {
    this.requests.push(request);
    if (this.requests.length >= 2) this.signalMultipleStarted();
    await this.releasePromise;
    return { status: 200, apnsId: crypto.randomUUID() };
  }

  release() { this.signalRelease(); }
}

describe("E2EE voice-call control plane", () => {
  beforeEach(resetDb);

  test("TypeScript commitment encoding matches the pinned Swift vector", () => {
    const vectorContext: CallCommitmentContextV1 = {
      callId: "00000000-0000-0000-0000-000000000001",
      dialogId: "00000000-0000-0000-0000-000000000002",
      callerAccountId: "alice",
      callerDeviceId: "alice-ios-1",
      calleeAccountId: "bob",
      offeredProtocolVersions: [1],
      offeredMediaProfileVersions: [1],
    };
    const caller: CallKeyMaterialV1 = {
      publicKey: Buffer.from("8f40c5adb68f25624ae5b214ea767a6ec94d829d3d7b5e1ad1ba6f3e2138285f", "hex"),
      nonce: bytes(64), fingerprint: bytes(96),
    };
    const callerCommitment = callerCommitmentV1(vectorContext, caller);
    expect(callerCommitment.toString("hex"))
      .toBe("72af3dc7b2dc7adc92b31af69f240bc4f280052f0f6828aa51d6f21fdaf78411");
    const callee: CallKeyMaterialV1 = {
      publicKey: Buffer.from("358072d6365880d1aeea329adf9121383851ed21a28e3b75e965d0d2cd166254", "hex"),
      nonce: bytes(128), fingerprint: bytes(160),
    };
    expect(calleeCommitmentV1(vectorContext, callerCommitment, "bob-ios-1", 1, 1, callee).toString("hex"))
      .toBe("8b077d9791a6db5e2eb6efdc9f4d53590bd281f50caf6dc51d667b9a2ca4bca0");
  });

  test("voice capability requires an explicit healthy TURN gate and APNs", () => {
    const saved = {
      enabled: process.env.TOJ_VOICE_CALLS_ENABLED,
      ready: process.env.TOJ_TURN_READY,
      urls: process.env.TOJ_TURN_URLS,
      secret: process.env.TOJ_TURN_SHARED_SECRET,
    };
    try {
      process.env.TOJ_VOICE_CALLS_ENABLED = "1";
      process.env.TOJ_TURN_URLS = "turn:turn.example.test:3478";
      process.env.TOJ_TURN_SHARED_SECRET = "test-secret";
      delete process.env.TOJ_TURN_READY;
      expect(voiceCallsConfigured(true)).toBe(false);
      process.env.TOJ_TURN_READY = "1";
      expect(voiceCallsConfigured(false)).toBe(false);
      expect(voiceCallsConfigured(true)).toBe(true);
      process.env.TOJ_TURN_URLS = "  ,  ";
      expect(voiceCallsConfigured(true)).toBe(false);
      process.env.TOJ_TURN_URLS = "turn:turn.example.test:3478";
      process.env.TOJ_TURN_SHARED_SECRET = "   ";
      expect(voiceCallsConfigured(true)).toBe(false);
    } finally {
      for (const [key, value] of Object.entries(saved)) {
        const environmentKey = {
          enabled: "TOJ_VOICE_CALLS_ENABLED", ready: "TOJ_TURN_READY",
          urls: "TOJ_TURN_URLS", secret: "TOJ_TURN_SHARED_SECRET",
        }[key]!;
        if (value === undefined) delete process.env[environmentKey];
        else process.env[environmentKey] = value;
      }
    }
  });

  test("two-sided commitments, first-answer-wins, signaling, and history are durable", async () => {
    const { alice, bob, dialogId } = await pair();
    const otherBobDevice = await addDevice(bob.accountId);
    await registerVoIPPushToken(db, bob.deviceId, "ab".repeat(32), "sandbox");
    await registerVoIPPushToken(db, otherBobDevice, "ac".repeat(32), "sandbox");
    const callId = crypto.randomUUID();
    const ctx = context(callId, dialogId, alice, bob);
    const callerMaterial = { publicKey: bytes(1), nonce: bytes(33), fingerprint: bytes(65) };
    const calleeMaterial = { publicKey: bytes(97), nonce: bytes(129), fingerprint: bytes(161) };
    const callerCommitment = callerCommitmentV1(ctx, callerMaterial);
    const calleeCommitment = calleeCommitmentV1(
      ctx, callerCommitment, bob.deviceId, 1, 1, calleeMaterial,
    );

    const created = await createCall(db, {
      callerAccountId: alice.accountId, callerDeviceId: alice.deviceId,
      callId, dialogId, callerCommitment: callerCommitment.toString("base64"),
      supportedProtocolVersions: [1], offeredMediaProfileVersions: [1], networkKey: "test-network",
    });
    expect(created.ringTargetCount).toBe(2);
    expect(created.call.calleeCommitment).toBeNull();
    const accepted = await acceptCall(db, {
      accountId: bob.accountId, deviceId: bob.deviceId, callId,
      calleeCommitment: calleeCommitment.toString("base64"), protocolVersion: 1,
      selectedMediaProfileVersion: 1,
    });
    expect(accepted.call.calleePublicKey).toBeNull();
    await expect(acceptCall(db, {
      accountId: bob.accountId, deviceId: otherBobDevice, callId,
      calleeCommitment: calleeCommitment.toString("base64"), protocolVersion: 1,
      selectedMediaProfileVersion: 1,
    })).rejects.toMatchObject({ code: "answered_elsewhere" });

    const tampered = Buffer.from(callerMaterial.nonce);
    tampered[0] ^= 1;
    await expect(revealCallKey(db, {
      accountId: alice.accountId, deviceId: alice.deviceId, callId,
      publicKey: callerMaterial.publicKey.toString("base64"), nonce: tampered.toString("base64"),
      fingerprint: callerMaterial.fingerprint.toString("base64"),
    })).rejects.toMatchObject({ code: "invalid_commitment" });
    await revealCallKey(db, {
      accountId: alice.accountId, deviceId: alice.deviceId, callId,
      publicKey: callerMaterial.publicKey.toString("base64"), nonce: callerMaterial.nonce.toString("base64"),
      fingerprint: callerMaterial.fingerprint.toString("base64"),
    });
    await revealCallKey(db, {
      accountId: bob.accountId, deviceId: bob.deviceId, callId,
      publicKey: calleeMaterial.publicKey.toString("base64"), nonce: calleeMaterial.nonce.toString("base64"),
      fingerprint: calleeMaterial.fingerprint.toString("base64"), confirmation: bytes(193).toString("base64"),
    });
    const active = await confirmCallKey(db, {
      accountId: alice.accountId, deviceId: alice.deviceId, callId,
      confirmation: bytes(225).toString("base64"),
    });
    expect(active.call.state).toBe("active");
    const initialLease = Number((await db`
      SELECT EXTRACT(EPOCH FROM (expires_at - now())) AS seconds FROM calls WHERE id = ${callId}`)[0].seconds);
    expect(initialLease).toBeGreaterThan(100);
    expect(initialLease).toBeLessThanOrEqual(121);

    const oldTurnURLs = process.env.TOJ_TURN_URLS;
    const oldTurnSecret = process.env.TOJ_TURN_SHARED_SECRET;
    try {
      process.env.TOJ_TURN_URLS = "turn:one.example.test:3478,turns:two.example.test:443";
      process.env.TOJ_TURN_SHARED_SECRET = "turn-test-secret";
      const firstICE = await getIceConfig(db, alice.accountId, alice.deviceId, callId);
      const secondICE = await getIceConfig(db, alice.accountId, alice.deviceId, callId);
      expect(secondICE.iceServers).toEqual(firstICE.iceServers);
      const username = firstICE.iceServers.at(-1)!.username!;
      expect(username.split(":").at(-1)).toMatch(/^[0-9a-f]{32}$/);
      expect(await db`SELECT id FROM turn_allocations WHERE call_id = ${callId} AND account_id = ${alice.accountId}`)
        .toHaveLength(1);
      await expect(getIceConfig(db, bob.accountId, otherBobDevice, callId))
        .rejects.toMatchObject({ code: "invalid_device" });
      await expect(endCall(db, {
        accountId: bob.accountId, deviceId: otherBobDevice, callId, reason: "local_ended",
      })).rejects.toMatchObject({ code: "invalid_device" });
    } finally {
      if (oldTurnURLs === undefined) delete process.env.TOJ_TURN_URLS;
      else process.env.TOJ_TURN_URLS = oldTurnURLs;
      if (oldTurnSecret === undefined) delete process.env.TOJ_TURN_SHARED_SECRET;
      else process.env.TOJ_TURN_SHARED_SECRET = oldTurnSecret;
    }

    const expiry = Date.now() + 60_000;
    await db`UPDATE calls SET expires_at = now() + interval '30 seconds' WHERE id = ${callId}`;
    const signal = await sendEncryptedCallEvent(db, {
      accountId: alice.accountId, deviceId: alice.deviceId, callId,
      version: 1, kind: "offer", senderSequence: 1,
      ciphertext: Buffer.alloc(65_564, 7).toString("base64"), expiresAtMilliseconds: expiry,
    });
    expect(signal.event.kind).toBe("offer");
    expect(signal.event.expiresAtMilliseconds).toBe(expiry);
    const renewedLease = Number((await db`
      SELECT EXTRACT(EPOCH FROM (expires_at - now())) AS seconds FROM calls WHERE id = ${callId}`)[0].seconds);
    expect(renewedLease).toBeGreaterThan(100);
    expect((await getCallEvents(db, bob.accountId, callId)).events.at(-1)?.ciphertext)
      .toBe(Buffer.alloc(65_564, 7).toString("base64"));

    // Exact transport retries are idempotent and do not consume the rolling signaling budget.
    const retriedSignal = await sendEncryptedCallEvent(db, {
      accountId: alice.accountId, deviceId: alice.deviceId, callId,
      version: 1, kind: "offer", senderSequence: 1,
      ciphertext: Buffer.alloc(65_564, 7).toString("base64"), expiresAtMilliseconds: expiry,
    });
    expect(retriedSignal.event.eventSeq).toBe(signal.event.eventSeq);
    expect((await db`
      SELECT event_count, ciphertext_bytes, negotiation_event_count
      FROM call_signal_budgets WHERE call_id = ${callId} AND sender_device_id = ${alice.deviceId}`)[0])
      .toMatchObject({ event_count: 1, ciphertext_bytes: "65564", negotiation_event_count: 1 });

    const smallSignal = (kind: "offer" | "control", senderSequence = 2) => sendEncryptedCallEvent(db, {
      accountId: alice.accountId, deviceId: alice.deviceId, callId,
      version: 1, kind, senderSequence,
      ciphertext: Buffer.alloc(1, 9).toString("base64"), expiresAtMilliseconds: expiry,
    });
    await db`
      UPDATE call_signal_budgets SET event_count = 120, ciphertext_bytes = 0,
        negotiation_event_count = 0, window_started_at = now()
      WHERE call_id = ${callId} AND sender_device_id = ${alice.deviceId}`;
    await expect(smallSignal("control")).rejects.toMatchObject({ code: "rate_limited", status: 429 });
    expect((await db`
      SELECT event_count FROM call_signal_budgets
      WHERE call_id = ${callId} AND sender_device_id = ${alice.deviceId}`)[0].event_count).toBe(120);

    await db`
      UPDATE call_signal_budgets SET event_count = 0, ciphertext_bytes = 524288,
        negotiation_event_count = 0, window_started_at = now()
      WHERE call_id = ${callId} AND sender_device_id = ${alice.deviceId}`;
    await expect(smallSignal("control")).rejects.toMatchObject({ code: "rate_limited", status: 429 });

    await db`
      UPDATE call_signal_budgets SET event_count = 0, ciphertext_bytes = 0,
        negotiation_event_count = 12, window_started_at = now()
      WHERE call_id = ${callId} AND sender_device_id = ${alice.deviceId}`;
    await expect(smallSignal("offer")).rejects.toMatchObject({ code: "rate_limited", status: 429 });

    // The call-row lock serializes racing devices/requests at the final budget slot: one commits,
    // one rolls back, and the stored counter never exceeds the configured ceiling.
    await db`
      UPDATE call_signal_budgets SET event_count = 119, ciphertext_bytes = 0,
        negotiation_event_count = 0, window_started_at = now()
      WHERE call_id = ${callId} AND sender_device_id = ${alice.deviceId}`;
    const racingSignals = await Promise.allSettled([
      smallSignal("control", 2),
      smallSignal("control", 3),
    ]);
    expect(racingSignals.filter((result) => result.status === "fulfilled")).toHaveLength(1);
    const rejectedRace = racingSignals.find((result) => result.status === "rejected") as PromiseRejectedResult;
    expect(rejectedRace.reason).toMatchObject({ code: "rate_limited", status: 429 });
    expect(Number((await db`
      SELECT event_count FROM call_signal_budgets
      WHERE call_id = ${callId} AND sender_device_id = ${alice.deviceId}`)[0].event_count)).toBe(120);

    await db`
      UPDATE call_signal_budgets SET event_count = 0, ciphertext_bytes = 0,
        negotiation_event_count = 0, window_started_at = now()
      WHERE call_id = ${callId} AND sender_device_id = ${alice.deviceId}`;
    const hangup = await sendEncryptedCallEvent(db, {
      accountId: alice.accountId, deviceId: alice.deviceId, callId,
      version: 1, kind: "hangup", senderSequence: 4,
      ciphertext: Buffer.alloc(1, 11).toString("base64"), expiresAtMilliseconds: expiry,
    });
    expect(hangup.syncPushes?.length).toBeGreaterThan(0);
    expect((await db`SELECT state, end_reason FROM calls WHERE id = ${callId}`)[0])
      .toMatchObject({ state: "ended", end_reason: "remote_ended" });
    expect(await db`SELECT account_id FROM call_participant_leases WHERE call_id = ${callId}`)
      .toHaveLength(0);
    await expect(smallSignal("control", 5)).rejects.toMatchObject({ code: "invalid_state", status: 409 });

    const server = startCloudServer(0, db, null, null);
    try {
      const revoked = await fetch(`http://127.0.0.1:${server.port}/v1/session`, {
        method: "DELETE", headers: { authorization: `Bearer ${alice.token}` },
      });
      expect(revoked.status).toBe(200);
    } finally {
      await server.stop(true);
    }
    expect((await db`SELECT state FROM calls WHERE id = ${callId}`)[0].state).toBe("ended");
    expect(await db`SELECT account_id FROM call_participant_leases WHERE call_id = ${callId}`).toHaveLength(0);
    const history = await getHistory(db, alice.accountId, dialogId);
    const service = history.messages.find((message) => message.kind === "service");
    expect(service).toBeDefined();
    expect(JSON.parse(service!.text)).toMatchObject({
      v: 1, type: "voice_call", callId, callerAccountId: alice.accountId, outcome: "completed",
    });
    const expiries = await db`SELECT expires_at FROM call_events WHERE call_id = ${callId}`;
    expect(expiries.every((row) => new Date(row.expires_at).getTime() <= Date.now() + 10 * 60_000 + 1_000)).toBe(true);
  });

  test("VoIP registration is separate and the outbox emits the minimal payload", async () => {
    const { alice, bob, dialogId } = await pair();
    await registerVoIPPushToken(db, bob.deviceId, "cd".repeat(32), "sandbox");
    const callId = crypto.randomUUID();
    const ctx = context(callId, dialogId, alice, bob);
    const callerMaterial = { publicKey: bytes(2), nonce: bytes(34), fingerprint: bytes(66) };
    await createCall(db, {
      callerAccountId: alice.accountId, callerDeviceId: alice.deviceId, callId, dialogId,
      callerCommitment: callerCommitmentV1(ctx, callerMaterial).toString("base64"),
      supportedProtocolVersions: [1], offeredMediaProfileVersions: [1],
    });
    const sender = new StubSender();
    expect(await processVoIPPushBatch(db, sender)).toBe(1);
    expect(sender.requests[0]).toMatchObject({
      kind: "voip", callId, callerAccountId: alice.accountId, environment: "sandbox",
    });
    const request = sender.requests[0];
    if (request.kind !== "voip") throw new Error("expected VoIP request");
    expect(buildVoIPAPNsPayload(request)).toEqual({
      aps: { "content-available": 1 },
      toj: { v: 1, type: "voice_call", callId, callerAccountId: alice.accountId, expiresAt: request.expiresAt },
    });
    expect(buildAPNsHeaders(request, "com.toj.Toj", "com.toj.Toj.voip", 123)).toEqual({
      "apns-topic": "com.toj.Toj.voip",
      "apns-push-type": "voip",
      "apns-priority": "10",
      "apns-expiration": "0",
    });
    const stored = (await db`
      SELECT voip_push_token_ciphertext, voip_push_token_nonce, voip_push_token_key_id,
        push_token_ciphertext FROM devices WHERE id = ${bob.deviceId}`)[0];
    expect(Buffer.from(stored.voip_push_token_ciphertext).includes(Buffer.from("cd".repeat(32)))).toBe(false);
    const sealed = {
      ciphertext: Buffer.from(stored.voip_push_token_ciphertext),
      nonce: Buffer.from(stored.voip_push_token_nonce),
      keyId: stored.voip_push_token_key_id,
    };
    expect(open(sealed, voipPushTokenAAD(bob.deviceId)).toString("utf8")).toBe("cd".repeat(32));
    expect(() => open(sealed, pushTokenAAD(bob.deviceId))).toThrow();
    expect(stored.push_token_ciphertext).toBeNull();
  });

  test("VoIP delivery uses bounded concurrency so one slow APNs request cannot stall the batch", async () => {
    const { alice, bob, dialogId } = await pair();
    const targetDevices = [bob.deviceId];
    for (let index = 0; index < 4; index += 1) targetDevices.push(await addDevice(bob.accountId));
    for (const [index, deviceId] of targetDevices.entries()) {
      await registerVoIPPushToken(db, deviceId, (index + 40).toString(16).padStart(2, "0").repeat(32), "sandbox");
    }
    const callId = crypto.randomUUID();
    const ctx = context(callId, dialogId, alice, bob);
    const caller = { publicKey: bytes(2), nonce: bytes(34), fingerprint: bytes(66) };
    await createCall(db, {
      callerAccountId: alice.accountId, callerDeviceId: alice.deviceId, callId, dialogId,
      callerCommitment: callerCommitmentV1(ctx, caller).toString("base64"),
      supportedProtocolVersions: [1], offeredMediaProfileVersions: [1],
    });

    const sender = new ConcurrentPausingSender();
    const processing = processVoIPPushBatch(db, sender);
    const startedConcurrently = await Promise.race([
      sender.multipleStarted.then(() => true),
      Bun.sleep(1_000).then(() => false),
    ]);
    sender.release();
    expect(startedConcurrently).toBe(true);
    expect(await processing).toBe(targetDevices.length);
    expect(sender.requests).toHaveLength(targetDevices.length);
  });

  test("only complete VoIP registrations ring and a decline is scoped to one device", async () => {
    const { alice, bob, dialogId } = await pair();
    const secondBobDevice = await addDevice(bob.accountId);
    const unregisteredBobDevice = await addDevice(bob.accountId);
    await registerVoIPPushToken(db, bob.deviceId, "d1".repeat(32), "sandbox");
    await registerVoIPPushToken(db, secondBobDevice, "d2".repeat(32), "sandbox");
    const callId = crypto.randomUUID();
    const ctx = context(callId, dialogId, alice, bob);
    const caller = { publicKey: bytes(5), nonce: bytes(37), fingerprint: bytes(69) };
    const created = await createCall(db, {
      callerAccountId: alice.accountId, callerDeviceId: alice.deviceId, callId, dialogId,
      callerCommitment: callerCommitmentV1(ctx, caller).toString("base64"),
      supportedProtocolVersions: [1], offeredMediaProfileVersions: [1],
    });
    expect(created.ringTargetCount).toBe(2);
    const targets = await db`
      SELECT device_id, status FROM call_ring_targets WHERE call_id = ${callId} ORDER BY device_id`;
    expect(targets.map((row) => row.device_id).sort()).toEqual([bob.deviceId, secondBobDevice].sort());
    expect(targets.some((row) => row.device_id === unregisteredBobDevice)).toBe(false);

    const firstDecline = await declineCall(db, {
      accountId: bob.accountId, deviceId: bob.deviceId, callId,
    });
    expect(firstDecline.call.state).toBe("requested");
    expect((await db`
      SELECT status FROM call_ring_targets WHERE call_id = ${callId} AND device_id = ${bob.deviceId}`)[0].status)
      .toBe("declined");
    expect((await db`
      SELECT status FROM call_ring_targets WHERE call_id = ${callId} AND device_id = ${secondBobDevice}`)[0].status)
      .toBe("ringing");

    const finalDecline = await declineCall(db, {
      accountId: bob.accountId, deviceId: secondBobDevice, callId,
    });
    expect(finalDecline.call.state).toBe("ended");
    expect((await declineCall(db, {
      accountId: bob.accountId, deviceId: secondBobDevice, callId,
    })).call.state).toBe("ended");
    const service = (await getHistory(db, bob.accountId, dialogId)).messages
      .find((message) => message.kind === "service" && JSON.parse(message.text).callId === callId);
    expect(JSON.parse(service!.text)).toMatchObject({
      callerAccountId: alice.accountId, outcome: "declined",
    });
  });

  test("deadline is rechecked on the locked call before credentials are issued", async () => {
    const { alice, bob, dialogId } = await pair();
    await registerVoIPPushToken(db, bob.deviceId, "d3".repeat(32), "sandbox");
    const callId = crypto.randomUUID();
    const ctx = context(callId, dialogId, alice, bob);
    const caller = { publicKey: bytes(6), nonce: bytes(38), fingerprint: bytes(70) };
    await createCall(db, {
      callerAccountId: alice.accountId, callerDeviceId: alice.deviceId, callId, dialogId,
      callerCommitment: callerCommitmentV1(ctx, caller).toString("base64"),
      supportedProtocolVersions: [1], offeredMediaProfileVersions: [1],
    });

    await db`UPDATE calls SET expires_at = now() - interval '1 second' WHERE id = ${callId}`;
    const oldURLs = process.env.TOJ_TURN_URLS;
    const oldSecret = process.env.TOJ_TURN_SHARED_SECRET;
    try {
      process.env.TOJ_TURN_URLS = "turn:one.example.test:3478";
      process.env.TOJ_TURN_SHARED_SECRET = "turn-test-secret";
      await expect(getIceConfig(db, alice.accountId, alice.deviceId, callId))
        .rejects.toMatchObject({ code: "expired" });
    } finally {
      if (oldURLs === undefined) delete process.env.TOJ_TURN_URLS;
      else process.env.TOJ_TURN_URLS = oldURLs;
      if (oldSecret === undefined) delete process.env.TOJ_TURN_SHARED_SECRET;
      else process.env.TOJ_TURN_SHARED_SECRET = oldSecret;
    }
    expect((await db`SELECT state FROM calls WHERE id = ${callId}`)[0].state).toBe("requested");
  });

  test("call history stays pending after a transient failure and retries idempotently", async () => {
    const { alice, bob, dialogId } = await pair();
    await registerVoIPPushToken(db, bob.deviceId, "d4".repeat(32), "sandbox");
    const callId = crypto.randomUUID();
    const ctx = context(callId, dialogId, alice, bob);
    const caller = { publicKey: bytes(7), nonce: bytes(39), fingerprint: bytes(71) };
    await createCall(db, {
      callerAccountId: alice.accountId, callerDeviceId: alice.deviceId, callId, dialogId,
      callerCommitment: callerCommitmentV1(ctx, caller).toString("base64"),
      supportedProtocolVersions: [1], offeredMediaProfileVersions: [1],
    });
    await sendMessage(db, {
      senderAccountId: alice.accountId, senderDeviceId: alice.deviceId, dialogId,
      clientMsgId: callId, body: "ordinary message using the public call id",
    });
    await db`
      UPDATE dialog_members SET left_at = now()
      WHERE dialog_id = ${dialogId} AND account_id = ${alice.accountId}`;
    expect((await cancelCall(db, {
      accountId: alice.accountId, deviceId: alice.deviceId, callId,
    })).call.state).toBe("ended");
    expect((await db`SELECT status, attempts FROM call_history_outbox WHERE call_id = ${callId}`)[0])
      .toMatchObject({ status: "pending", attempts: 1 });
    const outbox = (await db`
      SELECT history_client_msg_id FROM call_history_outbox WHERE call_id = ${callId}`)[0];
    expect(outbox.history_client_msg_id).not.toBe(callId);

    await db`UPDATE calls SET ended_at = now() - interval '31 days' WHERE id = ${callId}`;
    await db`UPDATE call_history_outbox SET available_at = now() + interval '1 hour' WHERE call_id = ${callId}`;
    expect((await cleanupCallData(db, 10)).calls).toBe(0);
    expect(await db`SELECT id FROM calls WHERE id = ${callId}`).toHaveLength(1);

    await db`
      UPDATE dialog_members SET left_at = NULL
      WHERE dialog_id = ${dialogId} AND account_id = ${alice.accountId}`;
    await db`UPDATE call_history_outbox SET available_at = now() WHERE call_id = ${callId}`;
    expect((await processCallHistoryOutbox(db, 1, callId)).processed).toBe(1);
    expect((await processCallHistoryOutbox(db, 1, callId)).processed).toBe(0);
    expect((await db`SELECT status FROM call_history_outbox WHERE call_id = ${callId}`)[0].status)
      .toBe("delivered");
    const rows = (await getHistory(db, bob.accountId, dialogId)).messages
      .filter((message) => message.kind === "service" && JSON.parse(message.text).callId === callId);
    expect(rows).toHaveLength(1);
  });

  test("account deletion and call termination commit together with the original caller identity", async () => {
    const { alice, bob, dialogId } = await pair();
    await registerVoIPPushToken(db, bob.deviceId, "d5".repeat(32), "sandbox");
    const callId = crypto.randomUUID();
    const ctx = context(callId, dialogId, alice, bob);
    const caller = { publicKey: bytes(8), nonce: bytes(40), fingerprint: bytes(72) };
    await createCall(db, {
      callerAccountId: alice.accountId, callerDeviceId: alice.deviceId, callId, dialogId,
      callerCommitment: callerCommitmentV1(ctx, caller).toString("base64"),
      supportedProtocolVersions: [1], offeredMediaProfileVersions: [1],
    });
    const deletion = await startAccountDeletion(db, alice.accountId);
    const result = await deleteAccountAndTerminateCalls(db, alice.accountId, deletion.code!);
    expect(result.deleted).toBe(true);
    expect((await db`SELECT status FROM accounts WHERE id = ${alice.accountId}`)[0].status).toBe("deleted");
    expect((await db`SELECT state FROM calls WHERE id = ${callId}`)[0].state).toBe("ended");
    const service = (await getHistory(db, bob.accountId, dialogId)).messages
      .find((message) => message.kind === "service" && JSON.parse(message.text).callId === callId);
    expect(service!.sender_account_id).toBe(alice.accountId);
    expect(JSON.parse(service!.text)).toMatchObject({ callerAccountId: alice.accountId });
  });

  test("device revocation and owned call termination are atomic", async () => {
    const { alice, bob, dialogId } = await pair();
    await registerVoIPPushToken(db, bob.deviceId, "d7".repeat(32), "sandbox");
    const callId = crypto.randomUUID();
    const ctx = context(callId, dialogId, alice, bob);
    const caller = { publicKey: bytes(10), nonce: bytes(42), fingerprint: bytes(74) };
    await createCall(db, {
      callerAccountId: alice.accountId, callerDeviceId: alice.deviceId, callId, dialogId,
      callerCommitment: callerCommitmentV1(ctx, caller).toString("base64"),
      supportedProtocolVersions: [1], offeredMediaProfileVersions: [1],
    });

    await expect(revokeDevice(db, alice.accountId, alice.deviceId, {
      beforeCommit: async (tx) => {
        await tx`UPDATE calls SET state = 'ended' WHERE id = ${callId}`;
        throw new Error("simulated transaction failure");
      },
    })).rejects.toThrow("simulated transaction failure");
    expect((await db`SELECT revoked_at FROM devices WHERE id = ${alice.deviceId}`)[0].revoked_at).toBeNull();
    expect((await db`SELECT state FROM calls WHERE id = ${callId}`)[0].state).toBe("requested");

    expect((await revokeDeviceAndTerminateCalls(db, alice.accountId, alice.deviceId)).revoked).toBe(true);
    expect((await db`SELECT revoked_at FROM devices WHERE id = ${alice.deviceId}`)[0].revoked_at).not.toBeNull();
    expect((await db`SELECT state FROM calls WHERE id = ${callId}`)[0].state).toBe("ended");
  });

  test("a concurrent call end cannot be overwritten by a late VoIP send result", async () => {
    const { alice, bob, dialogId } = await pair();
    await registerVoIPPushToken(db, bob.deviceId, "d6".repeat(32), "sandbox");
    const callId = crypto.randomUUID();
    const ctx = context(callId, dialogId, alice, bob);
    const caller = { publicKey: bytes(9), nonce: bytes(41), fingerprint: bytes(73) };
    await createCall(db, {
      callerAccountId: alice.accountId, callerDeviceId: alice.deviceId, callId, dialogId,
      callerCommitment: callerCommitmentV1(ctx, caller).toString("base64"),
      supportedProtocolVersions: [1], offeredMediaProfileVersions: [1],
    });
    const sender = new PausingSender();
    const processing = processVoIPPushBatch(db, sender);
    await sender.started;
    await cancelCall(db, { accountId: alice.accountId, deviceId: alice.deviceId, callId });
    sender.release();
    expect(await processing).toBe(1);
    expect((await db`
      SELECT status FROM voip_push_deliveries WHERE call_id = ${callId} AND device_id = ${bob.deviceId}`)[0].status)
      .toBe("dead");
  });

  test("blocks stop user messages and new calls but internal call history remains trusted", async () => {
    const { alice, bob, dialogId } = await pair();
    await registerVoIPPushToken(db, bob.deviceId, "e1".repeat(32), "sandbox");
    const callId = crypto.randomUUID();
    const ctx = context(callId, dialogId, alice, bob);
    const caller = { publicKey: bytes(4), nonce: bytes(36), fingerprint: bytes(68) };
    const callee = { publicKey: bytes(100), nonce: bytes(132), fingerprint: bytes(164) };
    const callerCommitment = callerCommitmentV1(ctx, caller);
    const calleeCommitment = calleeCommitmentV1(ctx, callerCommitment, bob.deviceId, 1, 1, callee);
    await createCall(db, {
      callerAccountId: alice.accountId, callerDeviceId: alice.deviceId, callId, dialogId,
      callerCommitment: callerCommitment.toString("base64"), supportedProtocolVersions: [1],
      offeredMediaProfileVersions: [1],
    });
    await acceptCall(db, { accountId: bob.accountId, deviceId: bob.deviceId, callId,
      calleeCommitment: calleeCommitment.toString("base64"), protocolVersion: 1, selectedMediaProfileVersion: 1 });
    await revealCallKey(db, { accountId: alice.accountId, deviceId: alice.deviceId, callId,
      publicKey: caller.publicKey.toString("base64"), nonce: caller.nonce.toString("base64"),
      fingerprint: caller.fingerprint.toString("base64") });
    await revealCallKey(db, { accountId: bob.accountId, deviceId: bob.deviceId, callId,
      publicKey: callee.publicKey.toString("base64"), nonce: callee.nonce.toString("base64"),
      fingerprint: callee.fingerprint.toString("base64"), confirmation: bytes(196).toString("base64") });
    await confirmCallKey(db, { accountId: alice.accountId, deviceId: alice.deviceId, callId,
      confirmation: bytes(228).toString("base64") });

    await blockAccount(db, bob.accountId, alice.accountId);
    expect((await db`SELECT state, end_reason FROM calls WHERE id = ${callId}`)[0])
      .toMatchObject({ state: "ended", end_reason: "blocked" });
    expect(await db`SELECT account_id FROM call_participant_leases WHERE call_id = ${callId}`)
      .toHaveLength(0);
    await expect(sendMessage(db, {
      senderAccountId: alice.accountId, senderDeviceId: alice.deviceId, dialogId,
      clientMsgId: crypto.randomUUID(), body: "blocked",
    })).rejects.toThrow("conversation is blocked");
    await endCall(db, { accountId: bob.accountId, deviceId: bob.deviceId, callId, reason: "local_ended" });
    await endCall(db, { accountId: bob.accountId, deviceId: bob.deviceId, callId, reason: "local_ended" });
    const serviceRows = (await getHistory(db, bob.accountId, dialogId)).messages
      .filter((message) => message.kind === "service" && JSON.parse(message.text).callId === callId);
    expect(serviceRows).toHaveLength(1);

    await expect(createCall(db, {
      callerAccountId: alice.accountId, callerDeviceId: alice.deviceId, callId: crypto.randomUUID(), dialogId,
      callerCommitment: bytes(1).toString("base64"), supportedProtocolVersions: [1],
      offeredMediaProfileVersions: [1],
    })).rejects.toMatchObject({ code: "blocked" });
  });

  test("once blocking wins the shared mutation lock, queued messages and calls cannot commit", async () => {
    const { alice, bob, dialogId } = await pair();
    await registerVoIPPushToken(db, bob.deviceId, "e6".repeat(32), "sandbox");
    const holderSql = makeSql(TEST_URL);
    const blockerSql = makeSql(TEST_URL);
    const senderSql = makeSql(TEST_URL);
    const callerSql = makeSql(TEST_URL);
    let releaseLocks!: () => void;
    let announceLocks!: () => void;
    const locksHeld = new Promise<void>((resolve) => { announceLocks = resolve; });
    const released = new Promise<void>((resolve) => { releaseLocks = resolve; });
    const holder = holderSql.begin(async (tx) => {
      await lockAccountMutations(tx, [alice.accountId, bob.accountId]);
      announceLocks();
      await released;
    });
    await locksHeld;

    const blocking = blockAccount(blockerSql, bob.accountId, alice.accountId);
    await waitForAdvisoryWaiters(1);
    const sending = sendMessage(senderSql, {
      senderAccountId: alice.accountId, senderDeviceId: alice.deviceId, dialogId,
      clientMsgId: crypto.randomUUID(), body: "must not cross the block boundary",
    }).then(() => null, (error: unknown) => error);
    const callId = crypto.randomUUID();
    const ctx = context(callId, dialogId, alice, bob);
    const calling = createCall(callerSql, {
      callerAccountId: alice.accountId, callerDeviceId: alice.deviceId, callId, dialogId,
      callerCommitment: callerCommitmentV1(ctx, {
        publicKey: bytes(11), nonce: bytes(43), fingerprint: bytes(75),
      }).toString("base64"),
      supportedProtocolVersions: [1], offeredMediaProfileVersions: [1],
    }).then(() => null, (error: unknown) => error);
    releaseLocks();
    await holder;

    expect((await blocking).blocked).toBe(true);
    expect(await sending).toMatchObject({ message: "conversation is blocked" });
    expect(await calling).toMatchObject({ code: "blocked" });
    expect(await db`SELECT id FROM calls WHERE id = ${callId}`).toHaveLength(0);
    await Promise.all([holderSql.close(), blockerSql.close(), senderSql.close(), callerSql.close()]);
  }, 15_000);

  test("HTTP event endpoint accepts the full encrypted boundary and rejects one byte over", async () => {
    const { alice, bob, dialogId } = await pair();
    await registerVoIPPushToken(db, bob.deviceId, "e2".repeat(32), "sandbox");
    const callId = crypto.randomUUID();
    const ctx = context(callId, dialogId, alice, bob);
    const caller = { publicKey: bytes(3), nonce: bytes(35), fingerprint: bytes(67) };
    const callee = { publicKey: bytes(99), nonce: bytes(131), fingerprint: bytes(163) };
    const callerCommitment = callerCommitmentV1(ctx, caller);
    const calleeCommitment = calleeCommitmentV1(ctx, callerCommitment, bob.deviceId, 1, 1, callee);
    await createCall(db, {
      callerAccountId: alice.accountId, callerDeviceId: alice.deviceId, callId, dialogId,
      callerCommitment: callerCommitment.toString("base64"), supportedProtocolVersions: [1],
      offeredMediaProfileVersions: [1],
    });
    await acceptCall(db, { accountId: bob.accountId, deviceId: bob.deviceId, callId,
      calleeCommitment: calleeCommitment.toString("base64"), protocolVersion: 1, selectedMediaProfileVersion: 1 });
    await revealCallKey(db, { accountId: alice.accountId, deviceId: alice.deviceId, callId,
      publicKey: caller.publicKey.toString("base64"), nonce: caller.nonce.toString("base64"),
      fingerprint: caller.fingerprint.toString("base64") });
    await revealCallKey(db, { accountId: bob.accountId, deviceId: bob.deviceId, callId,
      publicKey: callee.publicKey.toString("base64"), nonce: callee.nonce.toString("base64"),
      fingerprint: callee.fingerprint.toString("base64"), confirmation: bytes(195).toString("base64") });
    await confirmCallKey(db, { accountId: alice.accountId, deviceId: alice.deviceId, callId,
      confirmation: bytes(227).toString("base64") });

    const server = startCloudServer(0, db, null, null);
    const url = `http://127.0.0.1:${server.port}/v1/calls/${callId}/events`;
    try {
      const send = (size: number, sequence: number,
        kind: "offer" | "ice_candidate" | "control" = "offer") => fetch(url, {
        method: "POST",
        headers: { authorization: `Bearer ${alice.token}`, "content-type": "application/json" },
        body: JSON.stringify({
          version: 1, kind, senderSequence: sequence,
          ciphertext: Buffer.alloc(size).toString("base64"), expiresAtMilliseconds: Date.now() + 60_000,
        }),
      });
      const boundary = await send(65_564, 1);
      expect(boundary.status).toBe(201);
      const tooLarge = await send(65_565, 2);
      expect(tooLarge.status).toBe(413);
      expect(await tooLarge.json()).toMatchObject({ code: "payload_too_large" });
      const candidateTooLarge = await send(8_193, 3, "ice_candidate");
      expect(candidateTooLarge.status).toBe(413);
      expect(await candidateTooLarge.json()).toMatchObject({ code: "payload_too_large" });
      const controlTooLarge = await send(2_049, 4, "control");
      expect(controlTooLarge.status).toBe(413);
      expect(await controlTooLarge.json()).toMatchObject({ code: "payload_too_large" });
    } finally {
      await server.stop(true);
    }
  });

  test("telemetry accepts only pinned buckets, is participant-scoped, and rejects PII-shaped input", async () => {
    const { alice, bob, dialogId } = await pair();
    const carol = await account("+16505551102", "Carol");
    await registerVoIPPushToken(db, bob.deviceId, "e5".repeat(32), "sandbox");
    const callId = crypto.randomUUID();
    const ctx = context(callId, dialogId, alice, bob);
    const callerCommitment = callerCommitmentV1(ctx, { publicKey: bytes(3), nonce: bytes(35), fingerprint: bytes(67) });
    await createCall(db, {
      callerAccountId: alice.accountId, callerDeviceId: alice.deviceId, callId, dialogId,
      callerCommitment: callerCommitment.toString("base64"), supportedProtocolVersions: [1],
      offeredMediaProfileVersions: [1],
    });

    const report = {
      accountId: alice.accountId, deviceId: alice.deviceId, callId,
      outcome: "completed", routeClass: "relay_tls", privacyMode: "relay_only",
      setupBucket: "le_3s", recoveryBucket: "none", rttBucket: "le_200", lossBucket: "le_5",
      jitterBucket: "le_30", bitrateBucket: "le_32", recoveryCount: 2, appVersion: "0.1.0.0", region: "eu-central",
    };
    expect(await recordCallTelemetry(db, report)).toEqual({ recorded: true });
    expect(await recordCallTelemetry(db, report)).toEqual({ recorded: true });
    expect((await db`SELECT count(*)::int AS count FROM call_telemetry_reports WHERE call_id = ${callId}`)[0].count)
      .toBe(1);

    // A bucket value outside the pinned enumeration is rejected.
    await expect(recordCallTelemetry(db, { ...report, rttBucket: "le_9999" }))
      .rejects.toMatchObject({ code: "invalid_request" });
    // A required field is enforced.
    await expect(recordCallTelemetry(db, { ...report, outcome: undefined }))
      .rejects.toMatchObject({ code: "invalid_request" });
    // appVersion must match the safe numeric shape; free text (potential PII) is refused.
    await expect(recordCallTelemetry(db, { ...report, appVersion: "leak; DROP" }))
      .rejects.toMatchObject({ code: "invalid_request" });
    // A non-participant cannot report telemetry for a call and cannot even confirm it exists.
    await expect(recordCallTelemetry(db, { ...report, accountId: carol.accountId, deviceId: carol.deviceId }))
      .rejects.toMatchObject({ code: "not_found" });

    // The HTTP route returns 202 for a valid report and 400 for an invalid one.
    const server = startCloudServer(0, db, null, null);
    const url = `http://127.0.0.1:${server.port}/v1/calls/${callId}/telemetry`;
    try {
      const ok = await fetch(url, {
        method: "POST",
        headers: { authorization: `Bearer ${bob.token}`, "content-type": "application/json" },
        body: JSON.stringify({ outcome: "completed", rttBucket: "le_100" }),
      });
      expect(ok.status).toBe(202);
      expect(await ok.json()).toEqual({ recorded: true });
      const bad = await fetch(url, {
        method: "POST",
        headers: { authorization: `Bearer ${bob.token}`, "content-type": "application/json" },
        body: JSON.stringify({ outcome: "not_a_real_outcome" }),
      });
      expect(bad.status).toBe(400);
    } finally {
      await server.stop(true);
    }
  });
});
