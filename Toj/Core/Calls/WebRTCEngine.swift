import Foundation
import UIKit

nonisolated enum CallICETransportPolicy: String, Codable, Sendable {
    case all
    case relayOnly = "relay_only"
}

nonisolated extension CallPrivacyMode {
    var iceTransportPolicy: CallICETransportPolicy {
        switch self {
        case .fastestRoute: .all
        case .relayOnly: .relayOnly
        }
    }
}

nonisolated struct CallICEServer: Equatable, Sendable {
    let urls: [String]
    let username: String?
    let credential: String?
}

nonisolated struct CallICEConfiguration: Equatable, Sendable {
    let servers: [CallICEServer]
    let transportPolicy: CallICETransportPolicy
}

nonisolated struct CallLocalMediaIdentity: Equatable, Sendable {
    /// Raw SHA-256 digest of the generated DTLS certificate.
    let dtlsFingerprintSHA256: Data
}

nonisolated enum CallSDPType: String, Codable, Sendable {
    case offer
    case answer
}

nonisolated struct CallSessionDescription: Codable, Equatable, Sendable {
    let type: CallSDPType
    let sdp: String
}

nonisolated struct CallICECandidate: Codable, Equatable, Sendable {
    let sdpMid: String?
    let sdpMLineIndex: Int32
    let candidate: String

    enum CodingKeys: String, CodingKey {
        case sdpMid = "sdp_mid"
        case sdpMLineIndex = "sdp_mline_index"
        case candidate
    }
}

/// A relay-only device must ignore host and server-reflexive candidates from a peer that chose
/// fastest-route. Those candidates are valid for the peer, but installing them locally would break
/// the privacy promise. Dropping them still lets the two devices converge on TURN relay candidates.
nonisolated enum CallICECandidatePolicy {
    static func isRelay(_ candidate: String) -> Bool {
        let fields = candidate.lowercased().split(whereSeparator: {
            $0 == " " || $0 == "\t"
        })
        guard let typeIndex = fields.firstIndex(of: "typ"),
              fields.indices.contains(typeIndex + 1) else {
            return false
        }
        return fields[typeIndex + 1] == "relay"
    }

    static func permits(_ candidate: String, transportPolicy: CallICETransportPolicy) -> Bool {
        transportPolicy == .all || isRelay(candidate)
    }
}

nonisolated enum CallAudioRoute: String, Codable, CaseIterable, Sendable {
    case builtInReceiver = "built_in_receiver"
    case speaker
    case bluetooth
    case wired
    case airPlay = "air_play"
    case unknown
}

nonisolated enum CallMediaConnectionState: String, Codable, Sendable {
    case new
    case checking
    case connected
    case disconnected
    case failed
    case closed
}

nonisolated struct CallNetworkStats: Equatable, Sendable {
    let roundTripTimeMilliseconds: Double?
    let jitterMilliseconds: Double?
    let packetsLost: Int64?
    let packetsReceived: Int64?
    let availableOutgoingBitrate: Double?
    let audioBitrate: Double?
    let videoPacketsSent: Int64?
    let videoPacketsLost: Int64?
    let videoPacketsReceived: Int64?
    let videoInboundPacketsLost: Int64?
    let videoJitterMilliseconds: Double?
    let videoFramesDecoded: Int64?
    let videoTotalFreezeMilliseconds: Double?
    let videoDecodedFramesPerSecond: Double?

    init(
        roundTripTimeMilliseconds: Double?,
        jitterMilliseconds: Double?,
        packetsLost: Int64?,
        packetsReceived: Int64?,
        availableOutgoingBitrate: Double?,
        audioBitrate: Double?,
        videoPacketsSent: Int64? = nil,
        videoPacketsLost: Int64? = nil,
        videoPacketsReceived: Int64? = nil,
        videoInboundPacketsLost: Int64? = nil,
        videoJitterMilliseconds: Double? = nil,
        videoFramesDecoded: Int64? = nil,
        videoTotalFreezeMilliseconds: Double? = nil,
        videoDecodedFramesPerSecond: Double? = nil
    ) {
        self.roundTripTimeMilliseconds = roundTripTimeMilliseconds
        self.jitterMilliseconds = jitterMilliseconds
        self.packetsLost = packetsLost
        self.packetsReceived = packetsReceived
        self.availableOutgoingBitrate = availableOutgoingBitrate
        self.audioBitrate = audioBitrate
        self.videoPacketsSent = videoPacketsSent
        self.videoPacketsLost = videoPacketsLost
        self.videoPacketsReceived = videoPacketsReceived
        self.videoInboundPacketsLost = videoInboundPacketsLost
        self.videoJitterMilliseconds = videoJitterMilliseconds
        self.videoFramesDecoded = videoFramesDecoded
        self.videoTotalFreezeMilliseconds = videoTotalFreezeMilliseconds
        self.videoDecodedFramesPerSecond = videoDecodedFramesPerSecond
    }
}

nonisolated enum CallVideoRendererSource: Equatable, Sendable {
    case local
    case remote
}

/// Coarse, device-local capture health. It deliberately carries no device name, camera format,
/// resolution, or diagnostic text so it can be consumed by the lifecycle reducer without ever
/// becoming signaling or telemetry payload.
nonisolated struct CallVideoCaptureHealth: Equatable, Sendable {
    let interrupted: Bool
    let runtimeFailed: Bool
    let cameraAvailable: Bool
    let pressureCritical: Bool
}

/// Framework-neutral ownership token for the concrete RTC renderer. Two independent remote
/// handles may be attached concurrently (main call UI and PiP) to the same remote track.
@MainActor
final class CallVideoRendererHandle: @unchecked Sendable, Identifiable {
    let id: UUID
    let view: UIView
    let implementation: AnyObject

    init(id: UUID = UUID(), view: UIView, implementation: AnyObject) {
        self.id = id
        self.view = view
        self.implementation = implementation
    }
}

nonisolated enum WebRTCEvent: Equatable, Sendable {
    case localCandidate(CallICECandidate)
    case connectionStateChanged(CallMediaConnectionState)
    case audioRouteChanged(CallAudioRoute)
    case remoteVideoAvailabilityChanged(Bool)
    case localVideoCaptureHealthChanged(CallVideoCaptureHealth)
}

nonisolated enum WebRTCEngineError: Error, Equatable {
    case frameworkUnavailable
    case notPrepared
    case invalidFingerprint
    case operationFailed
    case mediaProfileAlreadyConfigured
    case incompatibleMediaProfile
    case cameraUnavailable
}

/// Framework-neutral seam around the official WebRTC implementation. All SDP
/// and candidates returned by this interface must pass through CallCipherSession
/// before transport.
protocol WebRTCEngine: Sendable {
    /// Generates and retains one DTLS certificate before the call is created,
    /// so its fingerprint can be included in the initial commitment. The same
    /// certificate must be installed on the eventual peer connection.
    func prepareLocalIdentity() async throws -> CallLocalMediaIdentity
    /// Installs initial or renewed ICE/TURN configuration without replacing the
    /// retained DTLS identity. Used after call creation and at credential refresh.
    func updateICEConfiguration(_ configuration: CallICEConfiguration) async throws
    /// One-shot media graph configuration. An identical retry is harmless; changing either
    /// argument after configuration fails closed. It must complete before any local or remote SDP.
    func configureMediaProfile(_ profile: UInt16, initialCameraIntent: Bool) async throws
    /// Creates the SDP and installs it as the peer connection's local description.
    func makeOffer(iceRestart: Bool) async throws -> CallSessionDescription
    /// Creates the SDP and installs it as the peer connection's local description.
    func makeAnswer() async throws -> CallSessionDescription
    /// Must parse the remote SDP fingerprint and compare its raw SHA-256 value
    /// with the committed fingerprint before installing the description.
    func setRemoteDescription(
        _ description: CallSessionDescription,
        expectedDTLSFingerprintSHA256: Data
    ) async throws
    func addRemoteICECandidate(_ candidate: CallICECandidate) async throws
    /// Called only from CallKit's audio-session activation/deactivation callbacks.
    func setAudioSessionActive(_ active: Bool) async
    func setMuted(_ muted: Bool) async
    func setCameraEnabled(_ enabled: Bool, position: CallCameraPosition) async throws
    func switchCamera(to position: CallCameraPosition) async throws
    func setVideoQualityTier(
        _ tier: CallVideoQualityTier,
        maximumFramesPerSecond: Int?
    ) async throws
    func makeVideoRenderer(source: CallVideoRendererSource) async throws -> CallVideoRendererHandle
    func releaseVideoRenderer(_ handle: CallVideoRendererHandle) async
    /// True only when the concrete capture session and the signed app entitlement permit camera
    /// capture while the owning scene is backgrounded in an active video-call PiP session.
    func supportsBackgroundCameraAccess() async -> Bool
    func setPreferredAudioRoute(_ route: CallAudioRoute) async throws
    func statistics() async -> CallNetworkStats?
    func events() async -> AsyncStream<WebRTCEvent>
    func stop() async
}

/// Fail-closed placeholder used until the pinned WebRTC XCFramework is linked.
/// It never simulates a connected or encrypted call.
actor UnavailableWebRTCEngine: WebRTCEngine {
    func prepareLocalIdentity() async throws -> CallLocalMediaIdentity {
        throw WebRTCEngineError.frameworkUnavailable
    }

    func updateICEConfiguration(_ configuration: CallICEConfiguration) async throws {
        throw WebRTCEngineError.frameworkUnavailable
    }

    func configureMediaProfile(_ profile: UInt16, initialCameraIntent: Bool) async throws {
        throw WebRTCEngineError.frameworkUnavailable
    }

    func makeOffer(iceRestart: Bool) async throws -> CallSessionDescription {
        throw WebRTCEngineError.frameworkUnavailable
    }

    func makeAnswer() async throws -> CallSessionDescription {
        throw WebRTCEngineError.frameworkUnavailable
    }

    func setRemoteDescription(
        _ description: CallSessionDescription,
        expectedDTLSFingerprintSHA256: Data
    ) async throws {
        throw WebRTCEngineError.frameworkUnavailable
    }

    func addRemoteICECandidate(_ candidate: CallICECandidate) async throws {
        throw WebRTCEngineError.frameworkUnavailable
    }

    func setMuted(_ muted: Bool) async {}

    func setCameraEnabled(_ enabled: Bool, position: CallCameraPosition) async throws {
        throw WebRTCEngineError.frameworkUnavailable
    }

    func switchCamera(to position: CallCameraPosition) async throws {
        throw WebRTCEngineError.frameworkUnavailable
    }

    func setVideoQualityTier(
        _ tier: CallVideoQualityTier,
        maximumFramesPerSecond: Int?
    ) async throws {
        throw WebRTCEngineError.frameworkUnavailable
    }

    func makeVideoRenderer(source: CallVideoRendererSource) async throws -> CallVideoRendererHandle {
        throw WebRTCEngineError.frameworkUnavailable
    }

    func releaseVideoRenderer(_ handle: CallVideoRendererHandle) async {}

    func supportsBackgroundCameraAccess() async -> Bool { false }

    func setAudioSessionActive(_ active: Bool) async {}

    func setPreferredAudioRoute(_ route: CallAudioRoute) async throws {
        throw WebRTCEngineError.frameworkUnavailable
    }

    func statistics() async -> CallNetworkStats? {
        nil
    }

    func events() async -> AsyncStream<WebRTCEvent> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func stop() async {}
}
