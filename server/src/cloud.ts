import type { ServerWebSocket } from "bun";
import { sql as defaultSql } from "./db";
import {
  startVerification,
  checkVerification,
  resolveDevice,
  lookupAccountByPhone,
  otpDeliveryFromEnvironment,
  revokeDevice,
  listDevices,
  startAccountDeletion,
  deleteAccount,
  privateBetaOTPConfigured,
  AuthError,
  type OTPDelivery,
} from "./auth";
import {
  APNsClient,
  PushError,
  registerPushToken,
  startPushWorker,
  unregisterPushToken,
  type PushSender,
} from "./push";
import {
  getBootstrapDialogsPage,
  getDifference,
  getHistory,
  getOrCreateDirectDialog,
  getState,
  readHistory,
  sendMessage,
  editMessage,
  deleteMessage,
  setReaction,
  startBootstrap,
  SyncError,
  type Push,
} from "./sync";
import {
  OperationalMetrics,
  logRequest,
  readiness,
  requestIdFrom,
  safeRoute,
  startMaintenanceWorker,
} from "./ops";
import {
  cancelMediaUpload,
  completeMediaUpload,
  createMediaUpload,
  downloadMediaChunk,
  downloadMediaThumbnail,
  getMediaUpload,
  mediaLimits,
  MediaError,
  uploadMediaChunk,
  uploadMediaThumbnail,
} from "./media";

type SocketData = { accountId: string; deviceId: string };
type Db = typeof defaultSql;

const jsonHeaders = { "content-type": "application/json", "cache-control": "no-store" };
const MAX_JSON_BYTES = 64 * 1024;

function json(value: unknown, status = 200, extraHeaders: HeadersInit = {}): Response {
  return new Response(JSON.stringify(value), {
    status,
    headers: { ...jsonHeaders, ...Object.fromEntries(new Headers(extraHeaders)) },
  });
}

async function readJson(req: Request): Promise<any> {
  if (req.method === "GET" || req.method === "HEAD") return {};
  const contentLength = Number(req.headers.get("content-length") ?? 0);
  if (contentLength > MAX_JSON_BYTES) throw new SyncError("request body too large");
  const text = await req.text();
  if (!text) return {};
  if (Buffer.byteLength(text) > MAX_JSON_BYTES) throw new SyncError("request body too large");
  try {
    return JSON.parse(text);
  } catch {
    throw new SyncError("invalid JSON body");
  }
}

async function readBinary(req: Request, maxBytes: number): Promise<Buffer> {
  const declaredHeader = req.headers.get("content-length");
  if (declaredHeader !== null) {
    const declared = Number(declaredHeader);
    if (!Number.isSafeInteger(declared) || declared < 0) throw new MediaError("invalid content length");
    if (declared > maxBytes) throw new MediaError("request body too large", 413);
  }
  if (!req.body) return Buffer.alloc(0);
  const reader = req.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > maxBytes) {
        await reader.cancel("request body too large");
        throw new MediaError("request body too large", 413);
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }
  return Buffer.concat(chunks.map((chunk) => Buffer.from(chunk)), total);
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

function disconnectDevice(
  sockets: Map<string, Set<ServerWebSocket<SocketData>>>,
  accountId: string,
  deviceId: string,
) {
  for (const socket of sockets.get(accountId) ?? []) {
    if (socket.data.deviceId === deviceId) socket.close(4001, "device revoked");
  }
}

function disconnectAccount(
  sockets: Map<string, Set<ServerWebSocket<SocketData>>>,
  accountId: string,
) {
  for (const socket of sockets.get(accountId) ?? []) socket.close(4002, "account deleted");
  sockets.delete(accountId);
}

function networkKey(req: Request, server: { requestIP(request: Request): { address: string } | null }): string | null {
  const forwarded = process.env.TOJ_TRUST_PROXY === "1"
    ? req.headers.get("x-forwarded-for")?.split(",")[0]?.trim()
    : null;
  return forwarded || server.requestIP(req)?.address || null;
}

export function startCloudServer(
  port = Number(process.env.PORT ?? 8788),
  db: Db = defaultSql,
  pushSender: PushSender | null = APNsClient.fromEnvironment(),
  otpDelivery: OTPDelivery | null = otpDeliveryFromEnvironment(),
) {
  const sockets = new Map<string, Set<ServerWebSocket<SocketData>>>();
  const metrics = new OperationalMetrics();
  const stopPushWorker = startPushWorker(db, pushSender);
  const stopMaintenanceWorker = startMaintenanceWorker(db);

  const server = Bun.serve<SocketData>({
    port,
    async fetch(req, server) {
      const url = new URL(req.url);
      const requestId = requestIdFrom(req);
      const route = safeRoute(url.pathname);
      const started = performance.now();
      let response: Response | undefined;
      try {
        if (url.pathname === "/health") response = new Response("ok");

        else if (url.pathname === "/ready") {
          response = json(await readiness(db, {
            sms: otpDelivery ? "configured" : privateBetaOTPConfigured() ? "development" : "disabled",
            push: pushSender ? "configured" : "disabled",
          }));
        }

        else if (url.pathname === "/metrics") {
          const metricsToken = process.env.TOJ_METRICS_TOKEN;
          if (!metricsToken) response = new Response("not found", { status: 404 });
          else if (bearer(req) !== metricsToken) response = new Response("unauthorized", { status: 401 });
          else response = new Response(metrics.render(), { headers: { "content-type": "text/plain; version=0.0.4" } });
        }

        else if (url.pathname === "/v1/ws") {
          const legacyQueryToken = process.env.TOJ_ALLOW_LEGACY_WS_QUERY_TOKEN === "1"
            ? url.searchParams.get("token")
            : null;
          const token = bearer(req) ?? legacyQueryToken;
          if (!token) response = new Response("token required", { status: 401 });
          else {
          const dev = await resolveDevice(db, token);
          if (server.upgrade(req, { data: dev })) response = undefined;
          else response = new Response("upgrade failed", { status: 400 });
          }
        }

        else if (url.pathname === "/v1/auth/start" && req.method === "POST") {
          const body = await readJson(req);
          if (!body.phone) throw new AuthError("phone required", 400);
          response = json(await startVerification(db, body.phone, {
            networkKey: networkKey(req, server), delivery: otpDelivery,
          }));
        }

        else if (url.pathname === "/v1/auth/check" && req.method === "POST") {
          const body = await readJson(req);
          if (!body.phone || !body.code) throw new AuthError("phone and code required", 400);
          response = json(await checkVerification(db, body.phone, body.code, body.platform ?? "ios", body.deviceName, body.displayName));
        }

        else {
          const session = await authed(db, req);
          const uploadChunkMatch = url.pathname.match(/^\/v1\/media\/uploads\/([0-9a-f-]+)\/chunks$/i);
          const uploadThumbnailMatch = url.pathname.match(/^\/v1\/media\/uploads\/([0-9a-f-]+)\/thumbnail$/i);
          const downloadChunkMatch = url.pathname.match(/^\/v1\/media\/([0-9a-f-]+)\/chunks$/i);
          const downloadThumbnailMatch = url.pathname.match(/^\/v1\/media\/([0-9a-f-]+)\/thumbnail$/i);

          if (uploadChunkMatch && req.method === "PUT") {
            const offsetHeader = req.headers.get("upload-offset");
            if (offsetHeader == null) throw new MediaError("upload offset required");
            const offset = Number(offsetHeader);
            const bytes = await readBinary(req, mediaLimits().chunkBytes);
            const result = await uploadMediaChunk(
              db, session.accountId, session.deviceId, uploadChunkMatch[1], offset, bytes,
            );
            response = json(result, 200, {
              "upload-offset": String(result.uploadOffset),
            });
          } else if (uploadThumbnailMatch && req.method === "PUT") {
            const contentType = req.headers.get("content-type") ?? "";
            const bytes = await readBinary(req, mediaLimits().thumbnailBytes);
            response = json(await uploadMediaThumbnail(
              db, session.accountId, session.deviceId, uploadThumbnailMatch[1], contentType, bytes,
            ));
          } else if (downloadChunkMatch && req.method === "GET") {
            const result = await downloadMediaChunk(
              db, session.accountId, downloadChunkMatch[1], Number(url.searchParams.get("offset") ?? 0),
            );
            response = new Response(result.bytes, {
              headers: {
                "content-type": result.contentType,
                "content-length": String(result.bytes.length),
                "cache-control": "private, no-store",
                "x-media-total-size": String(result.totalSize),
                "x-media-next-offset": String(result.nextOffset),
                "accept-ranges": "bytes",
              },
            });
          } else if (downloadThumbnailMatch && req.method === "GET") {
            const result = await downloadMediaThumbnail(db, session.accountId, downloadThumbnailMatch[1]);
            response = new Response(result.bytes, {
              headers: { "content-type": result.contentType, "cache-control": "private, no-store" },
            });
          } else {
          const body = await readJson(req);

        if (url.pathname === "/v1/devices/push" && req.method === "POST") {
          if (!body.token || !body.environment) throw new PushError("token and environment required");
          response = json(await registerPushToken(db, session.deviceId, body.token, body.environment));
        }

        if (url.pathname === "/v1/devices/push" && req.method === "DELETE") {
          response = json(await unregisterPushToken(db, session.deviceId));
        }

        if (url.pathname === "/v1/session" && req.method === "DELETE") {
          const result = await revokeDevice(db, session.accountId, session.deviceId);
          disconnectDevice(sockets, session.accountId, session.deviceId);
          response = json(result);
        }

        if (url.pathname === "/v1/account/deletion/start" && req.method === "POST") {
          response = json(await startAccountDeletion(db, session.accountId, {
            networkKey: networkKey(req, server), delivery: otpDelivery,
          }));
        }

        if (url.pathname === "/v1/account" && req.method === "DELETE") {
          if (!body.code) throw new AuthError("code required", 400);
          const result = await deleteAccount(db, session.accountId, String(body.code));
          disconnectAccount(sockets, session.accountId);
          response = json(result);
        }

        if (url.pathname === "/v1/devices" && req.method === "GET") {
          response = json(await listDevices(db, session.accountId, session.deviceId));
        }

        const deviceMatch = url.pathname.match(/^\/v1\/devices\/([0-9a-f-]+)$/i);
        if (deviceMatch && req.method === "DELETE") {
          const targetDeviceId = deviceMatch[1];
          if (targetDeviceId === session.deviceId) {
            throw new AuthError("use sign out for the current device", 400);
          }
          const result = await revokeDevice(db, session.accountId, targetDeviceId);
          disconnectDevice(sockets, session.accountId, targetDeviceId);
          response = json(result);
        }

        if (url.pathname === "/v1/sync/state" && req.method === "GET") {
          response = json(await getState(db, session.accountId));
        }

        if (url.pathname === "/v1/sync/difference" && req.method === "POST") {
          response = json(await getDifference(db, session.accountId, Number(body.sincePts ?? 0), {
            maxEvents: body.maxEvents,
            maxBytes: body.maxBytes,
          }));
        }

        if (url.pathname === "/v1/bootstrap/start" && req.method === "POST") {
          response = json(await startBootstrap(db, session.accountId));
        }

        if (url.pathname === "/v1/bootstrap/dialogs" && req.method === "POST") {
          response = json(await getBootstrapDialogsPage(db, session.accountId, body.token, {
            cursor: body.cursor,
            limit: body.limit,
            previewMessages: body.previewMessages,
          }));
        }

        if (url.pathname === "/v1/contacts/lookup" && req.method === "POST") {
          if (!body.phone) throw new SyncError("phone required");
          const found = await lookupAccountByPhone(db, session.accountId, body.phone);
          response = json(found ?? { found: false });
        }

        if (url.pathname === "/v1/dialogs/direct" && req.method === "POST") {
          if (!body.peerAccountId) throw new SyncError("peerAccountId required");
          response = json(await getOrCreateDirectDialog(
            db, session.accountId, body.peerAccountId, session.deviceId,
          ));
        }

        if (url.pathname === "/v1/messages/send" && req.method === "POST") {
          const result = await sendMessage(db, {
            senderAccountId: session.accountId,
            senderDeviceId: session.deviceId,
            dialogId: body.dialogId,
            clientMsgId: body.clientMsgId,
            kind: body.kind,
            body: body.body ?? "",
            mediaId: body.mediaId,
            replyToMsgId: body.replyToMsgId,
            forwardedFrom: body.forwardedFrom,
          });
          pushHints(sockets, result.pushes);
          response = json(result);
        }

        if (url.pathname === "/v1/messages/react" && req.method === "POST") {
          if (!body.dialogId || !body.msgId || !body.clientMutationId) throw new SyncError("reaction fields required");
          const result = await setReaction(db, {
            actorAccountId: session.accountId,
            actorDeviceId: session.deviceId,
            dialogId: body.dialogId,
            msgId: Number(body.msgId),
            clientMutationId: body.clientMutationId,
            emoji: body.emoji ?? null,
          });
          pushHints(sockets, result.pushes);
          response = json(result);
        }

        if (url.pathname === "/v1/messages/edit" && req.method === "POST") {
          if (!body.dialogId || !body.msgId || !body.clientMutationId) throw new SyncError("message mutation fields required");
          const result = await editMessage(db, {
            actorAccountId: session.accountId,
            actorDeviceId: session.deviceId,
            dialogId: body.dialogId,
            msgId: Number(body.msgId),
            clientMutationId: body.clientMutationId,
            body: body.body,
            expectedEditVersion: Number(body.expectedEditVersion),
          });
          pushHints(sockets, result.pushes);
          response = json(result);
        }

        if (url.pathname === "/v1/messages/delete" && req.method === "POST") {
          if (!body.dialogId || !body.msgId || !body.clientMutationId) throw new SyncError("message mutation fields required");
          const result = await deleteMessage(db, {
            actorAccountId: session.accountId,
            actorDeviceId: session.deviceId,
            dialogId: body.dialogId,
            msgId: Number(body.msgId),
            clientMutationId: body.clientMutationId,
          });
          pushHints(sockets, result.pushes);
          response = json(result);
        }

        if (url.pathname === "/v1/history" && req.method === "POST") {
          response = json(await getHistory(db, session.accountId, body.dialogId, {
            beforeMsgId: body.beforeMsgId,
            limit: body.limit,
            maxBytes: body.maxBytes,
          }));
        }

        if (url.pathname === "/v1/read" && req.method === "POST") {
          const result = await readHistory(db, {
            accountId: session.accountId,
            deviceId: session.deviceId,
            dialogId: body.dialogId,
            maxReadMsgId: Number(body.maxReadMsgId ?? 0),
          });
          pushHints(sockets, result.pushes);
          response = json(result);
        }

        if (url.pathname === "/v1/media/uploads" && req.method === "POST") {
          response = json(await createMediaUpload(db, session.accountId, session.deviceId, body), 201);
        }

        const mediaUploadMatch = url.pathname.match(/^\/v1\/media\/uploads\/([0-9a-f-]+)$/i);
        if (mediaUploadMatch && req.method === "GET") {
          response = json(await getMediaUpload(db, session.accountId, mediaUploadMatch[1]));
        }
        if (mediaUploadMatch && req.method === "DELETE") {
          response = json(await cancelMediaUpload(db, session.accountId, session.deviceId, mediaUploadMatch[1]));
        }

        const mediaCompleteMatch = url.pathname.match(/^\/v1\/media\/uploads\/([0-9a-f-]+)\/complete$/i);
        if (mediaCompleteMatch && req.method === "POST") {
          response = json(await completeMediaUpload(db, session.accountId, session.deviceId, mediaCompleteMatch[1]));
        }

        if (!response) response = new Response("not found", { status: 404 });
          }
        }
      } catch (err) {
        const status = err instanceof AuthError
          ? err.status
          : err instanceof MediaError ? err.status
          : err instanceof SyncError || err instanceof PushError ? 400 : 500;
        if (status === 500) {
          console.error(JSON.stringify({
            ts: new Date().toISOString(), event: "http.error", requestId,
            errorType: err instanceof Error ? err.name : "UnknownError",
          }));
        }
        const message = status === 500
          ? "internal server error"
          : err instanceof Error ? err.message : String(err);
        const headers: Record<string, string> = {};
        if (err instanceof AuthError && err.retryAfter) headers["retry-after"] = String(err.retryAfter);
        if (status === 401) headers["www-authenticate"] = "Bearer";
        response = json({ error: message }, status, headers);
      }
      const status = response?.status ?? 101;
      const durationMs = performance.now() - started;
      metrics.record(req.method, route, status, durationMs);
      logRequest({ requestId, method: req.method, route, status, durationMs });
      response?.headers.set("x-request-id", requestId);
      return response;
    },
    websocket: {
      open(ws) {
        const set = sockets.get(ws.data.accountId) ?? new Set<ServerWebSocket<SocketData>>();
        set.add(ws);
        sockets.set(ws.data.accountId, set);
        console.log(JSON.stringify({ ts: new Date().toISOString(), event: "cloud.ws.open" }));
      },
      close(ws) {
        const set = sockets.get(ws.data.accountId);
        if (set) {
          set.delete(ws);
          if (set.size === 0) sockets.delete(ws.data.accountId);
        }
        console.log(JSON.stringify({ ts: new Date().toISOString(), event: "cloud.ws.close" }));
      },
      message(ws, raw) {
        if (String(raw) === "ping") ws.send("pong");
      },
    },
  });

  const originalStop = server.stop.bind(server);
  server.stop = ((closeActiveConnections?: boolean) => {
    stopPushWorker();
    stopMaintenanceWorker();
    return originalStop(closeActiveConnections);
  }) as typeof server.stop;

  console.log(JSON.stringify({ ts: new Date().toISOString(), event: "cloud.listening", port: server.port }));
  return server;
}

if (import.meta.main) startCloudServer();
