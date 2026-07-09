import type { ServerWebSocket } from "bun";
import { sql as defaultSql } from "./db";
import { startVerification, checkVerification, resolveDevice, lookupAccountByPhone, AuthError } from "./auth";
import {
  getBootstrapDialogsPage,
  getDifference,
  getHistory,
  getOrCreateDirectDialog,
  getState,
  readHistory,
  sendMessage,
  startBootstrap,
  SyncError,
  type Push,
} from "./sync";

type SocketData = { accountId: string; deviceId: string };
type Db = typeof defaultSql;

const jsonHeaders = { "content-type": "application/json" };

function json(value: unknown, status = 200): Response {
  return new Response(JSON.stringify(value), { status, headers: jsonHeaders });
}

async function readJson(req: Request): Promise<any> {
  if (req.method === "GET" || req.method === "HEAD") return {};
  const text = await req.text();
  if (!text) return {};
  try {
    return JSON.parse(text);
  } catch {
    throw new SyncError("invalid JSON body");
  }
}

function bearer(req: Request): string | null {
  const auth = req.headers.get("authorization") ?? "";
  const match = auth.match(/^Bearer\s+(.+)$/i);
  return match ? match[1] : null;
}

async function authed(db: Db, req: Request): Promise<{ accountId: string; deviceId: string }> {
  const token = bearer(req);
  if (!token) throw new AuthError("missing bearer token");
  return await resolveDevice(db, token);
}

function pushHints(sockets: Map<string, Set<ServerWebSocket<SocketData>>>, pushes: Push[]) {
  for (const push of pushes) {
    const set = sockets.get(push.accountId);
    if (!set) continue;
    const payload = JSON.stringify({ type: "sync_hint", pts: push.pts, ptsCount: push.ptsCount });
    for (const ws of set) {
      if (ws.readyState === 1) ws.send(payload);
    }
  }
}

export function startCloudServer(port = Number(process.env.PORT ?? 8788), db: Db = defaultSql) {
  const sockets = new Map<string, Set<ServerWebSocket<SocketData>>>();
  const log = (...args: unknown[]) => console.log(new Date().toISOString(), ...args);

  const server = Bun.serve<SocketData>({
    port,
    async fetch(req, server) {
      const url = new URL(req.url);
      try {
        if (url.pathname === "/health") return new Response("ok");

        if (url.pathname === "/v1/ws") {
          const token = url.searchParams.get("token");
          if (!token) return new Response("token required", { status: 401 });
          const dev = await resolveDevice(db, token);
          if (server.upgrade(req, { data: dev })) return undefined;
          return new Response("upgrade failed", { status: 400 });
        }

        if (url.pathname === "/v1/auth/start" && req.method === "POST") {
          const body = await readJson(req);
          if (!body.phone) throw new AuthError("phone required");
          return json(await startVerification(db, body.phone));
        }

        if (url.pathname === "/v1/auth/check" && req.method === "POST") {
          const body = await readJson(req);
          if (!body.phone || !body.code) throw new AuthError("phone and code required");
          return json(await checkVerification(db, body.phone, body.code, body.platform ?? "ios", body.deviceName, body.displayName));
        }

        const session = await authed(db, req);
        const body = await readJson(req);

        if (url.pathname === "/v1/sync/state" && req.method === "GET") {
          return json(await getState(db, session.accountId));
        }

        if (url.pathname === "/v1/sync/difference" && req.method === "POST") {
          return json(await getDifference(db, session.accountId, Number(body.sincePts ?? 0), {
            maxEvents: body.maxEvents,
            maxBytes: body.maxBytes,
          }));
        }

        if (url.pathname === "/v1/bootstrap/start" && req.method === "POST") {
          return json(await startBootstrap(db, session.accountId));
        }

        if (url.pathname === "/v1/bootstrap/dialogs" && req.method === "POST") {
          return json(await getBootstrapDialogsPage(db, session.accountId, body.token, {
            cursor: body.cursor,
            limit: body.limit,
            previewMessages: body.previewMessages,
          }));
        }

        if (url.pathname === "/v1/contacts/lookup" && req.method === "POST") {
          if (!body.phone) throw new SyncError("phone required");
          const found = await lookupAccountByPhone(db, body.phone);
          return json(found ?? { found: false });
        }

        if (url.pathname === "/v1/dialogs/direct" && req.method === "POST") {
          if (!body.peerAccountId) throw new SyncError("peerAccountId required");
          return json(await getOrCreateDirectDialog(db, session.accountId, body.peerAccountId));
        }

        if (url.pathname === "/v1/messages/send" && req.method === "POST") {
          const result = await sendMessage(db, {
            senderAccountId: session.accountId,
            senderDeviceId: session.deviceId,
            dialogId: body.dialogId,
            clientMsgId: body.clientMsgId,
            kind: body.kind,
            body: body.body ?? "",
          });
          pushHints(sockets, result.pushes);
          return json(result);
        }

        if (url.pathname === "/v1/history" && req.method === "POST") {
          return json(await getHistory(db, session.accountId, body.dialogId, {
            beforeMsgId: body.beforeMsgId,
            limit: body.limit,
            maxBytes: body.maxBytes,
          }));
        }

        if (url.pathname === "/v1/read" && req.method === "POST") {
          const result = await readHistory(db, {
            accountId: session.accountId,
            dialogId: body.dialogId,
            maxReadMsgId: Number(body.maxReadMsgId ?? 0),
          });
          pushHints(sockets, result.pushes);
          return json(result);
        }

        return new Response("not found", { status: 404 });
      } catch (err) {
        const status = err instanceof AuthError ? 401 : err instanceof SyncError ? 400 : 500;
        if (status === 500) console.error(err);
        return json({ error: err instanceof Error ? err.message : String(err) }, status);
      }
    },
    websocket: {
      open(ws) {
        const set = sockets.get(ws.data.accountId) ?? new Set<ServerWebSocket<SocketData>>();
        set.add(ws);
        sockets.set(ws.data.accountId, set);
        log("cloud.ws.open", ws.data.accountId, ws.data.deviceId);
      },
      close(ws) {
        const set = sockets.get(ws.data.accountId);
        if (set) {
          set.delete(ws);
          if (set.size === 0) sockets.delete(ws.data.accountId);
        }
        log("cloud.ws.close", ws.data.accountId, ws.data.deviceId);
      },
      message(ws, raw) {
        if (String(raw) === "ping") ws.send("pong");
      },
    },
  });

  log(`cloud listening on :${server.port}`);
  return server;
}

if (import.meta.main) startCloudServer();
