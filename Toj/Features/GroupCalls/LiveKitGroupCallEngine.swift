import AVFoundation
import Foundation

#if canImport(LiveKit)
@preconcurrency import LiveKit

/// Tracks which authenticated epoch currently owns each finite cryptor key slot. A delayed
/// retirement task may target an epoch whose modulo slot has since been reused; in that case it
/// must not erase the newer occupant.
nonisolated struct GroupCallEpochKeySlots: Equatable, Sendable {
    private(set) var occupants: [Int32: Int64] = [:]
    let ringSize: Int64

    init(ringSize: Int64 = 16) {
        self.ringSize = ringSize
    }

    mutating func install(_ epoch: Int64) -> Int32 {
        let index = Int32(epoch % ringSize)
        occupants[index] = epoch
        return index
    }

    mutating func retire(_ epoch: Int64, currentEpoch: Int64) -> Int32? {
        let index = Int32(epoch % ringSize)
        guard epoch != currentEpoch, occupants[index] == epoch else { return nil }
        occupants[index] = nil
        return index
    }

    mutating func removeAll() {
        occupants.removeAll()
    }
}

/// SFU media adapter for group calls. It deliberately uses LiveKit's legacy `E2EEOptions`:
/// that path encrypts RTP frames above DTLS-SRTP without enabling an application data channel.
/// Server tokens independently deny data publishing.
@MainActor
final class LiveKitGroupCallEngine: NSObject, GroupCallMediaEngine {
    var onEvent: ((GroupCallEngineEvent) -> Void)?
    var isConnected: Bool { room?.connectionState == .connected }

    private let keyProvider = BaseKeyProvider(options: KeyProviderOptions(
        sharedKey: true,
        ratchetWindowSize: 0,
        uncryptedMagicBytes: Data(),
        failureTolerance: -1,
        keyRingSize: 16
    ))
    private var keySlots = GroupCallEpochKeySlots()
    private var room: Room?
    private var currentEpoch: Int64?
    private var participantId: String?
    private var authorizedParticipantIds: Set<String> = []
    private var authorizedCameraPublishers: Set<String> = []
    private var subscribedCameraPublishers: Set<String> = []
    private var authorizedScreenPublisher: String?
    private var cameraPosition: GroupCallCameraPosition = .front
    private var cameraTier: GroupCallQualityTier = .high
    private var publishedCameraTier: GroupCallQualityTier?
    private var screenShareActivationRequested = false
    private var failedDecryptions: [String: (count: Int, first: Date)] = [:]

    func installEpoch(_ material: GroupCallEpochMaterial) throws {
        guard material.epoch > 0,
              material.mediaKey.count == GroupCallCrypto.mediaKeyByteCount else {
            throw GroupCallEngineError.invalidEpoch
        }
        let index = keySlots.install(material.epoch)
        keyProvider.setKey(key: material.mediaKey.base64EncodedString(), index: index)
        keyProvider.setCurrentKeyIndex(index)
        guard keyProvider.getCurrentKeyIndex() == index,
              keyProvider.exportKey(index: index) != nil else {
            throw GroupCallEngineError.encryptionFailure
        }
        currentEpoch = material.epoch
    }

    func retireEpoch(_ epoch: Int64) {
        guard epoch > 0,
              let currentEpoch,
              let index = keySlots.retire(epoch, currentEpoch: currentEpoch) else { return }
        keyProvider.setKey(
            key: GroupCallCrypto.randomBytes(count: 32).base64EncodedString(),
            index: index
        )
        keyProvider.setCurrentKeyIndex(keyIndex(for: currentEpoch))
    }

    func setAuthorizedParticipants(
        _ participantIds: Set<String>,
        cameraPublishers: Set<String>,
        screenPublisher: String?
    ) async throws {
        guard cameraPublishers.isSubset(of: participantIds),
              screenPublisher.map(participantIds.contains) ?? true else {
            throw GroupCallEngineError.encryptionFailure
        }
        authorizedParticipantIds = participantIds
        authorizedCameraPublishers = cameraPublishers
        authorizedScreenPublisher = screenPublisher
        refreshCameraSubscriptionSelection()
        try await synchronizeSubscriptions()
        emitMediaSnapshot()
    }

    func connect(credentials: CloudGroupCallCredentials) async throws {
        guard room == nil else { throw GroupCallEngineError.alreadyConnected }
        guard currentEpoch != nil else { throw GroupCallEngineError.missingEpochKey }
        guard credentials.mediaEpoch == currentEpoch else {
            throw GroupCallEngineError.credentialsEpochMismatch
        }
        guard GroupCallEngineFactory.isAvailable else {
            throw GroupCallEngineError.unsupportedRuntime
        }

        try configureAudioSession()
        let videoLayers = [
            VideoParameters(
                dimensions: .h180_169,
                encoding: VideoEncoding(
                    maxBitrate: GroupCallQualityTier.low.maximumVideoBitrate,
                    maxFps: GroupCallQualityTier.low.captureFramesPerSecond
                )
            ),
            VideoParameters(
                dimensions: .h360_169,
                encoding: VideoEncoding(
                    maxBitrate: GroupCallQualityTier.medium.maximumVideoBitrate,
                    maxFps: GroupCallQualityTier.medium.captureFramesPerSecond
                )
            ),
        ]
        let screenLayers = [
            VideoParameters(
                dimensions: .h360_169,
                encoding: VideoEncoding(maxBitrate: 350_000, maxFps: 5)
            ),
            VideoParameters(
                dimensions: .h720_169,
                encoding: VideoEncoding(maxBitrate: 1_500_000, maxFps: 15)
            ),
        ]
        let videoPublish = VideoPublishOptions(
            encoding: VideoEncoding(
                maxBitrate: GroupCallQualityTier.high.maximumVideoBitrate,
                maxFps: GroupCallQualityTier.high.captureFramesPerSecond
            ),
            screenShareEncoding: VideoEncoding(maxBitrate: 2_500_000, maxFps: 15),
            simulcast: true,
            simulcastLayers: videoLayers,
            screenShareSimulcastLayers: screenLayers,
            preferredCodec: .h264,
            preferredBackupCodec: nil,
            degradationPreference: .balanced
        )
        let options = RoomOptions(
            defaultCameraCaptureOptions: CameraCaptureOptions(
                position: .front,
                dimensions: .h720_169,
                fps: 30
            ),
            defaultScreenShareCaptureOptions: ScreenShareCaptureOptions(
                dimensions: .h1080_169,
                fps: 15,
                appAudio: true,
                useBroadcastExtension: true
            ),
            defaultVideoPublishOptions: videoPublish,
            defaultAudioPublishOptions: AudioPublishOptions(
                encoding: AudioEncoding(maxBitrate: 32_000),
                dtx: true,
                red: true
            ),
            adaptiveStream: true,
            dynacast: true,
            stopLocalTrackOnUnpublish: true,
            suspendLocalVideoTracksInBackground: true,
            e2eeOptions: E2EEOptions(keyProvider: keyProvider, encryptionType: .gcm),
            encryptionOptions: nil,
            reportRemoteTrackStatistics: true,
            singlePeerConnection: true
        )
        let connectOptions = ConnectOptions(
            autoSubscribe: false,
            reconnectAttempts: 12,
            reconnectAttemptDelay: 0.3,
            reconnectMaxDelay: 7,
            isDscpEnabled: true,
            enableMicrophone: false
        )
        let room = Room(delegate: self, connectOptions: connectOptions, roomOptions: options)
        self.room = room
        participantId = credentials.participantId
        onEvent?(.connection(.connecting))
        do {
            try await room.connect(
                url: credentials.url,
                token: credentials.token,
                connectOptions: connectOptions,
                roomOptions: options
            )
        } catch {
            await room.disconnect()
            self.room = nil
            participantId = nil
            onEvent?(.connection(.disconnected))
            throw error
        }
        try await synchronizeSubscriptions()
        emitMediaSnapshot()
    }

    func setMicrophone(enabled: Bool) async throws {
        guard let room else { throw GroupCallEngineError.notConnected }
        try await room.localParticipant.setMicrophone(enabled: enabled)
        emitMediaSnapshot()
    }

    func setCamera(
        enabled: Bool,
        position: GroupCallCameraPosition,
        tier: GroupCallQualityTier
    ) async throws {
        guard let room else { throw GroupCallEngineError.notConnected }
        cameraPosition = position
        cameraTier = tier
        guard enabled else {
            try await room.localParticipant.setCamera(enabled: false)
            emitMediaSnapshot()
            return
        }
        let options = cameraOptions(position: position, tier: tier)
        if let publication = room.localParticipant.firstCameraPublication as? LocalTrackPublication,
           publishedCameraTier != tier {
            // Capture dimensions alone do not replace the publish options that bound RTP sender
            // encodings. Republish only on a tier transition so congestion/data-saver bitrate
            // caps actually reach the sender without reconfiguring capture every second.
            try await room.localParticipant.unpublish(publication: publication)
            publishedCameraTier = nil
        }
        if let track = room.localParticipant.firstCameraPublication?.track as? LocalVideoTrack,
           let capturer = track.capturer as? CameraCapturer {
            _ = try await capturer.set(options: options)
            try await room.localParticipant.setCamera(enabled: true)
        } else {
            try await room.localParticipant.setCamera(
                enabled: true,
                captureOptions: options,
                publishOptions: VideoPublishOptions(
                    encoding: VideoEncoding(
                        maxBitrate: tier.maximumVideoBitrate,
                        maxFps: tier.captureFramesPerSecond
                    ),
                    simulcast: true,
                    preferredCodec: .h264,
                    preferredBackupCodec: nil,
                    degradationPreference: .balanced
                )
            )
            publishedCameraTier = tier
        }
        emitMediaSnapshot()
    }

    func switchCamera(to position: GroupCallCameraPosition) async throws {
        guard let room,
              let track = room.localParticipant.firstCameraPublication?.track as? LocalVideoTrack,
              let capturer = track.capturer as? CameraCapturer else {
            throw GroupCallEngineError.cameraUnavailable
        }
        _ = try await capturer.set(options: cameraOptions(position: position, tier: cameraTier))
        cameraPosition = position
        emitMediaSnapshot()
    }

    func senderSample() async -> GroupCallSenderSample? {
        guard let participant = room?.localParticipant,
              let statistics = participant.firstCameraPublication?.track?.statistics
                ?? participant.firstAudioPublication?.track?.statistics else {
            return nil
        }
        let videoFeedback = statistics.remoteInboundRtpStream.filter { $0.kind == "video" }
        let feedback = videoFeedback.isEmpty ? statistics.remoteInboundRtpStream : videoFeedback
        guard let loss = feedback.compactMap(\.fractionLost).max(),
              let roundTrip = feedback.compactMap(\.roundTripTime).max(),
              let jitter = feedback.compactMap(\.jitter).max(),
              let available = statistics.iceCandidatePair
                .compactMap(\.availableOutgoingBitrate).max(),
              loss.isFinite,
              roundTrip.isFinite,
              jitter.isFinite,
              available.isFinite else { return nil }
        return GroupCallSenderSample(
            packetLossPercent: max(0, loss * 100),
            roundTripMilliseconds: max(0, roundTrip * 1_000),
            jitterMilliseconds: max(0, jitter * 1_000),
            availableOutgoingBitrate: max(0, Int(available))
        )
    }

    func setScreenShare(enabled: Bool) async throws -> Bool {
        guard let room else { throw GroupCallEngineError.notConnected }
        guard GroupCallEngineFactory.supportsScreenShare else {
            throw GroupCallEngineError.screenShareUnavailable
        }
        if !enabled {
            try await room.localParticipant.setScreenShare(enabled: false)
            BroadcastManager.shared.requestStop()
            screenShareActivationRequested = false
            emitMediaSnapshot()
            return false
        }
        if !BroadcastManager.shared.isBroadcasting {
            guard !screenShareActivationRequested else { return false }
            screenShareActivationRequested = true
        }
        _ = try await room.localParticipant.setScreenShare(enabled: true)
        if room.localParticipant.isScreenShareEnabled() {
            screenShareActivationRequested = false
        }
        emitMediaSnapshot()
        return room.localParticipant.isScreenShareEnabled()
    }

    func disconnect() async {
        guard let room else { return }
        BroadcastManager.shared.requestStop()
        _ = try? await room.localParticipant.setScreenShare(enabled: false)
        _ = try? await room.localParticipant.setCamera(enabled: false)
        _ = try? await room.localParticipant.setMicrophone(enabled: false)
        await room.disconnect()
        self.room = nil
        participantId = nil
        currentEpoch = nil
        keySlots.removeAll()
        publishedCameraTier = nil
        screenShareActivationRequested = false
        authorizedParticipantIds.removeAll()
        authorizedCameraPublishers.removeAll()
        subscribedCameraPublishers.removeAll()
        authorizedScreenPublisher = nil
        failedDecryptions.removeAll()
        onEvent?(.videoTracks([]))
        onEvent?(.participants([]))
        onEvent?(.connection(.disconnected))
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: [.notifyOthersOnDeactivation]
        )
    }

    private func keyIndex(for epoch: Int64) -> Int32 {
        Int32(epoch % 16)
    }

    private func cameraOptions(
        position: GroupCallCameraPosition,
        tier: GroupCallQualityTier
    ) -> CameraCaptureOptions {
        CameraCaptureOptions(
            position: position == .front ? .front : .back,
            dimensions: dimensions(for: tier),
            fps: tier.captureFramesPerSecond
        )
    }

    private func dimensions(for tier: GroupCallQualityTier) -> Dimensions {
        switch tier {
        case .low: .h180_169
        case .medium: .h360_169
        case .high: .h720_169
        }
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .videoChat,
            options: [.allowBluetoothHFP, .allowBluetoothA2DP, .allowAirPlay, .defaultToSpeaker]
        )
        try session.setActive(true)
    }

    private func synchronizeSubscriptions() async throws {
        guard let room else { return }
        refreshCameraSubscriptionSelection()
        for participant in room.remoteParticipants.values {
            guard let identity = participant.identity?.stringValue else {
                for publication in participant.trackPublications.values {
                    if let remote = publication as? RemoteTrackPublication {
                        try await remote.set(subscribed: false)
                    }
                }
                continue
            }
            for publication in participant.trackPublications.values {
                guard let remote = publication as? RemoteTrackPublication else { continue }
                try await remote.set(subscribed: shouldSubscribe(remote, participantId: identity))
            }
        }
    }

    private func shouldSubscribe(
        _ publication: RemoteTrackPublication,
        participantId: String
    ) -> Bool {
        guard authorizedParticipantIds.contains(participantId) else { return false }
        switch publication.source {
        case .microphone:
            return true
        case .camera:
            return subscribedCameraPublishers.contains(participantId)
        case .screenShareVideo, .screenShareAudio:
            return authorizedScreenPublisher == participantId
        case .unknown:
            return false
        @unknown default:
            return false
        }
    }

    private func refreshCameraSubscriptionSelection() {
        guard let room else {
            subscribedCameraPublishers.removeAll()
            return
        }
        let ranked = room.remoteParticipants.values.compactMap { participant -> (String, Bool, Bool)? in
            guard let id = participant.identity?.stringValue,
                  authorizedParticipantIds.contains(id),
                  authorizedCameraPublishers.contains(id) else { return nil }
            return (id, participant.isSpeaking, subscribedCameraPublishers.contains(id))
        }.sorted { left, right in
            if left.1 != right.1 { return left.1 }
            if left.2 != right.2 { return left.2 }
            return left.0 < right.0
        }
        subscribedCameraPublishers = Set(ranked.prefix(9).map(\.0))
    }

    private func emitMediaSnapshot() {
        guard let room else { return }
        let allParticipants: [(participant: Participant, id: String, isLocal: Bool)] = [
            (room.localParticipant, participantId ?? room.localParticipant.identity?.stringValue ?? "local", true),
        ] + room.remoteParticipants.values.compactMap { participant in
            guard let identity = participant.identity?.stringValue,
                  authorizedParticipantIds.contains(identity) else { return nil }
            return (participant, identity, false)
        }

        let participants = allParticipants.map { item in
            GroupCallEngineParticipant(
                id: item.id,
                isSpeaking: item.participant.isSpeaking,
                connectionQuality: qualityName(item.participant.connectionQuality),
                hasCamera: authorizedCameraPublishers.contains(item.id) && (
                    item.participant.firstCameraPublication.map {
                        !$0.isMuted && $0.track != nil
                    } ?? false
                ),
                hasScreenShare: authorizedScreenPublisher == item.id && (
                    item.participant.firstScreenSharePublication.map {
                        !$0.isMuted && $0.track != nil
                    } ?? false
                )
            )
        }
        var tracks: [GroupCallVideoTrackReference] = []
        for item in allParticipants {
            if authorizedCameraPublishers.contains(item.id),
               let camera = item.participant.firstCameraVideoTrack {
                tracks.append(GroupCallVideoTrackReference(
                    id: "\(item.id):camera",
                    participantId: item.id,
                    source: .camera,
                    isLocal: item.isLocal,
                    opaqueTrack: camera
                ))
            }
            if authorizedScreenPublisher == item.id,
               let screen = item.participant.firstScreenShareVideoTrack {
                tracks.append(GroupCallVideoTrackReference(
                    id: "\(item.id):screen",
                    participantId: item.id,
                    source: .screenShare,
                    isLocal: item.isLocal,
                    opaqueTrack: screen
                ))
            }
        }
        onEvent?(.participants(participants.sorted(by: { $0.id < $1.id })))
        onEvent?(.videoTracks(tracks.sorted(by: { $0.id < $1.id })))
    }

    private func qualityName(_ quality: ConnectionQuality) -> String {
        switch quality {
        case .excellent: "excellent"
        case .good: "good"
        case .poor: "poor"
        case .lost: "lost"
        case .unknown: "unknown"
        @unknown default: "unknown"
        }
    }

    private func handleE2EEState(_ state: E2EEState, trackId: String) {
        switch state {
        case .ok, .key_ratcheted:
            failedDecryptions[trackId] = nil
            onEvent?(.encryptionVerified(trackId: trackId))
        case .new:
            break
        case .missing_key, .decryption_failed:
            let now = Date()
            let prior = failedDecryptions[trackId]
            let value: (count: Int, first: Date)
            if let prior, now.timeIntervalSince(prior.first) <= 5 {
                value = (prior.count + 1, prior.first)
            } else {
                value = (1, now)
            }
            failedDecryptions[trackId] = value
            if value.count >= 3 {
                onEvent?(.encryptionFailure(trackId: trackId, reason: state.toString()))
            } else {
                onEvent?(.encryptionWarning(trackId: trackId, reason: state.toString()))
            }
        case .encryption_failed, .internal_error:
            onEvent?(.encryptionFailure(trackId: trackId, reason: state.toString()))
        @unknown default:
            onEvent?(.encryptionFailure(trackId: trackId, reason: "unknown"))
        }
    }
}

extension LiveKitGroupCallEngine: RoomDelegate {
    nonisolated func room(
        _ room: Room,
        didUpdateConnectionState connectionState: ConnectionState,
        from oldConnectionState: ConnectionState
    ) {
        _ = oldConnectionState
        let mapped: GroupCallEngineConnectionState = switch connectionState {
        case .disconnected, .disconnecting: .disconnected
        case .connecting: .connecting
        case .reconnecting: .reconnecting
        case .connected: .connected
        @unknown default: .disconnected
        }
        Task { @MainActor [weak self] in
            self?.onEvent?(.connection(mapped))
            self?.emitMediaSnapshot()
        }
    }

    nonisolated func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        _ = participant
        Task { @MainActor [weak self] in
            try? await self?.synchronizeSubscriptions()
            self?.emitMediaSnapshot()
        }
    }

    nonisolated func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        _ = participant
        Task { @MainActor [weak self] in self?.emitMediaSnapshot() }
    }

    nonisolated func room(
        _ room: Room,
        participant: RemoteParticipant,
        didPublishTrack publication: RemoteTrackPublication
    ) {
        _ = (room, participant, publication)
        Task { @MainActor [weak self] in
            try? await self?.synchronizeSubscriptions()
            self?.emitMediaSnapshot()
        }
    }

    nonisolated func room(_ room: Room, didUpdateSpeakingParticipants participants: [Participant]) {
        _ = participants
        Task { @MainActor [weak self] in
            self?.refreshCameraSubscriptionSelection()
            try? await self?.synchronizeSubscriptions()
            self?.emitMediaSnapshot()
        }
    }

    nonisolated func room(
        _ room: Room,
        participant: Participant,
        didUpdateConnectionQuality quality: ConnectionQuality
    ) {
        _ = (participant, quality)
        Task { @MainActor [weak self] in self?.emitMediaSnapshot() }
    }

    nonisolated func room(
        _ room: Room,
        participant: RemoteParticipant,
        didSubscribeTrack publication: RemoteTrackPublication
    ) {
        _ = (participant, publication)
        Task { @MainActor [weak self] in self?.emitMediaSnapshot() }
    }

    nonisolated func room(
        _ room: Room,
        participant: RemoteParticipant,
        didUnsubscribeTrack publication: RemoteTrackPublication
    ) {
        _ = (participant, publication)
        Task { @MainActor [weak self] in self?.emitMediaSnapshot() }
    }

    nonisolated func room(
        _ room: Room,
        participant: Participant,
        trackPublication: TrackPublication,
        didUpdateIsMuted isMuted: Bool
    ) {
        _ = (participant, trackPublication, isMuted)
        Task { @MainActor [weak self] in self?.emitMediaSnapshot() }
    }

    nonisolated func room(
        _ room: Room,
        trackPublication: TrackPublication,
        didUpdateE2EEState state: E2EEState
    ) {
        let trackId = trackPublication.sid.stringValue
        Task { @MainActor [weak self] in
            self?.handleE2EEState(state, trackId: trackId)
        }
    }
}
#endif
