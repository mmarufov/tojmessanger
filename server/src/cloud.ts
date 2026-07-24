import type { ServerWebSocket } from "bun";
import { sql as defaultSql } from "./db";
import {
  startVerification,
  checkVerification,
  resolveDevice,
  lookupAccountByPhone,
  getProfile,
  updateProfile,
  otpDeliveryFromEnvironment,
  listDevices,
  startAccountDeletion,
  privateBetaOTPConfigured,
  AuthError,
  type OTPDelivery,
} from "./auth";
import {
  APNsClient,
  PushError,
  registerPushToken,
  registerVoIPPushToken,
  startPushWorker,
  unregisterPushToken,
  unregisterVoIPPushToken,
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
  startSyncNotificationListener,
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
  LARGE_MEDIA_PART_SIZE,
  mediaLimits,
  MediaError,
  uploadMediaChunk,
  uploadMediaPart,
  uploadMediaThumbnail,
} from "./media";
import {
  acceptCall,
  blockAccount,
  CallError,
  cancelCall,
  confirmCallKey,
  createCall,
  declineCall,
  deleteAccountAndTerminateCalls,
  endCall,
  getActiveCalls,
  getCall,
  getCallEvents,
  getIceConfig,
  recordCallTelemetry,
  resolveCallHintTargets,
  revealCallKey,
  revokeDeviceAndTerminateCalls,
  sendEncryptedCallEvent,
  startCallCleanupWorker,
  startCallNotificationListener,
  unblockAccount,
  videoCallsEnabledForAccount,
  videoCallsConfigured,
  voiceCallsConfigured,
  type CallHint,
} from "./calls";

type SocketData = { accountId: string; deviceId: string };
type Db = typeof defaultSql;

const jsonHeaders = { "content-type": "application/json", "cache-control": "no-store" };
const MAX_JSON_BYTES = 64 * 1024;

export const CLOUD_CAPABILITIES = {
  api_version: 4,
  capabilities: [
    "core_text",
    "replies",
    "message_mutations",
    "reactions",
    "forwarding",
    "media_uploads",
    "media_multipart_v2",
    "voice_notes",
    "profiles",
  ],
} as const;

function cloudCapabilities(voiceCalls: boolean, videoCalls: boolean) {
  const capabilities = [...CLOUD_CAPABILITIES.capabilities];
  if (voiceCalls) capabilities.push("voice_calls_v1");
  if (videoCalls) capabilities.push("video_calls_v1");
  return { ...CLOUD_CAPABILITIES, capabilities };
}

function json(value: unknown, status = 200, extraHeaders: HeadersInit = {}): Response {
  return new Response(JSON.stringify(value), {
    status,
    headers: { ...jsonHeaders, ...Object.fromEntries(new Headers(extraHeaders)) },
  });
}

async function readJson(req: Request, maxBytes = MAX_JSON_BYTES): Promise<any> {
  if (req.method === "GET" || req.method === "HEAD") return {};
  const contentLength = Number(req.headers.get("content-length") ?? 0);
  if (contentLength > maxBytes) throw new SyncError("request body too large");
  const text = await req.text();
  if (!text) return {};
  if (Buffer.byteLength(text) > maxBytes) throw new SyncError("request body too large");
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

function pushCallHints(sockets: Map<string, Set<ServerWebSocket<SocketData>>>, hints: CallHint[]) {
  for (const hint of hints) {
    const payload = JSON.stringify({
      type: "call_hint", callId: hint.callId, latestEventSeq: hint.latestEventSeq,
    });
    for (const ws of sockets.get(hint.accountId) ?? []) {
      if (ws.data.deviceId === hint.deviceId && ws.readyState === 1) ws.send(payload);
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
  const callsAvailable = voiceCallsConfigured(pushSender !== null);
  const videoAvailable = videoCallsConfigured(callsAvailable);
  const stopPushWorker = startPushWorker(db, pushSender);
  const stopMaintenanceWorker = startMaintenanceWorker(db);
  const stopCallCleanupWorker = startCallCleanupWorker(db);
  const stopSyncNotifications = startSyncNotificationListener(
    process.env.TOJ_CALL_NOTIFY_DATABASE_URL ?? process.env.DATABASE_URL ?? null,
    (wakeup) => pushHints(sockets, [wakeup]),
  );
  const stopCallNotifications = startCallNotificationListener(
    process.env.TOJ_CALL_NOTIFY_DATABASE_URL ?? process.env.DATABASE_URL ?? null,
    async (wakeup) => {
      const localDeviceIds = [...sockets.values()]
        .flatMap((set) => [...set].map((socket) => socket.data.deviceId));
      const hints = await resolveCallHintTargets(db, wakeup, [...new Set(localDeviceIds)]);
      pushCallHints(sockets, hints);
    },
  );

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

        else if (url.pathname === "/v1/capabilities" && req.method === "GET") {
          const capabilityToken = bearer(req);
          const accountVideoAvailable = capabilityToken
            ? videoCallsEnabledForAccount((await resolveDevice(db, capabilityToken)).accountId, videoAvailable)
            : false;
          response = json(cloudCapabilities(callsAvailable, accountVideoAvailable));
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
          const uploadPartMatch = url.pathname.match(/^\/v1\/media\/uploads\/([0-9a-f-]+)\/parts\/(\d+)$/i);
          const uploadThumbnailMatch = url.pathname.match(/^\/v1\/media\/uploads\/([0-9a-f-]+)\/thumbnail$/i);
          const downloadChunkMatch = url.pathname.match(/^\/v1\/media\/([0-9a-f-]+)\/chunks$/i);
          const downloadThumbnailMatch = url.pathname.match(/^\/v1\/media\/([0-9a-f-]+)\/thumbnail$/i);

          if (uploadPartMatch && req.method === "PUT") {
            const bytes = await readBinary(req, LARGE_MEDIA_PART_SIZE);
            response = json(await uploadMediaPart(
              db, session.accountId, session.deviceId, uploadPartMatch[1], Number(uploadPartMatch[2]), bytes,
            ));
          } else if (uploadChunkMatch && req.method === "PUT") {
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
          const body = await readJson(
            req,
            /^\/v1\/calls\/[0-9a-f-]+\/events$/i.test(url.pathname) ? 96 * 1024 : MAX_JSON_BYTES,
          );
          const callActionMatch = url.pathname.match(
            /^\/v1\/calls\/([0-9a-f-]+)\/(accept|reveal|confirm|decline|cancel|end|events|ice-config|telemetry)$/i,
          );
          const callMatch = url.pathname.match(/^\/v1\/calls\/([0-9a-f-]+)$/i);
          const blockMatch = url.pathname.match(/^\/v1\/blocks\/([0-9a-f-]+)$/i);

        if (url.pathname === "/v1/devices/push" && req.method === "POST") {
          if (!body.token || !body.environment) throw new PushError("token and environment required");
          response = json(await registerPushToken(db, session.deviceId, body.token, body.environment));
        }

        if (url.pathname === "/v1/devices/push" && req.method === "DELETE") {
          response = json(await unregisterPushToken(db, session.deviceId));
        }

        if (url.pathname === "/v1/devices/voip-push" && req.method === "PUT") {
          if (!body.token || !body.environment) throw new PushError("token and environment required");
          response = json(await registerVoIPPushToken(
            db,
            session.deviceId,
            body.token,
            body.environment,
            body.supportedCallProtocolVersions,
            body.supportedCallMediaProfileVersions,
            body.callViewVersion,
          ));
        }

        if (url.pathname === "/v1/devices/voip-push" && req.method === "DELETE") {
          response = json(await unregisterVoIPPushToken(db, session.deviceId));
        }

        if (blockMatch && req.method === "PUT") {
          const result = await blockAccount(db, session.accountId, blockMatch[1]);
          pushCallHints(sockets, result.hints);
          pushHints(sockets, result.syncPushes);
          response = json({ blocked: result.blocked });
        }

        if (blockMatch && req.method === "DELETE") {
          response = json(await unblockAccount(db, session.accountId, blockMatch[1]));
        }

        if (url.pathname === "/v1/calls" && req.method === "POST") {
          if (!callsAvailable) throw new CallError("voice calls are disabled", "calls_disabled", 503);
          const result = await createCall(db, {
            callerAccountId: session.accountId,
            callerDeviceId: session.deviceId,
            callId: body.callId,
            dialogId: body.dialogId,
            callerCommitment: body.callerCommitment,
            supportedProtocolVersions: body.supportedProtocolVersions,
            offeredMediaProfileVersions: body.offeredMediaProfileVersions,
            networkKey: networkKey(req, server),
            videoEnabled: videoCallsEnabledForAccount(session.accountId, videoAvailable),
            videoRolloutReady: videoAvailable,
          });
          pushCallHints(sockets, result.hints);
          response = json({ call: result.call, ringTargetCount: result.ringTargetCount }, 201);
        }

        if (url.pathname === "/v1/calls/active" && req.method === "GET") {
          response = json(await getActiveCalls(db, session.accountId, session.deviceId));
        }

        if (callMatch && req.method === "GET") {
          response = json(await getCall(db, session.accountId, session.deviceId, callMatch[1]));
        }

        if (callActionMatch?.[2] === "accept" && req.method === "POST") {
          const result = await acceptCall(db, {
            accountId: session.accountId, deviceId: session.deviceId, callId: callActionMatch[1],
            calleeCommitment: body.calleeCommitment, protocolVersion: body.protocolVersion,
            selectedMediaProfileVersion: body.selectedMediaProfileVersion,
          });
          pushCallHints(sockets, result.hints);
          response = json({ call: result.call });
        }

        if (callActionMatch?.[2] === "reveal" && req.method === "POST") {
          const result = await revealCallKey(db, {
            accountId: session.accountId, deviceId: session.deviceId, callId: callActionMatch[1],
            publicKey: body.publicKey, nonce: body.nonce, fingerprint: body.fingerprint,
            confirmation: body.confirmation,
          });
          pushCallHints(sockets, result.hints);
          response = json({ call: result.call });
        }

        if (callActionMatch?.[2] === "confirm" && req.method === "POST") {
          const result = await confirmCallKey(db, {
            accountId: session.accountId, deviceId: session.deviceId, callId: callActionMatch[1],
            confirmation: body.confirmation,
          });
          pushCallHints(sockets, result.hints);
          response = json({ call: result.call });
        }

        if (callActionMatch?.[2] === "decline" && req.method === "POST") {
          const result = await declineCall(db, {
            accountId: session.accountId, deviceId: session.deviceId, callId: callActionMatch[1], reason: body.reason,
          });
          pushCallHints(sockets, result.hints);
          pushHints(sockets, result.syncPushes ?? []);
          response = json({ call: result.call });
        }

        if (callActionMatch?.[2] === "cancel" && req.method === "POST") {
          const result = await cancelCall(db, {
            accountId: session.accountId, deviceId: session.deviceId, callId: callActionMatch[1], reason: body.reason,
          });
          pushCallHints(sockets, result.hints);
          pushHints(sockets, result.syncPushes ?? []);
          response = json({ call: result.call });
        }

        if (callActionMatch?.[2] === "end" && req.method === "POST") {
          const result = await endCall(db, {
            accountId: session.accountId, deviceId: session.deviceId, callId: callActionMatch[1], reason: body.reason,
          });
          pushCallHints(sockets, result.hints);
          pushHints(sockets, result.syncPushes ?? []);
          response = json({ call: result.call });
        }

        if (callActionMatch?.[2] === "events" && req.method === "POST") {
          const result = await sendEncryptedCallEvent(db, {
            accountId: session.accountId, deviceId: session.deviceId, callId: callActionMatch[1],
            senderSequence: body.senderSequence, ciphertext: body.ciphertext,
            version: body.version, kind: body.kind, expiresAtMilliseconds: body.expiresAtMilliseconds,
          });
          pushCallHints(sockets, result.hints);
          pushHints(sockets, result.syncPushes ?? []);
          response = json({ event: result.event }, 201);
        }

        if (callActionMatch?.[2] === "events" && req.method === "GET") {
          response = json(await getCallEvents(
            db, session.accountId, session.deviceId, callActionMatch[1],
            url.searchParams.get("after") ?? 0, url.searchParams.get("limit") ?? 100,
          ));
        }

        if (callActionMatch?.[2] === "ice-config" && req.method === "GET") {
          response = json(await getIceConfig(db, session.accountId, session.deviceId, callActionMatch[1]));
        }

        if (callActionMatch?.[2] === "telemetry" && req.method === "POST") {
          response = json(await recordCallTelemetry(db, {
            accountId: session.accountId, deviceId: session.deviceId, callId: callActionMatch[1],
            outcome: body.outcome, role: body.role, routeClass: body.routeClass,
            privacyMode: body.privacyMode, setupBucket: body.setupBucket, recoveryBucket: body.recoveryBucket,
            rttBucket: body.rttBucket, lossBucket: body.lossBucket, jitterBucket: body.jitterBucket,
            bitrateBucket: body.bitrateBucket, recoveryCount: body.recoveryCount,
            appVersion: body.appVersion, region: body.region,
          }), 202);
        }

        if (url.pathname === "/v1/session" && req.method === "DELETE") {
          const result = await revokeDeviceAndTerminateCalls(db, session.accountId, session.deviceId);
          disconnectDevice(sockets, session.accountId, session.deviceId);
          pushCallHints(sockets, result.hints);
          pushHints(sockets, result.syncPushes);
          response = json({ revoked: result.revoked });
        }

        if (url.pathname === "/v1/account/deletion/start" && req.method === "POST") {
          response = json(await startAccountDeletion(db, session.accountId, {
            networkKey: networkKey(req, server), delivery: otpDelivery,
          }));
        }

        if (url.pathname === "/v1/account" && req.method === "DELETE") {
          if (!body.code) throw new AuthError("code required", 400);
          const result = await deleteAccountAndTerminateCalls(db, session.accountId, String(body.code));
          pushCallHints(sockets, result.hints);
          pushHints(sockets, result.syncPushes);
          disconnectAccount(sockets, session.accountId);
          response = json({ deleted: result.deleted });
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
          const result = await revokeDeviceAndTerminateCalls(db, session.accountId, targetDeviceId);
          disconnectDevice(sockets, session.accountId, targetDeviceId);
          pushCallHints(sockets, result.hints);
          pushHints(sockets, result.syncPushes);
          response = json({ revoked: result.revoked });
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

        if (url.pathname === "/v1/profile" && req.method === "GET") {
          response = json(await getProfile(db, session.accountId));
        }

        if (url.pathname === "/v1/profile" && req.method === "PUT") {
          const result = await updateProfile(db, session.accountId, session.deviceId, body);
          pushHints(sockets, result.pushes);
          response = json(result.profile);
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
            afterMsgId: body.afterMsgId,
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
          : err instanceof CallError ? err.status
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
        if (err instanceof MediaError && err.retryAfter) headers["retry-after"] = String(err.retryAfter);
        if (err instanceof CallError && err.retryAfter) headers["retry-after"] = String(err.retryAfter);
        if (status === 401) headers["www-authenticate"] = "Bearer";
        response = json({
          error: message,
          ...(err instanceof MediaError ? { code: err.code } : {}),
          ...(err instanceof CallError ? { code: err.code, ...err.details } : {}),
        }, status, headers);
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
    stopCallCleanupWorker();
    stopSyncNotifications();
    stopCallNotifications();
    return originalStop(closeActiveConnections);
  }) as typeof server.stop;

  console.log(JSON.stringify({ ts: new Date().toISOString(), event: "cloud.listening", port: server.port }));
  return server;
}

if (import.meta.main) startCloudServer();
