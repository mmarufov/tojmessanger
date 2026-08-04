import Foundation

@MainActor
final class GroupCallVideoTrackReference: Identifiable, Equatable, @unchecked Sendable {
    nonisolated let id: String
    nonisolated let participantId: String
    nonisolated let source: Source
    nonisolated let isLocal: Bool
    nonisolated let opaqueIdentity: ObjectIdentifier
    let opaqueTrack: AnyObject

    nonisolated enum Source: String, Sendable {
        case camera
        case screenShare = "screen_share"
    }

    init(
        id: String,
        participantId: String,
        source: Source,
        isLocal: Bool,
        opaqueTrack: AnyObject
    ) {
        self.id = id
        self.participantId = participantId
        self.source = source
        self.isLocal = isLocal
        opaqueIdentity = ObjectIdentifier(opaqueTrack)
        self.opaqueTrack = opaqueTrack
    }

    nonisolated static func == (lhs: GroupCallVideoTrackReference, rhs: GroupCallVideoTrackReference) -> Bool {
        lhs.id == rhs.id && lhs.opaqueIdentity == rhs.opaqueIdentity
    }
}

nonisolated enum GroupCallEngineConnectionState: String, Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case reconnecting
}

@MainActor
enum GroupCallEngineEvent {
    case connection(GroupCallEngineConnectionState)
    case participants([GroupCallEngineParticipant])
    case videoTracks([GroupCallVideoTrackReference])
    case encryptionVerified(trackId: String)
    case encryptionWarning(trackId: String, reason: String)
    case encryptionFailure(trackId: String, reason: String)
}

nonisolated enum GroupCallEngineError: Error, Equatable {
    case unavailable
    case unsupportedRuntime
    case invalidEpoch
    case missingEpochKey
    case credentialsEpochMismatch
    case alreadyConnected
    case notConnected
    case cameraUnavailable
    case screenShareUnavailable
    case encryptionFailure
}

@MainActor
protocol GroupCallMediaEngine: AnyObject, Sendable {
    var onEvent: ((GroupCallEngineEvent) -> Void)? { get set }
    var isConnected: Bool { get }

    func installEpoch(_ material: GroupCallEpochMaterial) throws
    func retireEpoch(_ epoch: Int64)
    func setAuthorizedParticipants(
        _ participantIds: Set<String>,
        cameraPublishers: Set<String>,
        screenPublisher: String?
    ) async throws
    func connect(credentials: CloudGroupCallCredentials) async throws
    func setMicrophone(enabled: Bool) async throws
    func setCamera(
        enabled: Bool,
        position: GroupCallCameraPosition,
        tier: GroupCallQualityTier
    ) async throws
    func switchCamera(to position: GroupCallCameraPosition) async throws
    func senderSample() async -> GroupCallSenderSample?
    /// Returns false after presenting ReplayKit's picker; the caller should retry after the
    /// broadcast extension connects while keeping its server lease alive.
    func setScreenShare(enabled: Bool) async throws -> Bool
    func disconnect() async
}

@MainActor
final class UnavailableGroupCallEngine: GroupCallMediaEngine {
    var onEvent: ((GroupCallEngineEvent) -> Void)?
    var isConnected: Bool { false }

    func installEpoch(_ material: GroupCallEpochMaterial) throws {
        _ = material
        throw GroupCallEngineError.unavailable
    }

    func retireEpoch(_ epoch: Int64) { _ = epoch }
    func setAuthorizedParticipants(
        _ participantIds: Set<String>,
        cameraPublishers: Set<String>,
        screenPublisher: String?
    ) async throws {
        _ = (participantIds, cameraPublishers, screenPublisher)
        throw GroupCallEngineError.unavailable
    }
    func connect(credentials: CloudGroupCallCredentials) async throws {
        _ = credentials
        throw GroupCallEngineError.unavailable
    }
    func setMicrophone(enabled: Bool) async throws {
        _ = enabled
        throw GroupCallEngineError.unavailable
    }
    func setCamera(
        enabled: Bool,
        position: GroupCallCameraPosition,
        tier: GroupCallQualityTier
    ) async throws {
        _ = (enabled, position, tier)
        throw GroupCallEngineError.unavailable
    }
    func switchCamera(to position: GroupCallCameraPosition) async throws {
        _ = position
        throw GroupCallEngineError.unavailable
    }
    func senderSample() async -> GroupCallSenderSample? { nil }
    func setScreenShare(enabled: Bool) async throws -> Bool {
        _ = enabled
        throw GroupCallEngineError.unavailable
    }
    func disconnect() async {}
}
