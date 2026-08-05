import { afterAll, beforeEach, describe, expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { checkVerification, startVerification } from "./auth";
import { revokeDeviceAndTerminateCalls } from "./calls";
import { startCloudServer } from "./cloud";
import { makeSql } from "./db";
import {
  acquireGroupCamera,
  acquireGroupScreenShare,
  activateGroupCallEpoch as activateGroupCallEpochWithControl,
  expireStaleGroupCallParticipants,
  getGroupCall,
  getGroupCallCredentials as getGroupCallCredentialsWithControl,
  type GroupCallSFUControl,
  groupCallSFUControlConfigured,
  groupCallSchemaReadiness,
  heartbeatGroupCamera,
  heartbeatGroupCall,
  heartbeatGroupScreenShare,
  joinGroupCall as joinGroupCallWithControl,
  leaveGroupCall as leaveGroupCallWithControl,
  endGroupCall as endGroupCallWithControl,
  removeGroupCallParticipant as removeGroupCallParticipantWithControl,
  reconcileGroupCallSFUParticipant,
  reconcilePendingGroupCallSFUStates,
  requireGroupCallSFUBarrierApplied,
  releaseGroupCamera,
  releaseGroupScreenShare,
  resolveGroupCallHintTargets,
  startGroupCall,
} from "./group-calls";
import { createGroup, removeGroupMember, transferGroupOwner } from "./groups";
import { registerGroupCallCapabilities, registerVoIPPushToken } from "./push";

const TEST_URL = process.env.TEST_DATABASE_URL ?? "postgres://localhost:5432/toj_test";
const db = makeSql(TEST_URL);
const groupCallEnvironmentKeys = [
  "NODE_ENV",
  "TOJ_GROUPS_V1_ENABLED",
  "TOJ_GROUP_CALLS_ENABLED",
  "TOJ_GROUP_CALLS_SFU_READY",
  "TOJ_GROUP_CALLS_E2EE_REQUIRED",
  "TOJ_GROUP_CALLS_ROLLOUT_PERCENT",
  "TOJ_GROUP_SCREEN_SHARING_ENABLED",
  "TOJ_GROUP_SCREEN_SHARING_READY",
  "TOJ_LIVEKIT_URL",
  "TOJ_LIVEKIT_API_KEY",
  "TOJ_LIVEKIT_API_SECRET",
  "TOJ_LIVEKIT_DEPLOYMENT",
] as const;
const savedGroupCallEnvironment = new Map(
  groupCallEnvironmentKeys.map((key) => [key, process.env[key]]),
);

class FakeGroupCallSFUControl implements GroupCallSFUControl {
  rooms: Array<{ room: string; participantLimit: number }> = [];
  updates: Array<{
    room: string; identity: string; mediaAllowed: boolean;
    cameraAllowed: boolean; screenShareAllowed: boolean;
  }> = [];
  removals: Array<{ room: string; identity: string; tokenNotBefore: number }> = [];
  private updateGate: {
    started: () => void;
    resume: Promise<void>;
  } | null = null;
  private failingUpdates = 0;
  private failingRemovals = 0;
  private updateDelayMs = 0;
  private cloudTokenCutoffs = false;
  activeUpdates = 0;
  maxConcurrentUpdates = 0;

  async ensureRoom(room: string, participantLimit: number) {
    this.rooms.push({ room, participantLimit });
  }

  async updateParticipant(input: {
    room: string; identity: string; mediaAllowed: boolean;
    cameraAllowed: boolean; screenShareAllowed: boolean;
  }) {
    this.updates.push(input);
    this.activeUpdates += 1;
    this.maxConcurrentUpdates = Math.max(this.maxConcurrentUpdates, this.activeUpdates);
    try {
      if (this.failingUpdates > 0) {
        this.failingUpdates -= 1;
        throw new Error("injected SFU update failure");
      }
      if (this.updateGate) {
        const gate = this.updateGate;
        this.updateGate = null;
        gate.started();
        await gate.resume;
      }
      if (this.updateDelayMs > 0) {
        await new Promise((resolve) => setTimeout(resolve, this.updateDelayMs));
      }
    } finally {
      this.activeUpdates -= 1;
    }
  }

  async removeParticipant(room: string, identity: string) {
    const tokenNotBefore = this.cloudTokenCutoffs ? Math.floor(Date.now() / 1_000) + 1 : 0;
    this.removals.push({ room, identity, tokenNotBefore });
    this.activeUpdates += 1;
    this.maxConcurrentUpdates = Math.max(this.maxConcurrentUpdates, this.activeUpdates);
    try {
      if (this.failingRemovals > 0) {
        this.failingRemovals -= 1;
        throw new Error("injected SFU removal failure");
      }
      if (this.updateDelayMs > 0) {
        await new Promise((resolve) => setTimeout(resolve, this.updateDelayMs));
      }
    } finally {
      this.activeUpdates -= 1;
    }
    return tokenNotBefore;
  }

  pauseNextUpdate(): { started: Promise<void>; resume: () => void } {
    let markStarted: () => void = () => {};
    let resume: () => void = () => {};
    const started = new Promise<void>((resolve) => { markStarted = resolve; });
    const resumePromise = new Promise<void>((resolve) => { resume = resolve; });
    this.updateGate = { started: markStarted, resume: resumePromise };
    return { started, resume };
  }

  failNextUpdates(count = 1) {
    this.failingUpdates = count;
  }

  failNextRemovals(count = 1) {
    this.failingRemovals = count;
  }

  delayUpdates(milliseconds: number) {
    this.updateDelayMs = milliseconds;
  }

  useCloudTokenCutoffs() {
    this.cloudTokenCutoffs = true;
  }
}

let sfu: FakeGroupCallSFUControl;

const joinGroupCall = (
  sql: Parameters<typeof joinGroupCallWithControl>[0],
  input: Parameters<typeof joinGroupCallWithControl>[1],
) => joinGroupCallWithControl(sql, input, sfu);
const activateGroupCallEpoch = (
  sql: Parameters<typeof activateGroupCallEpochWithControl>[0],
  input: Parameters<typeof activateGroupCallEpochWithControl>[1],
) => activateGroupCallEpochWithControl(sql, input, sfu);
const leaveGroupCall = (
  sql: Parameters<typeof leaveGroupCallWithControl>[0],
  input: Parameters<typeof leaveGroupCallWithControl>[1],
) => leaveGroupCallWithControl(sql, input, sfu);
const endGroupCall = (
  sql: Parameters<typeof endGroupCallWithControl>[0],
  input: Parameters<typeof endGroupCallWithControl>[1],
) => endGroupCallWithControl(sql, input, sfu);
const removeGroupCallParticipant = (
  sql: Parameters<typeof removeGroupCallParticipantWithControl>[0],
  input: Parameters<typeof removeGroupCallParticipantWithControl>[1],
) => removeGroupCallParticipantWithControl(sql, input, sfu);
const getGroupCallCredentials = (
  sql: Parameters<typeof getGroupCallCredentialsWithControl>[0],
  accountId: string,
  deviceId: string,
  callId: unknown,
) => getGroupCallCredentialsWithControl(sql, accountId, deviceId, callId, sfu);

function configureGroupCalls() {
  process.env.NODE_ENV = "test";
  process.env.TOJ_GROUPS_V1_ENABLED = "1";
  process.env.TOJ_GROUP_CALLS_ENABLED = "1";
  process.env.TOJ_GROUP_CALLS_SFU_READY = "1";
  process.env.TOJ_GROUP_CALLS_E2EE_REQUIRED = "1";
  process.env.TOJ_GROUP_CALLS_ROLLOUT_PERCENT = "100";
  process.env.TOJ_GROUP_SCREEN_SHARING_ENABLED = "1";
  process.env.TOJ_GROUP_SCREEN_SHARING_READY = "1";
  process.env.TOJ_LIVEKIT_URL = "wss://group-media.test.toj.example";
  process.env.TOJ_LIVEKIT_API_KEY = "test-key";
  process.env.TOJ_LIVEKIT_API_SECRET = "test-secret-that-is-at-least-thirty-two-bytes-long";
  process.env.TOJ_LIVEKIT_DEPLOYMENT = "cloud";
}

async function resetDb() {
  await db`TRUNCATE accounts, otp_challenges RESTART IDENTITY CASCADE`;
  configureGroupCalls();
  sfu = new FakeGroupCallSFUControl();
}

async function account(phone: string, name: string, tokenByte: string) {
  const { code } = await startVerification(db, phone);
  const session = await checkVerification(db, phone, code, "ios", `${name} iPhone`, name);
  await registerVoIPPushToken(
    db, session.deviceId, tokenByte.repeat(32), "sandbox",
    [1], [1, 2], 2, [1], 1, true,
  );
  return session;
}

async function secondDevice(phone: string, name: string, tokenByte: string) {
  await db`UPDATE otp_challenges SET created_at = created_at - interval '31 seconds'`;
  const { code } = await startVerification(db, phone);
  const session = await checkVerification(db, phone, code, "ios", `${name} iPad`, name);
  await registerVoIPPushToken(
    db, session.deviceId, tokenByte.repeat(32), "sandbox",
    [1], [1, 2], 2, [1], 1, true,
  );
  return session;
}

const bytes = (value: number, count = 32) => Buffer.alloc(count, value).toString("base64");

function transcriptHash(participants: Array<{
  accountId: string; deviceId: string; joinPublicKey: string; joinNonce: string;
}>): string {
  const hash = createHash("sha256");
  const add = (value: Buffer) => {
    const length = Buffer.allocUnsafe(4);
    length.writeUInt32BE(value.length);
    hash.update(length).update(value);
  };
  add(Buffer.from("toj-group-participants-v1", "utf8"));
  for (const participant of [...participants].sort((left, right) =>
    left.deviceId.localeCompare(right.deviceId))) {
    add(Buffer.from(participant.accountId, "utf8"));
    add(Buffer.from(participant.deviceId, "utf8"));
    add(Buffer.from(participant.joinPublicKey, "base64"));
    add(Buffer.from(participant.joinNonce, "base64"));
  }
  return hash.digest("base64");
}

async function fixture() {
  const owner = await account("+16505554100", "Owner", "a1");
  const alice = await account("+16505554101", "Alice", "a2");
  const bob = await account("+16505554102", "Bob", "a3");
  const groupId = crypto.randomUUID();
  await createGroup(db, {
    creatorAccountId: owner.accountId,
    creatorDeviceId: owner.deviceId,
    groupId,
    title: "Group call",
    memberIds: [alice.accountId, bob.accountId],
  });
  return { owner, alice, bob, groupId };
}

async function start(owner: Awaited<ReturnType<typeof account>>, groupId: string) {
  return startGroupCall(db, {
    accountId: owner.accountId,
    deviceId: owner.deviceId,
    callId: crypto.randomUUID(),
    dialogId: groupId,
    initialKind: "video",
    joinPublicKey: bytes(11),
    joinNonce: bytes(12),
    epochKeyCommitment: bytes(13),
  }, sfu);
}

async function joinAndActivate(
  owner: Awaited<ReturnType<typeof account>>,
  joining: Awaited<ReturnType<typeof account>>,
  started: Awaited<ReturnType<typeof start>>,
  seed: number,
) {
  const joined = await joinGroupCall(db, {
    accountId: joining.accountId,
    deviceId: joining.deviceId,
    callId: started.call.id,
    joinPublicKey: bytes(seed),
    joinNonce: bytes(seed + 1),
  });
  const activated = await activateGroupCallEpoch(db, {
    accountId: owner.accountId,
    deviceId: owner.deviceId,
    callId: started.call.id,
    epoch: started.call.mediaEpoch + 1,
    expectedMembershipRevision: joined.call.membershipRevision,
    keyCommitment: bytes(seed + 2),
    participantSetHash: transcriptHash(joined.call.participants),
    envelopes: [{
      recipientDeviceId: joining.deviceId,
      ciphertext: bytes(seed + 3, 48),
    }],
  });
  return { joined, activated };
}

describe("E2EE group calls and screen sharing", () => {
  beforeEach(resetDb);

  test("schema contract is complete and legacy device registration clears group capabilities", async () => {
    expect(await groupCallSchemaReadiness(db)).toEqual({
      ready: true,
      missingTables: [],
      missingDeviceColumns: [],
      missingCriticalColumns: [],
      invalidColumns: [],
      invalidPrimaryKeys: [],
      missingIndexes: [],
      invalidIndexes: [],
      invalidConstraints: [],
      missingMigrations: [],
    });
    const alice = await account("+16505554110", "Alice", "b1");
    const capable = (await db`
      SELECT supported_group_call_versions, group_call_view_version, supports_group_screen_share
      FROM devices WHERE id = ${alice.deviceId}`)[0];
    expect(Array.from(capable.supported_group_call_versions, Number)).toEqual([1]);
    expect(Number(capable.group_call_view_version)).toBe(1);
    expect(capable.supports_group_screen_share).toBe(true);

    await registerVoIPPushToken(db, alice.deviceId, "b1".repeat(32), "sandbox");
    const legacy = (await db`
      SELECT supported_group_call_versions, group_call_view_version, supports_group_screen_share
      FROM devices WHERE id = ${alice.deviceId}`)[0];
    expect(Array.from(legacy.supported_group_call_versions, Number)).toEqual([]);
    expect(Number(legacy.group_call_view_version)).toBe(0);
    expect(legacy.supports_group_screen_share).toBe(false);

    await registerGroupCallCapabilities(db, alice.deviceId, [1], 1, true);
    await registerGroupCallCapabilities(db, alice.deviceId, [], 0, false);
    const explicitlyCleared = (await db`
      SELECT supported_group_call_versions, group_call_view_version, supports_group_screen_share
      FROM devices WHERE id = ${alice.deviceId}`)[0];
    expect(Array.from(explicitlyCleared.supported_group_call_versions, Number)).toEqual([]);
    expect(Number(explicitlyCleared.group_call_view_version)).toBe(0);
    expect(explicitlyCleared.supports_group_screen_share).toBe(false);

    await registerVoIPPushToken(
      db, alice.deviceId, "b1".repeat(32), "sandbox", [1], [1, 2], 2, [1], 1, true,
    );
    await registerVoIPPushToken(
      db, alice.deviceId, "b1".repeat(32), "sandbox", [1], [1, 2], 2, [], 0, false,
    );
    const voipExplicitlyCleared = (await db`
      SELECT supported_group_call_versions, group_call_view_version, supports_group_screen_share
      FROM devices WHERE id = ${alice.deviceId}`)[0];
    expect(Array.from(voipExplicitlyCleared.supported_group_call_versions, Number)).toEqual([]);
    expect(Number(voipExplicitlyCleared.group_call_view_version)).toBe(0);
    expect(voipExplicitlyCleared.supports_group_screen_share).toBe(false);
  });

  test("schema readiness fails closed on drifted columns, indexes, constraints, and markers", async () => {
    let readiness: Awaited<ReturnType<typeof groupCallSchemaReadiness>> | undefined;
    const rollback = new Error("rollback schema drift probe");
    try {
      await db.begin(async (transaction) => {
        await transaction`
          ALTER TABLE group_call_sfu_participant_states
          ALTER COLUMN media_allowed DROP NOT NULL`;
        await transaction`DROP INDEX group_call_sfu_state_retention_idx`;
        await transaction`
          CREATE INDEX group_call_sfu_state_retention_idx
          ON group_call_sfu_participant_states(call_id)`;
        await transaction`
          ALTER TABLE group_call_sfu_participant_states
          DROP CONSTRAINT group_call_sfu_media_gate_check`;
        await transaction`
          ALTER TABLE group_call_sfu_participant_states
          ADD CONSTRAINT group_call_sfu_media_gate_check CHECK (TRUE)`;
        await transaction`
          DELETE FROM schema_migrations WHERE name = 'group-calls-media-fence-v2'`;
        readiness = await groupCallSchemaReadiness(transaction, { bypassCache: true });
        throw rollback;
      });
    } catch (error) {
      if (error !== rollback) throw error;
    }

    expect(readiness?.ready).toBe(false);
    expect(readiness?.invalidColumns).toContain(
      "group_call_sfu_participant_states.media_allowed",
    );
    expect(readiness?.invalidIndexes).toContain("group_call_sfu_state_retention_idx");
    expect(readiness?.invalidConstraints).toContain("group_call_sfu_media_gate_check");
    expect(readiness?.missingMigrations).toContain("group-calls-media-fence-v2");
    expect((await groupCallSchemaReadiness(db, { bypassCache: true })).ready).toBe(true);
  });

  test("group media capability registration does not require or create a PushKit target", async () => {
    const { code } = await startVerification(db, "+16505554111");
    const session = await checkVerification(
      db, "+16505554111", code, "ios", "Muted iPad", "Muted",
    );
    const response = await registerGroupCallCapabilities(db, session.deviceId, [1], 1, true);
    expect(response).toEqual({
      registered: true,
      supportedGroupCallVersions: [1],
      groupCallViewVersion: 1,
      supportsGroupScreenShare: true,
    });
    const device = (await db`
      SELECT voip_push_token_hash, supported_group_call_versions,
        group_call_view_version, supports_group_screen_share
      FROM devices WHERE id = ${session.deviceId}`)[0];
    expect(device.voip_push_token_hash).toBeNull();
    expect(Array.from(device.supported_group_call_versions, Number)).toEqual([1]);
    expect(Number(device.group_call_view_version)).toBe(1);
    expect(device.supports_group_screen_share).toBe(true);
  });

  test("the SFU drain plane remains configured after admission is switched off", () => {
    process.env.TOJ_GROUP_CALLS_ENABLED = "0";
    process.env.TOJ_GROUP_CALLS_ROLLOUT_PERCENT = "0";
    expect(groupCallSFUControlConfigured()).toBe(true);
    process.env.TOJ_GROUP_CALLS_SFU_READY = "0";
    expect(groupCallSFUControlConfigured()).toBe(false);
  });

  test("production refuses an SFU deployment that cannot revoke cached room tokens", () => {
    process.env.NODE_ENV = "production";
    delete process.env.TOJ_LIVEKIT_DEPLOYMENT;
    expect(groupCallSFUControlConfigured()).toBe(false);
    process.env.TOJ_LIVEKIT_DEPLOYMENT = "cloud";
    expect(groupCallSFUControlConfigured()).toBe(true);
  });

  test("capability discovery is scoped to the authenticated device", async () => {
    const owner = await account("+16505554120", "Capability", "d1");
    const legacyDevice = await secondDevice("+16505554120", "Capability", "d2");
    await registerGroupCallCapabilities(db, legacyDevice.deviceId, [], 0, false);
    const server = startCloudServer(0, db, null, null, {
      backgroundWorkers: false,
      groupCallSFUControl: sfu,
    });
    try {
      const base = `http://127.0.0.1:${server.port}`;
      const capabilities = async (token: string) => {
        const response = await fetch(`${base}/v1/capabilities`, {
          headers: { authorization: `Bearer ${token}` },
        });
        expect(response.status).toBe(200);
        return (await response.json() as { capabilities: string[] }).capabilities;
      };
      expect(await capabilities(owner.token)).toContain("group_calls_v1");
      expect(await capabilities(legacyDevice.token)).not.toContain("group_calls_v1");
    } finally {
      server.stop(true);
    }
  });

  test("start and rekey issue only room-scoped short-lived credentials after exact envelope coverage", async () => {
    const { owner, alice, groupId } = await fixture();
    const started = await start(owner, groupId);
    expect(started.call.participants).toHaveLength(1);
    expect(started.call.rekeyRequired).toBe(false);
    const [, claimsPart] = started.credentials.token.split(".");
    const claims = JSON.parse(Buffer.from(claimsPart, "base64url").toString("utf8"));
    expect(claims.sub).toBe(started.credentials.participantId);
    expect(claims.video).toMatchObject({
      roomJoin: true,
      canPublish: true,
      canSubscribe: true,
      canPublishData: false,
      roomAdmin: false,
      roomCreate: false,
      roomRecord: false,
      canPublishSources: ["microphone"],
    });
    expect(claims.video.room).toMatch(/^toj_gc_/);
    expect(sfu.rooms).toEqual([{
      room: claims.video.room,
      participantLimit: 32,
    }]);
    expect(claims.exp - claims.iat).toBe(300);
    expect(JSON.stringify(claims)).not.toContain(owner.accountId);
    expect(started.credentials.token).not.toContain(process.env.TOJ_LIVEKIT_API_SECRET!);

    sfu.useCloudTokenCutoffs();
    const joined = await joinGroupCall(db, {
      accountId: alice.accountId,
      deviceId: alice.deviceId,
      callId: started.call.id,
      joinPublicKey: bytes(21),
      joinNonce: bytes(22),
    });
    expect(joined.call.rekeyRequired).toBe(true);
    expect(joined.call.participants.find((item) => item.deviceId === alice.deviceId)?.status)
      .toBe("pending_key");
    await expect(getGroupCallCredentials(db, alice.accountId, alice.deviceId, started.call.id))
      .rejects.toMatchObject({ code: "epoch_not_ready", status: 409 });
    await expect(startGroupCall(db, {
      accountId: owner.accountId,
      deviceId: owner.deviceId,
      callId: started.call.id,
      dialogId: groupId,
      initialKind: "video",
      joinPublicKey: bytes(11),
      joinNonce: bytes(12),
      epochKeyCommitment: bytes(13),
    }, sfu)).rejects.toMatchObject({ code: "epoch_not_ready", status: 409 });

    const nextEpoch = started.call.mediaEpoch + 1;
    const activation = await activateGroupCallEpoch(db, {
      accountId: owner.accountId,
      deviceId: owner.deviceId,
      callId: started.call.id,
      epoch: nextEpoch,
      expectedMembershipRevision: joined.call.membershipRevision,
      keyCommitment: bytes(23),
      participantSetHash: transcriptHash(joined.call.participants),
      envelopes: [{ recipientDeviceId: alice.deviceId, ciphertext: bytes(24, 48) }],
    });
    expect(activation.call.rekeyRequired).toBe(false);
    expect(activation.call.participants.every((item) => item.status === "active")).toBe(true);
    const aliceView = await getGroupCall(db, alice.accountId, alice.deviceId, started.call.id);
    expect(aliceView.call.selfEnvelope).toMatchObject({
      epoch: nextEpoch,
      ciphertext: bytes(24, 48),
    });
    expect((await getGroupCallCredentials(
      db, alice.accountId, alice.deviceId, started.call.id,
    )).credentials.mediaEpoch).toBe(nextEpoch);
    const replacement = (await getGroupCallCredentials(
      db, owner.accountId, owner.deviceId, started.call.id,
    )).credentials;
    const replacementClaims = JSON.parse(Buffer.from(
      replacement.token.split(".")[1],
      "base64url",
    ).toString("utf8"));
    const ownerCutoff = Math.max(...sfu.removals
      .filter((removal) => removal.identity === started.credentials.participantId)
      .map((removal) => removal.tokenNotBefore));
    expect(ownerCutoff).toBeGreaterThan(claims.nbf);
    expect(replacementClaims.nbf).toBeGreaterThanOrEqual(ownerCutoff);

    const retry = await activateGroupCallEpoch(db, {
      accountId: owner.accountId,
      deviceId: owner.deviceId,
      callId: started.call.id,
      epoch: nextEpoch,
      expectedMembershipRevision: joined.call.membershipRevision,
      keyCommitment: bytes(23),
      participantSetHash: transcriptHash(joined.call.participants),
      envelopes: [{ recipientDeviceId: alice.deviceId, ciphertext: bytes(24, 48) }],
    });
    expect(retry.duplicate).toBe(true);
  });

  test("an unjoined device cannot drive a pending SFU reconciliation for a guessed call", async () => {
    const { owner, bob, groupId } = await fixture();
    const started = await start(owner, groupId);
    await db`
      UPDATE group_call_sfu_participant_states
      SET revision = revision + 1, updated_at = now(), next_attempt_at = now()
      WHERE call_id = ${started.call.id} AND device_id = ${owner.deviceId}`;
    const updateCount = sfu.updates.length;
    const removalCount = sfu.removals.length;

    await expect(getGroupCallCredentials(
      db, bob.accountId, bob.deviceId, started.call.id,
    )).rejects.toMatchObject({ code: "not_joined", status: 409 });

    expect(sfu.updates).toHaveLength(updateCount);
    expect(sfu.removals).toHaveLength(removalCount);
    const pending = (await db`
      SELECT revision, applied_revision
      FROM group_call_sfu_participant_states
      WHERE call_id = ${started.call.id} AND device_id = ${owner.deviceId}`)[0];
    expect(Number(pending.applied_revision)).toBeLessThan(Number(pending.revision));
  });

  test("membership changes fail closed until every old SFU session is revoked and rekeyed", async () => {
    const { owner, alice, groupId } = await fixture();
    const started = await start(owner, groupId);
    await acquireGroupCamera(db, {
      accountId: owner.accountId,
      deviceId: owner.deviceId,
      callId: started.call.id,
      generation: crypto.randomUUID(),
    }, sfu);

    sfu.failNextRemovals();
    await expect(joinGroupCall(db, {
      accountId: alice.accountId,
      deviceId: alice.deviceId,
      callId: started.call.id,
      joinPublicKey: bytes(25),
      joinNonce: bytes(26),
    })).rejects.toMatchObject({ code: "sfu_control_unavailable", status: 503 });

    const fenced = await getGroupCall(db, owner.accountId, owner.deviceId, started.call.id);
    expect(fenced.call.rekeyRequired).toBe(true);
    expect(fenced.call.participants).toHaveLength(2);
    expect(await db`
      SELECT 1 FROM group_call_camera_leases WHERE call_id = ${started.call.id}`)
      .toHaveLength(0);
    await expect(getGroupCallCredentials(
      db, owner.accountId, owner.deviceId, started.call.id,
    )).rejects.toMatchObject({ code: "sfu_control_unavailable", status: 503 });

    const pending = (await db`
      SELECT media_allowed, applied_media_allowed, revision, applied_revision,
        attempt_count, last_error_code
      FROM group_call_sfu_participant_states
      WHERE call_id = ${started.call.id} AND device_id = ${owner.deviceId}`)[0];
    expect(pending.media_allowed).toBe(false);
    expect(pending.applied_media_allowed).toBe(true);
    expect(Number(pending.applied_revision)).toBeLessThan(Number(pending.revision));
    expect(Number(pending.attempt_count)).toBe(1);
    expect(pending.last_error_code).toBe("request_failed");

    await db`
      UPDATE group_call_sfu_participant_states SET next_attempt_at = now()
      WHERE call_id = ${started.call.id}`;
    await requireGroupCallSFUBarrierApplied(db, [started.call.id], sfu);
    expect(sfu.removals).toContainEqual(expect.objectContaining({
      identity: started.credentials.participantId,
    }));
    await expect(getGroupCallCredentials(
      db, owner.accountId, owner.deviceId, started.call.id,
    )).rejects.toMatchObject({ code: "epoch_not_ready", status: 409 });

    const activated = await activateGroupCallEpoch(db, {
      accountId: owner.accountId,
      deviceId: owner.deviceId,
      callId: started.call.id,
      epoch: 2,
      expectedMembershipRevision: fenced.call.membershipRevision,
      keyCommitment: bytes(27),
      participantSetHash: transcriptHash(fenced.call.participants),
      envelopes: [{ recipientDeviceId: alice.deviceId, ciphertext: bytes(28, 48) }],
    });
    expect(activated.call.rekeyRequired).toBe(false);
    expect((await getGroupCallCredentials(
      db, owner.accountId, owner.deviceId, started.call.id,
    )).credentials.mediaEpoch).toBe(2);
    const applied = (await db`
      SELECT attempt_count, last_error_code, applied_media_allowed
      FROM group_call_sfu_participant_states
      WHERE call_id = ${started.call.id} AND device_id = ${owner.deviceId}`)[0];
    expect(Number(applied.attempt_count)).toBe(0);
    expect(applied.last_error_code).toBeNull();
    expect(applied.applied_media_allowed).toBe(true);
  });

  test("rekey rejects omitted recipients, wrong transcripts, stale revisions, and non-leaders", async () => {
    const { owner, alice, bob, groupId } = await fixture();
    const started = await start(owner, groupId);
    await joinGroupCall(db, {
      accountId: alice.accountId, deviceId: alice.deviceId, callId: started.call.id,
      joinPublicKey: bytes(31), joinNonce: bytes(32),
    });
    const joined = await joinGroupCall(db, {
      accountId: bob.accountId, deviceId: bob.deviceId, callId: started.call.id,
      joinPublicKey: bytes(33), joinNonce: bytes(34),
    });
    const base = {
      callId: started.call.id,
      epoch: 2,
      expectedMembershipRevision: joined.call.membershipRevision,
      keyCommitment: bytes(35),
      participantSetHash: transcriptHash(joined.call.participants),
    };
    await expect(activateGroupCallEpoch(db, {
      accountId: owner.accountId, deviceId: owner.deviceId, ...base,
      envelopes: [{ recipientDeviceId: alice.deviceId, ciphertext: bytes(36, 48) }],
    })).rejects.toMatchObject({ code: "incomplete_epoch", status: 409 });
    await expect(activateGroupCallEpoch(db, {
      accountId: owner.accountId, deviceId: owner.deviceId, ...base,
      participantSetHash: bytes(99),
      envelopes: [
        { recipientDeviceId: alice.deviceId, ciphertext: bytes(36, 48) },
        { recipientDeviceId: bob.deviceId, ciphertext: bytes(37, 48) },
      ],
    })).rejects.toMatchObject({ code: "stale_membership", status: 409 });
    await expect(activateGroupCallEpoch(db, {
      accountId: alice.accountId, deviceId: alice.deviceId, ...base,
      envelopes: [
        { recipientDeviceId: owner.deviceId, ciphertext: bytes(36, 48) },
        { recipientDeviceId: bob.deviceId, ciphertext: bytes(37, 48) },
      ],
    })).rejects.toMatchObject({ code: "not_key_leader", status: 403 });
  });

  test("group member removal revokes call access and forces an atomic epoch change", async () => {
    const { owner, alice, groupId } = await fixture();
    const started = await start(owner, groupId);
    const joined = await joinGroupCall(db, {
      accountId: alice.accountId, deviceId: alice.deviceId, callId: started.call.id,
      joinPublicKey: bytes(41), joinNonce: bytes(42),
    });
    await activateGroupCallEpoch(db, {
      accountId: owner.accountId, deviceId: owner.deviceId, callId: started.call.id,
      epoch: 2, expectedMembershipRevision: joined.call.membershipRevision,
      keyCommitment: bytes(43), participantSetHash: transcriptHash(joined.call.participants),
      envelopes: [{ recipientDeviceId: alice.deviceId, ciphertext: bytes(44, 48) }],
    });
    await removeGroupMember(db, {
      actorAccountId: owner.accountId,
      actorDeviceId: owner.deviceId,
      dialogId: groupId,
      targetAccountId: alice.accountId,
      clientMutationId: crypto.randomUUID(),
    }, sfu);
    const ownerView = await getGroupCall(db, owner.accountId, owner.deviceId, started.call.id);
    expect(ownerView.call.rekeyRequired).toBe(true);
    expect(ownerView.call.participants.map((item) => item.accountId)).toEqual([owner.accountId]);
    await expect(getGroupCall(db, alice.accountId, alice.deviceId, started.call.id))
      .rejects.toMatchObject({ code: "group_access_revoked", status: 410 });
    const removed = (await db`
      SELECT status, left_at FROM group_call_participants
      WHERE call_id = ${started.call.id} AND device_id = ${alice.deviceId}`)[0];
    expect(removed.status).toBe("removed");
    expect(removed.left_at).not.toBeNull();
  });

  test("only owners and admins can remove participants or end a call, and a removed account cannot rejoin", async () => {
    const { owner, alice, bob, groupId } = await fixture();
    const started = await start(owner, groupId);
    await joinGroupCall(db, {
      accountId: alice.accountId, deviceId: alice.deviceId, callId: started.call.id,
      joinPublicKey: bytes(45), joinNonce: bytes(46),
    });
    const joined = await joinGroupCall(db, {
      accountId: bob.accountId, deviceId: bob.deviceId, callId: started.call.id,
      joinPublicKey: bytes(47), joinNonce: bytes(48),
    });
    await activateGroupCallEpoch(db, {
      accountId: owner.accountId, deviceId: owner.deviceId, callId: started.call.id,
      epoch: 2, expectedMembershipRevision: joined.call.membershipRevision,
      keyCommitment: bytes(49), participantSetHash: transcriptHash(joined.call.participants),
      envelopes: [
        { recipientDeviceId: alice.deviceId, ciphertext: bytes(50, 48) },
        { recipientDeviceId: bob.deviceId, ciphertext: bytes(51, 48) },
      ],
    });
    await db`
      UPDATE dialog_members SET role = 'admin'
      WHERE dialog_id = ${groupId} AND account_id = ${alice.accountId}`;

    await expect(endGroupCall(db, {
      accountId: bob.accountId, deviceId: bob.deviceId, callId: started.call.id,
    })).rejects.toMatchObject({ code: "insufficient_group_role", status: 403 });
    await expect(removeGroupCallParticipant(db, {
      accountId: bob.accountId, deviceId: bob.deviceId, callId: started.call.id,
      targetDeviceId: alice.deviceId,
    })).rejects.toMatchObject({ code: "insufficient_group_role", status: 403 });
    await expect(removeGroupCallParticipant(db, {
      accountId: alice.accountId, deviceId: alice.deviceId, callId: started.call.id,
      targetDeviceId: owner.deviceId,
    })).rejects.toMatchObject({ code: "insufficient_group_role", status: 403 });

    const removed = await removeGroupCallParticipant(db, {
      accountId: alice.accountId, deviceId: alice.deviceId, callId: started.call.id,
      targetDeviceId: bob.deviceId,
    });
    expect(removed.call.selfRole).toBe("admin");
    expect(removed.call.participants.some((participant) => participant.deviceId === bob.deviceId))
      .toBe(false);
    await expect(joinGroupCall(db, {
      accountId: bob.accountId, deviceId: bob.deviceId, callId: started.call.id,
      joinPublicKey: bytes(52), joinNonce: bytes(53),
    })).rejects.toMatchObject({ code: "removed_from_call", status: 403 });

    const ended = await endGroupCall(db, {
      accountId: alice.accountId, deviceId: alice.deviceId, callId: started.call.id,
    });
    expect(ended.call).toMatchObject({ state: "ended", endReason: "ended_by_admin" });
    expect(ended.duplicate).toBe(false);
    expect((await endGroupCall(db, {
      accountId: owner.accountId, deviceId: owner.deviceId, callId: started.call.id,
    })).duplicate).toBe(true);
  });

  test("device revocation waits behind an authenticated start and atomically drains its call", async () => {
    const { owner, groupId } = await fixture();
    let releaseDialog: () => void = () => {};
    let markDialogLocked: () => void = () => {};
    const dialogLocked = new Promise<void>((resolve) => { markDialogLocked = resolve; });
    const dialogRelease = new Promise<void>((resolve) => { releaseDialog = resolve; });
    const blocker = db.begin(async (tx) => {
      await tx`SELECT id FROM dialogs WHERE id = ${groupId} FOR UPDATE`;
      markDialogLocked();
      await dialogRelease;
    });
    await dialogLocked;

    const startAttempt = start(owner, groupId);
    let startWaitingOnDialog = false;
    for (let attempt = 0; attempt < 100; attempt += 1) {
      const waiting = await db`
        SELECT 1 FROM pg_stat_activity
        WHERE datname = current_database() AND pid <> pg_backend_pid()
          AND wait_event_type = 'Lock'
          AND query ILIKE '%FROM dialogs WHERE id =%'
        LIMIT 1`;
      if (waiting.length) {
        startWaitingOnDialog = true;
        break;
      }
      await new Promise((resolve) => setTimeout(resolve, 5));
    }

    const revocation = revokeDeviceAndTerminateCalls(db, owner.accountId, owner.deviceId, sfu);
    const revocationOutcome = await Promise.race([
      revocation.then(() => "revoked"),
      new Promise<string>((resolve) => setTimeout(() => resolve("blocked"), 40)),
    ]);
    releaseDialog();
    await blocker;
    const [startResult, revokeResult] = await Promise.allSettled([startAttempt, revocation]);

    expect(startWaitingOnDialog).toBe(true);
    expect(revocationOutcome).toBe("blocked");
    expect(startResult.status).toBe("fulfilled");
    expect(revokeResult.status).toBe("fulfilled");
    expect(await db`
      SELECT 1 FROM group_calls
      WHERE dialog_id = ${groupId} AND state = 'active'`).toHaveLength(0);
  });

  test("state revisions advance for every externally visible room mutation", async () => {
    const { owner, alice, groupId } = await fixture();
    const revisions: number[] = [];
    const started = await start(owner, groupId);
    revisions.push(started.call.stateRevision);
    const joined = await joinGroupCall(db, {
      accountId: alice.accountId, deviceId: alice.deviceId, callId: started.call.id,
      joinPublicKey: bytes(54), joinNonce: bytes(55),
    });
    revisions.push(joined.call.stateRevision);
    const activated = await activateGroupCallEpoch(db, {
      accountId: owner.accountId, deviceId: owner.deviceId, callId: started.call.id,
      epoch: 2, expectedMembershipRevision: joined.call.membershipRevision,
      keyCommitment: bytes(56), participantSetHash: transcriptHash(joined.call.participants),
      envelopes: [{ recipientDeviceId: alice.deviceId, ciphertext: bytes(57, 48) }],
    });
    revisions.push(activated.call.stateRevision);
    const cameraGeneration = crypto.randomUUID();
    revisions.push((await acquireGroupCamera(db, {
      accountId: owner.accountId, deviceId: owner.deviceId,
      callId: started.call.id, generation: cameraGeneration,
    }, sfu)).call.stateRevision);
    await releaseGroupCamera(db, {
      accountId: owner.accountId, deviceId: owner.deviceId,
      callId: started.call.id, generation: cameraGeneration,
    }, sfu);
    revisions.push((await getGroupCall(db, owner.accountId, owner.deviceId, started.call.id))
      .call.stateRevision);
    const screenGeneration = crypto.randomUUID();
    revisions.push((await acquireGroupScreenShare(db, {
      accountId: owner.accountId, deviceId: owner.deviceId,
      callId: started.call.id, generation: screenGeneration,
    }, sfu)).call.stateRevision);
    await releaseGroupScreenShare(db, {
      accountId: owner.accountId, deviceId: owner.deviceId,
      callId: started.call.id, generation: screenGeneration,
    }, sfu);
    revisions.push((await getGroupCall(db, owner.accountId, owner.deviceId, started.call.id))
      .call.stateRevision);
    revisions.push((await endGroupCall(db, {
      accountId: owner.accountId, deviceId: owner.deviceId, callId: started.call.id,
    })).call.stateRevision);

    expect(revisions[0]).toBe(1);
    expect(revisions.every((revision, index) => index === 0 || revision > revisions[index - 1]))
      .toBe(true);
  });

  test("snapshot reads hold a call-row share lock for one coherent projection", async () => {
    const { owner, groupId } = await fixture();
    const started = await start(owner, groupId);
    let releaseWriter: () => void = () => {};
    let markLocked: () => void = () => {};
    const writerHeld = new Promise<void>((resolve) => { markLocked = resolve; });
    const writerRelease = new Promise<void>((resolve) => { releaseWriter = resolve; });
    const writer = db.begin(async (tx) => {
      await tx`SELECT id FROM group_calls WHERE id = ${started.call.id} FOR UPDATE`;
      markLocked();
      await writerRelease;
      await tx`
        UPDATE group_calls SET state_revision = state_revision + 1
        WHERE id = ${started.call.id}`;
    });
    await writerHeld;

    const read = getGroupCall(db, owner.accountId, owner.deviceId, started.call.id);
    const outcome = await Promise.race([
      read.then(() => "read"),
      new Promise<string>((resolve) => setTimeout(() => resolve("blocked"), 40)),
    ]);
    releaseWriter();
    await writer;
    const snapshot = await read;
    expect(outcome).toBe("blocked");
    expect(snapshot.call.stateRevision).toBe(started.call.stateRevision + 1);
  });

  test("only one generation-fenced screen share can hold the short renewable lease", async () => {
    const { owner, alice, groupId } = await fixture();
    const started = await start(owner, groupId);
    const joined = await joinGroupCall(db, {
      accountId: alice.accountId, deviceId: alice.deviceId, callId: started.call.id,
      joinPublicKey: bytes(51), joinNonce: bytes(52),
    });
    await activateGroupCallEpoch(db, {
      accountId: owner.accountId, deviceId: owner.deviceId, callId: started.call.id,
      epoch: 2, expectedMembershipRevision: joined.call.membershipRevision,
      keyCommitment: bytes(53), participantSetHash: transcriptHash(joined.call.participants),
      envelopes: [{ recipientDeviceId: alice.deviceId, ciphertext: bytes(54, 48) }],
    });
    const ownerGeneration = crypto.randomUUID();
    const acquired = await acquireGroupScreenShare(db, {
      accountId: owner.accountId, deviceId: owner.deviceId,
      callId: started.call.id, generation: ownerGeneration,
    }, sfu);
    expect(acquired.call.screenShare?.participantId).toBe(started.credentials.participantId);
    expect(sfu.updates.at(-1)).toMatchObject({
      identity: started.credentials.participantId,
      cameraAllowed: false,
      screenShareAllowed: true,
    });
    await expect(heartbeatGroupScreenShare(db, {
      accountId: owner.accountId, deviceId: owner.deviceId,
      callId: started.call.id, generation: ownerGeneration,
    })).rejects.toMatchObject({ code: "rate_limited", status: 429, retryAfter: 3 });
    await db`
      UPDATE group_call_screen_share_leases
      SET updated_at = now() - interval '4 seconds'
      WHERE call_id = ${started.call.id}`;
    const renewed = await heartbeatGroupScreenShare(db, {
      accountId: owner.accountId, deviceId: owner.deviceId,
      callId: started.call.id, generation: ownerGeneration,
    });
    expect(new Date(renewed.expiresAt).getTime()).toBeGreaterThan(Date.now());
    await expect(acquireGroupScreenShare(db, {
      accountId: alice.accountId, deviceId: alice.deviceId,
      callId: started.call.id, generation: crypto.randomUUID(),
    }, sfu)).rejects.toMatchObject({ code: "screen_share_busy", status: 409 });
    expect((await releaseGroupScreenShare(db, {
      accountId: owner.accountId, deviceId: owner.deviceId,
      callId: started.call.id, generation: crypto.randomUUID(),
    }, sfu)).released).toBe(true);
    expect((await getGroupCall(db, owner.accountId, owner.deviceId, started.call.id)).call.screenShare)
      .not.toBeNull();
    await releaseGroupScreenShare(db, {
      accountId: owner.accountId, deviceId: owner.deviceId,
      callId: started.call.id, generation: ownerGeneration,
    }, sfu);
    expect((await getGroupCall(db, owner.accountId, owner.deviceId, started.call.id)).call.screenShare)
      .toBeNull();
    expect(sfu.updates.at(-1)).toMatchObject({
      identity: started.credentials.participantId,
      cameraAllowed: false,
      screenShareAllowed: false,
    });
  });

  test("camera publishing is generation-fenced, SFU-authorized, and capped by the room limit", async () => {
    const { owner, alice, groupId } = await fixture();
    const started = await start(owner, groupId);
    await joinAndActivate(owner, alice, started, 91);
    await db`UPDATE group_calls SET publisher_limit = 1 WHERE id = ${started.call.id}`;

    const generation = crypto.randomUUID();
    const acquired = await acquireGroupCamera(db, {
      accountId: owner.accountId,
      deviceId: owner.deviceId,
      callId: started.call.id,
      generation,
    }, sfu);
    expect(acquired.call.cameraPublishers).toEqual([started.credentials.participantId]);
    expect(sfu.updates.at(-1)).toMatchObject({
      identity: started.credentials.participantId,
      cameraAllowed: true,
      screenShareAllowed: false,
    });
    await expect(acquireGroupCamera(db, {
      accountId: alice.accountId,
      deviceId: alice.deviceId,
      callId: started.call.id,
      generation: crypto.randomUUID(),
    }, sfu)).rejects.toMatchObject({ code: "publisher_limit_reached", status: 409 });
    await expect(acquireGroupCamera(db, {
      accountId: owner.accountId,
      deviceId: owner.deviceId,
      callId: started.call.id,
      generation: crypto.randomUUID(),
    }, sfu)).rejects.toMatchObject({ code: "idempotency_conflict", status: 409 });
    await expect(heartbeatGroupCamera(db, {
      accountId: owner.accountId,
      deviceId: owner.deviceId,
      callId: started.call.id,
      generation: crypto.randomUUID(),
    })).rejects.toMatchObject({ code: "camera_lease_expired", status: 409 });

    await releaseGroupCamera(db, {
      accountId: owner.accountId,
      deviceId: owner.deviceId,
      callId: started.call.id,
      generation,
    }, sfu);
    expect((await getGroupCall(db, owner.accountId, owner.deviceId, started.call.id))
      .call.cameraPublishers).toEqual([]);
    expect(sfu.updates.at(-1)).toMatchObject({ cameraAllowed: false });
  });

  test("expired media leases fail closed and reconcile the SFU to microphone-only", async () => {
    const { owner, groupId } = await fixture();
    const started = await start(owner, groupId);
    await acquireGroupCamera(db, {
      accountId: owner.accountId,
      deviceId: owner.deviceId,
      callId: started.call.id,
      generation: crypto.randomUUID(),
    }, sfu);
    await acquireGroupScreenShare(db, {
      accountId: owner.accountId,
      deviceId: owner.deviceId,
      callId: started.call.id,
      generation: crypto.randomUUID(),
    }, sfu);
    await db`
      UPDATE group_call_camera_leases
      SET expires_at = now() - interval '1 second'
      WHERE call_id = ${started.call.id}`;
    await db`
      UPDATE group_call_screen_share_leases
      SET expires_at = now() - interval '1 second'
      WHERE call_id = ${started.call.id}`;

    expect(await expireStaleGroupCallParticipants(db)).toBe(2);
    expect(await db`
      SELECT 1 FROM group_call_camera_leases WHERE call_id = ${started.call.id}`)
      .toHaveLength(0);
    expect(await db`
      SELECT 1 FROM group_call_screen_share_leases WHERE call_id = ${started.call.id}`)
      .toHaveLength(0);
    const pending = (await db`
      SELECT camera_allowed, screen_share_allowed, revision, applied_revision
      FROM group_call_sfu_participant_states
      WHERE call_id = ${started.call.id}
        AND participant_identity = ${started.credentials.participantId}`)[0];
    expect(pending.camera_allowed).toBe(false);
    expect(pending.screen_share_allowed).toBe(false);
    expect(Number(pending.revision)).toBeGreaterThan(Number(pending.applied_revision));

    expect(await reconcileGroupCallSFUParticipant(
      db, started.call.id, owner.deviceId, sfu,
    )).toBe(true);
    expect(sfu.updates.at(-1)).toMatchObject({
      identity: started.credentials.participantId,
      cameraAllowed: false,
      screenShareAllowed: false,
    });
  });

  test("a delayed SFU grant cannot win over a newer camera revoke", async () => {
    const { owner, groupId } = await fixture();
    const started = await start(owner, groupId);
    const generation = crypto.randomUUID();
    const gate = sfu.pauseNextUpdate();
    const acquisition = acquireGroupCamera(db, {
      accountId: owner.accountId,
      deviceId: owner.deviceId,
      callId: started.call.id,
      generation,
    }, sfu);
    await gate.started;
    await releaseGroupCamera(db, {
      accountId: owner.accountId,
      deviceId: owner.deviceId,
      callId: started.call.id,
      generation,
    }, sfu);
    gate.resume();
    await expect(acquisition).rejects.toMatchObject({
      code: "camera_lease_superseded",
      status: 409,
    });
    expect(sfu.updates.map((update) => update.cameraAllowed)).toEqual([true, false]);
    const state = (await db`
      SELECT desired_status, camera_allowed, revision, applied_revision
      FROM group_call_sfu_participant_states
      WHERE call_id = ${started.call.id} AND device_id = ${owner.deviceId}`)[0];
    expect(state.desired_status).toBe("active");
    expect(state.camera_allowed).toBe(false);
    expect(Number(state.applied_revision)).toBe(Number(state.revision));
  });

  test("duplicate media reacquisitions allow one durable SFU refresh per cadence", async () => {
    const { owner, groupId } = await fixture();
    const started = await start(owner, groupId);
    const cameraGeneration = crypto.randomUUID();
    await acquireGroupCamera(db, {
      accountId: owner.accountId, deviceId: owner.deviceId,
      callId: started.call.id, generation: cameraGeneration,
    }, sfu);
    await db`
      UPDATE group_call_camera_leases SET updated_at = now() - interval '4 seconds'
      WHERE call_id = ${started.call.id} AND device_id = ${owner.deviceId}`;
    sfu.updates = [];
    const cameraBurst = await Promise.allSettled(Array.from({ length: 8 }, () =>
      acquireGroupCamera(db, {
        accountId: owner.accountId, deviceId: owner.deviceId,
        callId: started.call.id, generation: cameraGeneration,
      }, sfu)));
    expect(cameraBurst.filter((result) => result.status === "fulfilled")).toHaveLength(1);
    const cameraRejected = cameraBurst.filter(
      (result): result is PromiseRejectedResult => result.status === "rejected",
    );
    expect(cameraRejected).toHaveLength(7);
    expect(cameraRejected.every((result) => result.reason?.code === "rate_limited"
      && result.reason?.status === 429 && result.reason?.retryAfter >= 1)).toBe(true);
    expect(sfu.updates.filter((update) => update.cameraAllowed)).toHaveLength(1);

    const screenGeneration = crypto.randomUUID();
    await acquireGroupScreenShare(db, {
      accountId: owner.accountId, deviceId: owner.deviceId,
      callId: started.call.id, generation: screenGeneration,
    }, sfu);
    await db`
      UPDATE group_call_screen_share_leases SET updated_at = now() - interval '4 seconds'
      WHERE call_id = ${started.call.id}`;
    sfu.updates = [];
    const screenBurst = await Promise.allSettled(Array.from({ length: 8 }, () =>
      acquireGroupScreenShare(db, {
        accountId: owner.accountId, deviceId: owner.deviceId,
        callId: started.call.id, generation: screenGeneration,
      }, sfu)));
    expect(screenBurst.filter((result) => result.status === "fulfilled")).toHaveLength(1);
    const screenRejected = screenBurst.filter(
      (result): result is PromiseRejectedResult => result.status === "rejected",
    );
    expect(screenRejected).toHaveLength(7);
    expect(screenRejected.every((result) => result.reason?.code === "rate_limited"
      && result.reason?.status === 429 && result.reason?.retryAfter >= 1)).toBe(true);
    expect(sfu.updates.filter((update) => update.screenShareAllowed)).toHaveLength(1);
  });

  test("an SFU permission failure compensates the camera lease and converges to microphone-only", async () => {
    const { owner, groupId } = await fixture();
    const started = await start(owner, groupId);
    sfu.failNextUpdates();
    await expect(acquireGroupCamera(db, {
      accountId: owner.accountId,
      deviceId: owner.deviceId,
      callId: started.call.id,
      generation: crypto.randomUUID(),
    }, sfu)).rejects.toMatchObject({ code: "sfu_control_unavailable", status: 503 });
    expect((await db`
      SELECT 1 FROM group_call_camera_leases WHERE call_id = ${started.call.id}`)).toHaveLength(0);
    expect(sfu.updates.at(-1)).toMatchObject({
      identity: started.credentials.participantId,
      cameraAllowed: false,
      screenShareAllowed: false,
    });
  });

  test("a rapid rejoin preserves and applies the pending removal for the old SFU identity", async () => {
    const { owner, alice, groupId } = await fixture();
    const started = await start(owner, groupId);
    const first = await joinAndActivate(owner, alice, started, 101);
    const oldIdentity = first.activated.call.participants
      .find((participant) => participant.deviceId === alice.deviceId)!.participantId;
    await leaveGroupCall(db, {
      accountId: alice.accountId,
      deviceId: alice.deviceId,
      callId: started.call.id,
    });
    const rejoined = await joinGroupCall(db, {
      accountId: alice.accountId,
      deviceId: alice.deviceId,
      callId: started.call.id,
      joinPublicKey: bytes(105),
      joinNonce: bytes(106),
    });
    const newIdentity = rejoined.call.participants
      .find((participant) => participant.deviceId === alice.deviceId)!.participantId;
    expect(newIdentity).not.toBe(oldIdentity);
    const states = await db`
      SELECT participant_identity, desired_status, revision, applied_revision
      FROM group_call_sfu_participant_states
      WHERE call_id = ${started.call.id} AND device_id = ${alice.deviceId}
      ORDER BY created_at`;
    expect(states).toHaveLength(2);
    expect(states.find((state: any) => state.participant_identity === oldIdentity)?.desired_status)
      .toBe("removed");
    expect(await reconcileGroupCallSFUParticipant(
      db, started.call.id, alice.deviceId, sfu,
    )).toBe(true);
    expect(sfu.removals).toContainEqual(expect.objectContaining({ identity: oldIdentity }));
    expect(sfu.removals.some((removal) => removal.identity === newIdentity)).toBe(false);
  });

  test("a stale key leader is removed, leadership rotates, and a one-person stale room ends", async () => {
    const { owner, alice, groupId } = await fixture();
    const started = await start(owner, groupId);
    await joinGroupCall(db, {
      accountId: alice.accountId, deviceId: alice.deviceId, callId: started.call.id,
      joinPublicKey: bytes(61), joinNonce: bytes(62),
    });
    await db`
      UPDATE group_call_participants SET last_seen_at = now() - interval '3 minutes'
      WHERE call_id = ${started.call.id} AND device_id = ${owner.deviceId}`;
    expect(await expireStaleGroupCallParticipants(db)).toBe(1);
    const aliceView = await getGroupCall(db, alice.accountId, alice.deviceId, started.call.id);
    expect(aliceView.call.keyLeaderDeviceId).toBe(alice.deviceId);
    expect(aliceView.call.rekeyRequired).toBe(true);

    await db`
      UPDATE group_call_participants SET last_seen_at = now() - interval '3 minutes'
      WHERE call_id = ${started.call.id} AND device_id = ${alice.deviceId}`;
    expect(await expireStaleGroupCallParticipants(db)).toBe(1);
    const ended = (await db`SELECT state, end_reason FROM group_calls WHERE id = ${started.call.id}`)[0];
    expect(ended).toMatchObject({ state: "ended", end_reason: "empty" });
  });

  test("cross-process hint resolution excludes unrelated, revoked, and removed creator devices", async () => {
    const { owner, alice, bob, groupId } = await fixture();
    const unrelated = await account("+16505554103", "Unrelated", "a4");
    const bobOther = await secondDevice("+16505554102", "Bob", "a5");
    const started = await start(owner, groupId);
    await transferGroupOwner(db, {
      actorAccountId: owner.accountId,
      actorDeviceId: owner.deviceId,
      dialogId: groupId,
      targetAccountId: alice.accountId,
      clientMutationId: crypto.randomUUID(),
    });
    await removeGroupMember(db, {
      actorAccountId: alice.accountId,
      actorDeviceId: alice.deviceId,
      dialogId: groupId,
      targetAccountId: owner.accountId,
      clientMutationId: crypto.randomUUID(),
    }, sfu);
    await db`UPDATE devices SET revoked_at = now() WHERE id = ${bobOther.deviceId}`;

    const targets = await resolveGroupCallHintTargets(db, {
      callId: started.call.id,
      stateRevision: 1,
    }, [
      owner.deviceId,
      alice.deviceId,
      bob.deviceId,
      bob.deviceId,
      bobOther.deviceId,
      unrelated.deviceId,
      "not-a-device-id",
    ]);
    expect(targets.map((target) => target.deviceId).sort())
      .toEqual([alice.deviceId, bob.deviceId].sort());
    expect(targets.every((target) => target.stateRevision > started.call.stateRevision)).toBe(true);
    expect(await resolveGroupCallHintTargets(db, {
      callId: "not-a-call-id", stateRevision: 1,
    }, [alice.deviceId])).toEqual([]);
  });

  test("the start budget serializes concurrent final-slot attempts", async () => {
    const { owner, alice, bob, groupId } = await fixture();
    const secondGroupId = crypto.randomUUID();
    await createGroup(db, {
      creatorAccountId: owner.accountId,
      creatorDeviceId: owner.deviceId,
      groupId: secondGroupId,
      title: "Second group call",
      memberIds: [alice.accountId, bob.accountId],
    });
    await db`
      INSERT INTO group_call_action_budgets(account_id, device_id, action)
      SELECT ${owner.accountId}, ${owner.deviceId}, 'start' FROM generate_series(1, 9)`;

    const attempts = await Promise.allSettled([
      start(owner, groupId),
      start(owner, secondGroupId),
    ]);
    expect(attempts.filter((result) => result.status === "fulfilled")).toHaveLength(1);
    const rejected = attempts.find((result) => result.status === "rejected") as PromiseRejectedResult;
    expect(rejected.reason).toMatchObject({ code: "rate_limited", status: 429, retryAfter: 60 });
    expect(Number((await db`
      SELECT count(*)::int AS count FROM group_call_action_budgets
      WHERE account_id = ${owner.accountId} AND action = 'start'`)[0].count)).toBe(10);
  });

  test("join, camera, and screen-share action budgets reject the exact next attempt", async () => {
    const { owner, alice, groupId } = await fixture();
    const started = await start(owner, groupId);
    await db`
      INSERT INTO group_call_action_budgets(account_id, device_id, action)
      SELECT ${alice.accountId}, ${alice.deviceId}, 'join' FROM generate_series(1, 60)`;
    await expect(joinGroupCall(db, {
      accountId: alice.accountId, deviceId: alice.deviceId, callId: started.call.id,
      joinPublicKey: bytes(111), joinNonce: bytes(112),
    })).rejects.toMatchObject({ code: "rate_limited", status: 429 });

    await db`
      INSERT INTO group_call_action_budgets(account_id, device_id, action)
      SELECT ${owner.accountId}, ${owner.deviceId}, 'camera_publish' FROM generate_series(1, 120)`;
    await expect(acquireGroupCamera(db, {
      accountId: owner.accountId, deviceId: owner.deviceId, callId: started.call.id,
      generation: crypto.randomUUID(),
    }, sfu)).rejects.toMatchObject({ code: "rate_limited", status: 429 });

    await db`
      INSERT INTO group_call_action_budgets(account_id, device_id, action)
      SELECT ${owner.accountId}, ${owner.deviceId}, 'screen_share' FROM generate_series(1, 20)`;
    await expect(acquireGroupScreenShare(db, {
      accountId: owner.accountId, deviceId: owner.deviceId, callId: started.call.id,
      generation: crypto.randomUUID(),
    }, sfu)).rejects.toMatchObject({ code: "rate_limited", status: 429 });
  });

  test("expired screen publishers are revoked at the SFU before a successor is granted", async () => {
    const { owner, alice, bob, groupId } = await fixture();
    const started = await start(owner, groupId);
    await joinGroupCall(db, {
      accountId: alice.accountId, deviceId: alice.deviceId, callId: started.call.id,
      joinPublicKey: bytes(113), joinNonce: bytes(114),
    });
    const joined = await joinGroupCall(db, {
      accountId: bob.accountId, deviceId: bob.deviceId, callId: started.call.id,
      joinPublicKey: bytes(115), joinNonce: bytes(116),
    });
    const active = await activateGroupCallEpoch(db, {
      accountId: owner.accountId, deviceId: owner.deviceId, callId: started.call.id,
      epoch: 2, expectedMembershipRevision: joined.call.membershipRevision,
      keyCommitment: bytes(117), participantSetHash: transcriptHash(joined.call.participants),
      envelopes: [
        { recipientDeviceId: alice.deviceId, ciphertext: bytes(118, 48) },
        { recipientDeviceId: bob.deviceId, ciphertext: bytes(119, 48) },
      ],
    });
    const aliceParticipant = active.call.participants.find(
      (participant) => participant.deviceId === alice.deviceId,
    )!;
    const bobParticipant = active.call.participants.find(
      (participant) => participant.deviceId === bob.deviceId,
    )!;
    await acquireGroupScreenShare(db, {
      accountId: alice.accountId, deviceId: alice.deviceId, callId: started.call.id,
      generation: crypto.randomUUID(),
    }, sfu);
    await db`
      UPDATE group_call_screen_share_leases
      SET expires_at = now() - interval '1 second'
      WHERE call_id = ${started.call.id}`;
    sfu.updates = [];

    const bobGeneration = crypto.randomUUID();
    const revokeGate = sfu.pauseNextUpdate();
    const bobAcquisition = acquireGroupScreenShare(db, {
      accountId: bob.accountId, deviceId: bob.deviceId, callId: started.call.id,
      generation: bobGeneration,
    }, sfu);
    await revokeGate.started;
    try {
      // The background worker sees Bob's pending grant while Alice's revoke is in flight. The
      // durable source barrier must keep that grant unclaimable until the revoke is applied.
      expect(await reconcilePendingGroupCallSFUStates(db, 100, sfu)).toBe(0);
      expect(sfu.updates.some((update) =>
        update.identity === bobParticipant.participantId && update.screenShareAllowed)).toBe(false);
    } finally {
      revokeGate.resume();
    }
    await bobAcquisition;
    expect(sfu.updates.map((update) => ({
      identity: update.identity,
      screenShareAllowed: update.screenShareAllowed,
    }))).toEqual([
      { identity: aliceParticipant.participantId, screenShareAllowed: false },
      { identity: bobParticipant.participantId, screenShareAllowed: true },
    ]);

    await releaseGroupScreenShare(db, {
      accountId: bob.accountId, deviceId: bob.deviceId, callId: started.call.id,
      generation: bobGeneration,
    }, sfu);
    await acquireGroupScreenShare(db, {
      accountId: alice.accountId, deviceId: alice.deviceId, callId: started.call.id,
      generation: crypto.randomUUID(),
    }, sfu);
    await db`
      UPDATE group_call_screen_share_leases
      SET expires_at = now() - interval '1 second'
      WHERE call_id = ${started.call.id}`;
    sfu.updates = [];
    sfu.failNextUpdates();
    await expect(acquireGroupScreenShare(db, {
      accountId: bob.accountId, deviceId: bob.deviceId, callId: started.call.id,
      generation: crypto.randomUUID(),
    }, sfu)).rejects.toMatchObject({ code: "sfu_control_unavailable", status: 503 });
    expect(await db`
      SELECT 1 FROM group_call_screen_share_leases WHERE call_id = ${started.call.id}`)
      .toHaveLength(0);
    expect(sfu.updates.some((update) =>
      update.identity === bobParticipant.participantId && update.screenShareAllowed)).toBe(false);
  });

  test("the SFU reconciliation worker is concurrent but bounded", async () => {
    const { owner, alice, bob, groupId } = await fixture();
    const started = await start(owner, groupId);
    await joinGroupCall(db, {
      accountId: alice.accountId, deviceId: alice.deviceId, callId: started.call.id,
      joinPublicKey: bytes(120), joinNonce: bytes(121),
    });
    await joinGroupCall(db, {
      accountId: bob.accountId, deviceId: bob.deviceId, callId: started.call.id,
      joinPublicKey: bytes(122), joinNonce: bytes(123),
    });
    await db`
      UPDATE group_call_sfu_participant_states
      SET applied_revision = 0, next_attempt_at = now()
      WHERE call_id = ${started.call.id}`;
    sfu.delayUpdates(25);
    expect(await reconcilePendingGroupCallSFUStates(db, 100, sfu)).toBe(3);
    expect(sfu.maxConcurrentUpdates).toBeGreaterThan(1);
    expect(sfu.maxConcurrentUpdates).toBeLessThanOrEqual(8);
  });

  test("cleanup skips a call-locked heartbeat boundary before touching its leases", async () => {
    const { owner, groupId } = await fixture();
    const started = await start(owner, groupId);
    await acquireGroupCamera(db, {
      accountId: owner.accountId, deviceId: owner.deviceId,
      callId: started.call.id, generation: crypto.randomUUID(),
    }, sfu);
    await db`
      UPDATE group_call_camera_leases SET expires_at = now() - interval '1 second'
      WHERE call_id = ${started.call.id}`;

    let releaseCall: () => void = () => {};
    let markCallLocked: () => void = () => {};
    const callLocked = new Promise<void>((resolve) => { markCallLocked = resolve; });
    const callRelease = new Promise<void>((resolve) => { releaseCall = resolve; });
    const liveMutation = db.begin(async (tx) => {
      await tx`SELECT id FROM group_calls WHERE id = ${started.call.id} FOR UPDATE`;
      markCallLocked();
      await callRelease;
    });
    await callLocked;

    const cleanup = expireStaleGroupCallParticipants(db);
    const cleanupOutcome = await Promise.race([
      cleanup.then((count) => ({ status: "completed", count })),
      new Promise<{ status: string; count: number }>((resolve) =>
        setTimeout(() => resolve({ status: "blocked", count: -1 }), 40)),
    ]);
    releaseCall();
    await liveMutation;
    await cleanup;

    expect(cleanupOutcome).toEqual({ status: "completed", count: 0 });
    expect(await db`
      SELECT 1 FROM group_call_camera_leases WHERE call_id = ${started.call.id}`)
      .toHaveLength(1);
  });

  test("cleanup retires expired epochs and eventually deletes ended call state", async () => {
    const { owner, alice, groupId } = await fixture();
    const started = await start(owner, groupId);
    await joinAndActivate(owner, alice, started, 124);
    await db`
      UPDATE group_call_epochs SET grace_expires_at = now() - interval '1 second'
      WHERE call_id = ${started.call.id} AND epoch = 1`;
    expect(await expireStaleGroupCallParticipants(db)).toBeGreaterThanOrEqual(1);
    expect((await db`
      SELECT epoch FROM group_call_epochs WHERE call_id = ${started.call.id} ORDER BY epoch`)
      .map((row: any) => Number(row.epoch))).toEqual([2]);

    await endGroupCall(db, {
      accountId: owner.accountId, deviceId: owner.deviceId, callId: started.call.id,
    });
    await db`
      UPDATE group_calls SET ended_at = now() - interval '31 days'
      WHERE id = ${started.call.id}`;
    expect(await db`
      SELECT 1 FROM group_call_sfu_participant_states
      WHERE call_id = ${started.call.id} AND applied_revision < revision`)
      .toHaveLength(0);
    expect(await expireStaleGroupCallParticipants(db)).toBeGreaterThanOrEqual(1);
    expect(await db`SELECT 1 FROM group_calls WHERE id = ${started.call.id}`).toHaveLength(0);
  });

  test("the route family is hidden when disabled and rollout zero stops new calls but lets joined calls drain", async () => {
    const { owner, alice, groupId } = await fixture();
    const started = await start(owner, groupId);
    const cameraGeneration = crypto.randomUUID();
    await acquireGroupCamera(db, {
      accountId: owner.accountId, deviceId: owner.deviceId,
      callId: started.call.id, generation: cameraGeneration,
    }, sfu);

    process.env.TOJ_GROUP_CALLS_ROLLOUT_PERCENT = "0";
    expect((await resolveGroupCallHintTargets(db, {
      callId: started.call.id, stateRevision: started.call.stateRevision,
    }, [owner.deviceId, alice.deviceId])).map((target) => target.deviceId))
      .toEqual([owner.deviceId]);
    await expect(getGroupCall(db, alice.accountId, alice.deviceId, started.call.id))
      .rejects.toMatchObject({ code: "not_found", status: 404 });
    const draining = startCloudServer(0, db, null, null, {
      backgroundWorkers: false,
      groupCallSFUControl: sfu,
    });
    try {
      const base = `http://127.0.0.1:${draining.port}`;
      const headers = { authorization: `Bearer ${owner.token}`, "content-type": "application/json" };
      const unselectedHeaders = {
        authorization: `Bearer ${alice.token}`,
        "content-type": "application/json",
      };
      const capabilities = await (await fetch(`${base}/v1/capabilities`, { headers })).json() as {
        capabilities: string[];
      };
      expect(capabilities.capabilities).not.toContain("group_calls_v1");
      const newStart = await fetch(`${base}/v1/group-calls`, {
        method: "POST", headers,
        body: JSON.stringify({
          callId: crypto.randomUUID(), dialogId: groupId, initialKind: "voice",
          joinPublicKey: bytes(71), joinNonce: bytes(72), epochKeyCommitment: bytes(73),
        }),
      });
      expect(newStart.status).toBe(404);
      expect((await fetch(`${base}/v1/group-calls/${started.call.id}`, {
        headers: unselectedHeaders,
      })).status).toBe(404);
      const heartbeat = await fetch(`${base}/v1/group-calls/${started.call.id}/heartbeat`, {
        method: "POST", headers, body: "{}",
      });
      expect(heartbeat.status).toBe(200);
      const throttledHeartbeat = await fetch(`${base}/v1/group-calls/${started.call.id}/heartbeat`, {
        method: "POST", headers, body: "{}",
      });
      expect(throttledHeartbeat.status).toBe(429);
      expect(Number(throttledHeartbeat.headers.get("retry-after"))).toBeGreaterThanOrEqual(1);

      const newCamera = await fetch(`${base}/v1/group-calls/${started.call.id}/camera`, {
        method: "POST", headers,
        body: JSON.stringify({ generation: crypto.randomUUID() }),
      });
      expect(newCamera.status).toBe(404);
      const released = await fetch(`${base}/v1/group-calls/${started.call.id}/camera/release`, {
        method: "POST", headers, body: JSON.stringify({ generation: cameraGeneration }),
      });
      expect(released.status).toBe(200);
      expect(await db`
        SELECT 1 FROM group_call_camera_leases WHERE call_id = ${started.call.id}`)
        .toHaveLength(0);
    } finally {
      draining.stop(true);
    }

    process.env.TOJ_GROUP_CALLS_ENABLED = "0";
    const disabled = startCloudServer(0, db, null, null, { backgroundWorkers: false });
    try {
      const response = await fetch(`http://127.0.0.1:${disabled.port}/v1/group-calls`, {
        method: "POST",
      });
      expect(response.status).toBe(404);
    } finally {
      disabled.stop(true);
    }
  });

  test("the same account cannot occupy two devices in one room", async () => {
    const { owner, alice, groupId } = await fixture();
    const aliceOther = await secondDevice("+16505554101", "Alice", "c1");
    const started = await start(owner, groupId);
    await joinGroupCall(db, {
      accountId: alice.accountId, deviceId: alice.deviceId, callId: started.call.id,
      joinPublicKey: bytes(81), joinNonce: bytes(82),
    });
    await expect(joinGroupCall(db, {
      accountId: aliceOther.accountId, deviceId: aliceOther.deviceId, callId: started.call.id,
      joinPublicKey: bytes(83), joinNonce: bytes(84),
    })).rejects.toMatchObject({ code: "joined_elsewhere", status: 409 });
  });
});

afterAll(async () => {
  for (const [key, value] of savedGroupCallEnvironment) {
    if (value === undefined) delete process.env[key];
    else process.env[key] = value;
  }
  await db.end();
});
