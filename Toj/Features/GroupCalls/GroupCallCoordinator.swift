import AVFoundation
import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class GroupCallCoordinator {
    static let shared = GroupCallCoordinator()

    private(set) var state: GroupCallConnectionState = .idle
    private(set) var securityState: GroupCallSecurityState = .preparing
    private(set) var activeCall: CloudGroupCallSnapshot?
    private(set) var availableCalls: [String: CloudGroupCallSnapshot] = [:]
    private(set) var participants: [GroupCallPresentationParticipant] = []
    private(set) var videoTracks: [GroupCallVideoTrackReference] = []
    private(set) var isMuted = true
    private(set) var isCameraEnabled = false
    private(set) var isScreenSharing = false
    private(set) var isStartingScreenShare = false
    private(set) var cameraPosition: GroupCallCameraPosition = .front
    private(set) var qualityTier: GroupCallQualityTier = .high
    private(set) var safetyEmojis: [String] = []
    private(set) var connectedAt: Date?
    private(set) var failureMessage: String?
    private(set) var weakNetwork = false
    private(set) var title = String(localized: "Group call")
    var isPresented = false

    var hasActiveCall: Bool {
        runtime != nil && state != .idle && state != .ended && state != .failed
    }

    var activeDialogId: String? { runtime?.dialogId }
    var canShareScreen: Bool { screenShareAvailable() && screenSharingNegotiated() }
    var isKeyLeader: Bool { activeCall?.keyLeaderDeviceId == session?.deviceId }
    var canManageGroupCall: Bool {
        activeCall?.selfRole == "owner" || activeCall?.selfRole == "admin"
    }

    @ObservationIgnored private let permissions: any CallPermissionProviding
    @ObservationIgnored private let clock: any CallClock
    @ObservationIgnored private let engineAvailable: @MainActor @Sendable () -> Bool
    @ObservationIgnored private let screenShareAvailable: @MainActor @Sendable () -> Bool
    @ObservationIgnored private let engineFactory: @MainActor @Sendable () -> any GroupCallMediaEngine
    @ObservationIgnored private var screenSharingNegotiated: @MainActor @Sendable () -> Bool = { false }
    @ObservationIgnored private var api: (any GroupCallAPITransport)?
    @ObservationIgnored private var session: CloudSession?
    @ObservationIgnored private var participantName: ((String, String) -> String)?
    @ObservationIgnored private var runtime: Runtime?
    @ObservationIgnored private var mediaReducer = GroupCallMediaReducer()
    @ObservationIgnored private var heartbeatTask: Task<Void, Never>?
    @ObservationIgnored private var rekeyTask: Task<Void, Never>?
    @ObservationIgnored private var rekeyWatchdogTask: Task<Void, Never>?
    @ObservationIgnored private var cameraHeartbeatTask: Task<Void, Never>?
    @ObservationIgnored private var screenHeartbeatTask: Task<Void, Never>?
    @ObservationIgnored private var screenActivationTask: Task<Void, Never>?
    @ObservationIgnored private var connectionRecoveryTask: Task<Void, Never>?
    @ObservationIgnored private var qualityTask: Task<Void, Never>?
    @ObservationIgnored private var keyRetirementTasks: [Int64: Task<Void, Never>] = [:]
    @ObservationIgnored private var networkTask: Task<Void, Never>?
    @ObservationIgnored private var previousNetworkSnapshot: ReplicaNetworkSnapshot?
    @ObservationIgnored private var lifecycleObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var cameraPressureObservers: [NSKeyValueObservation] = []
    @ObservationIgnored private var pressuredCameraIds: Set<String> = []
    @ObservationIgnored private var mediaDecisionRunning = false
    @ObservationIgnored private var mediaDecisionPending = false
    @ObservationIgnored private var mediaDecisionGeneration: UInt64?
    @ObservationIgnored private var admissionInFlight = false

    private final class Runtime {
        let callId: String
        let dialogId: String
        let identity: GroupCallJoinIdentity
        let engine: any GroupCallMediaEngine
        let generation: UInt64
        var snapshot: CloudGroupCallSnapshot
        var currentEpoch: GroupCallEpochMaterial?
        var connectedEpoch: Int64?
        var cameraGeneration: String?
        var screenGeneration: String?
        var rekeyStartedAt: Date?
        var appliedMicrophoneEnabled: Bool?
        var appliedCameraEnabled: Bool?
        var appliedCameraPosition: GroupCallCameraPosition?
        var appliedCameraTier: GroupCallQualityTier?
        var snapshotApplicationNonce: UInt64 = 0

        init(
            callId: String,
            dialogId: String,
            identity: GroupCallJoinIdentity,
            engine: any GroupCallMediaEngine,
            generation: UInt64,
            snapshot: CloudGroupCallSnapshot,
            currentEpoch: GroupCallEpochMaterial?
        ) {
            self.callId = callId
            self.dialogId = dialogId
            self.identity = identity
            self.engine = engine
            self.generation = generation
            self.snapshot = snapshot
            self.currentEpoch = currentEpoch
        }
    }

    init(
        permissions: any CallPermissionProviding = SystemCallPermissionProvider(),
        clock: any CallClock = SystemCallClock(),
        installSystemObservers: Bool = true,
        engineAvailable: @escaping @MainActor @Sendable () -> Bool = {
            GroupCallEngineFactory.isAvailable
        },
        screenShareAvailable: @escaping @MainActor @Sendable () -> Bool = {
            GroupCallEngineFactory.supportsScreenShare
        },
        engineFactory: @escaping @MainActor @Sendable () -> any GroupCallMediaEngine = {
            GroupCallEngineFactory.production()
        }
    ) {
        self.permissions = permissions
        self.clock = clock
        self.engineAvailable = engineAvailable
        self.screenShareAvailable = screenShareAvailable
        self.engineFactory = engineFactory
        mediaReducer.setDataUsagePolicy(CallPrivacyPreferences.shared.dataUsagePolicy)
        if installSystemObservers {
            installLifecycleObservers()
            installCameraPressureObservers()
            startNetworkObservation()
        }
    }

    func configure(
        api: any GroupCallAPITransport,
        session: CloudSession,
        screenSharingNegotiated: @escaping @MainActor @Sendable () -> Bool,
        participantName: @escaping (String, String) -> String
    ) {
        self.api = api
        self.session = session
        self.screenSharingNegotiated = screenSharingNegotiated
        self.participantName = participantName
    }

    /// Synchronously fences the authenticated session, then waits only for local media teardown.
    /// Server departure is best effort so sign-out cannot hang on a degraded control plane.
    func unbind() async {
        let callId = runtime?.callId
        let api = self.api
        let session = self.session
        self.api = nil
        self.session = nil
        screenSharingNegotiated = { false }
        participantName = nil
        admissionInFlight = false
        availableCalls.removeAll()
        await teardown(reportLeave: false, finalState: .ended)
        if let callId, let api, let session {
            Task {
                _ = try? await api.leaveGroupCall(id: callId, token: session.token)
            }
        }
    }

    func refreshActiveCall(dialogId: String) async {
        guard let api, let session, runtime?.dialogId != dialogId else { return }
        do {
            let response = try await api.activeGroupCall(dialogId: dialogId, token: session.token)
            guard self.session?.token == session.token else { return }
            if let call = response.call, call.isActive {
                if availableCalls[dialogId].map({ $0.stateRevision <= call.stateRevision }) ?? true {
                    availableCalls[dialogId] = call
                }
            } else {
                availableCalls[dialogId] = nil
            }
        } catch let error as CloudAPIError where error.status == 404 {
            availableCalls[dialogId] = nil
        } catch {
            // Discovery is opportunistic. The socket or a later foreground refresh retries it.
        }
    }

    func start(dialogId: String, title: String, initialKind: GroupCallInitialKind) async {
        if runtime != nil {
            isPresented = true
            return
        }
        guard !admissionInFlight else {
            isPresented = true
            return
        }
        admissionInFlight = true
        defer { admissionInFlight = false }
        guard engineAvailable(),
              let api,
              let session else {
            presentFailure(String(localized: "Encrypted group calling is unavailable on this device."))
            return
        }
        failureMessage = nil
        state = .preparing
        securityState = .preparing
        self.title = title
        isPresented = true

        let callId = UUID().uuidString.lowercased()
        let identity = GroupCallJoinIdentity()
        let generation = mediaReducer.beginRuntime()
        do {
            let participantHash = try GroupCallCrypto.participantSetHash(
                accountId: session.accountId,
                deviceId: session.deviceId,
                publicKey: identity.publicKey,
                nonce: identity.nonce
            )
            let epoch = try GroupCallCrypto.makeEpoch(
                callId: callId,
                dialogId: dialogId,
                epoch: 1,
                membershipRevision: 1,
                participantSetHash: participantHash
            )
            let response = try await api.startGroupCall(
                StartCloudGroupCallRequest(
                    callId: callId,
                    dialogId: dialogId,
                    initialKind: initialKind,
                    joinPublicKey: identity.publicKey.base64EncodedString(),
                    joinNonce: identity.nonce.base64EncodedString(),
                    epochKeyCommitment: epoch.keyCommitment.base64EncodedString()
                ),
                token: session.token
            )
            guard self.session?.token == session.token,
                  runtime == nil,
                  generation == mediaReducer.generation else {
                // The server accepted the start while this local runtime was being replaced or
                // signed out. Compensate immediately instead of leaving a ghost participant for
                // the stale-participant worker to discover later.
                _ = try? await api.leaveGroupCall(id: response.call.id, token: session.token)
                return
            }
            try validateOwnIdentity(in: response.call, identity: identity, session: session)
            try GroupCallCrypto.verifySnapshotTranscript(response.call)
            guard response.call.id == callId,
                  response.call.dialogId == dialogId,
                  response.call.mediaEpoch == 1,
                  response.credentials.mediaEpoch == 1,
                  response.credentials.participantId == response.call.selfParticipant?.participantId,
                  Data(base64Encoded: response.call.epoch.keyCommitment) == epoch.keyCommitment,
                  Data(base64Encoded: response.call.epoch.participantSetHash) == participantHash
            else { throw GroupCallCryptoError.invalidCommitment }

            let engine = engineFactory()
            try engine.installEpoch(epoch)
            try await engine.setAuthorizedParticipants(
                Set(response.call.participants.filter { $0.status == .active }.map(\.participantId)),
                cameraPublishers: Set(response.call.cameraPublishers),
                screenPublisher: response.call.screenShare?.participantId
            )
            installRuntime(
                Runtime(
                    callId: callId,
                    dialogId: dialogId,
                    identity: identity,
                    engine: engine,
                    generation: generation,
                    snapshot: response.call,
                    currentEpoch: epoch
                )
            )
            activeCall = response.call
            availableCalls[dialogId] = response.call
            safetyEmojis = GroupCallCrypto.safetyEmojis(callId: callId, epoch: epoch)
            mediaReducer.setSecureMediaReady(true, generation: generation)
            securityState = .keyReady
            state = .connecting
            try await engine.connect(credentials: response.credentials)
            guard runtime?.generation == generation else { return }
            runtime?.connectedEpoch = epoch.epoch
            startHeartbeat(generation: generation)
        } catch let error as CloudAPIError
            where error.code == "call_already_active" && error.existingCallId != nil {
            guard self.session?.token == session.token,
                  runtime == nil,
                  generation == mediaReducer.generation,
                  let existingCallId = error.existingCallId else { return }
            do {
                var existing = try await api.groupCall(id: existingCallId, token: session.token).call
                guard existing.dialogId == dialogId, existing.isActive else {
                    throw GroupCallCryptoError.invalidIdentifier
                }
                // A prior process may have started this call and lost its private join key before
                // persisting a runtime. Leave that unrecoverable identity before joining with a
                // fresh key; otherwise the server correctly rejects the changed key transcript.
                if existing.selfParticipant != nil {
                    existing = try await api.leaveGroupCall(
                        id: existingCallId,
                        token: session.token
                    ).call
                }
                guard self.session?.token == session.token,
                      runtime == nil,
                      generation == mediaReducer.generation else { return }
                mediaReducer.endRuntime()
                admissionInFlight = false
                if existing.isActive {
                    availableCalls[dialogId] = existing
                    await join(existing, title: title)
                } else {
                    await start(dialogId: dialogId, title: title, initialKind: initialKind)
                }
            } catch {
                guard self.session?.token == session.token,
                      runtime == nil,
                      generation == mediaReducer.generation else { return }
                await fail(error)
            }
        } catch {
            guard self.session?.token == session.token,
                  generation == mediaReducer.generation,
                  runtime == nil || runtime?.generation == generation else { return }
            await fail(error)
        }
    }

    func join(_ call: CloudGroupCallSnapshot, title: String) async {
        if runtime != nil {
            isPresented = true
            return
        }
        guard !admissionInFlight else {
            isPresented = true
            return
        }
        admissionInFlight = true
        defer { admissionInFlight = false }
        guard call.isActive,
              engineAvailable(),
              let api,
              let session else {
            presentFailure(String(localized: "This group call cannot be joined right now."))
            return
        }
        failureMessage = nil
        state = .preparing
        securityState = .preparing
        self.title = title
        isPresented = true
        let identity = GroupCallJoinIdentity()
        let generation = mediaReducer.beginRuntime()
        do {
            let response = try await api.joinGroupCall(
                id: call.id,
                body: JoinCloudGroupCallRequest(
                    joinPublicKey: identity.publicKey.base64EncodedString(),
                    joinNonce: identity.nonce.base64EncodedString()
                ),
                token: session.token
            )
            guard self.session?.token == session.token,
                  runtime == nil,
                  generation == mediaReducer.generation else {
                _ = try? await api.leaveGroupCall(id: response.call.id, token: session.token)
                return
            }
            try validateOwnIdentity(in: response.call, identity: identity, session: session)
            try GroupCallCrypto.verifySnapshotTranscript(response.call)
            let engine = engineFactory()
            installRuntime(Runtime(
                callId: response.call.id,
                dialogId: response.call.dialogId,
                identity: identity,
                engine: engine,
                generation: generation,
                snapshot: response.call,
                currentEpoch: nil
            ))
            activeCall = response.call
            availableCalls[response.call.dialogId] = response.call
            state = .waitingForKey
            startHeartbeat(generation: generation)
            await processSnapshot(response.call, generation: generation)
        } catch {
            guard self.session?.token == session.token,
                  generation == mediaReducer.generation,
                  runtime == nil || runtime?.generation == generation else { return }
            await fail(error)
        }
    }

    func joinAvailableCall(dialogId: String, title: String) async {
        if let call = availableCalls[dialogId] {
            await join(call, title: title)
        } else {
            await refreshActiveCall(dialogId: dialogId)
            if let call = availableCalls[dialogId] { await join(call, title: title) }
        }
    }

    func handle(_ hint: GroupCallSocketHint) async {
        guard let api, let session else { return }
        if let runtime, runtime.callId == hint.callId {
            guard hint.stateRevision > runtime.snapshot.stateRevision else { return }
            do {
                let response = try await api.groupCall(id: hint.callId, token: session.token)
                guard self.session?.token == session.token,
                      self.runtime?.generation == runtime.generation else { return }
                await processSnapshot(response.call, generation: runtime.generation)
            } catch {
                if (error as? CloudAPIError)?.status == 404 || (error as? CloudAPIError)?.status == 410 {
                    await teardown(reportLeave: false, finalState: .ended)
                }
            }
            return
        }
        do {
            let response = try await api.groupCall(id: hint.callId, token: session.token)
            guard self.session?.token == session.token else { return }
            if response.call.isActive {
                if availableCalls[response.call.dialogId]
                    .map({ $0.stateRevision <= response.call.stateRevision }) ?? true {
                    availableCalls[response.call.dialogId] = response.call
                }
            } else {
                availableCalls[response.call.dialogId] = nil
            }
        } catch {
            // The hint target may have lost group access before handling the bounded wake-up.
            if let apiError = error as? CloudAPIError,
               apiError.status == 404 || apiError.status == 410 {
                for (dialogId, call) in availableCalls where call.id == hint.callId {
                    availableCalls[dialogId] = nil
                }
            }
        }
    }

    /// Socket hints are lossy wake-ups. After transport reconnect, re-read the authoritative
    /// room snapshot even when no hint survived the outage.
    func reconcileAfterSocketReconnect() async {
        guard let runtime, let api, let session else { return }
        do {
            let response = try await api.groupCall(id: runtime.callId, token: session.token)
            guard self.session?.token == session.token,
                  self.runtime === runtime else { return }
            await processSnapshot(response.call, generation: runtime.generation)
        } catch let error as CloudAPIError where error.status == 404 || error.status == 410 {
            await teardown(reportLeave: false, finalState: .ended)
        } catch {
            // The call heartbeat and the next reconnect retry retain ownership of recovery.
        }
    }

    func toggleMute() async {
        guard let runtime else { return }
        let wantsMicrophone = isMuted
        if wantsMicrophone {
            let allowed = await permissions.microphoneAllowed()
            guard self.runtime?.generation == runtime.generation else { return }
            mediaReducer.setPermissions(
                microphone: allowed ? .granted : .denied,
                generation: runtime.generation
            )
            guard allowed else {
                failureMessage = String(localized: "Microphone access is disabled. You can enable it in Settings.")
                return
            }
        }
        mediaReducer.setMicrophoneIntent(wantsMicrophone)
        await applyMediaDecision(generation: runtime.generation)
    }

    func toggleCamera() async {
        guard let runtime else { return }
        let wantsCamera = !mediaReducer.userWantsCamera
        if wantsCamera {
            guard UIApplication.shared.applicationState == .active else { return }
            let allowed: Bool
            switch permissions.cameraPermission {
            case .authorized: allowed = true
            case .notDetermined: allowed = await permissions.requestCameraAccess()
            case .denied, .restricted: allowed = false
            }
            guard self.runtime?.generation == runtime.generation else { return }
            mediaReducer.setPermissions(
                camera: allowed ? .granted : .denied,
                generation: runtime.generation
            )
            guard allowed else {
                failureMessage = String(localized: "Camera access is disabled. You can enable it in Settings.")
                return
            }
        }
        mediaReducer.setCameraIntent(wantsCamera)
        await applyMediaDecision(generation: runtime.generation)
    }

    func switchCamera() async {
        guard let runtime, isCameraEnabled else { return }
        mediaReducer.switchCamera()
        cameraPosition = mediaReducer.preferredCamera
        do {
            try await runtime.engine.switchCamera(to: cameraPosition)
            guard !Task.isCancelled, self.runtime === runtime else { return }
            runtime.appliedCameraPosition = cameraPosition
        } catch {
            guard self.runtime === runtime else { return }
            failureMessage = String(localized: "The other camera is unavailable.")
        }
    }

    func toggleScreenShare() async {
        if isScreenSharing || isStartingScreenShare {
            await stopScreenShare()
        } else {
            await startScreenShare()
        }
    }

    func leave() async {
        await teardown(reportLeave: true, finalState: .ended)
    }

    func endForEveryone() async {
        guard let runtime, let api, let session else { return }
        state = .ending
        do {
            _ = try await api.endGroupCall(
                id: runtime.callId,
                reason: "ended_by_admin",
                token: session.token
            )
            await teardown(reportLeave: false, finalState: .ended)
        } catch {
            guard self.runtime === runtime else { return }
            failureMessage = String(localized: "Only a group administrator can end this call for everyone.")
            state = runtime.engine.isConnected ? .connected : .reconnecting
        }
    }

    func removeParticipant(deviceId: String) async {
        guard canManageGroupCall,
              let runtime,
              let api,
              let session,
              deviceId != session.deviceId else { return }
        do {
            let response = try await api.removeGroupCallParticipant(
                callId: runtime.callId,
                deviceId: deviceId,
                token: session.token
            )
            await processSnapshot(response.call, generation: runtime.generation)
        } catch {
            guard self.runtime === runtime else { return }
            failureMessage = userMessage(for: error)
        }
    }

    func dismissEndedCall() {
        guard state == .ended || state == .failed else { return }
        isPresented = false
        resetPresentation()
    }

    private func installRuntime(_ runtime: Runtime) {
        self.runtime = runtime
        let generation = runtime.generation
        let engineIdentity = ObjectIdentifier(runtime.engine)
        runtime.engine.onEvent = { [weak self] event in
            self?.handleEngineEvent(
                event,
                generation: generation,
                engineIdentity: engineIdentity
            )
        }
        isMuted = true
        isCameraEnabled = false
        isScreenSharing = false
        isStartingScreenShare = false
        cameraPosition = .front
        participants = []
        videoTracks = []
    }

    private func processSnapshot(_ snapshot: CloudGroupCallSnapshot, generation: UInt64) async {
        guard let runtime, runtime.generation == generation else { return }
        guard snapshot.stateRevision >= runtime.snapshot.stateRevision else { return }
        runtime.snapshotApplicationNonce &+= 1
        if runtime.snapshotApplicationNonce == 0 { runtime.snapshotApplicationNonce = 1 }
        let applicationNonce = runtime.snapshotApplicationNonce
        do {
            guard snapshot.id == runtime.callId,
                  snapshot.dialogId == runtime.dialogId else {
                throw GroupCallCryptoError.invalidIdentifier
            }
            try validateOwnIdentity(
                in: snapshot,
                identity: runtime.identity,
                session: session
            )
            try GroupCallCrypto.verifySnapshotTranscript(snapshot)
            guard snapshot.isActive else {
                await teardown(reportLeave: false, finalState: .ended)
                return
            }
            runtime.snapshot = snapshot
            activeCall = snapshot
            availableCalls[snapshot.dialogId] = snapshot
            let activeParticipantIds = Set(snapshot.participants
                .filter { $0.status == .active }
                .map(\.participantId))
            let cameraPublishers = Set(snapshot.cameraPublishers)
            guard cameraPublishers.isSubset(of: activeParticipantIds),
                  snapshot.screenShare.map({ activeParticipantIds.contains($0.participantId) }) ?? true
            else { throw GroupCallCryptoError.invalidParticipantSet }
            if !snapshot.rekeyRequired { securityState = .keyReady }
            try await runtime.engine.setAuthorizedParticipants(
                activeParticipantIds,
                cameraPublishers: cameraPublishers,
                screenPublisher: snapshot.screenShare?.participantId
            )
            guard snapshotApplicationIsCurrent(
                generation: generation,
                stateRevision: snapshot.stateRevision,
                nonce: applicationNonce
            ) else { return }
            rebuildPresentationParticipants()

            if snapshot.rekeyRequired {
                try await pauseMediaForRekey(generation: generation)
                guard snapshotApplicationIsCurrent(
                    generation: generation,
                    stateRevision: snapshot.stateRevision,
                    nonce: applicationNonce
                ) else { return }
                scheduleRekeyWatchdog(generation: generation)
                if snapshot.keyLeaderDeviceId == session?.deviceId {
                    scheduleRekey(snapshot: snapshot, generation: generation)
                }
                return
            }

            if runtime.currentEpoch?.epoch != snapshot.mediaEpoch {
                if snapshot.keyLeaderDeviceId == session?.deviceId {
                    // The leader installs its key from the exact successful epoch activation
                    // response. A server snapshot cannot manufacture plaintext key material.
                    guard runtime.currentEpoch?.epoch == snapshot.mediaEpoch else {
                        throw GroupCallCryptoError.invalidEnvelope
                    }
                } else {
                    guard let envelope = snapshot.selfEnvelope else {
                        state = .waitingForKey
                        return
                    }
                    let material = try GroupCallCrypto.open(
                        envelope: envelope,
                        snapshot: snapshot,
                        localIdentity: runtime.identity
                    )
                    try install(material, into: runtime)
                }
            }
            guard let material = runtime.currentEpoch,
                  material.epoch == snapshot.mediaEpoch else {
                state = .waitingForKey
                return
            }
            safetyEmojis = GroupCallCrypto.safetyEmojis(callId: snapshot.id, epoch: material)
            runtime.rekeyStartedAt = nil
            cancelRekeyWatchdog()
            mediaReducer.setSecureMediaReady(true, generation: generation)
            // Every membership epoch is preceded by a server-side participant removal and token
            // revocation. Even if LiveKit has not delivered its disconnect callback yet, the old
            // transport is no longer authorized and must be replaced with credentials fenced to
            // this exact epoch.
            if runtime.connectedEpoch != material.epoch || !runtime.engine.isConnected {
                guard let api, let session else { return }
                let credentials = try await api.groupCallCredentials(
                    id: runtime.callId,
                    token: session.token
                ).credentials
                guard snapshotApplicationIsCurrent(
                    generation: generation,
                    stateRevision: snapshot.stateRevision,
                    nonce: applicationNonce
                ) else { return }
                state = .connecting
                try await runtime.engine.connect(credentials: credentials)
                guard snapshotApplicationIsCurrent(
                    generation: generation,
                    stateRevision: snapshot.stateRevision,
                    nonce: applicationNonce
                ) else { return }
                runtime.connectedEpoch = material.epoch
            }
            await applyMediaDecision(generation: generation)
        } catch is CancellationError {
            return
        } catch {
            guard self.runtime === runtime,
                  snapshotApplicationIsCurrent(
                    generation: generation,
                    stateRevision: snapshot.stateRevision,
                    nonce: applicationNonce
                  ) else { return }
            await fail(error)
        }
    }

    private func snapshotApplicationIsCurrent(
        generation: UInt64,
        stateRevision: Int64,
        nonce: UInt64
    ) -> Bool {
        guard let runtime else { return false }
        return runtime.generation == generation
            && runtime.snapshot.stateRevision == stateRevision
            && runtime.snapshotApplicationNonce == nonce
    }

    private func scheduleRekey(
        snapshot: CloudGroupCallSnapshot,
        generation: UInt64
    ) {
        guard rekeyTask == nil else { return }
        runtime?.rekeyStartedAt = runtime?.rekeyStartedAt ?? clock.now
        rekeyTask = Task { [weak self] in
            guard let self else { return }
            defer { self.rekeyTask = nil }
            await self.performRekey(snapshot: snapshot, generation: generation)
        }
    }

    /// Immediately fail closed while group membership is between media epochs. The SFU removal
    /// is defense in depth: no participant is allowed to keep publishing with the previous key
    /// while a leader is slow, offline, or maliciously withholding the next epoch.
    private func pauseMediaForRekey(generation: UInt64) async throws {
        guard let runtime, runtime.generation == generation else { throw CancellationError() }
        runtime.rekeyStartedAt = runtime.rekeyStartedAt ?? clock.now
        securityState = .rekeying
        state = .waitingForKey
        mediaReducer.setSecureMediaReady(false, generation: generation)

        cameraHeartbeatTask?.cancel()
        cameraHeartbeatTask = nil
        screenHeartbeatTask?.cancel()
        screenHeartbeatTask = nil
        screenActivationTask?.cancel()
        screenActivationTask = nil
        let cameraGeneration = runtime.cameraGeneration
        let screenGeneration = runtime.screenGeneration
        let shouldStopScreen = screenGeneration != nil || isScreenSharing || isStartingScreenShare
        runtime.cameraGeneration = nil
        runtime.screenGeneration = nil
        mediaReducer.setScreenShareIntent(false)
        mediaReducer.setScreenLeaseHeld(false, generation: generation)

        do {
            // Launch every local stop before awaiting any one of them. In particular, a slow
            // camera unpublish must never leave ReplayKit sending frames under the previous epoch.
            async let microphoneStop: Void = runtime.engine.setMicrophone(enabled: false)
            async let cameraStop: Void = runtime.engine.setCamera(
                enabled: false,
                position: mediaReducer.preferredCamera,
                tier: qualityTier
            )
            async let screenStop: Bool = shouldStopScreen
                ? runtime.engine.setScreenShare(enabled: false)
                : false
            let (_, _, screenStillActive) = try await (microphoneStop, cameraStop, screenStop)
            guard !screenStillActive else { throw GroupCallEngineError.encryptionFailure }
        } catch {
            // If local publication cannot be disabled deterministically, disconnect rather than
            // risk sending media under a stale epoch.
            throw GroupCallEngineError.encryptionFailure
        }
        guard self.runtime?.generation == generation else { throw CancellationError() }
        runtime.appliedMicrophoneEnabled = false
        runtime.appliedCameraEnabled = false
        runtime.appliedCameraPosition = mediaReducer.preferredCamera
        runtime.appliedCameraTier = qualityTier
        isMuted = true
        isCameraEnabled = false
        isScreenSharing = false
        isStartingScreenShare = false
        scheduleLeaseRelease(
            callId: runtime.callId,
            cameraGeneration: cameraGeneration,
            screenGeneration: screenGeneration
        )
    }

    private func scheduleRekeyWatchdog(generation: UInt64) {
        guard rekeyWatchdogTask == nil else { return }
        rekeyWatchdogTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.clock.sleep(for: .seconds(10))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  let runtime = self.runtime,
                  runtime.generation == generation,
                  runtime.rekeyStartedAt != nil else { return }

            // Give a just-completed epoch one authoritative refresh before closing. This applies
            // to leaders and non-leaders so a stalled leader cannot leave peers publishing or
            // waiting forever.
            if let api = self.api, let session = self.session,
               let response = try? await api.groupCall(id: runtime.callId, token: session.token) {
                await self.processSnapshot(response.call, generation: generation)
            }
            guard !Task.isCancelled,
                  self.runtime?.generation == generation,
                  self.runtime?.rekeyStartedAt != nil else { return }
            await self.fail(GroupCallCryptoError.invalidEpoch)
        }
    }

    private func cancelRekeyWatchdog() {
        rekeyWatchdogTask?.cancel()
        rekeyWatchdogTask = nil
    }

    private func performRekey(
        snapshot initialSnapshot: CloudGroupCallSnapshot,
        generation: UInt64
    ) async {
        var snapshot = initialSnapshot
        var lastError: Error = GroupCallCryptoError.invalidEpoch

        while !Task.isCancelled {
            guard let runtime,
                  runtime.generation == generation,
                  let api,
                  let session else { return }

            do {
                guard snapshot.id == runtime.callId,
                      snapshot.dialogId == runtime.dialogId,
                      snapshot.isActive else {
                    throw GroupCallCryptoError.invalidIdentifier
                }
                try validateOwnIdentity(in: snapshot, identity: runtime.identity, session: session)
                try GroupCallCrypto.verifySnapshotTranscript(snapshot)
                guard snapshot.rekeyRequired,
                      snapshot.keyLeaderDeviceId == session.deviceId else {
                    await processSnapshot(snapshot, generation: generation)
                    return
                }

                let participantHash = try GroupCallCrypto.participantSetHash(snapshot.participants)
                let material = try GroupCallCrypto.makeEpoch(
                    callId: snapshot.id,
                    dialogId: snapshot.dialogId,
                    epoch: snapshot.mediaEpoch + 1,
                    membershipRevision: snapshot.membershipRevision,
                    participantSetHash: participantHash
                )
                let envelopes = try snapshot.participants
                    .filter { $0.deviceId != session.deviceId }
                    .map {
                        let sealed = try GroupCallCrypto.seal(
                            epoch: material,
                            callId: snapshot.id,
                            dialogId: snapshot.dialogId,
                            senderDeviceId: session.deviceId,
                            senderIdentity: runtime.identity,
                            recipient: $0
                        )
                        return GroupCallEpochRecipientEnvelope(
                            recipientDeviceId: sealed.recipientDeviceId,
                            ciphertext: sealed.ciphertext.base64EncodedString()
                        )
                    }
                let response = try await api.activateGroupCallEpoch(
                    id: snapshot.id,
                    body: ActivateCloudGroupCallEpochRequest(
                        epoch: material.epoch,
                        expectedMembershipRevision: material.membershipRevision,
                        keyCommitment: material.keyCommitment.base64EncodedString(),
                        participantSetHash: participantHash.base64EncodedString(),
                        envelopes: envelopes
                    ),
                    token: session.token
                )
                guard self.runtime?.generation == generation else { return }
                try GroupCallCrypto.verifySnapshotTranscript(response.call)
                guard response.call.mediaEpoch == material.epoch,
                      response.call.epoch.membershipRevision == material.membershipRevision,
                      Data(base64Encoded: response.call.epoch.keyCommitment) == material.keyCommitment,
                      Data(base64Encoded: response.call.epoch.participantSetHash) == participantHash
                else { throw GroupCallCryptoError.invalidCommitment }
                try install(material, into: runtime)
                await processSnapshot(response.call, generation: generation)
                return
            } catch {
                lastError = error
            }

            guard self.runtime?.generation == generation else { return }
            if let started = runtime.rekeyStartedAt,
               clock.now.timeIntervalSince(started) >= 10 {
                await fail(lastError)
                return
            }
            do {
                try await clock.sleep(for: .milliseconds(500))
                guard self.runtime?.generation == generation else { return }
                snapshot = try await api.groupCall(id: runtime.callId, token: session.token).call
            } catch {
                lastError = error
            }
        }
    }

    private func install(_ material: GroupCallEpochMaterial, into runtime: Runtime) throws {
        let previous = runtime.currentEpoch?.epoch
        try runtime.engine.installEpoch(material)
        runtime.currentEpoch = material
        if let previous, previous != material.epoch {
            scheduleRetirement(of: previous, generation: runtime.generation)
        }
    }

    private func scheduleRetirement(of epoch: Int64, generation: UInt64) {
        keyRetirementTasks[epoch]?.cancel()
        keyRetirementTasks[epoch] = Task { [weak self] in
            try? await self?.clock.sleep(for: .seconds(10))
            guard let self,
                  !Task.isCancelled,
                  self.runtime?.generation == generation,
                  self.runtime?.currentEpoch?.epoch != epoch else { return }
            self.runtime?.engine.retireEpoch(epoch)
            self.keyRetirementTasks[epoch] = nil
        }
    }

    private func startHeartbeat(generation: UInt64) {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            var failures = 0
            while let self, !Task.isCancelled, self.runtime?.generation == generation {
                do { try await self.clock.sleep(for: .seconds(20)) } catch { return }
                guard let runtime = self.runtime,
                      runtime.generation == generation,
                      let api = self.api,
                      let session = self.session else { return }
                do {
                    let response = try await api.heartbeatGroupCall(
                        id: runtime.callId,
                        token: session.token
                    )
                    failures = 0
                    if response.state != "active" {
                        await self.teardown(reportLeave: false, finalState: .ended)
                        return
                    }
                    if response.stateRevision > runtime.snapshot.stateRevision {
                        let latest = try await api.groupCall(id: runtime.callId, token: session.token)
                        await self.processSnapshot(latest.call, generation: generation)
                    }
                } catch {
                    failures += 1
                    if failures >= 4 {
                        await self.fail(error)
                        return
                    }
                }
            }
        }
    }

    private func startScreenShare() async {
        guard canShareScreen,
              let runtime,
              let api,
              let session,
              runtime.engine.isConnected,
              securityState == .keyReady || securityState == .verified,
              !runtime.snapshot.rekeyRequired,
              runtime.rekeyStartedAt == nil else {
            failureMessage = String(localized: "Screen sharing is not available in this build.")
            return
        }
        let generationId = UUID().uuidString.lowercased()
        do {
            let response = try await api.acquireGroupScreenShare(
                callId: runtime.callId,
                generation: generationId,
                token: session.token
            )
            guard !Task.isCancelled, self.runtime === runtime else {
                _ = try? await api.releaseGroupScreenShare(
                    callId: runtime.callId,
                    generation: generationId,
                    token: session.token
                )
                return
            }
            // Record ownership before applying the returned snapshot so a simultaneous rekey or
            // room end can compensate the server lease through the ordinary teardown path.
            runtime.screenGeneration = generationId
            mediaReducer.setScreenExtensionReady(true)
            mediaReducer.setScreenLeaseHeld(true, generation: runtime.generation)
            mediaReducer.setScreenShareIntent(true)
            if let snapshot = response.call {
                await processSnapshot(snapshot, generation: runtime.generation)
                guard !Task.isCancelled,
                      self.runtime === runtime,
                      runtime.screenGeneration == generationId else { return }
            }
            guard !runtime.snapshot.rekeyRequired,
                  runtime.rekeyStartedAt == nil,
                  mediaReducer.decision(now: clock.now).screenShareAllowed else {
                await stopScreenShare(for: runtime)
                return
            }
            isStartingScreenShare = true
            startScreenHeartbeat(runtimeGeneration: runtime.generation, leaseGeneration: generationId)
            let active = try await runtime.engine.setScreenShare(enabled: true)
            guard !Task.isCancelled,
                  self.runtime === runtime,
                  runtime.screenGeneration == generationId,
                  !runtime.snapshot.rekeyRequired,
                  runtime.rekeyStartedAt == nil,
                  mediaReducer.decision(now: clock.now).screenShareAllowed else {
                _ = try? await runtime.engine.setScreenShare(enabled: false)
                _ = try? await api.releaseGroupScreenShare(
                    callId: runtime.callId,
                    generation: generationId,
                    token: session.token
                )
                return
            }
            isScreenSharing = active
            isStartingScreenShare = !active
            if !active {
                startScreenActivationRetry(
                    runtimeGeneration: runtime.generation,
                    leaseGeneration: generationId
                )
            }
        } catch {
            guard self.runtime === runtime else { return }
            failureMessage = error.localizedDescription
            await stopScreenShare(for: runtime)
        }
    }

    private func startScreenActivationRetry(
        runtimeGeneration: UInt64,
        leaseGeneration: String
    ) {
        screenActivationTask?.cancel()
        screenActivationTask = Task { [weak self] in
            for _ in 0..<20 {
                guard let self,
                      !Task.isCancelled,
                      let runtime = self.runtime,
                      runtime.generation == runtimeGeneration,
                      runtime.screenGeneration == leaseGeneration,
                      !runtime.snapshot.rekeyRequired,
                      runtime.rekeyStartedAt == nil else { return }
                do { try await self.clock.sleep(for: .seconds(1)) } catch { return }
                guard !Task.isCancelled,
                      self.runtime === runtime,
                      runtime.screenGeneration == leaseGeneration,
                      self.mediaReducer.decision(now: self.clock.now).screenShareAllowed else {
                    return
                }
                let active = (try? await runtime.engine.setScreenShare(enabled: true)) == true
                guard !Task.isCancelled,
                      self.runtime === runtime,
                      runtime.screenGeneration == leaseGeneration,
                      !runtime.snapshot.rekeyRequired,
                      runtime.rekeyStartedAt == nil,
                      self.mediaReducer.decision(now: self.clock.now).screenShareAllowed else {
                    if active { _ = try? await runtime.engine.setScreenShare(enabled: false) }
                    return
                }
                if active {
                    self.isStartingScreenShare = false
                    self.isScreenSharing = true
                    return
                }
            }
            guard let self, let runtime = self.runtime,
                  runtime.generation == runtimeGeneration,
                  runtime.screenGeneration == leaseGeneration else { return }
            await self.stopScreenShare(for: runtime)
        }
    }

    private func startScreenHeartbeat(runtimeGeneration: UInt64, leaseGeneration: String) {
        screenHeartbeatTask?.cancel()
        screenHeartbeatTask = Task { [weak self] in
            var transientFailures = 0
            var nextDelay = Duration.seconds(5)
            while let self, !Task.isCancelled {
                do { try await self.clock.sleep(for: nextDelay) } catch { return }
                nextDelay = .seconds(5)
                guard let runtime = self.runtime,
                      runtime.generation == runtimeGeneration,
                      runtime.screenGeneration == leaseGeneration,
                      let api = self.api,
                      let session = self.session else { return }
                do {
                    let response = try await api.heartbeatGroupScreenShare(
                        callId: runtime.callId,
                        generation: leaseGeneration,
                        token: session.token
                    )
                    guard !Task.isCancelled,
                          self.runtime === runtime,
                          runtime.screenGeneration == leaseGeneration else { return }
                    transientFailures = 0
                    if let snapshot = response.call {
                        await self.processSnapshot(snapshot, generation: runtimeGeneration)
                    }
                } catch {
                    transientFailures += 1
                    if case .transient = cloudFailureDisposition(error), transientFailures < 2 {
                        // Retry inside the 15-second lease instead of waiting another full interval.
                        nextDelay = .milliseconds(500)
                        continue
                    }
                    guard self.runtime === runtime,
                          runtime.screenGeneration == leaseGeneration else { return }
                    await self.stopScreenShare(for: runtime)
                    return
                }
            }
        }
    }

    private func stopScreenShare(for expectedRuntime: Runtime? = nil) async {
        if let expectedRuntime, runtime !== expectedRuntime { return }
        screenHeartbeatTask?.cancel()
        screenHeartbeatTask = nil
        screenActivationTask?.cancel()
        screenActivationTask = nil
        guard let runtime else {
            isScreenSharing = false
            isStartingScreenShare = false
            return
        }
        let leaseGeneration = runtime.screenGeneration
        runtime.screenGeneration = nil
        mediaReducer.setScreenShareIntent(false)
        mediaReducer.setScreenLeaseHeld(false, generation: runtime.generation)
        _ = try? await runtime.engine.setScreenShare(enabled: false)
        if let leaseGeneration, let api, let session {
            _ = try? await api.releaseGroupScreenShare(
                callId: runtime.callId,
                generation: leaseGeneration,
                token: session.token
            )
        }
        if self.runtime === runtime {
            isScreenSharing = false
            isStartingScreenShare = false
        }
    }

    private func applyMediaDecision(generation: UInt64) async {
        guard runtime?.generation == generation else { return }
        mediaDecisionPending = true
        guard !mediaDecisionRunning else { return }
        mediaDecisionRunning = true
        mediaDecisionGeneration = generation
        defer {
            if mediaDecisionGeneration == generation {
                mediaDecisionRunning = false
                mediaDecisionGeneration = nil
            }
        }
        while mediaDecisionPending,
              !Task.isCancelled,
              runtime?.generation == generation {
            mediaDecisionPending = false
            await applyMediaDecisionOnce(generation: generation)
        }
    }

    private func applyMediaDecisionOnce(generation: UInt64) async {
        guard let runtime, runtime.generation == generation, runtime.engine.isConnected else { return }
        var decision = mediaReducer.decision(now: clock.now)
        qualityTier = decision.qualityTier
        if (isScreenSharing || isStartingScreenShare) && !decision.screenShareAllowed {
            await stopScreenShare()
            guard self.runtime?.generation == generation else { return }
        }
        do {
            if runtime.appliedMicrophoneEnabled != decision.microphoneActive {
                try await runtime.engine.setMicrophone(enabled: decision.microphoneActive)
                guard !Task.isCancelled, self.runtime === runtime else {
                    if decision.microphoneActive {
                        try? await runtime.engine.setMicrophone(enabled: false)
                    }
                    return
                }
                let latest = mediaReducer.decision(now: clock.now)
                guard latest.microphoneActive == decision.microphoneActive else {
                    if decision.microphoneActive {
                        try? await runtime.engine.setMicrophone(enabled: false)
                        runtime.appliedMicrophoneEnabled = false
                    }
                    mediaDecisionPending = true
                    return
                }
                runtime.appliedMicrophoneEnabled = decision.microphoneActive
            }
            guard !Task.isCancelled, self.runtime === runtime else { return }
            isMuted = !decision.microphoneActive
        } catch {
            guard self.runtime === runtime else { return }
            isMuted = true
            if decision.microphoneActive {
                failureMessage = String(localized: "The microphone is unavailable. Tap mute to try again.")
            } else {
                // A requested security mute must be enforceable. Disconnect if the engine cannot
                // prove that publication stopped.
                await fail(GroupCallEngineError.encryptionFailure)
            }
            return
        }

        do {
            if decision.cameraActive {
                if !isCameraEnabled { mediaReducer.resetNetworkAdaptation() }
                try await ensureCameraLease(for: runtime)
            }
            guard !Task.isCancelled, self.runtime === runtime else { return }
            decision = mediaReducer.decision(now: clock.now)
            qualityTier = decision.qualityTier
            if !decision.cameraActive {
                await releaseCameraLease(for: runtime)
                guard self.runtime === runtime else { return }
            }
            if runtime.appliedCameraEnabled != decision.cameraActive
                || runtime.appliedCameraPosition != mediaReducer.preferredCamera
                || runtime.appliedCameraTier != decision.qualityTier {
                try await runtime.engine.setCamera(
                    enabled: decision.cameraActive,
                    position: mediaReducer.preferredCamera,
                    tier: decision.qualityTier
                )
                guard !Task.isCancelled, self.runtime === runtime else {
                    if decision.cameraActive {
                        try? await runtime.engine.setCamera(
                            enabled: false,
                            position: mediaReducer.preferredCamera,
                            tier: decision.qualityTier
                        )
                    }
                    return
                }
                let latest = mediaReducer.decision(now: clock.now)
                guard latest.cameraActive == decision.cameraActive,
                      latest.qualityTier == decision.qualityTier else {
                    if decision.cameraActive && !latest.cameraActive {
                        try? await runtime.engine.setCamera(
                            enabled: false,
                            position: mediaReducer.preferredCamera,
                            tier: latest.qualityTier
                        )
                        runtime.appliedCameraEnabled = false
                        await releaseCameraLease(for: runtime)
                    }
                    mediaDecisionPending = true
                    return
                }
                runtime.appliedCameraEnabled = decision.cameraActive
                runtime.appliedCameraPosition = mediaReducer.preferredCamera
                runtime.appliedCameraTier = decision.qualityTier
            }
            guard !Task.isCancelled, self.runtime === runtime else { return }
            if !decision.cameraActive {
                await releaseCameraLease(for: runtime)
            }
            isCameraEnabled = decision.cameraActive
            cameraPosition = mediaReducer.preferredCamera
        } catch is CancellationError {
            if self.runtime === runtime { mediaDecisionPending = true }
        } catch {
            guard self.runtime === runtime else { return }
            mediaReducer.setCameraIntent(false)
            try? await runtime.engine.setCamera(
                enabled: false,
                position: mediaReducer.preferredCamera,
                tier: decision.qualityTier
            )
            runtime.appliedCameraEnabled = false
            runtime.appliedCameraPosition = mediaReducer.preferredCamera
            runtime.appliedCameraTier = decision.qualityTier
            await releaseCameraLease(for: runtime)
            isCameraEnabled = false
            failureMessage = String(localized: "A media device became unavailable.")
        }
    }

    private func ensureCameraLease(for runtime: Runtime) async throws {
        guard let api, let session else { throw GroupCallEngineError.notConnected }
        if runtime.cameraGeneration != nil {
            guard !Task.isCancelled,
                  self.runtime === runtime,
                  mediaReducer.decision(now: clock.now).cameraActive else {
                throw CancellationError()
            }
            return
        }
        let leaseGeneration = UUID().uuidString.lowercased()
        let response = try await api.acquireGroupCamera(
            callId: runtime.callId,
            generation: leaseGeneration,
            token: session.token
        )
        guard !Task.isCancelled,
              self.runtime === runtime,
              !runtime.snapshot.rekeyRequired,
              runtime.rekeyStartedAt == nil,
              mediaReducer.decision(now: clock.now).cameraActive else {
            _ = try? await api.releaseGroupCamera(
                callId: runtime.callId,
                generation: leaseGeneration,
                token: session.token
            )
            throw CancellationError()
        }
        runtime.cameraGeneration = leaseGeneration
        startCameraHeartbeat(runtimeGeneration: runtime.generation, leaseGeneration: leaseGeneration)
        if let snapshot = response.call {
            await processSnapshot(snapshot, generation: runtime.generation)
            guard !Task.isCancelled,
                  self.runtime === runtime,
                  runtime.cameraGeneration == leaseGeneration,
                  !runtime.snapshot.rekeyRequired,
                  runtime.rekeyStartedAt == nil,
                  mediaReducer.decision(now: clock.now).cameraActive else {
                if self.runtime === runtime, runtime.cameraGeneration == leaseGeneration {
                    await releaseCameraLease(for: runtime)
                }
                throw CancellationError()
            }
        }
    }

    private func releaseCameraLease(for runtime: Runtime) async {
        guard self.runtime === runtime else { return }
        cameraHeartbeatTask?.cancel()
        cameraHeartbeatTask = nil
        guard let leaseGeneration = runtime.cameraGeneration else { return }
        runtime.cameraGeneration = nil
        if let api, let session {
            _ = try? await api.releaseGroupCamera(
                callId: runtime.callId,
                generation: leaseGeneration,
                token: session.token
            )
        }
    }

    /// Media capture is already stopped before this is called. Lease cleanup is intentionally
    /// detached so a degraded control path cannot delay an authenticated epoch transition.
    private func scheduleLeaseRelease(
        callId: String,
        cameraGeneration: String?,
        screenGeneration: String?
    ) {
        guard cameraGeneration != nil || screenGeneration != nil,
              let api,
              let session else { return }
        Task {
            if let cameraGeneration {
                _ = try? await api.releaseGroupCamera(
                    callId: callId,
                    generation: cameraGeneration,
                    token: session.token
                )
            }
            if let screenGeneration {
                _ = try? await api.releaseGroupScreenShare(
                    callId: callId,
                    generation: screenGeneration,
                    token: session.token
                )
            }
        }
    }

    private func startCameraHeartbeat(runtimeGeneration: UInt64, leaseGeneration: String) {
        cameraHeartbeatTask?.cancel()
        cameraHeartbeatTask = Task { [weak self] in
            var transientFailures = 0
            var nextDelay = Duration.seconds(5)
            while let self, !Task.isCancelled {
                do { try await self.clock.sleep(for: nextDelay) } catch { return }
                nextDelay = .seconds(5)
                guard let runtime = self.runtime,
                      runtime.generation == runtimeGeneration,
                      runtime.cameraGeneration == leaseGeneration,
                      let api = self.api,
                      let session = self.session else { return }
                do {
                    let response = try await api.heartbeatGroupCamera(
                        callId: runtime.callId,
                        generation: leaseGeneration,
                        token: session.token
                    )
                    guard !Task.isCancelled,
                          self.runtime === runtime,
                          runtime.cameraGeneration == leaseGeneration else { return }
                    transientFailures = 0
                    if let snapshot = response.call {
                        await self.processSnapshot(snapshot, generation: runtimeGeneration)
                    }
                } catch {
                    transientFailures += 1
                    if case .transient = cloudFailureDisposition(error), transientFailures < 2 {
                        // Retry inside the 15-second lease instead of waiting another full interval.
                        nextDelay = .milliseconds(500)
                        continue
                    }
                    guard self.runtime === runtime,
                          runtime.cameraGeneration == leaseGeneration else { return }
                    runtime.cameraGeneration = nil
                    self.mediaReducer.setCameraIntent(false)
                    try? await runtime.engine.setCamera(
                        enabled: false,
                        position: self.mediaReducer.preferredCamera,
                        tier: self.qualityTier
                    )
                    guard self.runtime === runtime else { return }
                    runtime.appliedCameraEnabled = false
                    runtime.appliedCameraPosition = self.mediaReducer.preferredCamera
                    runtime.appliedCameraTier = self.qualityTier
                    self.isCameraEnabled = false
                    self.failureMessage = String(localized: "Camera publishing was paused because its secure lease expired.")
                    return
                }
            }
        }
    }

    private func handleEngineEvent(
        _ event: GroupCallEngineEvent,
        generation: UInt64,
        engineIdentity: ObjectIdentifier
    ) {
        guard let runtime,
              runtime.generation == generation,
              ObjectIdentifier(runtime.engine) == engineIdentity else { return }
        switch event {
        case .connection(let connection):
            switch connection {
            case .connected:
                guard !runtime.snapshot.rekeyRequired,
                      runtime.rekeyStartedAt == nil else {
                    state = .waitingForKey
                    return
                }
                state = .connected
                runtime.appliedMicrophoneEnabled = nil
                runtime.appliedCameraEnabled = nil
                runtime.appliedCameraPosition = nil
                runtime.appliedCameraTier = nil
                connectedAt = connectedAt ?? clock.now
                startQualitySampling(generation: runtime.generation)
                connectionRecoveryTask?.cancel()
                connectionRecoveryTask = Task { [weak self] in
                    await self?.restoreMediaAfterConnection(generation: runtime.generation)
                }
            case .connecting:
                state = runtime.rekeyStartedAt == nil ? .connecting : .waitingForKey
            case .reconnecting:
                state = runtime.rekeyStartedAt == nil ? .reconnecting : .waitingForKey
                mediaReducer.resetNetworkAdaptation()
                runtime.appliedMicrophoneEnabled = nil
                runtime.appliedCameraEnabled = nil
                runtime.appliedCameraPosition = nil
                runtime.appliedCameraTier = nil
            case .disconnected:
                if state != .ending && state != .ended && state != .failed {
                    state = runtime.rekeyStartedAt == nil ? .reconnecting : .waitingForKey
                }
            }
        case .participants(let engineParticipants):
            let allowed = Set(runtime.snapshot.participants
                .filter { $0.status == .active }
                .map(\.participantId))
            guard engineParticipants.allSatisfy({ allowed.contains($0.id) }) else {
                Task { await self.fail(GroupCallCryptoError.invalidParticipantSet) }
                return
            }
            rebuildPresentationParticipants(engineParticipants: engineParticipants)
        case .videoTracks(let tracks):
            let allowed = Set(runtime.snapshot.participants
                .filter { $0.status == .active }
                .map(\.participantId))
            let cameraPublishers = Set(runtime.snapshot.cameraPublishers)
            let screenPublisher = runtime.snapshot.screenShare?.participantId
            guard tracks.allSatisfy({ track in
                guard allowed.contains(track.participantId) else { return false }
                return switch track.source {
                case .camera: cameraPublishers.contains(track.participantId)
                case .screenShare: screenPublisher == track.participantId
                }
            }) else {
                Task { await self.fail(GroupCallCryptoError.invalidParticipantSet) }
                return
            }
            videoTracks = tracks
        case .encryptionState(let epoch, let expectedTrackIds, let verifiedTrackIds):
            guard runtime.currentEpoch?.epoch == epoch,
                  runtime.rekeyStartedAt == nil,
                  !runtime.snapshot.rekeyRequired else { return }
            securityState = !expectedTrackIds.isEmpty
                && expectedTrackIds.isSubset(of: verifiedTrackIds)
                ? .verified
                : .keyReady
        case .encryptionWarning(let epoch, _, _):
            guard runtime.currentEpoch?.epoch == epoch,
                  runtime.rekeyStartedAt == nil,
                  !runtime.snapshot.rekeyRequired else { return }
            // Individual cryptors can report a short missing-key transition while a track is
            // attaching. Drop the verified claim immediately; the engine escalates only after
            // repeated failures for this exact epoch.
            securityState = .keyReady
        case .encryptionFailure(let epoch, _, _):
            guard runtime.currentEpoch?.epoch == epoch else { return }
            Task { await self.fail(GroupCallEngineError.encryptionFailure) }
        }
    }

    private func refreshCurrentCall(generation: UInt64) async {
        guard let runtime,
              runtime.generation == generation,
              let api,
              let session,
              let response = try? await api.groupCall(id: runtime.callId, token: session.token)
        else { return }
        await processSnapshot(response.call, generation: generation)
    }

    private func restoreMediaAfterConnection(generation: UInt64) async {
        guard let runtime,
              runtime.generation == generation,
              !runtime.snapshot.rekeyRequired,
              runtime.rekeyStartedAt == nil,
              let api,
              let session else { return }

        if let leaseGeneration = runtime.cameraGeneration {
            do {
                let response = try await api.acquireGroupCamera(
                    callId: runtime.callId,
                    generation: leaseGeneration,
                    token: session.token
                )
                guard !Task.isCancelled,
                      self.runtime === runtime,
                      runtime.cameraGeneration == leaseGeneration else { return }
                if let snapshot = response.call {
                    await processSnapshot(snapshot, generation: generation)
                }
                guard !Task.isCancelled,
                      self.runtime === runtime,
                      runtime.cameraGeneration == leaseGeneration,
                      !runtime.snapshot.rekeyRequired,
                      runtime.rekeyStartedAt == nil,
                      mediaReducer.decision(now: clock.now).cameraActive else { return }
                startCameraHeartbeat(
                    runtimeGeneration: generation,
                    leaseGeneration: leaseGeneration
                )
            } catch {
                guard self.runtime === runtime,
                      runtime.cameraGeneration == leaseGeneration else { return }
                cameraHeartbeatTask?.cancel()
                cameraHeartbeatTask = nil
                runtime.cameraGeneration = nil
                mediaReducer.setCameraIntent(false)
                try? await runtime.engine.setCamera(
                    enabled: false,
                    position: mediaReducer.preferredCamera,
                    tier: qualityTier
                )
                guard self.runtime === runtime else { return }
                runtime.appliedCameraEnabled = false
                runtime.appliedCameraPosition = mediaReducer.preferredCamera
                runtime.appliedCameraTier = qualityTier
                _ = try? await api.releaseGroupCamera(
                    callId: runtime.callId,
                    generation: leaseGeneration,
                    token: session.token
                )
                isCameraEnabled = false
                failureMessage = String(localized: "Camera publishing could not be restored after reconnecting.")
            }
        }

        if let leaseGeneration = runtime.screenGeneration {
            do {
                let response = try await api.acquireGroupScreenShare(
                    callId: runtime.callId,
                    generation: leaseGeneration,
                    token: session.token
                )
                guard !Task.isCancelled,
                      self.runtime === runtime,
                      runtime.screenGeneration == leaseGeneration else { return }
                if let snapshot = response.call {
                    await processSnapshot(snapshot, generation: generation)
                }
                guard !Task.isCancelled,
                      self.runtime === runtime,
                      runtime.screenGeneration == leaseGeneration,
                      !runtime.snapshot.rekeyRequired,
                      runtime.rekeyStartedAt == nil,
                      mediaReducer.decision(now: clock.now).screenShareAllowed else { return }
                startScreenHeartbeat(
                    runtimeGeneration: generation,
                    leaseGeneration: leaseGeneration
                )
                let active = try await runtime.engine.setScreenShare(enabled: true)
                guard !Task.isCancelled,
                      self.runtime === runtime,
                      runtime.screenGeneration == leaseGeneration,
                      !runtime.snapshot.rekeyRequired,
                      runtime.rekeyStartedAt == nil,
                      mediaReducer.decision(now: clock.now).screenShareAllowed else {
                    if active { _ = try? await runtime.engine.setScreenShare(enabled: false) }
                    return
                }
                isScreenSharing = active
                isStartingScreenShare = !active
                if !active {
                    startScreenActivationRetry(
                        runtimeGeneration: generation,
                        leaseGeneration: leaseGeneration
                    )
                }
            } catch {
                guard self.runtime === runtime,
                      runtime.screenGeneration == leaseGeneration else { return }
                failureMessage = String(localized: "Screen sharing stopped while the call reconnected.")
                await stopScreenShare(for: runtime)
            }
        }

        await applyMediaDecision(generation: generation)
    }

    private func startQualitySampling(generation: UInt64) {
        qualityTask?.cancel()
        qualityTask = Task { [weak self] in
            while let self, !Task.isCancelled, self.runtime?.generation == generation {
                do { try await self.clock.sleep(for: .seconds(1)) } catch { return }
                guard let runtime = self.runtime,
                      runtime.generation == generation else { return }
                let sample = await runtime.engine.senderSample()
                guard self.runtime?.generation == generation else { return }
                self.mediaReducer.setDataUsagePolicy(
                    CallPrivacyPreferences.shared.dataUsagePolicy
                )
                self.mediaReducer.recordSenderSample(sample)
                await self.applyMediaDecision(generation: generation)
            }
        }
    }

    private func rebuildPresentationParticipants(
        engineParticipants: [GroupCallEngineParticipant] = []
    ) {
        guard let snapshot = activeCall else {
            participants = []
            return
        }
        let media = Dictionary(uniqueKeysWithValues: engineParticipants.map { ($0.id, $0) })
        participants = snapshot.participants
            .filter { $0.status == .active }
            .map { participant in
                let state = media[participant.participantId]
                return GroupCallPresentationParticipant(
                    id: participant.deviceId,
                    accountId: participant.accountId,
                    participantId: participant.participantId,
                    displayName: participantName?(participant.accountId, snapshot.dialogId)
                        ?? String(participant.accountId.prefix(8)),
                    isSelf: participant.isSelf,
                    isSpeaking: state?.isSpeaking ?? false,
                    connectionQuality: state?.connectionQuality ?? "unknown",
                    hasCamera: state?.hasCamera ?? false,
                    hasScreenShare: state?.hasScreenShare ?? false
                )
            }
            .sorted {
                if $0.isSelf != $1.isSelf { return $0.isSelf }
                if $0.isSpeaking != $1.isSpeaking { return $0.isSpeaking }
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
    }

    private func validateOwnIdentity(
        in snapshot: CloudGroupCallSnapshot,
        identity: GroupCallJoinIdentity,
        session: CloudSession?
    ) throws {
        guard let session,
              let own = snapshot.selfParticipant,
              own.accountId == session.accountId,
              own.deviceId == session.deviceId,
              own.joinPublicKey == identity.publicKey.base64EncodedString(),
              own.joinNonce == identity.nonce.base64EncodedString()
        else { throw GroupCallCryptoError.recipientMismatch }
    }

    private func fail(_ error: Error) async {
        failureMessage = userMessage(for: error)
        securityState = (error is GroupCallCryptoError || error is GroupCallEngineError)
            ? .failed : securityState
        await teardown(reportLeave: true, finalState: .failed)
    }

    private func teardown(
        reportLeave: Bool,
        finalState: GroupCallConnectionState
    ) async {
        guard let retiringRuntime = runtime else {
            mediaReducer.endRuntime()
            state = finalState
            return
        }
        state = .ending
        // Claim the runtime before the first await. Every in-flight permission, lease, ReplayKit,
        // and engine callback now fails its identity/generation check and cannot resurrect media.
        runtime = nil
        retiringRuntime.engine.onEvent = nil
        mediaReducer.endRuntime()
        let teardownGeneration = mediaReducer.generation
        heartbeatTask?.cancel()
        heartbeatTask = nil
        rekeyTask?.cancel()
        rekeyTask = nil
        cancelRekeyWatchdog()
        connectionRecoveryTask?.cancel()
        connectionRecoveryTask = nil
        qualityTask?.cancel()
        qualityTask = nil
        screenHeartbeatTask?.cancel()
        screenHeartbeatTask = nil
        screenActivationTask?.cancel()
        screenActivationTask = nil
        cameraHeartbeatTask?.cancel()
        cameraHeartbeatTask = nil
        for task in keyRetirementTasks.values { task.cancel() }
        keyRetirementTasks.removeAll()
        let api = self.api
        let session = self.session
        let cameraGeneration = retiringRuntime.cameraGeneration
        let screenGeneration = retiringRuntime.screenGeneration
        retiringRuntime.cameraGeneration = nil
        retiringRuntime.screenGeneration = nil
        if availableCalls[retiringRuntime.dialogId]?.id == retiringRuntime.callId {
            availableCalls[retiringRuntime.dialogId] = nil
        }
        activeCall = nil
        participants = []
        videoTracks = []
        isMuted = true
        isCameraEnabled = false
        isScreenSharing = false
        isStartingScreenShare = false
        mediaDecisionPending = false
        mediaDecisionRunning = false
        mediaDecisionGeneration = nil
        connectedAt = nil

        // Start every local stop together; disconnect is the final fence after all publication
        // calls settle. Their failures are irrelevant because disconnect still closes transport.
        async let microphoneStop: Void? = try? await retiringRuntime.engine.setMicrophone(enabled: false)
        async let cameraStop: Void? = try? await retiringRuntime.engine.setCamera(
            enabled: false,
            position: mediaReducer.preferredCamera,
            tier: qualityTier
        )
        async let screenStop: Bool? = try? await retiringRuntime.engine.setScreenShare(enabled: false)
        _ = await (microphoneStop, cameraStop, screenStop)
        await retiringRuntime.engine.disconnect()
        if runtime == nil, mediaReducer.generation == teardownGeneration {
            state = finalState
        }

        // Local capture and transport are already stopped. Network cleanup is deliberately
        // detached from the user's Leave action; renewable server leases and stale-participant
        // cleanup are the crash-safe fallback if these best-effort calls time out.
        if let api, let session {
            let callId = retiringRuntime.callId
            Task {
                if reportLeave {
                    _ = try? await api.leaveGroupCall(id: callId, token: session.token)
                } else {
                    if let cameraGeneration {
                        _ = try? await api.releaseGroupCamera(
                            callId: callId,
                            generation: cameraGeneration,
                            token: session.token
                        )
                    }
                    if let screenGeneration {
                        _ = try? await api.releaseGroupScreenShare(
                            callId: callId,
                            generation: screenGeneration,
                            token: session.token
                        )
                    }
                }
            }
        }
    }

    private func resetPresentation() {
        state = .idle
        securityState = .preparing
        failureMessage = nil
        safetyEmojis = []
        title = String(localized: "Group call")
    }

    private func presentFailure(_ message: String) {
        failureMessage = message
        state = .failed
        isPresented = true
    }

    private func userMessage(for error: Error) -> String {
        if let apiError = error as? CloudAPIError {
            switch apiError.code {
            case "call_already_active": return String(localized: "A group call is already active. Join it instead.")
            case "participant_limit_reached": return String(localized: "This call has reached its participant limit.")
            case "joined_elsewhere": return String(localized: "This account is already in the call on another device.")
            case "screen_share_busy": return String(localized: "Another participant is already sharing their screen.")
            case "publisher_limit_reached": return String(localized: "This call has reached its camera limit. You can keep participating with audio.")
            case "camera_lease_superseded", "camera_lease_expired": return String(localized: "Camera publishing was safely paused. Tap the camera button to try again.")
            case "sfu_control_unavailable": return String(localized: "Group media is temporarily unavailable. Your microphone and camera were kept private.")
            case "device_capability_unavailable": return String(localized: "Update Toj on this device to join encrypted group calls.")
            default: return apiError.message
            }
        }
        if error is GroupCallCryptoError || error is GroupCallEngineError {
            return String(localized: "The encrypted group call failed a security check and was closed.")
        }
        return error.localizedDescription
    }

    private func installLifecycleObservers() {
        let center = NotificationCenter.default
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.mediaReducer.setForeground(false)
                guard let generation = self?.runtime?.generation else { return }
                await self?.applyMediaDecision(generation: generation)
            }
        })
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.mediaReducer.setForeground(true)
                guard let generation = self?.runtime?.generation else { return }
                await self?.refreshCurrentCall(generation: generation)
                await self?.applyMediaDecision(generation: generation)
            }
        })
        lifecycleObservers.append(center.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.applyThermalState() }
        })
        lifecycleObservers.append(center.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.mediaReducer.setCaptureInterrupted(true)
                self?.failureMessage = String(localized: "Camera paused because another app or system service is using it.")
                guard let generation = self?.runtime?.generation else { return }
                await self?.applyMediaDecision(generation: generation)
            }
        })
        lifecycleObservers.append(center.addObserver(
            forName: AVCaptureSession.interruptionEndedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.mediaReducer.setCaptureInterrupted(false)
                guard let generation = self?.runtime?.generation else { return }
                await self?.applyMediaDecision(generation: generation)
            }
        })
        lifecycleObservers.append(center.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.mediaReducer.setCaptureInterrupted(true)
                self?.failureMessage = String(localized: "Camera paused after a capture error. Toj will retry when it is available.")
                guard let generation = self?.runtime?.generation else { return }
                await self?.applyMediaDecision(generation: generation)
            }
        })
        lifecycleObservers.append(center.addObserver(
            forName: AVCaptureSession.didStartRunningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.mediaReducer.setCaptureInterrupted(false)
                guard let generation = self?.runtime?.generation else { return }
                await self?.applyMediaDecision(generation: generation)
            }
        })
    }

    private func installCameraPressureObservers() {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera],
            mediaType: .video,
            position: .unspecified
        )
        cameraPressureObservers = discovery.devices.map { device in
            device.observe(\.systemPressureState, options: [.initial, .new]) { [weak self] device, _ in
                let pressureLevel = device.systemPressureState.level
                let pressured = pressureLevel == .serious
                    || pressureLevel == .critical
                    || pressureLevel == .shutdown
                let id = device.uniqueID
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if pressured {
                        pressuredCameraIds.insert(id)
                    } else {
                        pressuredCameraIds.remove(id)
                    }
                    mediaReducer.setSystemPressure(!pressuredCameraIds.isEmpty)
                    guard let generation = runtime?.generation else { return }
                    await applyMediaDecision(generation: generation)
                }
            }
        }
    }

    private func applyThermalState() {
        let state: GroupCallThermalState = switch ProcessInfo.processInfo.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .critical
        }
        mediaReducer.setThermalState(state, now: clock.now)
        guard let generation = runtime?.generation else { return }
        Task { await applyMediaDecision(generation: generation) }
    }

    private func startNetworkObservation() {
        networkTask = Task { [weak self] in
            for await snapshot in ReplicaNetworkMonitor.shared.updates() {
                guard let self, !Task.isCancelled else { return }
                let groupClass: GroupCallNetworkClass = if snapshot.networkClass == .offline {
                    .offline
                } else if snapshot.isRoaming {
                    .roaming
                } else if snapshot.isConstrained {
                    .constrained
                } else if snapshot.networkClass == .cellular {
                    .cellular
                } else {
                    .wifi
                }
                if self.previousNetworkSnapshot != snapshot {
                    self.mediaReducer.resetNetworkAdaptation()
                    self.previousNetworkSnapshot = snapshot
                }
                self.mediaReducer.setDataUsagePolicy(CallPrivacyPreferences.shared.dataUsagePolicy)
                self.weakNetwork = groupClass == .constrained
                    || groupClass == .roaming
                    || groupClass == .offline
                self.mediaReducer.setNetworkClass(groupClass)
                if let generation = self.runtime?.generation {
                    await self.applyMediaDecision(generation: generation)
                }
            }
        }
    }
}
