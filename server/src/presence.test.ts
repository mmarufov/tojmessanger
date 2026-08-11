import { afterAll, beforeEach, describe, expect, test } from "bun:test";
import { checkVerification, startVerification } from "./auth";
import { blockAccount } from "./calls";
import { startCloudServer } from "./cloud";
import { makeSql } from "./db";
import { hashToken } from "./crypto";
import { createGroup, removeGroupMember } from "./groups";
import {
  expirePresenceLeases,
  heartbeatPresence,
  presenceEnabledForAccount,
  presenceSchemaReadiness,
  publishTyping,
  queryPresence,
  setPresenceActivity,
  startPresenceNotificationListener,
} from "./presence";
import { getOrCreateDirectDialog } from "./sync";

const TEST_URL = process.env.TEST_DATABASE_URL ?? "postgres://localhost:5432/toj_test";
const db = makeSql(TEST_URL);

async function resetDb() {
  process.env.TOJ_PRESENCE_V1_ENABLED = "1";
  process.env.TOJ_PRESENCE_ROLLOUT_PERCENT = "100";
  delete process.env.TOJ_PRESENCE_ALLOWLIST;
  await db`TRUNCATE accounts, otp_challenges RESTART IDENTITY CASCADE`;
}

async function account(phone: string, name: string) {
  const { code } = await startVerification(db, phone);
  return checkVerification(db, phone, code, "ios", `${name} iPhone`, name);
}

async function directPair() {
  const alice = await account("+16505559801", "Alice");
  const bob = await account("+16505559802", "Bob");
  const dialog = await getOrCreateDirectDialog(db, alice.accountId, bob.accountId, alice.deviceId);
  return { alice, bob, dialogId: dialog.dialogId };
}

describe.serial("presence_v1", () => {
  beforeEach(resetDb);
  afterAll(() => db.end());

  test("schema and deterministic rollout fail closed", async () => {
    expect((await presenceSchemaReadiness(db)).ready).toBe(true);
    const user = await account("+16505559800", "Rollout");
    expect(presenceEnabledForAccount(user.accountId)).toBe(true);
    process.env.TOJ_PRESENCE_ROLLOUT_PERCENT = "0";
    expect(presenceEnabledForAccount(user.accountId)).toBe(false);
    process.env.TOJ_PRESENCE_ALLOWLIST = user.accountId;
    expect(presenceEnabledForAccount(user.accountId)).toBe(true);
  });

  test("capability and query endpoint are authenticated, gated, and bounded", async () => {
    const { alice, bob } = await directPair();
    const server = startCloudServer(0, db, null, null, { backgroundWorkers: false });
    const base = `http://127.0.0.1:${server.port}`;
    try {
      const publicCapabilities = await (await fetch(`${base}/v1/capabilities`)).json() as {
        capabilities: string[];
      };
      expect(publicCapabilities.capabilities).not.toContain("presence_v1");
      const accountCapabilities = await (await fetch(`${base}/v1/capabilities`, {
        headers: { authorization: `Bearer ${bob.token}` },
      })).json() as { capabilities: string[] };
      expect(accountCapabilities.capabilities).toContain("presence_v1");
      expect((await fetch(`${base}/v1/presence/query`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ accountIds: [alice.accountId] }),
      })).status).toBe(401);
      expect((await fetch(`${base}/v1/presence/query`, {
        method: "POST",
        headers: {
          authorization: `Bearer ${bob.token}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({ accountIds: "not-an-array" }),
      })).status).toBe(400);
      const tooMany = Array.from({ length: 201 }, () => crypto.randomUUID());
      expect((await fetch(`${base}/v1/presence/query`, {
        method: "POST",
        headers: {
          authorization: `Bearer ${bob.token}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({ accountIds: tooMany }),
      })).status).toBe(413);
    } finally {
      await server.stop(true);
    }
  });

  test("realtime frames are bounded, rate-limited, and identity comes from the socket", async () => {
    const { alice, bob, dialogId } = await directPair();
    const previousMetricsToken = process.env.TOJ_METRICS_TOKEN;
    process.env.TOJ_METRICS_TOKEN = "presence-test-metrics";
    const server = startCloudServer(0, db, null, null, { backgroundWorkers: false });
    const aliceSocket = new WebSocket(`ws://127.0.0.1:${server.port}/v1/ws`, {
      headers: { authorization: `Bearer ${alice.token}` },
    });
    const bobSocket = new WebSocket(`ws://127.0.0.1:${server.port}/v1/ws`, {
      headers: { authorization: `Bearer ${bob.token}` },
    });
    const bobEvents: any[] = [];
    bobSocket.onmessage = (message) => {
      try { bobEvents.push(JSON.parse(String(message.data))); } catch {}
    };
    const opened = (socket: WebSocket) => new Promise<void>((resolve, reject) => {
      if (socket.readyState === WebSocket.OPEN) return resolve();
      const timer = setTimeout(() => reject(new Error("websocket open timed out")), 3_000);
      socket.onopen = () => { clearTimeout(timer); resolve(); };
      socket.onerror = () => { clearTimeout(timer); reject(new Error("websocket error")); };
    });
    try {
      await Promise.all([opened(aliceSocket), opened(bobSocket)]);
      aliceSocket.send(JSON.stringify({ type: "presence_activity", active: true }));
      await Bun.sleep(50);
      const typing = JSON.stringify({ type: "typing_activity", dialogId, active: true });
      aliceSocket.send(typing);
      aliceSocket.send(typing);
      aliceSocket.send("{");
      aliceSocket.send(JSON.stringify({ type: "unsupported_activity" }));
      aliceSocket.send("x".repeat(4_097));
      await Bun.sleep(150);
      const typingEvents = bobEvents.filter((event) => event.type === "typing_update");
      expect(typingEvents).toHaveLength(1);
      expect(typingEvents[0]).toMatchObject({
        dialogId,
        actorAccountId: alice.accountId,
        active: true,
        expiresInMs: 7_000,
      });
      expect(typingEvents[0].typingSessionId).not.toBe(alice.accountId);
      const metrics = await (await fetch(`http://127.0.0.1:${server.port}/metrics`, {
        headers: { authorization: "Bearer presence-test-metrics" },
      })).text();
      expect(metrics).toContain('toj_presence_rejected_frames_total{reason="rate_limited"} 1');
      expect(metrics).toContain('toj_presence_rejected_frames_total{reason="oversized"} 1');
    } finally {
      aliceSocket.close();
      bobSocket.close();
      await server.stop(true);
      if (previousMetricsToken === undefined) delete process.env.TOJ_METRICS_TOKEN;
      else process.env.TOJ_METRICS_TOKEN = previousMetricsToken;
    }
  }, 5_000);

  test("only direct peers receive exact online and final-device last seen", async () => {
    const { alice, bob } = await directPair();
    const outsider = await account("+16505559803", "Outsider");
    const firstConnection = crypto.randomUUID();
    const broadcasts = await setPresenceActivity(db, {
      accountId: alice.accountId,
      deviceId: alice.deviceId,
      connectionId: firstConnection,
      active: true,
    });
    expect(broadcasts[0]?.recipientAccountIds).toEqual([bob.accountId]);
    expect(await queryPresence(db, bob.accountId, [alice.accountId, outsider.accountId]))
      .toEqual({ presences: [expect.objectContaining({ accountId: alice.accountId, online: true })] });

    const second = (await db`
      INSERT INTO devices(account_id, platform, device_name, auth_token_hash)
      VALUES (${alice.accountId}, 'ios', 'Alice iPad', ${hashToken(crypto.randomUUID())})
      RETURNING id`)[0];
    const secondConnection = crypto.randomUUID();
    expect(await setPresenceActivity(db, {
      accountId: alice.accountId, deviceId: String(second.id),
      connectionId: secondConnection, active: true,
    })).toEqual([]);
    expect(await setPresenceActivity(db, {
      accountId: alice.accountId, deviceId: alice.deviceId,
      connectionId: firstConnection, active: false,
    })).toEqual([]);
    const offline = await setPresenceActivity(db, {
      accountId: alice.accountId, deviceId: String(second.id),
      connectionId: secondConnection, active: false,
    });
    expect(offline[0]?.event).toEqual(expect.objectContaining({
      type: "presence_update", accountId: alice.accountId, online: false,
    }));
    const snapshot = (await queryPresence(db, bob.accountId, [alice.accountId])).presences[0];
    expect(snapshot.online).toBe(false);
    expect(snapshot.lastSeenAt).not.toBeNull();
    expect(snapshot.revision).toBe(2);
  });

  test("a stale socket close cannot deactivate its replacement", async () => {
    const { alice, bob } = await directPair();
    const oldConnection = crypto.randomUUID();
    const newConnection = crypto.randomUUID();
    await setPresenceActivity(db, {
      accountId: alice.accountId, deviceId: alice.deviceId,
      connectionId: oldConnection, active: true,
    });
    await setPresenceActivity(db, {
      accountId: alice.accountId, deviceId: alice.deviceId,
      connectionId: newConnection, active: true,
    });
    expect(await setPresenceActivity(db, {
      accountId: alice.accountId, deviceId: alice.deviceId,
      connectionId: oldConnection, active: false,
    })).toEqual([]);
    expect((await queryPresence(db, bob.accountId, [alice.accountId])).presences[0].online)
      .toBe(true);
  });

  test("expired leases publish the last confirmed heartbeat and advance revision", async () => {
    const { alice, bob } = await directPair();
    await setPresenceActivity(db, {
      accountId: alice.accountId, deviceId: alice.deviceId,
      connectionId: crypto.randomUUID(), active: true,
    });
    const heartbeat = new Date(Date.now() - 90_000);
    await db`
      UPDATE device_presence_leases
      SET last_heartbeat_at = ${heartbeat}, expires_at = now() - interval '1 second'
      WHERE device_id = ${alice.deviceId}`;
    const broadcasts = await expirePresenceLeases(db);
    expect(broadcasts[0]?.recipientAccountIds).toEqual([bob.accountId]);
    const snapshot = (await queryPresence(db, bob.accountId, [alice.accountId])).presences[0];
    expect(snapshot.online).toBe(false);
    expect(new Date(snapshot.lastSeenAt!).getTime()).toBe(heartbeat.getTime());
    expect(snapshot.revision).toBe(2);
  });

  test("a heartbeat re-establishes a foreground socket whose lease expired", async () => {
    const { alice, bob } = await directPair();
    const connectionId = crypto.randomUUID();
    await setPresenceActivity(db, {
      accountId: alice.accountId, deviceId: alice.deviceId, connectionId, active: true,
    });
    await db`
      UPDATE device_presence_leases
      SET last_heartbeat_at = now() - interval '2 seconds',
          expires_at = now() - interval '1 second'
      WHERE device_id = ${alice.deviceId}`;
    await expirePresenceLeases(db);
    const broadcasts = await heartbeatPresence(db, {
      accountId: alice.accountId, deviceId: alice.deviceId, connectionId,
    });
    expect(broadcasts[0]?.event).toEqual(expect.objectContaining({
      type: "presence_update", online: true, revision: 3,
    }));
    expect((await queryPresence(db, bob.accountId, [alice.accountId])).presences[0].online)
      .toBe(true);
  });

  test("PostgreSQL notifications deliver presence events across server processes", async () => {
    const { alice, bob } = await directPair();
    let resolveBroadcast: ((value: unknown) => void) | undefined;
    const received = new Promise<any>((resolve) => { resolveBroadcast = resolve; });
    const stop = startPresenceNotificationListener(TEST_URL, (broadcast) => {
      if (broadcast.recipientAccountIds.includes(bob.accountId)) resolveBroadcast?.(broadcast);
    });
    try {
      await Bun.sleep(100);
      await setPresenceActivity(db, {
        accountId: alice.accountId,
        deviceId: alice.deviceId,
        connectionId: crypto.randomUUID(),
        active: true,
      });
      const broadcast = await Promise.race([
        received,
        Bun.sleep(3_000).then(() => { throw new Error("presence notification timed out"); }),
      ]);
      expect(broadcast.event).toEqual(expect.objectContaining({
        type: "presence_update", accountId: alice.accountId, online: true,
      }));
    } finally {
      stop();
    }
  }, 5_000);

  test("blocking hides direct presence and direct typing in both directions", async () => {
    const { alice, bob, dialogId } = await directPair();
    await setPresenceActivity(db, {
      accountId: alice.accountId, deviceId: alice.deviceId,
      connectionId: crypto.randomUUID(), active: true,
    });
    await blockAccount(db, bob.accountId, alice.accountId);
    expect(await queryPresence(db, bob.accountId, [alice.accountId])).toEqual({ presences: [] });
    expect(await publishTyping(db, {
      accountId: alice.accountId, dialogId,
      typingSessionId: crypto.randomUUID(), active: true,
    })).toEqual([]);
  });

  test("group typing reaches current members and rejects removed members", async () => {
    const owner = await account("+16505554110", "Owner");
    const alice = await account("+16505554111", "Alice");
    const bob = await account("+16505554112", "Bob");
    const groupId = crypto.randomUUID();
    await createGroup(db, {
      creatorAccountId: owner.accountId,
      creatorDeviceId: owner.deviceId,
      groupId,
      title: "Presence",
      memberIds: [alice.accountId, bob.accountId],
    });
    const event = await publishTyping(db, {
      accountId: alice.accountId, dialogId: groupId,
      typingSessionId: crypto.randomUUID(), active: true,
    });
    expect(event[0]?.recipientAccountIds.sort()).toEqual([bob.accountId, owner.accountId].sort());
    expect(event[0]?.event).toEqual(expect.objectContaining({
      type: "typing_update", actorAccountId: alice.accountId, expiresInMs: 7_000,
    }));
    await removeGroupMember(db, {
      actorAccountId: owner.accountId,
      actorDeviceId: owner.deviceId,
      dialogId: groupId,
      targetAccountId: alice.accountId,
      clientMutationId: crypto.randomUUID(),
    });
    expect(await publishTyping(db, {
      accountId: alice.accountId, dialogId: groupId,
      typingSessionId: crypto.randomUUID(), active: true,
    })).toEqual([]);
  });
});
