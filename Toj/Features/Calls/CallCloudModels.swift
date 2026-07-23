import Foundation

nonisolated enum CloudCallViewKind: String, Codable, Sendable {
    case full
    case invitation
    case lifecycle
}

nonisolated indirect enum CloudJSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: CloudJSONValue])
    case array([CloudJSONValue])
    case null

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: CloudJSONValue].self) { self = .object(value) }
        else { self = .array(try container.decode([CloudJSONValue].self)) }
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

nonisolated struct CloudCallSnapshot: Codable, Identifiable, Equatable, Sendable {
    let view: CloudCallViewKind?
    let id: String
    let dialogId: String
    let callerAccountId: String
    let callerDeviceId: String
    let calleeAccountId: String
    let state: String
    let offeredProtocolVersions: [Int]
    let offeredMediaProfileVersions: [Int]
    let selectableMediaProfileVersions: [Int]?
    let initialKind: CallInitialKind?
    let protocolVersion: Int?
    let mediaProfileVersion: Int?
    let callerCommitment: String?
    let calleeCommitment: String?
    let callerFingerprint: String?
    let acceptedDeviceId: String?
    let calleePublicKey: String?
    let calleeNonce: String?
    let calleeFingerprint: String?
    let callerPublicKey: String?
    let callerNonce: String?
    let createdAt: String
    let expiresAt: String
    let acceptedAt: String?
    let confirmedAt: String?
    let endedAt: String?
    let endReason: String?
    let localRingStatus: String?
    let latestEventSeq: Int64
}

/// A device-scoped call response. Decoding enforces that invitation and lifecycle projections do
/// not accidentally grow setup secrets if the server projection regresses.
nonisolated enum CallViewDTO: Codable, Equatable, Sendable {
    case full(CloudCallSnapshot)
    case invitation(CloudCallSnapshot)
    case lifecycle(CloudCallSnapshot)

    var snapshot: CloudCallSnapshot {
        switch self {
        case .full(let snapshot), .invitation(let snapshot), .lifecycle(let snapshot): snapshot
        }
    }

    init(from decoder: Decoder) throws {
        let snapshot = try CloudCallSnapshot(from: decoder)
        switch snapshot.view ?? .full {
        case .full:
            self = .full(snapshot)
        case .invitation:
            guard Self.excludesAcceptedSetup(snapshot) else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "Invitation exposed accepted-call setup state")
                )
            }
            self = .invitation(snapshot)
        case .lifecycle:
            guard Self.excludesAcceptedSetup(snapshot),
                  snapshot.callerCommitment == nil,
                  snapshot.offeredProtocolVersions.isEmpty,
                  snapshot.offeredMediaProfileVersions.isEmpty,
                  (snapshot.selectableMediaProfileVersions ?? []).isEmpty,
                  snapshot.state == "ended",
                  snapshot.acceptedAt == nil,
                  snapshot.confirmedAt == nil,
                  snapshot.latestEventSeq == 0
            else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "Lifecycle projection exposed negotiation state")
                )
            }
            self = .lifecycle(snapshot)
        }
    }

    func encode(to encoder: Encoder) throws {
        try snapshot.encode(to: encoder)
    }

    private static func excludesAcceptedSetup(_ snapshot: CloudCallSnapshot) -> Bool {
        snapshot.protocolVersion == nil
            && snapshot.mediaProfileVersion == nil
            && snapshot.calleeCommitment == nil
            && snapshot.callerFingerprint == nil
            && snapshot.acceptedDeviceId == nil
            && snapshot.calleePublicKey == nil
            && snapshot.calleeNonce == nil
            && snapshot.calleeFingerprint == nil
            && snapshot.callerPublicKey == nil
            && snapshot.callerNonce == nil
    }
}

nonisolated struct VoIPPushRegistrationRequest: Codable, Equatable, Sendable {
    let token: String
    let environment: String
    let supportedCallProtocolVersions: [Int]
    let supportedCallMediaProfileVersions: [Int]
    let callViewVersion: Int
}

nonisolated struct CloudCallEvent: Codable, Identifiable, Equatable, Sendable {
    var id: Int64 { eventSeq }
    let eventSeq: Int64
    let type: String
    let senderAccountId: String?
    let senderDeviceId: String?
    let senderSequence: Int64?
    let version: Int?
    let kind: String?
    let ciphertext: String?
    let expiresAtMilliseconds: Int64?
    let data: CloudJSONValue?
    let createdAt: String
    let expiresAt: String
}

nonisolated struct CloudCallResponse: Codable, Equatable, Sendable {
    let callView: CallViewDTO
    var call: CloudCallSnapshot { callView.snapshot }

    private enum CodingKeys: String, CodingKey { case call }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        callView = try container.decode(CallViewDTO.self, forKey: .call)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(callView, forKey: .call)
    }
}

nonisolated struct CloudCallCreateResponse: Codable, Equatable, Sendable {
    let callView: CallViewDTO
    let ringTargetCount: Int
    var call: CloudCallSnapshot { callView.snapshot }

    private enum CodingKeys: String, CodingKey { case call, ringTargetCount }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        callView = try container.decode(CallViewDTO.self, forKey: .call)
        ringTargetCount = try container.decode(Int.self, forKey: .ringTargetCount)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(callView, forKey: .call)
        try container.encode(ringTargetCount, forKey: .ringTargetCount)
    }
}

nonisolated struct CloudActiveCallsResponse: Codable, Equatable, Sendable {
    let callViews: [CallViewDTO]
    var calls: [CloudCallSnapshot] { callViews.map(\.snapshot) }

    private enum CodingKeys: String, CodingKey { case calls }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        callViews = try container.decode([CallViewDTO].self, forKey: .calls)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(callViews, forKey: .calls)
    }
}

nonisolated struct CloudCallEventResponse: Codable, Equatable, Sendable {
    let event: CloudCallEvent
}

nonisolated struct CloudCallEventsResponse: Codable, Equatable, Sendable {
    let callId: String
    let events: [CloudCallEvent]
    let latestEventSeq: Int64
    let hasMore: Bool
}

nonisolated struct CloudCallIceServer: Codable, Equatable, Sendable {
    let urls: [String]
    let username: String?
    let credential: String?
}

nonisolated struct CloudCallIceConfiguration: Codable, Equatable, Sendable {
    let ttlSeconds: Int
    let iceServers: [CloudCallIceServer]
}

nonisolated struct CreateCloudCallRequest: Codable, Equatable, Sendable {
    let callId: String
    let dialogId: String
    let callerCommitment: String
    let supportedProtocolVersions: [Int]
    let offeredMediaProfileVersions: [Int]
}

nonisolated struct AcceptCloudCallRequest: Codable, Equatable, Sendable {
    let calleeCommitment: String
    let protocolVersion: Int
    let selectedMediaProfileVersion: Int
}

nonisolated struct RevealCloudCallRequest: Codable, Equatable, Sendable {
    let publicKey: String
    let nonce: String
    let fingerprint: String
    let confirmation: String?
}

nonisolated struct ConfirmCloudCallRequest: Codable, Equatable, Sendable {
    let confirmation: String
}

nonisolated struct EndCloudCallRequest: Codable, Equatable, Sendable {
    let reason: String?
}

nonisolated struct SendCloudCallEventRequest: Codable, Equatable, Sendable {
    let version: Int
    let kind: String
    let senderSequence: Int64
    let ciphertext: String
    let expiresAtMilliseconds: Int64
}

nonisolated struct CloudBlockResponse: Codable, Equatable, Sendable {
    let blocked: Bool
}

/// One privacy-preserving telemetry report sent after a call reaches a terminal state. Every field
/// is a pinned bucket label or enumeration the server independently re-validates. Property names are
/// camelCase to match the server's request reader (the API uses no key-conversion strategy).
nonisolated struct CallTelemetryRequest: Codable, Equatable, Sendable {
    let outcome: String
    let role: String?
    let routeClass: String?
    let privacyMode: String?
    let setupBucket: String?
    let recoveryBucket: String?
    let rttBucket: String?
    let lossBucket: String?
    let jitterBucket: String?
    let bitrateBucket: String?
    let recoveryCount: Int
    let appVersion: String?
    let region: String?
}

nonisolated struct CloudCallTelemetryResponse: Codable, Equatable, Sendable {
    let recorded: Bool
}

/// The call coordinator depends only on this transport surface. Production uses `CloudAPI`;
/// deterministic tests can provide an in-memory fake without opening sockets.
protocol CallAPITransport {
    func createCall(_ body: CreateCloudCallRequest, token: String) async throws -> CloudCallCreateResponse
    func activeCalls(token: String) async throws -> CloudActiveCallsResponse
    func call(id: String, token: String) async throws -> CloudCallResponse
    func acceptCall(id: String, body: AcceptCloudCallRequest, token: String) async throws -> CloudCallResponse
    func revealCall(id: String, body: RevealCloudCallRequest, token: String) async throws -> CloudCallResponse
    func confirmCall(id: String, body: ConfirmCloudCallRequest, token: String) async throws -> CloudCallResponse
    func declineCall(id: String, reason: String?, token: String) async throws -> CloudCallResponse
    func cancelCall(id: String, reason: String?, token: String) async throws -> CloudCallResponse
    func endCall(id: String, reason: String?, token: String) async throws -> CloudCallResponse
    func sendCallEvent(
        callId: String,
        body: SendCloudCallEventRequest,
        token: String
    ) async throws -> CloudCallEventResponse
    func callEvents(
        callId: String,
        after eventSequence: Int64,
        limit: Int,
        token: String
    ) async throws -> CloudCallEventsResponse
    func sendCallTelemetry(
        callId: String,
        body: CallTelemetryRequest,
        token: String
    ) async throws -> CloudCallTelemetryResponse
    func callIceConfiguration(callId: String, token: String) async throws -> CloudCallIceConfiguration
}

extension CallAPITransport {
    func callEvents(
        callId: String,
        after eventSequence: Int64,
        token: String
    ) async throws -> CloudCallEventsResponse {
        try await callEvents(callId: callId, after: eventSequence, limit: 100, token: token)
    }
}

extension CloudAPI: CallAPITransport {}
