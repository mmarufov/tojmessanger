import { afterAll, beforeAll, expect, test } from "bun:test";
import { startRelay, type Envelope } from "./relay";

let server: ReturnType<typeof startRelay>;
let base: string;
let wsBase: string;

beforeAll(() => {
  server = startRelay(0);
  base = `http://127.0.0.1:${server.port}`;
  wsBase = `ws://127.0.0.1:${server.port}`;
});

afterAll(() => {
  server.stop(true);
});

function connect(user: string, onMessage: (env: Envelope) => void): Promise<WebSocket> {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`${wsBase}/v1/ws?user=${user}`);
    ws.onopen = () => resolve(ws);
    ws.onerror = (e) => reject(e);
    ws.onmessage = (event) => onMessage(JSON.parse(String(event.data)));
  });
}

function waitFor<T>(predicate: () => T | undefined, ms = 2000): Promise<T> {
  const start = Date.now();
  return new Promise((resolve, reject) => {
    const tick = () => {
      const value = predicate();
      if (value !== undefined) return resolve(value);
      if (Date.now() - start > ms) return reject(new Error("timeout"));
      setTimeout(tick, 10);
    };
    tick();
  });
}

const msg = (from: string, to: string, id: string): Envelope => ({
  v: 1,
  type: "msg",
  id,
  from,
  to,
  payloadType: 3,
  payload: "b3BhcXVlLWNpcGhlcnRleHQ=",
  ts: Date.now(),
});

test("prekey bundles: PUT then GET round-trips, unknown user 404s", async () => {
  const bundle = JSON.stringify({ registrationId: 42, identityKey: "abc" });
  const put = await fetch(`${base}/v1/keys/alice`, { method: "PUT", body: bundle });
  expect(put.status).toBe(200);

  const hit = await fetch(`${base}/v1/keys/alice`);
  expect(hit.status).toBe(200);
  expect(await hit.text()).toBe(bundle);

  const miss = await fetch(`${base}/v1/keys/nobody`);
  expect(miss.status).toBe(404);
});

test("online delivery: sender gets ack, recipient gets envelope", async () => {
  const aliceInbox: Envelope[] = [];
  const bobInbox: Envelope[] = [];
  const alice = await connect("alice", (e) => aliceInbox.push(e));
  const bob = await connect("bob", (e) => bobInbox.push(e));

  alice.send(JSON.stringify(msg("alice", "bob", "m-1")));

  const ack = await waitFor(() => aliceInbox.find((e) => e.type === "ack" && e.id === "m-1"));
  expect(ack.from).toBe("server");
  const received = await waitFor(() => bobInbox.find((e) => e.type === "msg" && e.id === "m-1"));
  expect(received.from).toBe("alice");
  expect(received.payload).toBe("b3BhcXVlLWNpcGhlcnRleHQ=");

  alice.close();
  bob.close();
});

test("offline queue: messages flush when recipient connects", async () => {
  const aliceInbox: Envelope[] = [];
  const alice = await connect("alice", (e) => aliceInbox.push(e));

  alice.send(JSON.stringify(msg("alice", "offline-bob", "m-q1")));
  alice.send(JSON.stringify(msg("alice", "offline-bob", "m-q2")));
  await waitFor(() => aliceInbox.filter((e) => e.type === "ack").length >= 2 ? true : undefined);

  const bobInbox: Envelope[] = [];
  const bob = await connect("offline-bob", (e) => bobInbox.push(e));
  await waitFor(() => bobInbox.length >= 2 ? true : undefined);
  expect(bobInbox.map((e) => e.id).sort()).toEqual(["m-q1", "m-q2"]);

  alice.close();
  bob.close();
});

test("duplicate ids are acked but not re-delivered", async () => {
  const bobInbox: Envelope[] = [];
  const aliceInbox: Envelope[] = [];
  const alice = await connect("alice", (e) => aliceInbox.push(e));
  const bob = await connect("bob", (e) => bobInbox.push(e));

  alice.send(JSON.stringify(msg("alice", "bob", "m-dup")));
  alice.send(JSON.stringify(msg("alice", "bob", "m-dup")));

  await waitFor(() => aliceInbox.filter((e) => e.type === "ack" && e.id === "m-dup").length >= 2 ? true : undefined);
  await waitFor(() => bobInbox.find((e) => e.id === "m-dup"));
  await new Promise((r) => setTimeout(r, 50));
  expect(bobInbox.filter((e) => e.id === "m-dup").length).toBe(1);

  alice.close();
  bob.close();
});

test("spoofed from is dropped", async () => {
  const bobInbox: Envelope[] = [];
  const mallory = await connect("mallory", () => {});
  const bob = await connect("bob", (e) => bobInbox.push(e));

  mallory.send(JSON.stringify(msg("alice", "bob", "m-spoof")));
  await new Promise((r) => setTimeout(r, 100));
  expect(bobInbox.find((e) => e.id === "m-spoof")).toBeUndefined();

  mallory.close();
  bob.close();
});
