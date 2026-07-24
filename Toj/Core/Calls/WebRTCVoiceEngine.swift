import AVFoundation
import Foundation
@preconcurrency import ObjectiveC

#if canImport(WebRTC)
@preconcurrency import WebRTC
#endif

#if canImport(WebRTC)

private actor CallCaptureOperationGate {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isLocked {
            isLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            isLocked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// Audio/video adapter around the pinned, official WebRTC iOS framework.
///
/// The adapter is main-actor isolated so all mutations of the ObjC WebRTC
/// graph are serialized. WebRTC invokes delegate methods on its own threads;
/// those callbacks immediately hop back to the main actor before touching
/// state or emitting events.
@MainActor
final class WebRTCCallEngine: NSObject, WebRTCEngine {
    /// The encrypted signaling plaintext limit is 64 KiB. SDP is restricted
    /// to ASCII and 30 KiB, so even the worst case where every byte requires
    /// JSON escaping remains below that limit with the wire envelope included.
    private static let maximumSignaledSDPBytes = 30 * 1_024
    private static let maximumCandidateBytes = 2_048
    /// This is a ceiling, not a target. WebRTC's congestion controller and
    /// Opus continue adapting below 32 kbps (including constrained ~20 kbps
    /// operation) from packet loss, RTT, and available-bandwidth feedback.
    private static let maximumAudioBitrateBps = 32_000
    #if DEBUG
    static private(set) var lastGeneratedSDPForTesting: String?
    static private(set) var lastSDPValidationFailureForTesting: String?
    static private(set) var lastMediaReassertFailureForTesting: String?
    #endif

    private static let initializeSSLOnce: Bool = {
        RTCInitializeSSL()
    }()

    private let factory: RTCPeerConnectionFactory?
    private let rtcAudioSession: RTCAudioSession

    private var certificate: RTCCertificate?
    private var localIdentity: CallLocalMediaIdentity?
    private var iceConfiguration: CallICEConfiguration?
    private var peerConnection: RTCPeerConnection?
    private var localAudioTrack: RTCAudioTrack?
    private var audioSender: RTCRtpSender?
    private var mediaConfiguration: (profile: UInt16, initialCameraIntent: Bool)?
    private var descriptionWasCreatedOrInstalled = false
    private var localVideoSource: RTCVideoSource?
    private var localVideoTrack: RTCVideoTrack?
    private var videoSender: RTCRtpSender?
    private var videoTransceiver: RTCRtpTransceiver?
    private var cameraCapturer: RTCCameraVideoCapturer?
    private let captureOperationGate = CallCaptureOperationGate()
    private var cameraOperationGeneration: UInt64 = 0
    private var cameraPosition: CallCameraPosition = .front
    private var videoTier: CallVideoQualityTier = .high
    private var videoMaximumFramesPerSecond: Int?
    private var cameraIsRunning = false
    private var remoteVideoTrack: RTCVideoTrack?
    private var videoRenderers: [UUID: (source: CallVideoRendererSource, renderer: RTCMTLVideoView)] = [:]
    private var captureObservers: [NSObjectProtocol] = []
    private var pressureObservation: NSKeyValueObservation?
    private var captureInterrupted = false
    private var captureRuntimeFailed = false
    private var captureCameraAvailable = true
    private var capturePressureCritical = false
    private var mediaConfigurationFailed = false
    nonisolated(unsafe) private var routeObserver: NSObjectProtocol?
    private var eventContinuations: [UUID: AsyncStream<WebRTCEvent>.Continuation] = [:]
    private var lastConnectionState: CallMediaConnectionState?
    private var lastOutboundBytes: Double?
    private var lastStatsTimestamp: TimeInterval?
    private var stopped = false

    override init() {
        if Self.initializeSSLOnce {
            factory = RTCPeerConnectionFactory(
                encoderFactory: RTCDefaultVideoEncoderFactory(),
                decoderFactory: RTCDefaultVideoDecoderFactory()
            )
        } else {
            factory = nil
        }
        rtcAudioSession = RTCAudioSession.sharedInstance()
        super.init()

        // CallKit owns AVAudioSession activation. Merely creating a local
        // audio track must not start the microphone or playout audio.
        rtcAudioSession.useManualAudio = true
        rtcAudioSession.isAudioEnabled = false

        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.emitCurrentAudioRoute()
            }
        }
    }

    deinit {
        if let routeObserver {
            NotificationCenter.default.removeObserver(routeObserver)
        }
    }

    func prepareLocalIdentity() async throws -> CallLocalMediaIdentity {
        guard !stopped else { throw WebRTCEngineError.operationFailed }
        guard factory != nil else { throw WebRTCEngineError.frameworkUnavailable }
        if let localIdentity {
            return localIdentity
        }

        guard let generated = RTCCertificate.generate(withParams: ["name": "ECDSA"]),
              let fingerprint = generated.getFingerprints().first(where: {
                  $0.algorithm.caseInsensitiveCompare("sha-256") == .orderedSame
              }),
              let fingerprintData = Self.parseColonSeparatedFingerprint(fingerprint.value),
              fingerprintData.count == 32
        else {
            throw WebRTCEngineError.invalidFingerprint
        }

        let identity = CallLocalMediaIdentity(dtlsFingerprintSHA256: fingerprintData)
        certificate = generated
        localIdentity = identity
        return identity
    }

    func updateICEConfiguration(_ configuration: CallICEConfiguration) async throws {
        guard !stopped, certificate != nil, localIdentity != nil else {
            throw WebRTCEngineError.notPrepared
        }
        guard Self.isValid(configuration) else {
            throw WebRTCEngineError.operationFailed
        }

        // Privacy mode is fixed when a call starts. Credential renewal must
        // never be able to silently downgrade relay-only operation.
        if let existing = iceConfiguration,
           existing.transportPolicy != configuration.transportPolicy {
            throw WebRTCEngineError.operationFailed
        }

        let rtcConfiguration = try makeRTCConfiguration(from: configuration)

        if let peerConnection {
            guard peerConnection.setConfiguration(rtcConfiguration) else {
                throw WebRTCEngineError.operationFailed
            }
        } else {
            try createPeerConnection(configuration: rtcConfiguration)
        }
        iceConfiguration = configuration
    }

    func configureMediaProfile(_ profile: UInt16, initialCameraIntent: Bool) async throws {
        guard !stopped, let peerConnection else { throw WebRTCEngineError.notPrepared }
        guard !descriptionWasCreatedOrInstalled else {
            throw WebRTCEngineError.mediaProfileAlreadyConfigured
        }
        if let mediaConfiguration {
            guard mediaConfiguration.profile == profile,
                  mediaConfiguration.initialCameraIntent == initialCameraIntent else {
                throw WebRTCEngineError.mediaProfileAlreadyConfigured
            }
            return
        }
        guard profile == CallMediaProfileVersion.voice
                || profile == CallMediaProfileVersion.cameraVideo else {
            throw WebRTCEngineError.incompatibleMediaProfile
        }
        guard !mediaConfigurationFailed else { throw WebRTCEngineError.operationFailed }
        guard profile == CallMediaProfileVersion.cameraVideo else {
            mediaConfiguration = (profile, initialCameraIntent)
            return
        }

        guard let factory else {
            mediaConfigurationFailed = true
            throw WebRTCEngineError.frameworkUnavailable
        }
        let source = factory.videoSource()
        let track = factory.videoTrack(with: source, trackId: "toj-camera")
        track.isEnabled = false
        let transceiverInit = RTCRtpTransceiverInit()
        transceiverInit.direction = .sendRecv
        transceiverInit.streamIds = ["toj-camera-stream"]
        guard let transceiver = peerConnection.addTransceiver(of: .video, init: transceiverInit) else {
            mediaConfigurationFailed = true
            throw WebRTCEngineError.operationFailed
        }
        do {
            try preferH264(on: transceiver)
        } catch {
            transceiver.stopInternal()
            mediaConfigurationFailed = true
            throw error
        }
        localVideoSource = source
        localVideoTrack = track
        videoSender = transceiver.sender
        videoTransceiver = transceiver
        let capturer = RTCCameraVideoCapturer(delegate: source)
        cameraCapturer = capturer
        installCaptureObservers(for: capturer)
        mediaConfiguration = (profile, initialCameraIntent)
    }

    func makeOffer(iceRestart: Bool) async throws -> CallSessionDescription {
        let peerConnection = try preparedPeerConnection()
        guard let mediaConfiguration else { throw WebRTCEngineError.notPrepared }
        if mediaConfiguration.profile == CallMediaProfileVersion.cameraVideo {
            try reassertVideoSendingState(on: peerConnection)
        }
        descriptionWasCreatedOrInstalled = true
        if iceRestart {
            peerConnection.restartIce()
        }

        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                kRTCMediaConstraintsOfferToReceiveAudio: kRTCMediaConstraintsValueTrue,
                kRTCMediaConstraintsOfferToReceiveVideo: mediaConfiguration.profile
                    == CallMediaProfileVersion.cameraVideo
                    ? kRTCMediaConstraintsValueTrue : kRTCMediaConstraintsValueFalse,
                kRTCMediaConstraintsVoiceActivityDetection: kRTCMediaConstraintsValueTrue,
                kRTCMediaConstraintsIceRestart: iceRestart
                    ? kRTCMediaConstraintsValueTrue
                    : kRTCMediaConstraintsValueFalse,
            ],
            optionalConstraints: nil
        )
        let generated = try await createOffer(peerConnection, constraints: constraints)
        return try await installLocalDescription(generated, expectedType: .offer)
    }

    func makeAnswer() async throws -> CallSessionDescription {
        let peerConnection = try preparedPeerConnection()
        guard let mediaConfiguration else { throw WebRTCEngineError.notPrepared }
        if mediaConfiguration.profile == CallMediaProfileVersion.cameraVideo {
            try reassertVideoSendingState(on: peerConnection)
        }
        descriptionWasCreatedOrInstalled = true
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                kRTCMediaConstraintsOfferToReceiveAudio: kRTCMediaConstraintsValueTrue,
                kRTCMediaConstraintsOfferToReceiveVideo: mediaConfiguration.profile
                    == CallMediaProfileVersion.cameraVideo
                    ? kRTCMediaConstraintsValueTrue : kRTCMediaConstraintsValueFalse,
                kRTCMediaConstraintsVoiceActivityDetection: kRTCMediaConstraintsValueTrue,
            ],
            optionalConstraints: nil
        )
        let generated = try await createAnswer(peerConnection, constraints: constraints)
        return try await installLocalDescription(generated, expectedType: .answer)
    }

    func setRemoteDescription(
        _ description: CallSessionDescription,
        expectedDTLSFingerprintSHA256: Data
    ) async throws {
        guard let mediaConfiguration else { throw WebRTCEngineError.notPrepared }
        guard description.sdp.utf8.count <= Self.maximumSignaledSDPBytes,
              Self.isSafeSDPText(description.sdp) else {
            throw WebRTCEngineError.operationFailed
        }
        guard expectedDTLSFingerprintSHA256.count == 32,
              let parsedFingerprint = Self.uniqueSHA256Fingerprint(in: description.sdp),
              Self.constantTimeEqual(parsedFingerprint, expectedDTLSFingerprintSHA256)
        else {
            throw WebRTCEngineError.invalidFingerprint
        }
        guard Self.isValidMediaSDP(
            description.sdp,
            profile: mediaConfiguration.profile,
            type: description.type
        ) else {
            throw WebRTCEngineError.operationFailed
        }

        let peerConnection = try preparedPeerConnection()
        descriptionWasCreatedOrInstalled = true
        let relayOnly = iceConfiguration?.transportPolicy == .relayOnly
        let safeSDP = relayOnly ? Self.removingNonRelayCandidates(from: description.sdp) : description.sdp
        let rtcDescription = RTCSessionDescription(
            type: description.type == .offer ? .offer : .answer,
            sdp: safeSDP
        )
        try await setRemote(rtcDescription, on: peerConnection)
        if mediaConfiguration.profile == CallMediaProfileVersion.cameraVideo {
            try reassertVideoSendingState(on: peerConnection)
        }
    }

    func addRemoteICECandidate(_ candidate: CallICECandidate) async throws {
        guard candidate.candidate.utf8.count <= Self.maximumCandidateBytes,
              Self.isSafeSDPText(candidate.candidate),
              candidate.candidate.lowercased().hasPrefix("candidate:"),
              !candidate.candidate.contains("\r"),
              !candidate.candidate.contains("\n"),
              candidate.sdpMLineIndex >= 0,
              (candidate.sdpMid?.utf8.count ?? 0) <= 64
        else {
            throw WebRTCEngineError.operationFailed
        }
        if iceConfiguration?.transportPolicy == .relayOnly,
           !Self.isRelayCandidate(candidate.candidate) {
            // A fastest-route peer legitimately trickles host/srflx candidates. They are unusable
            // under this device's relay-only policy, so discard them exactly as SDP candidates are
            // discarded instead of treating the mixed privacy modes as a protocol failure.
            return
        }

        let peerConnection = try preparedPeerConnection()
        let rtcCandidate = RTCIceCandidate(
            sdp: candidate.candidate,
            sdpMLineIndex: candidate.sdpMLineIndex,
            sdpMid: candidate.sdpMid
        )
        try await add(rtcCandidate, to: peerConnection)
    }

    func setAudioSessionActive(_ active: Bool) async {
        guard !stopped else { return }
        let systemSession = AVAudioSession.sharedInstance()
        if active {
            // CallKit has already activated the system session by the time this
            // method is called. Inform WebRTC, then permit its VoIP audio unit.
            rtcAudioSession.audioSessionDidActivate(systemSession)
            rtcAudioSession.isAudioEnabled = true
            emitCurrentAudioRoute()
        } else {
            rtcAudioSession.isAudioEnabled = false
            rtcAudioSession.audioSessionDidDeactivate(systemSession)
        }
    }

    func setMuted(_ muted: Bool) async {
        guard !stopped else { return }
        localAudioTrack?.isEnabled = !muted
    }

    func setCameraEnabled(_ enabled: Bool, position: CallCameraPosition) async throws {
        guard !stopped else { throw WebRTCEngineError.operationFailed }
        cameraOperationGeneration &+= 1
        let operationGeneration = cameraOperationGeneration
        await captureOperationGate.acquire()
        do {
            try await setCameraEnabledLocked(
                enabled,
                position: position,
                operationGeneration: operationGeneration
            )
            await captureOperationGate.release()
        } catch {
            await captureOperationGate.release()
            throw error
        }
    }

    private func setCameraEnabledLocked(
        _ enabled: Bool,
        position: CallCameraPosition,
        operationGeneration: UInt64
    ) async throws {
        guard !stopped,
              operationGeneration == cameraOperationGeneration,
              mediaConfiguration?.profile == CallMediaProfileVersion.cameraVideo,
              let track = localVideoTrack,
              let capturer = cameraCapturer else {
            throw WebRTCEngineError.incompatibleMediaProfile
        }
        cameraPosition = position
        if !enabled {
            track.isEnabled = false
            if cameraIsRunning {
                await stopCapture(capturer)
                cameraIsRunning = false
            }
            guard !stopped, operationGeneration == cameraOperationGeneration else {
                throw WebRTCEngineError.operationFailed
            }
            return
        }
        if cameraIsRunning {
            track.isEnabled = true
            return
        }
        let selection = try Self.captureSelection(
            position: position,
            tier: videoTier,
            maximumFramesPerSecond: videoMaximumFramesPerSecond
        )
        try await startCapture(
            capturer,
            device: selection.device,
            format: selection.format,
            fps: selection.fps
        )
        guard !stopped, operationGeneration == cameraOperationGeneration else {
            track.isEnabled = false
            await stopCapture(capturer)
            cameraIsRunning = false
            throw WebRTCEngineError.operationFailed
        }
        cameraIsRunning = true
        captureRuntimeFailed = false
        captureInterrupted = false
        captureCameraAvailable = true
        track.isEnabled = true
        emitCaptureHealth()
    }

    func switchCamera(to position: CallCameraPosition) async throws {
        guard !stopped,
              mediaConfiguration?.profile == CallMediaProfileVersion.cameraVideo else {
            throw WebRTCEngineError.incompatibleMediaProfile
        }
        guard position != cameraPosition else { return }
        cameraOperationGeneration &+= 1
        let operationGeneration = cameraOperationGeneration
        await captureOperationGate.acquire()
        do {
            guard !stopped, operationGeneration == cameraOperationGeneration else {
                throw WebRTCEngineError.operationFailed
            }
            let previousPosition = cameraPosition
            let wasRunning = cameraIsRunning
            if wasRunning {
                try await setCameraEnabledLocked(
                    false,
                    position: previousPosition,
                    operationGeneration: operationGeneration
                )
            }
            guard !stopped, operationGeneration == cameraOperationGeneration else {
                throw WebRTCEngineError.operationFailed
            }
            cameraPosition = position
            if wasRunning {
                try await setCameraEnabledLocked(
                    true,
                    position: position,
                    operationGeneration: operationGeneration
                )
            }
            await captureOperationGate.release()
        } catch {
            await captureOperationGate.release()
            throw error
        }
    }

    func setVideoQualityTier(
        _ tier: CallVideoQualityTier,
        maximumFramesPerSecond: Int?
    ) async throws {
        guard mediaConfiguration?.profile == CallMediaProfileVersion.cameraVideo else {
            throw WebRTCEngineError.incompatibleMediaProfile
        }
        let normalizedFrameCap = maximumFramesPerSecond.map {
            max(1, min(tier.framesPerSecond, $0))
        }
        let changed = tier != videoTier || normalizedFrameCap != videoMaximumFramesPerSecond
        videoTier = tier
        videoMaximumFramesPerSecond = normalizedFrameCap
        try applyVideoTier(tier, maximumFramesPerSecond: normalizedFrameCap)
        if changed, cameraIsRunning {
            // A quality restart is automatic and must never outrank a later user-off action.
            // Observe the current generation before waiting, then abandon the restart if any
            // user or lifecycle operation superseded it while capture was busy.
            let observedGeneration = cameraOperationGeneration
            await captureOperationGate.acquire()
            guard !stopped,
                  observedGeneration == cameraOperationGeneration,
                  cameraIsRunning else {
                await captureOperationGate.release()
                return
            }
            cameraOperationGeneration &+= 1
            let operationGeneration = cameraOperationGeneration
            let position = cameraPosition
            do {
                try await setCameraEnabledLocked(
                    false,
                    position: position,
                    operationGeneration: operationGeneration
                )
                try await setCameraEnabledLocked(
                    true,
                    position: position,
                    operationGeneration: operationGeneration
                )
                await captureOperationGate.release()
            } catch {
                await captureOperationGate.release()
                throw error
            }
        }
    }

    func makeVideoRenderer(source: CallVideoRendererSource) async throws -> CallVideoRendererHandle {
        guard mediaConfiguration?.profile == CallMediaProfileVersion.cameraVideo else {
            throw WebRTCEngineError.incompatibleMediaProfile
        }
        let renderer = RTCMTLVideoView(frame: .zero)
        renderer.videoContentMode = .scaleAspectFill
        let handle = CallVideoRendererHandle(view: renderer, implementation: renderer)
        videoRenderers[handle.id] = (source, renderer)
        switch source {
        case .local: localVideoTrack?.add(renderer)
        case .remote: remoteVideoTrack?.add(renderer)
        }
        return handle
    }

    func releaseVideoRenderer(_ handle: CallVideoRendererHandle) async {
        guard let entry = videoRenderers.removeValue(forKey: handle.id) else { return }
        switch entry.source {
        case .local: localVideoTrack?.remove(entry.renderer)
        case .remote: remoteVideoTrack?.remove(entry.renderer)
        }
        entry.renderer.renderFrame(nil)
    }

    func supportsBackgroundCameraAccess() async -> Bool {
        guard let session = cameraCapturer?.captureSession,
              session.isMultitaskingCameraAccessSupported else { return false }
        if !session.isMultitaskingCameraAccessEnabled {
            session.isMultitaskingCameraAccessEnabled = true
        }
        return session.isMultitaskingCameraAccessEnabled
    }

    func setPreferredAudioRoute(_ route: CallAudioRoute) async throws {
        guard !stopped else { throw WebRTCEngineError.operationFailed }

        let systemSession = rtcAudioSession.session
        rtcAudioSession.lockForConfiguration()
        defer { rtcAudioSession.unlockForConfiguration() }

        switch route {
        case .speaker:
            try rtcAudioSession.overrideOutputAudioPort(.speaker)

        case .builtInReceiver:
            if let builtInMic = systemSession.availableInputs?.first(where: {
                $0.portType == .builtInMic
            }) {
                try rtcAudioSession.setPreferredInput(builtInMic)
            }
            try rtcAudioSession.overrideOutputAudioPort(.none)

        case .bluetooth:
            guard let input = systemSession.availableInputs?.first(where: {
                $0.portType == .bluetoothHFP || $0.portType == .bluetoothLE
            }) else {
                throw WebRTCEngineError.operationFailed
            }
            try rtcAudioSession.setPreferredInput(input)
            try rtcAudioSession.overrideOutputAudioPort(.none)

        case .wired:
            if Self.currentRoute(systemSession) != .wired,
               let input = systemSession.availableInputs?.first(where: {
                $0.portType == .headsetMic || $0.portType == .usbAudio
            }) {
                try rtcAudioSession.setPreferredInput(input)
                try rtcAudioSession.overrideOutputAudioPort(.none)
            } else if Self.currentRoute(systemSession) != .wired {
                throw WebRTCEngineError.operationFailed
            }

        case .airPlay:
            // AVAudioSession has no API to force an AirPlay output. It can be
            // selected by the system route picker; accept it only if selected.
            guard Self.currentRoute(systemSession) == .airPlay else {
                throw WebRTCEngineError.operationFailed
            }

        case .unknown:
            throw WebRTCEngineError.operationFailed
        }

        emitCurrentAudioRoute()
    }

    func statistics() async -> CallNetworkStats? {
        guard !stopped, let peerConnection else { return nil }
        let report = await withCheckedContinuation {
            (continuation: CheckedContinuation<RTCStatisticsReport, Never>) in
            peerConnection.statistics { report in
                continuation.resume(returning: report)
            }
        }
        return makeNetworkStats(from: report)
    }

    func events() async -> AsyncStream<WebRTCEvent> {
        guard !stopped else {
            return AsyncStream { continuation in continuation.finish() }
        }

        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            eventContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.eventContinuations.removeValue(forKey: id)
                }
            }
        }
    }

    func stop() async {
        guard !stopped else { return }
        stopped = true
        cameraOperationGeneration &+= 1
        await captureOperationGate.acquire()

        rtcAudioSession.isAudioEnabled = false
        localAudioTrack?.isEnabled = false
        localVideoTrack?.isEnabled = false
        if cameraIsRunning, let cameraCapturer {
            await stopCapture(cameraCapturer)
        }
        cameraIsRunning = false
        for (_, entry) in videoRenderers {
            switch entry.source {
            case .local: localVideoTrack?.remove(entry.renderer)
            case .remote: remoteVideoTrack?.remove(entry.renderer)
            }
            entry.renderer.renderFrame(nil)
        }
        videoRenderers.removeAll()
        peerConnection?.delegate = nil
        peerConnection?.close()
        peerConnection = nil
        audioSender = nil
        localAudioTrack = nil
        localVideoTrack = nil
        localVideoSource = nil
        remoteVideoTrack = nil
        videoSender = nil
        videoTransceiver = nil
        cameraCapturer = nil
        pressureObservation?.invalidate()
        pressureObservation = nil
        for observer in captureObservers { NotificationCenter.default.removeObserver(observer) }
        captureObservers.removeAll()
        mediaConfiguration = nil
        iceConfiguration = nil
        localIdentity = nil
        certificate = nil
        lastOutboundBytes = nil
        lastStatsTimestamp = nil

        if let routeObserver {
            NotificationCenter.default.removeObserver(routeObserver)
            self.routeObserver = nil
        }
        eventContinuations.values.forEach { $0.finish() }
        eventContinuations.removeAll()
        await captureOperationGate.release()
    }

    // MARK: - Peer creation

    private func makeRTCConfiguration(
        from configuration: CallICEConfiguration
    ) throws -> RTCConfiguration {
        guard let certificate else { throw WebRTCEngineError.notPrepared }

        let result = RTCConfiguration()
        result.iceServers = configuration.servers.map {
            RTCIceServer(
                urlStrings: $0.urls,
                username: $0.username,
                credential: $0.credential
            )
        }
        result.certificate = certificate
        result.iceTransportPolicy = configuration.transportPolicy == .relayOnly ? .relay : .all
        result.bundlePolicy = .maxBundle
        result.rtcpMuxPolicy = .require
        result.continualGatheringPolicy = .gatherContinually
        result.iceCandidatePoolSize = 1
        result.shouldPruneTurnPorts = true
        result.shouldPresumeWritableWhenFullyRelayed = configuration.transportPolicy == .relayOnly
        result.sdpSemantics = .unifiedPlan
        return result
    }

    private func createPeerConnection(configuration: RTCConfiguration) throws {
        guard let factory else { throw WebRTCEngineError.frameworkUnavailable }
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: nil
        )
        guard let peerConnection = factory.peerConnection(
            with: configuration,
            constraints: constraints,
            delegate: self
        ) else {
            throw WebRTCEngineError.operationFailed
        }

        let audioSource = factory.audioSource(with: nil)
        let audioTrack = factory.audioTrack(with: audioSource, trackId: "toj-audio")
        guard let sender = peerConnection.add(audioTrack, streamIds: ["toj-audio-stream"]) else {
            peerConnection.close()
            throw WebRTCEngineError.operationFailed
        }

        let parameters = sender.parameters
        for encoding in parameters.encodings {
            encoding.maxBitrateBps = NSNumber(value: Self.maximumAudioBitrateBps)
            encoding.networkPriority = .high
            encoding.bitratePriority = 1
            encoding.adaptiveAudioPacketTime = false
        }
        sender.parameters = parameters
        guard peerConnection.setBweMinBitrateBps(
            nil,
            currentBitrateBps: nil,
            maxBitrateBps: NSNumber(value: Self.maximumAudioBitrateBps)
        ) else {
            peerConnection.close()
            throw WebRTCEngineError.operationFailed
        }

        self.peerConnection = peerConnection
        localAudioTrack = audioTrack
        audioSender = sender
    }

    private func preferH264(on transceiver: RTCRtpTransceiver) throws {
        guard let factory else { throw WebRTCEngineError.frameworkUnavailable }
        let capabilities = factory
            .rtpSenderCapabilities(forKind: kRTCMediaStreamTrackKindVideo).codecs
        let h264 = capabilities.filter { $0.name.caseInsensitiveCompare("H264") == .orderedSame }
        guard !h264.isEmpty else { throw WebRTCEngineError.incompatibleMediaProfile }

        func rank(_ codec: RTCRtpCodecCapability) -> Int {
            let profile = codec.parameters["profile-level-id"]?.lowercased() ?? ""
            if profile.hasPrefix("640c") { return 0 } // constrained high
            if profile.hasPrefix("42e0") { return 1 } // constrained baseline
            return 2
        }
        let orderedH264 = h264
            .filter { ($0.parameters["packetization-mode"] ?? "1") == "1" }
            .sorted { rank($0) < rank($1) }
        guard !orderedH264.isEmpty else { throw WebRTCEngineError.incompatibleMediaProfile }
        let repair = capabilities.filter {
            ["rtx", "red", "ulpfec"].contains($0.name.lowercased())
        }
        try transceiver.setCodecPreferences(orderedH264 + repair, error: ())
    }

    /// Applying a remote offer can clear the disabled local track from the matching Unified Plan
    /// transceiver in the pinned artifact. Reattach that same permanent track before generating an
    /// answer so camera-off is expressed as a disabled `sendrecv` sender, never as `recvonly`.
    private func reassertVideoSendingState(on peerConnection: RTCPeerConnection) throws {
        #if DEBUG
        Self.lastMediaReassertFailureForTesting = nil
        #endif
        guard let track = localVideoTrack else { throw WebRTCEngineError.notPrepared }
        let transceivers = peerConnection.transceivers.filter {
            $0.mediaType == .video && !$0.isStopped
        }
        let transceiver: RTCRtpTransceiver
        if transceivers.count == 1, let only = transceivers.first {
            transceiver = only
        } else if transceivers.count == 2,
                  let associated = transceivers.first(where: { !$0.mid.isEmpty }),
                  let unassociated = transceivers.first(where: { $0 !== associated && $0.mid.isEmpty }) {
            // libwebrtc creates the offer-associated answer transceiver instead of recycling the
            // preconfigured nil-mid transceiver. Stop only that never-signaled placeholder, then
            // move the permanent disabled track onto the authenticated offer's transceiver.
            unassociated.stopInternal()
            transceiver = associated
        } else {
            #if DEBUG
            Self.lastMediaReassertFailureForTesting = "could not select video transceiver from mids \(transceivers.map(\.mid))"
            #endif
            throw WebRTCEngineError.operationFailed
        }
        transceiver.sender.track = track
        transceiver.sender.streamIds = ["toj-camera-stream"]
        var directionError: NSError?
        transceiver.setDirection(.sendRecv, error: &directionError)
        if let directionError {
            #if DEBUG
            Self.lastMediaReassertFailureForTesting = "direction: \(directionError)"
            #endif
            throw WebRTCEngineError.operationFailed
        }
        do {
            try preferH264(on: transceiver)
        } catch {
            #if DEBUG
            Self.lastMediaReassertFailureForTesting = "codec preferences: \(error)"
            #endif
            throw error
        }
        videoSender = transceiver.sender
        videoTransceiver = transceiver
        try applyVideoTier(videoTier, maximumFramesPerSecond: videoMaximumFramesPerSecond)
    }

    private static func captureSelection(
        position: CallCameraPosition,
        tier: CallVideoQualityTier,
        maximumFramesPerSecond: Int?
    ) throws -> (device: AVCaptureDevice, format: AVCaptureDevice.Format, fps: Int) {
        let requestedPosition: AVCaptureDevice.Position = position == .front ? .front : .back
        guard let device = RTCCameraVideoCapturer.captureDevices().first(where: {
            $0.position == requestedPosition
        }) else { throw WebRTCEngineError.cameraUnavailable }
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        guard let format = formats.min(by: { lhs, rhs in
            let left = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
            let right = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
            let leftDistance = abs(Int(left.width) - tier.captureWidth)
                + abs(Int(left.height) - tier.captureHeight)
            let rightDistance = abs(Int(right.width) - tier.captureWidth)
                + abs(Int(right.height) - tier.captureHeight)
            return leftDistance < rightDistance
        }) else { throw WebRTCEngineError.cameraUnavailable }
        let maximumFPS = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
        guard maximumFPS >= 1 else { throw WebRTCEngineError.cameraUnavailable }
        let targetFPS = min(tier.framesPerSecond, maximumFramesPerSecond ?? tier.framesPerSecond)
        return (device, format, max(1, min(targetFPS, Int(maximumFPS))))
    }

    private func applyVideoTier(
        _ tier: CallVideoQualityTier,
        maximumFramesPerSecond: Int? = nil
    ) throws {
        guard let videoSender else { throw WebRTCEngineError.notPrepared }
        let parameters = videoSender.parameters
        guard !parameters.encodings.isEmpty else { throw WebRTCEngineError.operationFailed }
        for encoding in parameters.encodings {
            encoding.maxBitrateBps = NSNumber(value: tier.maximumBitrate)
            encoding.maxFramerate = NSNumber(
                value: min(tier.framesPerSecond, maximumFramesPerSecond ?? tier.framesPerSecond)
            )
            encoding.networkPriority = .low
            encoding.bitratePriority = 0.5
        }
        videoSender.parameters = parameters
    }

    private func startCapture(
        _ capturer: RTCCameraVideoCapturer,
        device: AVCaptureDevice,
        format: AVCaptureDevice.Format,
        fps: Int
    ) async throws {
        observePressure(on: device)
        try await capturer.startCapture(with: device, format: format, fps: fps)
    }

    private func installCaptureObservers(for capturer: RTCCameraVideoCapturer) {
        let center = NotificationCenter.default
        let session = capturer.captureSession
        captureObservers = [
            center.addObserver(
                forName: AVCaptureSession.wasInterruptedNotification,
                object: session,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.captureInterrupted = true
                    self?.emitCaptureHealth()
                }
            },
            center.addObserver(
                forName: AVCaptureSession.interruptionEndedNotification,
                object: session,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.captureInterrupted = false
                    self?.captureRuntimeFailed = false
                    self?.emitCaptureHealth()
                }
            },
            center.addObserver(
                forName: AVCaptureSession.runtimeErrorNotification,
                object: session,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.captureRuntimeFailed = true
                    self?.emitCaptureHealth()
                }
            },
            center.addObserver(
                forName: AVCaptureDevice.wasConnectedNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshCameraAvailability()
                }
            },
            center.addObserver(
                forName: AVCaptureDevice.wasDisconnectedNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshCameraAvailability()
                }
            },
        ]
        refreshCameraAvailability()
    }

    private func observePressure(on device: AVCaptureDevice) {
        pressureObservation?.invalidate()
        pressureObservation = device.observe(\.systemPressureState, options: [.initial, .new]) {
            [weak self] _, change in
            let critical = change.newValue?.level == .shutdown
                || change.newValue?.level == .critical
            Task { @MainActor [weak self] in
                self?.capturePressureCritical = critical
                self?.emitCaptureHealth()
            }
        }
    }

    private func refreshCameraAvailability() {
        let requested: AVCaptureDevice.Position = cameraPosition == .front ? .front : .back
        captureCameraAvailable = RTCCameraVideoCapturer.captureDevices().contains {
            $0.position == requested
        }
        emitCaptureHealth()
    }

    private func emitCaptureHealth() {
        emit(.localVideoCaptureHealthChanged(CallVideoCaptureHealth(
            interrupted: captureInterrupted,
            runtimeFailed: captureRuntimeFailed,
            cameraAvailable: captureCameraAvailable,
            pressureCritical: capturePressureCritical
        )))
    }

    private func stopCapture(_ capturer: RTCCameraVideoCapturer) async {
        await capturer.stopCapture()
    }

    private func preparedPeerConnection() throws -> RTCPeerConnection {
        guard !stopped else { throw WebRTCEngineError.operationFailed }
        guard certificate != nil, localIdentity != nil else {
            throw WebRTCEngineError.notPrepared
        }
        guard iceConfiguration != nil, let peerConnection else {
            throw WebRTCEngineError.notPrepared
        }
        return peerConnection
    }

    private static func isValid(_ configuration: CallICEConfiguration) -> Bool {
        guard !configuration.servers.isEmpty else { return false }
        var containsAuthenticatedTURN = false

        for server in configuration.servers {
            guard !server.urls.isEmpty else { return false }
            for rawURL in server.urls {
                let scheme = rawURL.split(separator: ":", maxSplits: 1).first?.lowercased()
                guard scheme == "stun" || scheme == "stuns"
                        || scheme == "turn" || scheme == "turns"
                else { return false }

                if scheme == "turn" || scheme == "turns" {
                    guard let username = server.username, !username.isEmpty,
                          let credential = server.credential, !credential.isEmpty
                    else { return false }
                    containsAuthenticatedTURN = true
                }
            }
        }
        return containsAuthenticatedTURN
    }

    // MARK: - SDP and candidate safety

    private func installLocalDescription(
        _ generated: RTCSessionDescription,
        expectedType: CallSDPType
    ) async throws -> CallSessionDescription {
        let peerConnection = try preparedPeerConnection()
        guard let mediaConfiguration else { throw WebRTCEngineError.notPrepared }
        let relayOnly = iceConfiguration?.transportPolicy == .relayOnly
        let configuredSDP = try Self.configuredSDP(
            generated.sdp,
            profile: mediaConfiguration.profile,
            type: expectedType,
            relayOnly: relayOnly
        )

        guard let localIdentity,
              let actualFingerprint = Self.uniqueSHA256Fingerprint(in: configuredSDP),
              Self.constantTimeEqual(actualFingerprint, localIdentity.dtlsFingerprintSHA256)
        else {
            throw WebRTCEngineError.invalidFingerprint
        }

        let rtcType: RTCSdpType = expectedType == .offer ? .offer : .answer
        let configured = RTCSessionDescription(type: rtcType, sdp: configuredSDP)
        try await setLocal(configured, on: peerConnection)
        return CallSessionDescription(type: expectedType, sdp: configuredSDP)
    }

    private static func configuredSDP(
        _ sdp: String,
        profile: UInt16,
        type: CallSDPType,
        relayOnly: Bool
    ) throws -> String {
        #if DEBUG
        lastGeneratedSDPForTesting = sdp
        #endif
        guard sdp.utf8.count <= maximumSignaledSDPBytes,
              isSafeSDPText(sdp) else {
            throw WebRTCEngineError.operationFailed
        }
        guard isValidMediaSDP(sdp, profile: profile, type: type, strictCodecs: false) else {
            throw WebRTCEngineError.operationFailed
        }

        var lines = normalizedLines(sdp)
        guard let mediaStart = lines.firstIndex(where: { $0.hasPrefix("m=audio ") }) else {
            throw WebRTCEngineError.operationFailed
        }
        let mediaEnd = lines[(mediaStart + 1)...].firstIndex(where: { $0.hasPrefix("m=") })
            ?? lines.endIndex

        let opusPayloads = lines[mediaStart..<mediaEnd].compactMap { line -> String? in
            guard line.lowercased().contains(" opus/48000"),
                  line.hasPrefix("a=rtpmap:")
            else { return nil }
            return line.dropFirst("a=rtpmap:".count).split(separator: " ").first.map(String.init)
        }
        guard let opusPayload = opusPayloads.first else {
            throw WebRTCEngineError.operationFailed
        }

        var mediaParts = lines[mediaStart].split(separator: " ").map(String.init)
        guard mediaParts.count >= 4 else { throw WebRTCEngineError.operationFailed }
        mediaParts = Array(mediaParts.prefix(3)) + [opusPayload]
        lines[mediaStart] = mediaParts.joined(separator: " ")

        var foundFormatParameters = false
        var foundPacketTime = false
        var foundMaximumPacketTime = false
        let existingFormatParameters = lines[mediaStart..<mediaEnd].contains {
            $0.hasPrefix("a=fmtp:\(opusPayload) ") || $0 == "a=fmtp:\(opusPayload)"
        }
        let existingPacketTime = lines[mediaStart..<mediaEnd].contains { $0.hasPrefix("a=ptime:") }
        let existingMaximumPacketTime = lines[mediaStart..<mediaEnd].contains {
            $0.hasPrefix("a=maxptime:")
        }
        var filtered: [String] = []
        filtered.reserveCapacity(lines.count + 2)

        for (index, line) in lines.enumerated() {
            let isAudioMediaLine = index >= mediaStart && index < mediaEnd
            if isAudioMediaLine, let payload = payloadIdentifier(in: line), payload != opusPayload {
                continue
            }
            if relayOnly, line.hasPrefix("a=candidate:"), !isRelayCandidate(line) {
                continue
            }

            if isAudioMediaLine,
               (line.hasPrefix("a=fmtp:\(opusPayload) ") || line == "a=fmtp:\(opusPayload)") {
                filtered.append(configuredOpusFormatLine(line, payload: opusPayload))
                foundFormatParameters = true
            } else if isAudioMediaLine, line.hasPrefix("a=ptime:") {
                filtered.append("a=ptime:20")
                foundPacketTime = true
            } else if isAudioMediaLine, line.hasPrefix("a=maxptime:") {
                filtered.append("a=maxptime:20")
                foundMaximumPacketTime = true
            } else {
                filtered.append(line)
                if isAudioMediaLine, line.hasPrefix("a=rtpmap:\(opusPayload) ") {
                    if !existingFormatParameters, !foundFormatParameters {
                        filtered.append(configuredOpusFormatLine(nil, payload: opusPayload))
                        foundFormatParameters = true
                    }
                    if !existingPacketTime, !foundPacketTime {
                        filtered.append("a=ptime:20")
                        foundPacketTime = true
                    }
                    if !existingMaximumPacketTime, !foundMaximumPacketTime {
                        filtered.append("a=maxptime:20")
                        foundMaximumPacketTime = true
                    }
                }
            }
        }

        guard foundFormatParameters, foundPacketTime, foundMaximumPacketTime else {
            throw WebRTCEngineError.operationFailed
        }
        let result = filtered.joined(separator: "\r\n") + "\r\n"
        guard result.utf8.count <= maximumSignaledSDPBytes,
              isValidMediaSDP(result, profile: profile, type: type) else {
            throw WebRTCEngineError.operationFailed
        }
        return result
    }

    private static func configuredOpusFormatLine(_ line: String?, payload: String) -> String {
        var values: [String: String] = [:]
        if let line, let firstSpace = line.firstIndex(of: " ") {
            let rawParameters = line[line.index(after: firstSpace)...]
            for item in rawParameters.split(separator: ";") {
                let pair = item.split(separator: "=", maxSplits: 1).map {
                    String($0).trimmingCharacters(in: .whitespaces)
                }
                if pair.count == 2 {
                    values[pair[0].lowercased()] = pair[1]
                }
            }
        }
        values["maxaveragebitrate"] = String(maximumAudioBitrateBps)
        values["minptime"] = "20"
        values["stereo"] = "0"
        values["sprop-stereo"] = "0"
        values["useinbandfec"] = "1"
        values["usedtx"] = "1"

        let orderedKeys = [
            "minptime", "maxaveragebitrate", "useinbandfec", "usedtx", "stereo", "sprop-stereo",
        ]
        let known = orderedKeys.compactMap { key in values[key].map { "\(key)=\($0)" } }
        let remaining = values.keys.filter { !orderedKeys.contains($0) }.sorted().compactMap { key in
            values[key].map { "\(key)=\($0)" }
        }
        return "a=fmtp:\(payload) " + (known + remaining).joined(separator: ";")
    }

    private static func payloadIdentifier(in line: String) -> String? {
        let prefixes = ["a=rtpmap:", "a=fmtp:", "a=rtcp-fb:"]
        guard let prefix = prefixes.first(where: { line.hasPrefix($0) }) else { return nil }
        return line.dropFirst(prefix.count).split(whereSeparator: { $0 == " " || $0 == "\t" }).first
            .map(String.init)
    }

    private struct SDPMediaSection {
        let kind: String
        let port: Int
        let transport: String
        let payloads: [String]
        let lines: [String]
    }

    private static func isValidMediaSDP(
        _ sdp: String,
        profile: UInt16,
        type: CallSDPType,
        strictCodecs: Bool = true
    ) -> Bool {
        #if DEBUG
        lastSDPValidationFailureForTesting = nil
        #endif
        func reject(_ reason: String) -> Bool {
            #if DEBUG
            lastSDPValidationFailureForTesting = reason
            #endif
            return false
        }
        let lines = normalizedLines(sdp)
        guard !lines.contains(where: {
            $0.lowercased().hasPrefix("a=crypto:") || $0.lowercased().hasPrefix("m=application ")
        }) else { return reject("forbidden SDES or data channel") }

        var sessionLines: [String] = []
        var sections: [SDPMediaSection] = []
        var current: [String] = []
        for line in lines {
            if line.hasPrefix("m=") {
                if !current.isEmpty {
                    guard let parsed = parseMediaSection(current) else {
                        return reject("malformed media section")
                    }
                    sections.append(parsed)
                }
                current = [line]
            } else if current.isEmpty {
                sessionLines.append(line)
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty {
            guard let parsed = parseMediaSection(current) else {
                return reject("malformed final media section")
            }
            sections.append(parsed)
        }
        let expectedKinds = profile == CallMediaProfileVersion.voice
            ? ["audio"] : ["audio", "video"]
        guard sections.map(\.kind) == expectedKinds else {
            return reject("unexpected media sections: \(sections.map(\.kind))")
        }

        let sessionSetup = attributeValue("a=setup:", in: sessionLines)
        let sessionUfrag = attributeValue("a=ice-ufrag:", in: sessionLines)
        let sessionPassword = attributeValue("a=ice-pwd:", in: sessionLines)
        var mids: [String] = []
        var bundledTransportCredentials: Set<String> = []
        var bundledSetupRoles: Set<String> = []
        for section in sections {
            guard let resolvedUfrag = attributeValue("a=ice-ufrag:", in: section.lines) ?? sessionUfrag,
                  !resolvedUfrag.isEmpty,
                  let resolvedPassword = attributeValue("a=ice-pwd:", in: section.lines) ?? sessionPassword,
                  !resolvedPassword.isEmpty
            else { return reject("missing or duplicate ICE credentials in \(section.kind)") }
            guard section.port > 0,
                  section.transport.uppercased() == "UDP/TLS/RTP/SAVPF",
                  section.lines.contains("a=sendrecv"),
                  !section.lines.contains("a=inactive"),
                  !section.lines.contains("a=sendonly"),
                  !section.lines.contains("a=recvonly"),
                  section.lines.contains("a=rtcp-mux"),
                  let mid = attributeValue("a=mid:", in: section.lines), !mid.isEmpty
            else { return reject("invalid transport, direction, rtcp-mux, or mid in \(section.kind)") }
            mids.append(mid)
            bundledTransportCredentials.insert("\(resolvedUfrag)\u{0}\(resolvedPassword)")
            guard let setup = attributeValue("a=setup:", in: section.lines) ?? sessionSetup else {
                return reject("missing or duplicate setup role in \(section.kind)")
            }
            bundledSetupRoles.insert(setup)
            switch type {
            case .offer:
                guard setup == "actpass" else { return reject("invalid offer setup role") }
            case .answer:
                guard setup == "active" || setup == "passive" else {
                    return reject("invalid answer setup role")
                }
            }
            if strictCodecs {
                guard section.kind == "audio"
                        ? hasOnlyExpectedAudioCodecs(section)
                        : hasOnlyExpectedVideoCodecs(section) else {
                    return reject("unexpected \(section.kind) codecs")
                }
            } else if section.kind == "audio" {
                guard containsCodec("opus", clockRate: "48000", in: section) else {
                    return reject("generated audio lacks Opus")
                }
            } else {
                guard containsCodec("h264", clockRate: "90000", in: section) else {
                    return reject("generated video lacks H264")
                }
            }
        }
        let bundleLines = sessionLines.filter { $0.hasPrefix("a=group:BUNDLE ") }
        guard Set(mids).count == mids.count,
              bundledTransportCredentials.count == 1,
              bundledSetupRoles.count == 1,
              bundleLines.count == 1,
              let bundleLine = bundleLines.first
        else { return reject("invalid BUNDLE transport invariants") }
        let bundledMids = bundleLine.dropFirst("a=group:BUNDLE ".count)
            .split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard bundledMids == mids else { return reject("BUNDLE mids do not match media sections") }
        return true
    }

    #if DEBUG
    static func validatesMediaSDPForTesting(
        _ sdp: String,
        profile: UInt16,
        type: CallSDPType,
        expectedFingerprint: Data
    ) -> Bool {
        guard let actual = uniqueSHA256Fingerprint(in: sdp),
              constantTimeEqual(actual, expectedFingerprint) else { return false }
        return isValidMediaSDP(sdp, profile: profile, type: type)
    }
    #endif

    private static func parseMediaSection(_ lines: [String]) -> SDPMediaSection? {
        guard let first = lines.first else { return nil }
        let fields = first.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard fields.count >= 4, fields[0].hasPrefix("m="),
              let port = fields[1].split(separator: "/").first.flatMap({ Int($0) }) else { return nil }
        return SDPMediaSection(
            kind: String(fields[0].dropFirst(2)).lowercased(),
            port: port,
            transport: fields[2],
            payloads: Array(fields.dropFirst(3)),
            lines: lines
        )
    }

    private static func attributeValue(_ prefix: String, in lines: [String]) -> String? {
        let values = lines.filter { $0.hasPrefix(prefix) }.map {
            String($0.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        guard values.count == 1 else { return nil }
        return values[0]
    }

    private static func codecMap(in section: SDPMediaSection) -> [String: String] {
        var result: [String: String] = [:]
        for line in section.lines where line.lowercased().hasPrefix("a=rtpmap:") {
            let remainder = line.dropFirst("a=rtpmap:".count)
            let fields = remainder.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if fields.count == 2 { result[String(fields[0])] = String(fields[1]).lowercased() }
        }
        return result
    }

    private static func containsCodec(
        _ name: String,
        clockRate: String,
        in section: SDPMediaSection
    ) -> Bool {
        codecMap(in: section).contains { payload, codec in
            section.payloads.contains(payload) && codec.hasPrefix("\(name)/\(clockRate)")
        }
    }

    private static func hasOnlyExpectedAudioCodecs(_ section: SDPMediaSection) -> Bool {
        let codecs = codecMap(in: section)
        guard section.payloads.count == 1, let payload = section.payloads.first,
              codecs[payload]?.hasPrefix("opus/48000") == true else { return false }
        return codecs.keys.allSatisfy { !section.payloads.contains($0) || $0 == payload }
    }

    private static func hasOnlyExpectedVideoCodecs(_ section: SDPMediaSection) -> Bool {
        let codecs = codecMap(in: section)
        let activeCodecs = section.payloads.compactMap { payload in
            codecs[payload].map { (payload, $0) }
        }
        guard activeCodecs.count == section.payloads.count else { return false }
        let h264Payloads = activeCodecs.compactMap { payload, codec -> String? in
            codec.hasPrefix("h264/90000") ? payload : nil
        }
        let redPayloads = activeCodecs.compactMap { payload, codec -> String? in
            codec.hasPrefix("red/90000") ? payload : nil
        }
        guard !h264Payloads.isEmpty else { return false }
        var rtxTargets: Set<String> = []

        for (payload, codec) in activeCodecs {
            let name = codec.split(separator: "/").first.map(String.init) ?? ""
            guard ["h264", "rtx", "red", "ulpfec"].contains(name) else { return false }
            guard let parameters = formatParameters(payload: payload, in: section.lines) else {
                return false
            }
            if name == "h264" {
                let profile = parameters["profile-level-id"]?.lowercased() ?? ""
                guard parameters["packetization-mode"] == "1",
                      parameters["level-asymmetry-allowed"] == "1",
                      profile.count == 6,
                      profile.allSatisfy(\.isHexDigit),
                      profile.hasPrefix("640c") || profile.hasPrefix("42e0") else { return false }
            } else if name == "rtx" {
                guard let apt = parameters["apt"],
                      h264Payloads.contains(apt) || redPayloads.contains(apt) else { return false }
                rtxTargets.insert(apt)
            }
        }
        // Every advertised H264 payload has its own RTX repair payload. The pinned artifact also
        // advertises RTX over RED; that exact repair chain is valid, while dangling or recursive
        // apt references remain rejected above.
        return Set(h264Payloads).isSubset(of: rtxTargets)
    }

    private static func formatParameters(payload: String, in lines: [String]) -> [String: String]? {
        let matchingLines = lines.filter {
            $0.hasPrefix("a=fmtp:\(payload) ") || $0 == "a=fmtp:\(payload)"
        }
        guard matchingLines.count <= 1 else { return nil }
        guard let line = matchingLines.first else { return [:] }
        guard let space = line.firstIndex(of: " ") else { return nil }
        var result: [String: String] = [:]
        for item in line[line.index(after: space)...].split(separator: ";") {
            let pair = item.split(separator: "=", maxSplits: 1).map {
                String($0).trimmingCharacters(in: .whitespaces).lowercased()
            }
            guard pair.count == 2, !pair[0].isEmpty, !pair[1].isEmpty,
                  result[pair[0]] == nil else { return nil }
            result[pair[0]] = pair[1]
        }
        return result
    }

    private static func uniqueSHA256Fingerprint(in sdp: String) -> Data? {
        var result: Data?
        for line in normalizedLines(sdp) where line.lowercased().hasPrefix("a=fingerprint:") {
            let value = line.dropFirst("a=fingerprint:".count)
            let fields = value.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count == 2, fields[0].lowercased() == "sha-256",
                  let parsed = parseColonSeparatedFingerprint(String(fields[1])),
                  parsed.count == 32
            else { return nil }
            if let result, !constantTimeEqual(result, parsed) {
                return nil
            }
            result = parsed
        }
        return result
    }

    private static func parseColonSeparatedFingerprint(_ value: String) -> Data? {
        let octets = value.split(separator: ":", omittingEmptySubsequences: false)
        guard octets.count == 32 else { return nil }
        var result = Data()
        result.reserveCapacity(32)
        for octet in octets {
            guard octet.count == 2, let byte = UInt8(octet, radix: 16) else { return nil }
            result.append(byte)
        }
        return result
    }

    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) {
            difference |= left ^ right
        }
        return difference == 0
    }

    private static func removingNonRelayCandidates(from sdp: String) -> String {
        normalizedLines(sdp).filter {
            !$0.hasPrefix("a=candidate:") || isRelayCandidate($0)
        }.joined(separator: "\r\n") + "\r\n"
    }

    private static func isRelayCandidate(_ candidate: String) -> Bool {
        CallICECandidatePolicy.isRelay(candidate)
    }

    private static func normalizedLines(_ sdp: String) -> [String] {
        sdp.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    private static func isSafeSDPText(_ sdp: String) -> Bool {
        sdp.unicodeScalars.allSatisfy { scalar in
            scalar.value == 0x09 || scalar.value == 0x0A || scalar.value == 0x0D
                || (0x20...0x7E).contains(scalar.value)
        }
    }

    // MARK: - WebRTC completion bridging

    private func createOffer(
        _ peerConnection: RTCPeerConnection,
        constraints: RTCMediaConstraints
    ) async throws -> RTCSessionDescription {
        try await withCheckedThrowingContinuation { continuation in
            peerConnection.offer(for: constraints) { description, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let description {
                    continuation.resume(returning: description)
                } else {
                    continuation.resume(throwing: WebRTCEngineError.operationFailed)
                }
            }
        }
    }

    private func createAnswer(
        _ peerConnection: RTCPeerConnection,
        constraints: RTCMediaConstraints
    ) async throws -> RTCSessionDescription {
        try await withCheckedThrowingContinuation { continuation in
            peerConnection.answer(for: constraints) { description, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let description {
                    continuation.resume(returning: description)
                } else {
                    continuation.resume(throwing: WebRTCEngineError.operationFailed)
                }
            }
        }
    }

    private func setLocal(
        _ description: RTCSessionDescription,
        on peerConnection: RTCPeerConnection
    ) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            peerConnection.setLocalDescription(description) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func setRemote(
        _ description: RTCSessionDescription,
        on peerConnection: RTCPeerConnection
    ) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            peerConnection.setRemoteDescription(description) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func add(
        _ candidate: RTCIceCandidate,
        to peerConnection: RTCPeerConnection
    ) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            peerConnection.add(candidate) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    // MARK: - Events and stats

    private func emit(_ event: WebRTCEvent) {
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }

    private func emitConnectionState(_ state: CallMediaConnectionState) {
        guard lastConnectionState != state else { return }
        lastConnectionState = state
        emit(.connectionStateChanged(state))
    }

    private func emitCurrentAudioRoute() {
        emit(.audioRouteChanged(Self.currentRoute(rtcAudioSession.session)))
    }

    private func installRemoteVideoTrack(_ track: RTCVideoTrack?) {
        guard remoteVideoTrack !== track else { return }
        if let remoteVideoTrack {
            for entry in videoRenderers.values where entry.source == .remote {
                remoteVideoTrack.remove(entry.renderer)
            }
        }
        remoteVideoTrack = track
        if let track {
            for entry in videoRenderers.values where entry.source == .remote {
                track.add(entry.renderer)
            }
        }
        emit(.remoteVideoAvailabilityChanged(track != nil))
    }

    private static func currentRoute(_ session: AVAudioSession) -> CallAudioRoute {
        let outputs = session.currentRoute.outputs
        if outputs.contains(where: { $0.portType == .builtInSpeaker }) { return .speaker }
        if outputs.contains(where: { $0.portType == .builtInReceiver }) { return .builtInReceiver }
        if outputs.contains(where: {
            $0.portType == .bluetoothA2DP || $0.portType == .bluetoothHFP
                || $0.portType == .bluetoothLE
        }) { return .bluetooth }
        if outputs.contains(where: { $0.portType == .airPlay }) { return .airPlay }
        if outputs.contains(where: {
            $0.portType == .headphones || $0.portType == .headsetMic
                || $0.portType == .usbAudio || $0.portType == .lineOut
        }) { return .wired }
        return .unknown
    }

    private func makeNetworkStats(from report: RTCStatisticsReport) -> CallNetworkStats {
        let statistics = Array(report.statistics.values)
        let candidatePairs = statistics.filter { $0.type == "candidate-pair" }
        let selectedPair = candidatePairs.first(where: {
            Self.bool($0.values["selected"]) == true
        }) ?? candidatePairs.first(where: {
            Self.bool($0.values["nominated"]) == true
                && Self.string($0.values["state"]) == "succeeded"
        })

        let inboundAudio = statistics.filter {
            $0.type == "inbound-rtp" && Self.isAudioStats($0.values)
        }
        let outboundAudio = statistics.filter {
            $0.type == "outbound-rtp" && Self.isAudioStats($0.values)
        }
        let remoteInboundAudio = statistics.filter {
            $0.type == "remote-inbound-rtp" && Self.isAudioStats($0.values)
        }
        let inboundVideo = statistics.filter {
            $0.type == "inbound-rtp" && Self.isVideoStats($0.values)
        }
        let outboundVideo = statistics.filter {
            $0.type == "outbound-rtp" && Self.isVideoStats($0.values)
        }
        let remoteInboundVideo = statistics.filter {
            $0.type == "remote-inbound-rtp" && Self.isVideoStats($0.values)
        }

        let packetsLost = inboundAudio.compactMap { Self.int64($0.values["packetsLost"]) }.reduce(0, +)
        let packetsReceived = inboundAudio.compactMap {
            Self.int64($0.values["packetsReceived"])
        }.reduce(0, +)
        let jitterSeconds = inboundAudio.compactMap { Self.double($0.values["jitter"]) }.max()
        let roundTripSeconds = Self.double(selectedPair?.values["currentRoundTripTime"])
            ?? remoteInboundAudio.compactMap { Self.double($0.values["roundTripTime"]) }.max()
        let totalOutboundBytes = outboundAudio.compactMap {
            Self.double($0.values["bytesSent"])
        }.reduce(0, +)

        let now = ProcessInfo.processInfo.systemUptime
        var audioBitrate: Double?
        if let previousBytes = lastOutboundBytes, let previousTime = lastStatsTimestamp,
           totalOutboundBytes >= previousBytes, now > previousTime {
            audioBitrate = (totalOutboundBytes - previousBytes) * 8 / (now - previousTime)
        }
        lastOutboundBytes = totalOutboundBytes
        lastStatsTimestamp = now

        let videoPacketsSent = outboundVideo.compactMap {
            Self.int64($0.values["packetsSent"])
        }.reduce(0, +)
        let senderVideoPacketsLost = remoteInboundVideo.compactMap {
            Self.int64($0.values["packetsLost"])
        }.reduce(0, +)
        let videoPacketsReceived = inboundVideo.compactMap {
            Self.int64($0.values["packetsReceived"])
        }.reduce(0, +)
        let receiverVideoPacketsLost = inboundVideo.compactMap {
            Self.int64($0.values["packetsLost"])
        }.reduce(0, +)
        let videoFramesDecoded = inboundVideo.compactMap {
            Self.int64($0.values["framesDecoded"])
        }.reduce(0, +)
        let videoFreezeSeconds = inboundVideo.compactMap {
            Self.double($0.values["totalFreezesDuration"])
        }.reduce(0, +)

        return CallNetworkStats(
            roundTripTimeMilliseconds: roundTripSeconds.map { $0 * 1_000 },
            jitterMilliseconds: jitterSeconds.map { $0 * 1_000 },
            packetsLost: inboundAudio.isEmpty ? nil : packetsLost,
            packetsReceived: inboundAudio.isEmpty ? nil : packetsReceived,
            availableOutgoingBitrate: Self.double(selectedPair?.values["availableOutgoingBitrate"]),
            audioBitrate: audioBitrate,
            videoPacketsSent: outboundVideo.isEmpty ? nil : videoPacketsSent,
            videoPacketsLost: remoteInboundVideo.isEmpty ? nil : senderVideoPacketsLost,
            videoPacketsReceived: inboundVideo.isEmpty ? nil : videoPacketsReceived,
            videoInboundPacketsLost: inboundVideo.isEmpty ? nil : receiverVideoPacketsLost,
            videoJitterMilliseconds: inboundVideo.compactMap {
                Self.double($0.values["jitter"])
            }.max().map { $0 * 1_000 },
            videoFramesDecoded: inboundVideo.isEmpty ? nil : videoFramesDecoded,
            videoTotalFreezeMilliseconds: inboundVideo.isEmpty ? nil : videoFreezeSeconds * 1_000,
            videoDecodedFramesPerSecond: inboundVideo.compactMap {
                Self.double($0.values["framesPerSecond"])
            }.max()
        )
    }

    private static func isAudioStats(_ values: [String: NSObject]) -> Bool {
        string(values["kind"]) == "audio" || string(values["mediaType"]) == "audio"
    }

    private static func isVideoStats(_ values: [String: NSObject]) -> Bool {
        string(values["kind"]) == "video" || string(values["mediaType"]) == "video"
    }

    private static func string(_ value: NSObject?) -> String? {
        (value as? NSString).map(String.init)
    }

    private static func double(_ value: NSObject?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private static func int64(_ value: NSObject?) -> Int64? {
        (value as? NSNumber)?.int64Value
    }

    private static func bool(_ value: NSObject?) -> Bool? {
        (value as? NSNumber)?.boolValue
    }
}

extension WebRTCCallEngine: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didChange stateChanged: RTCSignalingState
    ) {}

    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didAdd stream: RTCMediaStream
    ) {
        let track = stream.videoTracks.first
        Task { @MainActor [weak self] in self?.installRemoteVideoTrack(track) }
    }

    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didRemove stream: RTCMediaStream
    ) {}

    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didChange newState: RTCIceConnectionState
    ) {
        let mapped: CallMediaConnectionState
        switch newState {
        case .new: mapped = .new
        case .checking: mapped = .checking
        case .connected, .completed: mapped = .connected
        case .disconnected: mapped = .disconnected
        case .failed, .count: mapped = .failed
        case .closed: mapped = .closed
        @unknown default: mapped = .failed
        }
        Task { @MainActor [weak self] in self?.emitConnectionState(mapped) }
    }

    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didChange newState: RTCIceGatheringState
    ) {}

    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didGenerate candidate: RTCIceCandidate
    ) {
        let signaled = CallICECandidate(
            sdpMid: candidate.sdpMid,
            sdpMLineIndex: candidate.sdpMLineIndex,
            candidate: candidate.sdp
        )
        Task { @MainActor [weak self] in
            guard let self, !self.stopped else { return }
            if self.iceConfiguration?.transportPolicy == .relayOnly,
               !Self.isRelayCandidate(signaled.candidate) {
                return
            }
            self.emit(.localCandidate(signaled))
        }
    }

    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didRemove candidates: [RTCIceCandidate]
    ) {}

    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didStartReceivingOn transceiver: RTCRtpTransceiver
    ) {
        guard transceiver.mediaType == .video else { return }
        let track = transceiver.receiver.track as? RTCVideoTrack
        Task { @MainActor [weak self] in self?.installRemoteVideoTrack(track) }
    }

    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didOpen dataChannel: RTCDataChannel
    ) {
        // Toj voice calls have no data channels. A negotiated channel is not
        // used and is closed with the peer connection.
    }

    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didChange newState: RTCPeerConnectionState
    ) {
        let mapped: CallMediaConnectionState
        switch newState {
        case .new: mapped = .new
        case .connecting: mapped = .checking
        case .connected: mapped = .connected
        case .disconnected: mapped = .disconnected
        case .failed: mapped = .failed
        case .closed: mapped = .closed
        @unknown default: mapped = .failed
        }
        Task { @MainActor [weak self] in self?.emitConnectionState(mapped) }
    }
}

#endif
