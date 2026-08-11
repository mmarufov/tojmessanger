import type { ServerWebSocket } from "bun";
import { sql as defaultSql } from "./db";
import {
  startVerification,
  checkVerification,
  resolveDevice,
  lookupAccountByPhone,
  lookupAccountByUsername,
  getProfile,
  updateProfile,
  otpDeliveryFromEnvironment,
  listDevices,
  startAccountDeletion,
  privateBetaOTPConfigured,
  requireActiveDevice,
  AuthError,
  type OTPDelivery,
} from "./auth";
import {
  APNsClient,
  PushError,
  registerGroupCallCapabilities,
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
  sendMediaGroup,
  editMessage,
  deleteMessage,
  setReaction,
  startBootstrap,
  startSyncNotificationListener,
  SyncError,
  type Push,
} from "./sync";
import { DraftError, getDraft, putDraft } from "./drafts";
import {
  dialogPreferenceBacklogMetrics,
  groupCallBacklogMetrics,
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
import {
  addGroupMembers,
  changeGroupMemberRole,
  createGroup,
  getGroup,
  getGroupMembers,
  GroupError,
  leaveGroup,
  removeGroupMember,
  transferGroupOwner,
  updateGroupNotifications,
  updateGroupPermissions,
  updateGroupProfile,
} from "./groups";
import { DialogAccessError } from "./dialog-access";
import {
  profilePhotosSchemaReadiness,
  ProfilePhotoError,
  updateProfilePhoto,
} from "./profile-photos";
import {
  ensureSavedMessages,
  savedMessagesConfigured,
  savedMessagesEnabledForAccount,
  savedMessagesSchemaReadiness,
  SavedMessagesError,
} from "./saved-messages";
import {
  dialogPreferencesCapabilityEnabled,
  DialogPreferenceError,
  updateDialogPreferences,
} from "./dialog-preferences";
import { dialogPreferenceBehaviorAvailable } from "./dialog-preference-readiness";
import { draftMediaSchemaState } from "./draft-media-readiness";
import {
  acquireGroupCamera,
  acquireGroupScreenShare,
  activateGroupCallEpoch,
  endGroupCall,
  getActiveGroupCall,
  getGroupCall,
  getGroupCallCredentials,
  groupCallSchemaReadiness,
  groupCallSFUControlConfigured,
  groupCallsConfigured,
  groupCallsEnabledForAccount,
  groupScreenSharingConfigured,
  GroupCallError,
  heartbeatGroupCall,
  heartbeatGroupCamera,
  heartbeatGroupScreenShare,
  joinGroupCall,
  leaveGroupCall,
  releaseGroupCamera,
  releaseGroupScreenShare,
  removeGroupCallParticipant,
  resolveGroupCallHintTargets,
  startGroupCall,
  startGroupCallCleanupWorker,
  startGroupCallNotificationListener,
  startGroupCallSFUWorker,
  type GroupCallHint,
  type GroupCallSFUControl,
} from "./group-calls";
import {
  ChatFolderError,
  createChatFolder,
  deleteChatFolder,
  getChatFolders,
  moveChatFolder,
  updateChatFolder,
} from "./chat-folders";
import {
  ScheduledDeliveryError,
  cancelScheduledDelivery,
  completedScheduledMutationExists,
  createScheduledDelivery,
  getScheduledDelivery,
  listScheduledDeliveries,
  startScheduledDeliveryWorker,
  updateScheduledDelivery,
} from "./scheduled-deliveries";
import {
  LinkPreviewError,
  downloadLinkPreviewAsset,
  startLinkPreviewWorker,
} from "./link-previews";
import {
  chatFoldersEnabledForAccount,
  cloudProductivitySchemaState,
  linkPreviewsEnabledForAccount,
  scheduledDeliveryEnabledForAccount,
  workerHeartbeatFresh,
} from "./cloud-productivity-readiness";
import {
  heartbeatPresence,
  PresenceError,
  presenceConfigured,
  presenceEnabledForAccount,
  presenceMetrics,
  presenceSchemaReadiness,
  publishPresenceVisibility,
  publishTyping,
  queryPresence,
  recordPresenceRejectedFrame,
  nextPresenceConnectionEpoch,
  setPresenceActivity,
  startPresenceCleanupWorker,
  startPresenceNotificationListener,
  type PresenceBroadcast,
  validPresenceDialogId,
} from "./presence";

type SocketData = {
  accountId: string;
  deviceId: string;
  connectionId: string;
  presenceEpoch: string | null;
  presenceActive: boolean;
  typingDialogs: Set<string>;
  lastTypingAt: Map<string, number>;
  activityDepth: number;
  activityQueue: Promise<void>;
};
type Db = typeof defaultSql;

export type CloudServerOptions = {
  /** Deterministic integration tests can disable all polling/listener side effects. */
  backgroundWorkers?: boolean;
  groupCallSFUControl?: GroupCallSFUControl;
  /** Test-only override for the credential reconciliation cadence. */
  socketAuthorizationIntervalMs?: number;
};

const jsonHeaders = { "content-type": "application/json", "cache-control": "no-store" };
const MAX_JSON_BYTES = 64 * 1024;

export const CLOUD_CAPABILITIES = {
  api_version: 5,
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

function cloudCapabilities(
  voiceCalls: boolean,
  videoCalls: boolean,
  groups: boolean,
  savedMessages: boolean,
  cloudDrafts: boolean,
  mediaGroups: boolean,
  dialogPreferences: boolean,
  groupCalls: boolean,
  groupScreenSharing: boolean,
  chatFolders: boolean,
  scheduledDelivery: boolean,
  linkPreviews: boolean,
  profilePhotos: boolean,
  presence: boolean,
) {
  const capabilities = [...CLOUD_CAPABILITIES.capabilities];
  if (voiceCalls) capabilities.push("voice_calls_v1");
  if (videoCalls) capabilities.push("video_calls_v1");
  if (groups) capabilities.push("groups_v1");
  if (savedMessages) capabilities.push("saved_messages_v1");
  if (cloudDrafts) capabilities.push("cloud_drafts_v1");
  if (mediaGroups) capabilities.push("media_groups_v1");
  if (dialogPreferences) capabilities.push("dialog_preferences_v1");
  if (groupCalls) capabilities.push("group_calls_v1", "group_video_calls_v1");
  if (groupScreenSharing) capabilities.push("screen_sharing_v1");
  if (chatFolders) capabilities.push("chat_folders_v1");
  if (scheduledDelivery) capabilities.push("scheduled_delivery_v1");
  if (linkPreviews) capabilities.push("link_previews_v1");
  if (profilePhotos) capabilities.push("profile_photos_v1");
  if (presence) capabilities.push("presence_v1");
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

function pushGroupCallHints(
  sockets: Map<string, Set<ServerWebSocket<SocketData>>>,
  hints: GroupCallHint[],
) {
  for (const hint of hints) {
    const payload = JSON.stringify({
      type: "group_call_hint",
      callId: hint.callId,
      stateRevision: hint.stateRevision,
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
    if (socket.data.deviceId !== deviceId) continue;
    if (socket.readyState === 1) {
      socket.send(JSON.stringify({
        type: "session_revoked", deviceId, reason: "device_revoked",
      }));
    }
    socket.close(4001, "device revoked");
  }
}

function disconnectAccount(
  sockets: Map<string, Set<ServerWebSocket<SocketData>>>,
  accountId: string,
) {
  for (const socket of sockets.get(accountId) ?? []) {
    if (socket.readyState === 1) {
      socket.send(JSON.stringify({
        type: "session_revoked", deviceId: null, reason: "account_deleted",
      }));
    }
    socket.close(4002, "account deleted");
  }
  sockets.delete(accountId);
}

function pushPresenceBroadcasts(
  sockets: Map<string, Set<ServerWebSocket<SocketData>>>,
  broadcasts: PresenceBroadcast[],
) {
  for (const broadcast of broadcasts) {
    const payload = JSON.stringify(broadcast.event);
    for (const accountId of broadcast.recipientAccountIds) {
      for (const ws of sockets.get(accountId) ?? []) {
        if (broadcast.event.type === "session_revoked") {
          if (broadcast.event.deviceId == null
            || ws.data.deviceId === broadcast.event.deviceId) {
            if (ws.readyState === 1) ws.send(payload);
            ws.close(
              broadcast.event.deviceId == null ? 4002 : 4001,
              broadcast.event.deviceId == null ? "account deleted" : "device revoked",
            );
          }
        } else if (ws.readyState === 1) {
          ws.send(payload);
        }
      }
    }
  }
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
  options: CloudServerOptions = {},
) {
  const sockets = new Map<string, Set<ServerWebSocket<SocketData>>>();
  const presenceSocketCleanupTasks = new Set<Promise<void>>();
  const recentPresenceDeliveries = new Map<string, number>();
  const deliverPresenceBroadcasts = (broadcasts: PresenceBroadcast[]) => {
    const now = Date.now();
    const unique: PresenceBroadcast[] = [];
    for (const broadcast of broadcasts) {
      const recipientAccountIds = broadcast.recipientAccountIds.filter((accountId) => {
        // Mixed-version notifications may not carry a publication ID. They have no matching local
        // direct delivery on this new node, so pass them through without semantic coalescing.
        if (!broadcast.deliveryId) return true;
        const key = `${accountId}\0${broadcast.deliveryId}`;
        const previous = recentPresenceDeliveries.get(key) ?? 0;
        if (now - previous <= 5_000) return false;
        // Refresh insertion order so the first entry remains the least-recently delivered key.
        recentPresenceDeliveries.delete(key);
        recentPresenceDeliveries.set(key, now);
        if (recentPresenceDeliveries.size > 2_048) {
          const oldest = recentPresenceDeliveries.keys().next().value;
          if (oldest !== undefined) recentPresenceDeliveries.delete(oldest);
        }
        return true;
      });
      if (recipientAccountIds.length > 0) {
        unique.push({ ...broadcast, recipientAccountIds });
      }
    }
    if (unique.length > 0) pushPresenceBroadcasts(sockets, unique);
  };
  const metrics = new OperationalMetrics();
  const requireScheduledWorkerOrReplay = async (
    accountId: string,
    body: any,
    operation: "create" | "update" | "reschedule",
    workerHealthy: boolean,
  ) => {
    if (workerHealthy) return;
    const acceptedReplay = typeof body.clientMutationId === "string"
      && await completedScheduledMutationExists(
        db, accountId, body.clientMutationId, operation,
      );
    if (acceptedReplay) return;
    metrics.recordScheduledWorkerUnavailable();
    throw new ScheduledDeliveryError(
      "scheduled delivery worker is unavailable",
      "scheduled_worker_unavailable",
      503,
      15,
    );
  };
  const callsAvailable = voiceCallsConfigured(pushSender !== null);
  const videoAvailable = videoCallsConfigured(callsAvailable);
  const groupsAvailable = process.env.TOJ_GROUPS_V1_ENABLED === "1";
  const groupCallInfrastructureAvailable = groupCallsConfigured(groupsAvailable);
  const cloudDraftsAvailable = process.env.TOJ_CLOUD_DRAFTS_V1_ENABLED === "1";
  const mediaGroupsAvailable = process.env.TOJ_MEDIA_GROUPS_V1_ENABLED === "1";
  const dialogPreferencesConfigured = dialogPreferencesCapabilityEnabled();
  const productivityWorkersEnabled = process.env.TOJ_PRODUCTIVITY_WORKERS_DISABLED !== "1";
  const profilePhotosConfigured = process.env.TOJ_PROFILE_PHOTOS_V1_ENABLED === "1";
  let profilePhotosSchemaCache: { ready: boolean; expiresAt: number } | null = null;
  let profilePhotosSchemaProbe: Promise<boolean> | null = null;
  const profilePhotosAvailable = async (): Promise<boolean> => {
    if (!profilePhotosConfigured) return false;
    const now = Date.now();
    if (profilePhotosSchemaCache && profilePhotosSchemaCache.expiresAt > now) {
      return profilePhotosSchemaCache.ready;
    }
    if (!profilePhotosSchemaProbe) {
      profilePhotosSchemaProbe = profilePhotosSchemaReadiness(db)
        .then((state) => {
          profilePhotosSchemaCache = {
            ready: state.ready,
            expiresAt: Date.now() + (state.ready ? 60_000 : 2_000),
          };
          return state.ready;
        })
        .catch(() => {
          profilePhotosSchemaCache = { ready: false, expiresAt: Date.now() + 2_000 };
          return false;
        })
        .finally(() => { profilePhotosSchemaProbe = null; });
    }
    return await profilePhotosSchemaProbe;
  };
  const draftMediaAvailability = async () => {
    const schema = await draftMediaSchemaState(db);
    return {
      cloudDrafts: cloudDraftsAvailable && schema.ready,
      mediaGroups: mediaGroupsAvailable && schema.ready,
    };
  };
  const backgroundWorkers = options.backgroundWorkers !== false;
  let socketAuthorizationRunning = false;
  const auditSocketAuthorizations = async () => {
    if (socketAuthorizationRunning || sockets.size === 0) return;
    socketAuthorizationRunning = true;
    try {
      const deviceIds = [...new Set(
        [...sockets.values()].flatMap((set) => [...set].map((socket) => socket.data.deviceId)),
      )];
      if (deviceIds.length === 0) return;
      const activeRows = await db`
        SELECT device.id, device.account_id
        FROM devices AS device
        JOIN accounts AS account ON account.id = device.account_id
        WHERE device.id = ANY(${db.array(deviceIds, "uuid")}::uuid[])
          AND device.revoked_at IS NULL
          AND account.status IN ('active','limited')`;
      const active = new Set(activeRows.map((row) => `${row.account_id}\0${row.id}`));
      for (const [accountId, accountSockets] of sockets) {
        for (const socket of accountSockets) {
          if (active.has(`${accountId}\0${socket.data.deviceId}`)) continue;
          if (socket.readyState === 1) {
            socket.send(JSON.stringify({
              type: "session_revoked",
              deviceId: socket.data.deviceId,
              reason: "device_revoked",
            }));
          }
          socket.close(4001, "device revoked");
        }
      }
    } catch (error) {
      console.error(JSON.stringify({
        ts: new Date().toISOString(),
        event: "cloud.ws_authorization_audit_error",
        errorType: error instanceof Error ? error.name : "UnknownError",
      }));
    } finally {
      socketAuthorizationRunning = false;
    }
  };
  const socketAuthorizationInterval = backgroundWorkers
    ? setInterval(
        () => { void auditSocketAuthorizations(); },
        Math.max(250, options.socketAuthorizationIntervalMs ?? 5_000),
      )
    : null;
  socketAuthorizationInterval?.unref?.();
  const stopPushWorker = backgroundWorkers ? startPushWorker(db, pushSender) : () => {};
  const stopMaintenanceWorker = backgroundWorkers
    ? startMaintenanceWorker(db, undefined, metrics) : () => {};
  const stopCallCleanupWorker = backgroundWorkers ? startCallCleanupWorker(db) : () => {};
  const stopGroupCallCleanupWorker = backgroundWorkers
    ? startGroupCallCleanupWorker(db) : () => {};
  const stopGroupCallSFUWorker = backgroundWorkers && groupCallSFUControlConfigured()
    ? startGroupCallSFUWorker(db, 2_000, options.groupCallSFUControl)
    : () => {};
  const stopScheduledDeliveryWorker = backgroundWorkers && productivityWorkersEnabled
    ? startScheduledDeliveryWorker(db)
    : () => {};
  const stopLinkPreviewWorker = backgroundWorkers && productivityWorkersEnabled
    ? startLinkPreviewWorker(db)
    : () => {};
  const stopSyncNotifications = backgroundWorkers ? startSyncNotificationListener(
    process.env.TOJ_CALL_NOTIFY_DATABASE_URL ?? process.env.DATABASE_URL ?? null,
    (wakeup) => pushHints(sockets, [wakeup]),
  ) : () => {};
  const stopCallNotifications = backgroundWorkers ? startCallNotificationListener(
    process.env.TOJ_CALL_NOTIFY_DATABASE_URL ?? process.env.DATABASE_URL ?? null,
    async (wakeup) => {
      const localDeviceIds = [...sockets.values()]
        .flatMap((set) => [...set].map((socket) => socket.data.deviceId));
      const hints = await resolveCallHintTargets(db, wakeup, [...new Set(localDeviceIds)]);
      pushCallHints(sockets, hints);
    },
  ) : () => {};
  const stopGroupCallNotifications = backgroundWorkers ? startGroupCallNotificationListener(
    process.env.TOJ_CALL_NOTIFY_DATABASE_URL ?? process.env.DATABASE_URL ?? null,
    async (wakeup) => {
      const localDeviceIds = [...sockets.values()]
        .flatMap((set) => [...set].map((socket) => socket.data.deviceId));
      const hints = await resolveGroupCallHintTargets(db, wakeup, [...new Set(localDeviceIds)]);
      pushGroupCallHints(sockets, hints);
    },
  ) : () => {};
  const presenceDatabaseURL = process.env.TOJ_CALL_NOTIFY_DATABASE_URL
    ?? process.env.DATABASE_URL ?? null;
  // The same channel carries credential-revocation control frames, which must stay active even
  // while the presence feature is dark or its schema has not reached this node yet.
  const stopPresenceNotifications = backgroundWorkers ? startPresenceNotificationListener(
    presenceDatabaseURL,
    (broadcast) => deliverPresenceBroadcasts([broadcast]),
  ) : () => {};
  const stopPresenceCleanup = backgroundWorkers && presenceConfigured() ? startPresenceCleanupWorker(
    db,
    deliverPresenceBroadcasts,
  ) : () => {};

  let realtimePresenceSchemaCache: { ready: boolean; expiresAt: number } | null = null;
  let realtimePresenceSchemaProbe: Promise<boolean> | null = null;
  const realtimePresenceSchemaReady = async (): Promise<boolean> => {
    const now = Date.now();
    if (realtimePresenceSchemaCache && realtimePresenceSchemaCache.expiresAt > now) {
      return realtimePresenceSchemaCache.ready;
    }
    if (!realtimePresenceSchemaProbe) {
      realtimePresenceSchemaProbe = presenceSchemaReadiness(db)
        .then((state) => {
          realtimePresenceSchemaCache = {
            ready: state.ready,
            expiresAt: Date.now() + (state.ready ? 60_000 : 2_000),
          };
          return state.ready;
        })
        .catch(() => {
          realtimePresenceSchemaCache = { ready: false, expiresAt: Date.now() + 2_000 };
          return false;
        })
        .finally(() => { realtimePresenceSchemaProbe = null; });
    }
    return await realtimePresenceSchemaProbe;
  };

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
          const state = await readiness(db, {
            sms: otpDelivery ? "configured" : privateBetaOTPConfigured() ? "development" : "disabled",
            push: pushSender ? "configured" : "disabled",
          });
          response = json(state, state.status === "ready" ? 200 : 503);
        }

        else if (url.pathname === "/v1/capabilities" && req.method === "GET") {
          const capabilityToken = bearer(req);
          const capabilitySession = capabilityToken ? await resolveDevice(db, capabilityToken) : null;
          const accountVideoAvailable = capabilitySession
            ? videoCallsEnabledForAccount(capabilitySession.accountId, videoAvailable)
            : false;
          const accountSavedMessagesAvailable = capabilitySession
            ? (await savedMessagesSchemaReadiness(db)).ready
              && savedMessagesEnabledForAccount(capabilitySession.accountId)
            : false;
          const groupCallSchema = await groupCallSchemaReadiness(db);
          const presenceSchema = await presenceSchemaReadiness(db);
          const groupCallDevice = capabilitySession != null && groupCallSchema.ready
            ? (await db`
                SELECT supports_group_screen_share
                FROM devices
                WHERE id = ${capabilitySession.deviceId}
                  AND account_id = ${capabilitySession.accountId}
                  AND revoked_at IS NULL
                  AND 1 = ANY(supported_group_call_versions)
                  AND group_call_view_version >= 1`)[0]
            : null;
          const accountGroupCallsAvailable = capabilitySession != null
            && groupCallSchema.ready
            && groupCallDevice != null
            && groupCallsEnabledForAccount(
              capabilitySession.accountId,
              groupCallInfrastructureAvailable,
            );
          const draftMedia = await draftMediaAvailability();
          const productivitySchema = await cloudProductivitySchemaState(db);
          const chatFolders = Boolean(capabilitySession)
            && productivitySchema.ready
            && chatFoldersEnabledForAccount(capabilitySession!.accountId);
          const scheduledDelivery = Boolean(capabilitySession)
            && productivitySchema.ready
            && scheduledDeliveryEnabledForAccount(capabilitySession!.accountId);
          const linkPreviews = Boolean(capabilitySession)
            && productivitySchema.ready
            && linkPreviewsEnabledForAccount(capabilitySession!.accountId)
            && await workerHeartbeatFresh(db, "link_preview");
          response = json(cloudCapabilities(
            callsAvailable,
            accountVideoAvailable,
            groupsAvailable,
            accountSavedMessagesAvailable,
            draftMedia.cloudDrafts,
            draftMedia.mediaGroups,
            dialogPreferencesConfigured && await dialogPreferenceBehaviorAvailable(db),
            accountGroupCallsAvailable,
            accountGroupCallsAvailable
              && Boolean(groupCallDevice?.supports_group_screen_share)
              && groupScreenSharingConfigured(groupCallInfrastructureAvailable),
            chatFolders,
            scheduledDelivery,
            linkPreviews,
            await profilePhotosAvailable(),
            capabilitySession != null
              && presenceSchema.ready
              && presenceEnabledForAccount(capabilitySession.accountId),
          ));
        }

        else if (url.pathname === "/metrics") {
          const metricsToken = process.env.TOJ_METRICS_TOKEN;
          if (!metricsToken) response = new Response("not found", { status: 404 });
          else if (bearer(req) !== metricsToken) response = new Response("unauthorized", { status: 401 });
          else response = new Response(
            metrics.render()
              + await dialogPreferenceBacklogMetrics(db)
              + await groupCallBacklogMetrics(db)
              + await presenceMetrics(db),
            { headers: { "content-type": "text/plain; version=0.0.4" } },
          );
        }

        else if (url.pathname === "/v1/ws") {
          const legacyQueryToken = process.env.TOJ_ALLOW_LEGACY_WS_QUERY_TOKEN === "1"
            ? url.searchParams.get("token")
            : null;
          const token = bearer(req) ?? legacyQueryToken;
          if (!token) response = new Response("token required", { status: 401 });
          else {
          const dev = await resolveDevice(db, token);
          if (server.upgrade(req, { data: {
            ...dev,
            connectionId: crypto.randomUUID(),
            presenceEpoch: null,
            presenceActive: false,
            typingDialogs: new Set<string>(),
            lastTypingAt: new Map<string, number>(),
            activityDepth: 0,
            activityQueue: Promise.resolve(),
          } })) response = undefined;
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

        else if (
          (url.pathname === "/v1/groups" || url.pathname.startsWith("/v1/groups/"))
          && !groupsAvailable
        ) {
          // Hard-close the complete route family during dark deploys. Advertisement alone is not
          // sufficient because stale or modified clients could otherwise create live group events.
          response = new Response("not found", { status: 404 });
        }

        else if (
          (url.pathname === "/v1/group-calls" || url.pathname.startsWith("/v1/group-calls/"))
          && (
            !groupCallInfrastructureAvailable
            || !(await groupCallSchemaReadiness(db)).ready
          )
        ) {
          // Hide the complete control plane until the SFU, mandatory frame E2EE, base groups,
          // and additive schema are all ready. This is also the zero-risk rollback path.
          response = new Response("not found", { status: 404 });
        }

        else if (
          url.pathname === "/v1/dialogs/saved"
          && req.method === "POST"
          && (
            !savedMessagesConfigured()
            || !(await savedMessagesSchemaReadiness(db)).ready
          )
        ) {
          response = new Response("not found", { status: 404 });
        }

        else if (
          /^\/v1\/dialogs\/[0-9a-f-]+\/preferences$/i.test(url.pathname)
          && (
            !dialogPreferencesConfigured
            || !await dialogPreferenceBehaviorAvailable(db)
          )
        ) {
          response = json({
            error: "dialog preferences capability unavailable",
            code: "capability_unavailable",
          }, 404);
        }

        else if (
          url.pathname === "/v1/profile/photo"
          && req.method === "PUT"
          && !await profilePhotosAvailable()
        ) {
          response = json({
            error: "profile photos capability unavailable",
            code: "capability_unavailable",
          }, 404);
        }

        else {
          const session = await authed(db, req);
          const groupCallsAvailableForSession = groupCallsEnabledForAccount(
            session.accountId,
            groupCallInfrastructureAvailable,
          );
          const uploadChunkMatch = url.pathname.match(/^\/v1\/media\/uploads\/([0-9a-f-]+)\/chunks$/i);
          const uploadPartMatch = url.pathname.match(/^\/v1\/media\/uploads\/([0-9a-f-]+)\/parts\/(\d+)$/i);
          const uploadThumbnailMatch = url.pathname.match(/^\/v1\/media\/uploads\/([0-9a-f-]+)\/thumbnail$/i);
          const downloadChunkMatch = url.pathname.match(/^\/v1\/media\/([0-9a-f-]+)\/chunks$/i);
          const downloadThumbnailMatch = url.pathname.match(/^\/v1\/media\/([0-9a-f-]+)\/thumbnail$/i);
          const previewAssetMatch = url.pathname.match(/^\/v1\/link-previews\/assets\/([0-9a-f-]+)$/i);
          const productivitySchema = await cloudProductivitySchemaState(db);
          const chatFoldersAvailable = productivitySchema.ready
            && chatFoldersEnabledForAccount(session.accountId);
          const scheduledDeliveryAvailable = productivitySchema.ready
            && scheduledDeliveryEnabledForAccount(session.accountId);
          const scheduledDeliveryWorkerHealthy = scheduledDeliveryAvailable
            && await workerHeartbeatFresh(db, "scheduled_delivery");
          const linkPreviewsAvailable = productivitySchema.ready
            && linkPreviewsEnabledForAccount(session.accountId)
            && await workerHeartbeatFresh(db, "link_preview");

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
          } else if (previewAssetMatch && req.method === "GET" && linkPreviewsAvailable) {
            const result = await downloadLinkPreviewAsset(db, session.accountId, previewAssetMatch[1]);
            response = new Response(result.bytes, {
              headers: {
                "content-type": result.contentType,
                "content-length": String(result.bytes.length),
                "cache-control": "private, max-age=86400",
              },
            });
          } else {
          const body = await readJson(
            req,
            url.pathname === "/v1/scheduled-messages"
              || url.pathname.startsWith("/v1/scheduled-messages/")
              ? 256 * 1024
              : /^\/v1\/calls\/[0-9a-f-]+\/events$/i.test(url.pathname)
                ? 96 * 1024
                : /^\/v1\/group-calls\/[0-9a-f-]+\/epochs$/i.test(url.pathname)
                  ? 160 * 1024
                  : MAX_JSON_BYTES,
          );
          const callActionMatch = url.pathname.match(
            /^\/v1\/calls\/([0-9a-f-]+)\/(accept|reveal|confirm|decline|cancel|end|events|ice-config|telemetry)$/i,
          );
          const callMatch = url.pathname.match(/^\/v1\/calls\/([0-9a-f-]+)$/i);
          const blockMatch = url.pathname.match(/^\/v1\/blocks\/([0-9a-f-]+)$/i);
          const groupMemberMatch = url.pathname.match(
            /^\/v1\/groups\/([0-9a-f-]+)\/members\/([0-9a-f-]+)$/i,
          );
          const groupMembersMatch = url.pathname.match(/^\/v1\/groups\/([0-9a-f-]+)\/members$/i);
          const groupTransferMatch = url.pathname.match(/^\/v1\/groups\/([0-9a-f-]+)\/transfer-owner$/i);
          const groupLeaveMatch = url.pathname.match(/^\/v1\/groups\/([0-9a-f-]+)\/leave$/i);
          const groupNotificationsMatch = url.pathname.match(/^\/v1\/groups\/([0-9a-f-]+)\/notifications$/i);
          const groupPermissionsMatch = url.pathname.match(/^\/v1\/groups\/([0-9a-f-]+)\/permissions$/i);
          const groupMatch = url.pathname.match(/^\/v1\/groups\/([0-9a-f-]+)$/i);
          const groupCallMatch = url.pathname.match(/^\/v1\/group-calls\/([0-9a-f-]+)$/i);
          const groupCallActionMatch = url.pathname.match(
            /^\/v1\/group-calls\/([0-9a-f-]+)\/(join|leave|end|heartbeat|credentials|epochs|camera|screen-share)$/i,
          );
          const groupCallCameraHeartbeatMatch = url.pathname.match(
            /^\/v1\/group-calls\/([0-9a-f-]+)\/camera\/heartbeat$/i,
          );
          const groupCallScreenHeartbeatMatch = url.pathname.match(
            /^\/v1\/group-calls\/([0-9a-f-]+)\/screen-share\/heartbeat$/i,
          );
          const groupCallCameraReleaseMatch = url.pathname.match(
            /^\/v1\/group-calls\/([0-9a-f-]+)\/camera\/release$/i,
          );
          const groupCallScreenReleaseMatch = url.pathname.match(
            /^\/v1\/group-calls\/([0-9a-f-]+)\/screen-share\/release$/i,
          );
          const groupCallParticipantMatch = url.pathname.match(
            /^\/v1\/group-calls\/([0-9a-f-]+)\/participants\/([0-9a-f-]+)$/i,
          );
          const dialogPreferencesMatch = url.pathname.match(
            /^\/v1\/dialogs\/([0-9a-f-]+)\/preferences$/i,
          );
          const folderMatch = url.pathname.match(/^\/v1\/chat-folders\/([0-9a-f-]+)$/i);
          const folderMoveMatch = url.pathname.match(/^\/v1\/chat-folders\/([0-9a-f-]+)\/move$/i);
          const scheduleMatch = url.pathname.match(/^\/v1\/scheduled-messages\/([0-9a-f-]+)$/i);
          const scheduleRescheduleMatch = url.pathname.match(
            /^\/v1\/scheduled-messages\/([0-9a-f-]+)\/reschedule$/i,
          );

        if (
          (url.pathname === "/v1/chat-folders" || url.pathname.startsWith("/v1/chat-folders/"))
          && !chatFoldersAvailable
        ) response = new Response("not found", { status: 404 });

        if (
          (url.pathname === "/v1/scheduled-messages" || url.pathname.startsWith("/v1/scheduled-messages/"))
          && !scheduledDeliveryAvailable
        ) response = new Response("not found", { status: 404 });

        if (url.pathname === "/v1/chat-folders" && req.method === "GET" && chatFoldersAvailable) {
          response = json(await getChatFolders(db, session.accountId));
        }
        if (url.pathname === "/v1/chat-folders" && req.method === "POST" && chatFoldersAvailable) {
          const result = await createChatFolder(db, {
            accountId: session.accountId, deviceId: session.deviceId, body,
          });
          response = json(result, result.duplicate ? 200 : 201);
        }
        if (folderMatch && req.method === "PATCH" && chatFoldersAvailable) {
          response = json(await updateChatFolder(db, {
            accountId: session.accountId, deviceId: session.deviceId,
            folderId: folderMatch[1], body,
          }));
        }
        if (folderMoveMatch && req.method === "POST" && chatFoldersAvailable) {
          response = json(await moveChatFolder(db, {
            accountId: session.accountId, deviceId: session.deviceId,
            folderId: folderMoveMatch[1], body,
          }));
        }
        if (folderMatch && req.method === "DELETE" && chatFoldersAvailable) {
          response = json(await deleteChatFolder(db, {
            accountId: session.accountId, deviceId: session.deviceId,
            folderId: folderMatch[1], body,
          }));
        }

        if (url.pathname === "/v1/scheduled-messages" && req.method === "GET" && scheduledDeliveryAvailable) {
          response = json(await listScheduledDeliveries(db, session.accountId, {
            dialogId: url.searchParams.get("dialogId"),
            cursor: url.searchParams.get("cursor"),
            limit: Number(url.searchParams.get("limit") ?? 50),
          }));
        }
        if (url.pathname === "/v1/scheduled-messages" && req.method === "POST" && scheduledDeliveryAvailable) {
          await requireScheduledWorkerOrReplay(
            session.accountId, body, "create", scheduledDeliveryWorkerHealthy,
          );
          const result = await createScheduledDelivery(db, {
            accountId: session.accountId, deviceId: session.deviceId, body,
          });
          response = json(result, result.duplicate ? 200 : 201);
        }
        if (scheduleMatch && req.method === "GET" && scheduledDeliveryAvailable) {
          const result = await getScheduledDelivery(db, session.accountId, scheduleMatch[1]);
          response = result ? json({ scheduledDelivery: result }) : new Response("not found", { status: 404 });
        }
        if (scheduleMatch && req.method === "PATCH" && scheduledDeliveryAvailable) {
          await requireScheduledWorkerOrReplay(
            session.accountId, body, "update", scheduledDeliveryWorkerHealthy,
          );
          response = json(await updateScheduledDelivery(db, {
            accountId: session.accountId, deviceId: session.deviceId,
            deliveryId: scheduleMatch[1], body,
          }));
        }
        if (scheduleRescheduleMatch && req.method === "POST" && scheduledDeliveryAvailable) {
          await requireScheduledWorkerOrReplay(
            session.accountId, body, "reschedule", scheduledDeliveryWorkerHealthy,
          );
          response = json(await updateScheduledDelivery(db, {
            accountId: session.accountId, deviceId: session.deviceId,
            deliveryId: scheduleRescheduleMatch[1], body, operation: "reschedule",
          }));
        }
        if (scheduleMatch && req.method === "DELETE" && scheduledDeliveryAvailable) {
          const result = await cancelScheduledDelivery(db, {
            accountId: session.accountId, deviceId: session.deviceId,
            deliveryId: scheduleMatch[1], body,
          });
          if (!scheduledDeliveryWorkerHealthy) {
            metrics.recordScheduledCancellationDuringOutage();
          }
          response = json(result);
        }

        if (url.pathname === "/v1/presence/query" && req.method === "POST") {
          response = json(await queryPresence(db, session.accountId, body.accountIds));
        }

        if (url.pathname === "/v1/groups" && req.method === "POST") {
          const result = await createGroup(db, {
            creatorAccountId: session.accountId,
            creatorDeviceId: session.deviceId,
            groupId: body.groupId,
            title: body.title,
            memberIds: body.memberIds,
          });
          pushHints(sockets, result.pushes ?? []);
          response = json({
            group: result.group,
            members: result.members,
            profiles: result.profiles,
            duplicate: result.duplicate,
          }, result.duplicate ? 200 : 201);
        }

        if (groupMatch && req.method === "GET") {
          response = json(await getGroup(db, session.accountId, groupMatch[1]));
        }

        if (groupMembersMatch && req.method === "GET") {
          response = json(await getGroupMembers(db, session.accountId, groupMembersMatch[1], {
            cursor: url.searchParams.get("cursor"),
            limit: url.searchParams.get("limit"),
          }));
        }

        if (groupMembersMatch && req.method === "POST") {
          const result = await addGroupMembers(db, {
            actorAccountId: session.accountId,
            actorDeviceId: session.deviceId,
            dialogId: groupMembersMatch[1],
            memberIds: body.memberIds,
            clientMutationId: body.clientMutationId,
          });
          pushHints(sockets, result.pushes ?? []);
          response = json(result);
        }

        if (groupMemberMatch && req.method === "DELETE") {
          const result = await removeGroupMember(db, {
            actorAccountId: session.accountId,
            actorDeviceId: session.deviceId,
            dialogId: groupMemberMatch[1],
            targetAccountId: groupMemberMatch[2],
            clientMutationId: body.clientMutationId,
          }, options.groupCallSFUControl);
          pushHints(sockets, result.pushes ?? []);
          response = json(result);
        }

        if (groupMemberMatch && req.method === "PATCH") {
          const result = await changeGroupMemberRole(db, {
            actorAccountId: session.accountId,
            actorDeviceId: session.deviceId,
            dialogId: groupMemberMatch[1],
            targetAccountId: groupMemberMatch[2],
            role: body.role,
            clientMutationId: body.clientMutationId,
          });
          pushHints(sockets, result.pushes ?? []);
          response = json(result);
        }

        if (groupMatch && req.method === "PATCH") {
          const result = await updateGroupProfile(db, {
            actorAccountId: session.accountId,
            actorDeviceId: session.deviceId,
            dialogId: groupMatch[1],
            title: body.title,
            photoMediaId: body.photoMediaId,
            clearPhoto: body.clearPhoto,
            clientMutationId: body.clientMutationId,
          });
          pushHints(sockets, result.pushes ?? []);
          response = json(result);
        }

        if (groupPermissionsMatch && req.method === "PUT") {
          const result = await updateGroupPermissions(db, {
            actorAccountId: session.accountId,
            actorDeviceId: session.deviceId,
            dialogId: groupPermissionsMatch[1],
            membersCanSend: body.membersCanSend,
            membersCanAddMembers: body.membersCanAddMembers,
            membersCanEditInfo: body.membersCanEditInfo,
            clientMutationId: body.clientMutationId,
          });
          pushHints(sockets, result.pushes ?? []);
          response = json(result);
        }

        if (groupTransferMatch && req.method === "POST") {
          const result = await transferGroupOwner(db, {
            actorAccountId: session.accountId,
            actorDeviceId: session.deviceId,
            dialogId: groupTransferMatch[1],
            targetAccountId: body.accountId,
            clientMutationId: body.clientMutationId,
          });
          pushHints(sockets, result.pushes ?? []);
          response = json(result);
        }

        if (groupLeaveMatch && req.method === "POST") {
          const result = await leaveGroup(db, {
            actorAccountId: session.accountId,
            actorDeviceId: session.deviceId,
            dialogId: groupLeaveMatch[1],
            successorAccountId: body.successorAccountId,
            clientMutationId: body.clientMutationId,
          }, options.groupCallSFUControl);
          pushHints(sockets, result.pushes);
          response = json({ left: result.left, closed: result.closed });
        }

        if (groupNotificationsMatch && req.method === "PUT") {
          const dialogPreferencesAvailable = dialogPreferencesConfigured
            && await dialogPreferenceBehaviorAvailable(db);
          const result = await updateGroupNotifications(db, {
            actorAccountId: session.accountId,
            actorDeviceId: session.deviceId,
            dialogId: groupNotificationsMatch[1],
            mode: body.mode,
            clientMutationId: body.clientMutationId,
            usePreferenceService: dialogPreferencesAvailable,
          });
          pushHints(sockets, result.pushes);
          response = json(result.envelope);
        }

        if (url.pathname === "/v1/group-calls" && req.method === "POST") {
          if (!groupCallsAvailableForSession) {
            throw new GroupCallError("group calls are unavailable", "capability_unavailable", 404);
          }
          const result = await startGroupCall(db, {
            accountId: session.accountId,
            deviceId: session.deviceId,
            callId: body.callId,
            dialogId: body.dialogId,
            initialKind: body.initialKind,
            joinPublicKey: body.joinPublicKey,
            joinNonce: body.joinNonce,
            epochKeyCommitment: body.epochKeyCommitment,
          }, options.groupCallSFUControl);
          pushGroupCallHints(sockets, result.hints);
          response = json({
            call: result.call,
            credentials: result.credentials,
            duplicate: result.duplicate,
          }, result.duplicate ? 200 : 201);
        }

        if (url.pathname === "/v1/group-calls/active" && req.method === "GET") {
          if (!groupCallsAvailableForSession) {
            throw new GroupCallError("group calls are unavailable", "capability_unavailable", 404);
          }
          response = json(await getActiveGroupCall(
            db,
            session.accountId,
            session.deviceId,
            url.searchParams.get("dialogId"),
          ));
        }

        if (groupCallMatch && req.method === "GET") {
          response = json(await getGroupCall(
            db, session.accountId, session.deviceId, groupCallMatch[1],
          ));
        }

        if (groupCallActionMatch?.[2] === "join" && req.method === "POST") {
          if (!groupCallsAvailableForSession) {
            throw new GroupCallError("group calls are unavailable", "capability_unavailable", 404);
          }
          const result = await joinGroupCall(db, {
            accountId: session.accountId,
            deviceId: session.deviceId,
            callId: groupCallActionMatch[1],
            joinPublicKey: body.joinPublicKey,
            joinNonce: body.joinNonce,
          }, options.groupCallSFUControl);
          pushGroupCallHints(sockets, result.hints);
          response = json({ call: result.call, duplicate: result.duplicate },
            result.duplicate ? 200 : 202);
        }

        if (groupCallActionMatch?.[2] === "epochs" && req.method === "POST") {
          const result = await activateGroupCallEpoch(db, {
            accountId: session.accountId,
            deviceId: session.deviceId,
            callId: groupCallActionMatch[1],
            epoch: body.epoch,
            expectedMembershipRevision: body.expectedMembershipRevision,
            keyCommitment: body.keyCommitment,
            participantSetHash: body.participantSetHash,
            envelopes: body.envelopes,
          }, options.groupCallSFUControl);
          pushGroupCallHints(sockets, result.hints);
          response = json({ call: result.call, duplicate: result.duplicate });
        }

        if (groupCallActionMatch?.[2] === "credentials" && req.method === "GET") {
          response = json(await getGroupCallCredentials(
            db, session.accountId, session.deviceId, groupCallActionMatch[1],
            options.groupCallSFUControl,
          ));
        }

        if (groupCallActionMatch?.[2] === "heartbeat" && req.method === "POST") {
          response = json(await heartbeatGroupCall(db, {
            accountId: session.accountId,
            deviceId: session.deviceId,
            callId: groupCallActionMatch[1],
          }));
        }

        if (groupCallActionMatch?.[2] === "leave" && req.method === "POST") {
          const result = await leaveGroupCall(db, {
            accountId: session.accountId,
            deviceId: session.deviceId,
            callId: groupCallActionMatch[1],
          }, options.groupCallSFUControl);
          pushGroupCallHints(sockets, result.hints);
          response = json({ call: result.call, duplicate: result.duplicate });
        }

        if (groupCallActionMatch?.[2] === "end" && req.method === "POST") {
          const result = await endGroupCall(db, {
            accountId: session.accountId,
            deviceId: session.deviceId,
            callId: groupCallActionMatch[1],
            reason: body.reason,
          }, options.groupCallSFUControl);
          pushGroupCallHints(sockets, result.hints);
          response = json({ call: result.call, duplicate: result.duplicate });
        }

        if (groupCallParticipantMatch && req.method === "DELETE") {
          const result = await removeGroupCallParticipant(db, {
            accountId: session.accountId,
            deviceId: session.deviceId,
            callId: groupCallParticipantMatch[1],
            targetDeviceId: groupCallParticipantMatch[2],
          }, options.groupCallSFUControl);
          pushGroupCallHints(sockets, result.hints);
          response = json({ call: result.call });
        }

        if (groupCallActionMatch?.[2] === "camera" && req.method === "POST") {
          const result = await acquireGroupCamera(db, {
            accountId: session.accountId,
            deviceId: session.deviceId,
            callId: groupCallActionMatch[1],
            generation: body.generation,
          }, options.groupCallSFUControl);
          pushGroupCallHints(sockets, result.hints);
          response = json({ generation: result.generation, expiresAt: result.expiresAt, call: result.call });
        }

        if (groupCallCameraHeartbeatMatch && req.method === "POST") {
          response = json(await heartbeatGroupCamera(db, {
            accountId: session.accountId,
            deviceId: session.deviceId,
            callId: groupCallCameraHeartbeatMatch[1],
            generation: body.generation,
          }));
        }

        if (groupCallCameraReleaseMatch && req.method === "POST") {
          const result = await releaseGroupCamera(db, {
            accountId: session.accountId,
            deviceId: session.deviceId,
            callId: groupCallCameraReleaseMatch[1],
            generation: body.generation,
          }, options.groupCallSFUControl);
          pushGroupCallHints(sockets, result.hints);
          response = json({ released: true });
        }

        if (groupCallActionMatch?.[2] === "screen-share" && req.method === "POST") {
          if (!groupCallsAvailableForSession) {
            throw new GroupCallError("group calls are unavailable", "capability_unavailable", 404);
          }
          const result = await acquireGroupScreenShare(db, {
            accountId: session.accountId,
            deviceId: session.deviceId,
            callId: groupCallActionMatch[1],
            generation: body.generation,
          }, options.groupCallSFUControl);
          pushGroupCallHints(sockets, result.hints);
          response = json({ generation: result.generation, expiresAt: result.expiresAt, call: result.call });
        }

        if (groupCallScreenHeartbeatMatch && req.method === "POST") {
          response = json(await heartbeatGroupScreenShare(db, {
            accountId: session.accountId,
            deviceId: session.deviceId,
            callId: groupCallScreenHeartbeatMatch[1],
            generation: body.generation,
          }));
        }

        if (groupCallScreenReleaseMatch && req.method === "POST") {
          const result = await releaseGroupScreenShare(db, {
            accountId: session.accountId,
            deviceId: session.deviceId,
            callId: groupCallScreenReleaseMatch[1],
            generation: body.generation,
          }, options.groupCallSFUControl);
          pushGroupCallHints(sockets, result.hints);
          response = json({ released: true });
        }

        if (dialogPreferencesMatch && req.method === "PUT") {
          const result = await updateDialogPreferences(db, {
            accountId: session.accountId,
            deviceId: session.deviceId,
            dialogId: dialogPreferencesMatch[1],
            clientMutationId: body.clientMutationId,
            patch: body,
          });
          pushHints(sockets, result.pushes);
          response = json({
            preferences: result.preferences,
            pts: result.pts,
            duplicate: result.duplicate,
          });
        }

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
            body.supportedGroupCallVersions,
            body.groupCallViewVersion,
            body.supportsGroupScreenShare,
          ));
        }

        if (url.pathname === "/v1/devices/group-call-capabilities" && req.method === "PUT") {
          response = json(await registerGroupCallCapabilities(
            db,
            session.deviceId,
            body.supportedGroupCallVersions,
            body.groupCallViewVersion,
            body.supportsGroupScreenShare,
          ));
        }

        if (url.pathname === "/v1/devices/voip-push" && req.method === "DELETE") {
          response = json(await unregisterVoIPPushToken(db, session.deviceId));
        }

        if (blockMatch && req.method === "PUT") {
          const result = await blockAccount(db, session.accountId, blockMatch[1]);
          pushCallHints(sockets, result.hints);
          pushHints(sockets, result.syncPushes);
          deliverPresenceBroadcasts(await publishPresenceVisibility(
            db, session.accountId, blockMatch[1], false,
          ));
          response = json({ blocked: result.blocked });
        }

        if (blockMatch && req.method === "DELETE") {
          const result = await unblockAccount(db, session.accountId, blockMatch[1]);
          deliverPresenceBroadcasts(await publishPresenceVisibility(
            db, session.accountId, blockMatch[1], true,
          ));
          response = json(result);
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
          const result = await revokeDeviceAndTerminateCalls(
            db,
            session.accountId,
            session.deviceId,
            options.groupCallSFUControl,
          );
          deliverPresenceBroadcasts(result.presenceBroadcasts);
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
          const result = await deleteAccountAndTerminateCalls(
            db,
            session.accountId,
            String(body.code),
            options.groupCallSFUControl,
          );
          pushCallHints(sockets, result.hints);
          pushHints(sockets, result.syncPushes);
          deliverPresenceBroadcasts(result.presenceBroadcasts);
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
          const result = await revokeDeviceAndTerminateCalls(
            db,
            session.accountId,
            targetDeviceId,
            options.groupCallSFUControl,
          );
          deliverPresenceBroadcasts(result.presenceBroadcasts);
          disconnectDevice(sockets, session.accountId, targetDeviceId);
          pushCallHints(sockets, result.hints);
          pushHints(sockets, result.syncPushes);
          response = json({ revoked: result.revoked });
        }

        if (url.pathname === "/v1/sync/state" && req.method === "GET") {
          response = json(await getState(db, session.accountId));
        }

        if (url.pathname === "/v1/sync/difference" && req.method === "POST") {
          const draftMedia = await draftMediaAvailability();
          response = json(await getDifference(db, session.accountId, Number(body.sincePts ?? 0), {
            maxEvents: body.maxEvents,
            maxBytes: body.maxBytes,
            cloudDraftsEnabled: draftMedia.cloudDrafts,
            chatFoldersEnabled: chatFoldersAvailable,
            scheduledDeliveryEnabled: scheduledDeliveryAvailable,
            linkPreviewsEnabled: linkPreviewsAvailable,
          }));
        }

        if (url.pathname === "/v1/bootstrap/start" && req.method === "POST") {
          response = json(await startBootstrap(db, session.accountId));
        }

        if (url.pathname === "/v1/bootstrap/dialogs" && req.method === "POST") {
          const draftMedia = await draftMediaAvailability();
          response = json(await getBootstrapDialogsPage(db, session.accountId, body.token, {
            cursor: body.cursor,
            limit: body.limit,
            previewMessages: body.previewMessages,
            cloudDraftsEnabled: draftMedia.cloudDrafts,
          }));
        }

        if (url.pathname === "/v1/contacts/lookup" && req.method === "POST") {
          if (!body.phone) throw new SyncError("phone required");
          const found = await lookupAccountByPhone(db, session.accountId, body.phone);
          response = json(found ?? { found: false });
        }

        if (url.pathname.startsWith("/v1/usernames/") && req.method === "GET") {
          const username = decodeURIComponent(url.pathname.slice("/v1/usernames/".length));
          const found = await lookupAccountByUsername(db, session.accountId, username);
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

        if (url.pathname === "/v1/profile/photo" && req.method === "PUT") {
          const result = await updateProfilePhoto(db, {
            accountId: session.accountId,
            deviceId: session.deviceId,
            mediaId: body.mediaId,
            clientMutationId: body.clientMutationId,
            basePhotoRevision: body.basePhotoRevision,
          });
          pushHints(sockets, result.pushes);
          response = json({
            profile: result.profile,
            committedPhotoRevision: result.committedPhotoRevision,
            duplicate: result.duplicate,
          });
        }

        if (url.pathname === "/v1/dialogs/direct" && req.method === "POST") {
          if (!body.peerAccountId) throw new SyncError("peerAccountId required");
          response = json(await getOrCreateDirectDialog(
            db, session.accountId, body.peerAccountId, session.deviceId,
          ));
        }

        if (url.pathname === "/v1/dialogs/saved" && req.method === "POST") {
          if (!savedMessagesEnabledForAccount(session.accountId)) {
            response = new Response("not found", { status: 404 });
          } else {
            const ensureStarted = performance.now();
            try {
              const result = await ensureSavedMessages(db, session.accountId, session.deviceId);
              metrics.recordSavedMessagesEnsure(
                result.created ? "created" : result.repaired ? "repaired" : "existing",
                performance.now() - ensureStarted,
              );
              pushHints(sockets, result.pushes);
              response = json({
                dialogId: result.dialogId,
                type: result.type,
                created: result.created,
                repaired: result.repaired,
                ...(result.eventPts === undefined ? {} : { eventPts: result.eventPts }),
              }, result.created ? 201 : 200);
            } catch (error) {
              metrics.recordSavedMessagesEnsure("error", performance.now() - ensureStarted);
              throw error;
            }
          }
        }

        if (url.pathname === "/v1/messages/send" && req.method === "POST") {
          const draftMedia = await draftMediaAvailability();
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
            mentions: body.mentions,
            draftConsumeOperationId:
              body.draftConsumeOperationId ?? body.draft_consume_operation_id,
            allowDraftConsumption: draftMedia.cloudDrafts,
            silent: body.silent === true,
            linkPreviewCandidate: body.linkPreviewCandidate ?? body.link_preview_candidate,
            linkPreviewsEnabled: linkPreviewsAvailable,
          });
          pushHints(sockets, result.pushes);
          response = json(result);
        }

        const draftMatch = url.pathname.match(/^\/v1\/drafts\/([0-9a-f-]+)$/i);
        if (draftMatch && req.method === "GET") {
          const draftMedia = await draftMediaAvailability();
          if (!draftMedia.cloudDrafts) {
            throw new DraftError("cloud drafts are unavailable", 404, "capability_unavailable");
          }
          response = json({ draft: await getDraft(db, session.accountId, draftMatch[1]) });
        }
        if (draftMatch && req.method === "PUT") {
          const draftMedia = await draftMediaAvailability();
          if (!draftMedia.cloudDrafts) {
            throw new DraftError("cloud drafts are unavailable", 404, "capability_unavailable");
          }
          const result = await putDraft(db, {
            accountId: session.accountId,
            deviceId: session.deviceId,
            dialogId: draftMatch[1],
            operationId: body.operation_id ?? body.operationId,
            state: body.state,
            text: body.text,
            replyToMsgId: body.reply_to_msg_id ?? body.replyToMsgId,
            mentions: body.mentions,
            attachments: body.attachments,
          });
          pushHints(sockets, result.pushes);
          response = json({ draft: result.draft, duplicate: result.duplicate });
        }

        if (url.pathname === "/v1/messages/send-group" && req.method === "POST") {
          const draftMedia = await draftMediaAvailability();
          if (!draftMedia.mediaGroups) {
            throw new SyncError(
              "media groups are unavailable",
              404,
              "capability_unavailable",
            );
          }
          const result = await sendMediaGroup(db, {
            senderAccountId: session.accountId,
            senderDeviceId: session.deviceId,
            dialogId: body.dialog_id ?? body.dialogId,
            clientGroupId: body.client_group_id ?? body.clientGroupId,
            items: body.items,
            body: body.body ?? body.caption ?? "",
            replyToMsgId: body.reply_to_msg_id ?? body.replyToMsgId,
            mentions: body.mentions,
            draftConsumeOperationId:
              body.draft_consume_operation_id ?? body.draftConsumeOperationId,
            allowDraftConsumption: draftMedia.cloudDrafts,
            silent: body.silent === true,
            linkPreviewCandidate: body.linkPreviewCandidate ?? body.link_preview_candidate,
            linkPreviewsEnabled: linkPreviewsAvailable,
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
            linkPreviewCandidate: body.linkPreviewCandidate ?? body.link_preview_candidate,
            linkPreviewsEnabled: linkPreviewsAvailable,
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
          : err instanceof GroupCallError ? err.status
          : err instanceof GroupError ? err.status
          : err instanceof SavedMessagesError ? err.status
          : err instanceof DialogPreferenceError ? err.status
          : err instanceof ProfilePhotoError ? err.status
          : err instanceof PresenceError ? err.status
          : err instanceof DialogAccessError ? err.status
          : err instanceof DraftError ? err.status
          : err instanceof ChatFolderError ? err.status
          : err instanceof ScheduledDeliveryError ? err.status
          : err instanceof LinkPreviewError ? err.status
          : err instanceof SyncError ? err.status
          : err instanceof PushError ? 400 : 500;
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
        if (err instanceof GroupCallError && err.retryAfter) headers["retry-after"] = String(err.retryAfter);
        if (err instanceof GroupError && err.retryAfter) headers["retry-after"] = String(err.retryAfter);
        if (err instanceof DraftError && err.retryAfter) headers["retry-after"] = String(err.retryAfter);
        if (err instanceof DialogPreferenceError && err.retryAfter) {
          headers["retry-after"] = String(err.retryAfter);
        }
        if (err instanceof ChatFolderError && err.retryAfter) headers["retry-after"] = String(err.retryAfter);
        if (err instanceof ScheduledDeliveryError && err.retryAfter) headers["retry-after"] = String(err.retryAfter);
        if (status === 401) headers["www-authenticate"] = "Bearer";
        response = json({
          error: message,
          ...(err instanceof MediaError ? { code: err.code } : {}),
          ...(err instanceof CallError ? { code: err.code, ...err.details } : {}),
          ...(err instanceof GroupCallError ? { code: err.code, ...err.details } : {}),
          ...(err instanceof GroupError ? { code: err.code, ...err.details } : {}),
          ...(err instanceof SavedMessagesError ? { code: err.code } : {}),
          ...(err instanceof DialogPreferenceError ? { code: err.code } : {}),
          ...(err instanceof ProfilePhotoError ? { code: err.code } : {}),
          ...(err instanceof PresenceError ? { code: err.code } : {}),
          ...(err instanceof DialogAccessError ? { code: err.code } : {}),
          ...(err instanceof DraftError ? { code: err.code } : {}),
          ...(err instanceof ChatFolderError ? { code: err.code } : {}),
          ...(err instanceof ScheduledDeliveryError ? { code: err.code, ...err.details } : {}),
          ...(err instanceof LinkPreviewError ? { code: err.code } : {}),
          ...(err instanceof SyncError ? { code: err.code, ...err.details } : {}),
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
        // Late-join hint: a client reconnecting after a gap learns the current cursor right away
        // instead of waiting for the next new event to produce a push.
        requireActiveDevice(db, ws.data.accountId, ws.data.deviceId)
          .then(() => getState(db, ws.data.accountId))
          .then((state) => {
            if (ws.readyState === 1) {
              ws.send(JSON.stringify({ type: "sync_hint", pts: state.pts, ptsCount: 0 }));
            }
          })
          .catch(() => ws.close(4001, "device revoked"));
        console.log(JSON.stringify({ ts: new Date().toISOString(), event: "cloud.ws.open" }));
      },
      close(ws) {
        const set = sockets.get(ws.data.accountId);
        if (set) {
          set.delete(ws);
          if (set.size === 0) sockets.delete(ws.data.accountId);
        }
        const cleanup = (async () => {
          await ws.data.activityQueue.catch(() => {});
          for (const dialogId of ws.data.typingDialogs) {
            deliverPresenceBroadcasts(await publishTyping(db, {
              accountId: ws.data.accountId,
              deviceId: ws.data.deviceId,
              dialogId,
              typingSessionId: ws.data.connectionId,
              active: false,
              allowRevokedCleanup: true,
            }));
          }
          ws.data.typingDialogs.clear();
          if (ws.data.presenceActive) {
            deliverPresenceBroadcasts(await setPresenceActivity(db, {
              accountId: ws.data.accountId,
              deviceId: ws.data.deviceId,
              connectionId: ws.data.connectionId,
              active: false,
              allowRevokedCleanup: true,
            }));
          }
        })().catch(() => {});
        presenceSocketCleanupTasks.add(cleanup);
        void cleanup.finally(() => presenceSocketCleanupTasks.delete(cleanup));
        console.log(JSON.stringify({ ts: new Date().toISOString(), event: "cloud.ws.close" }));
      },
      message(ws, raw) {
        const text = String(raw);
        if (text === "ping") { ws.send("pong"); return; }
        if (Buffer.byteLength(text) > 4_096) {
          recordPresenceRejectedFrame("oversized");
          return;
        }
        const handleActivity = async () => {
          let value: any;
          try { value = JSON.parse(text); } catch {
            recordPresenceRejectedFrame("malformed");
            return;
          }
          if (!value || typeof value.type !== "string") {
            recordPresenceRejectedFrame("malformed");
            return;
          }
          if (!presenceEnabledForAccount(ws.data.accountId)
            || !(await realtimePresenceSchemaReady())) {
            recordPresenceRejectedFrame("unauthorized");
            return;
          }
          if (value.type === "presence_activity") {
            if (typeof value.active !== "boolean") {
              recordPresenceRejectedFrame("malformed");
              return;
            }
            if (value.active && ws.data.presenceEpoch == null) {
              ws.data.presenceEpoch = await nextPresenceConnectionEpoch(db);
            }
            ws.data.presenceActive = value.active;
            if (!value.active) {
              for (const dialogId of ws.data.typingDialogs) {
                deliverPresenceBroadcasts(await publishTyping(db, {
                  accountId: ws.data.accountId,
                  deviceId: ws.data.deviceId,
                  dialogId,
                  typingSessionId: ws.data.connectionId,
                  active: false,
                }));
              }
              ws.data.typingDialogs.clear();
            }
            deliverPresenceBroadcasts(await setPresenceActivity(db, {
              accountId: ws.data.accountId,
              deviceId: ws.data.deviceId,
              connectionId: ws.data.connectionId,
              connectionEpoch: ws.data.presenceEpoch ?? undefined,
              active: value.active,
            }));
          } else if (value.type === "presence_heartbeat" && ws.data.presenceActive) {
            deliverPresenceBroadcasts(await heartbeatPresence(db, {
              accountId: ws.data.accountId,
              deviceId: ws.data.deviceId,
              connectionId: ws.data.connectionId,
              connectionEpoch: ws.data.presenceEpoch ?? undefined,
            }));
          } else if (value.type === "typing_activity") {
            if (!ws.data.presenceActive
              || !validPresenceDialogId(value.dialogId)
              || typeof value.active !== "boolean") {
              recordPresenceRejectedFrame("malformed");
              return;
            }
            const now = Date.now();
            const previous = ws.data.lastTypingAt.get(value.dialogId) ?? 0;
            if (value.active && now - previous < 2_000) {
              recordPresenceRejectedFrame("rate_limited");
              return;
            }
            if (value.active
              && !ws.data.typingDialogs.has(value.dialogId)
              && ws.data.typingDialogs.size >= 8) {
              recordPresenceRejectedFrame("rate_limited");
              return;
            }
            const broadcasts = await publishTyping(db, {
              accountId: ws.data.accountId,
              deviceId: ws.data.deviceId,
              dialogId: value.dialogId,
              typingSessionId: ws.data.connectionId,
              active: value.active,
            });
            if (value.active && broadcasts.length === 0) {
              recordPresenceRejectedFrame("unauthorized");
              return;
            }
            if (value.active) {
              ws.data.lastTypingAt.set(value.dialogId, now);
              ws.data.typingDialogs.add(value.dialogId);
            } else {
              ws.data.typingDialogs.delete(value.dialogId);
              ws.data.lastTypingAt.delete(value.dialogId);
            }
            deliverPresenceBroadcasts(broadcasts);
          } else {
            recordPresenceRejectedFrame("unsupported");
          }
        };
        if (ws.data.activityDepth >= 32) {
          recordPresenceRejectedFrame("rate_limited");
          return;
        }
        ws.data.activityDepth += 1;
        ws.data.activityQueue = ws.data.activityQueue
          .then(handleActivity, handleActivity)
          .catch((error) => {
            if (error instanceof AuthError) {
              recordPresenceRejectedFrame("unauthorized");
              ws.close(4001, "device revoked");
            } else if (error instanceof PresenceError
              && error.code === "stale_presence_connection") {
              recordPresenceRejectedFrame("unauthorized");
              ws.data.presenceActive = false;
              ws.close(4003, "connection superseded");
            }
          })
          .finally(() => {
            ws.data.activityDepth = Math.max(0, ws.data.activityDepth - 1);
          });
      },
    },
  });

  const originalStop = server.stop.bind(server);
  server.stop = ((closeActiveConnections?: boolean) => {
    stopPushWorker();
    stopMaintenanceWorker();
    stopCallCleanupWorker();
    stopGroupCallCleanupWorker();
    stopGroupCallSFUWorker();
    stopScheduledDeliveryWorker();
    stopLinkPreviewWorker();
    stopSyncNotifications();
    stopCallNotifications();
    stopGroupCallNotifications();
    stopPresenceNotifications();
    stopPresenceCleanup();
    if (socketAuthorizationInterval) clearInterval(socketAuthorizationInterval);
    const stopped = originalStop(closeActiveConnections);
    return Promise.resolve(stopped).then(async (value) => {
      await Promise.allSettled([...presenceSocketCleanupTasks]);
      return value;
    });
  }) as typeof server.stop;

  console.log(JSON.stringify({ ts: new Date().toISOString(), event: "cloud.listening", port: server.port }));
  return server;
}

if (import.meta.main) startCloudServer();
