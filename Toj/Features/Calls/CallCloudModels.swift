import Foundation

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
    let id: String
    let dialogId: String
    let callerAccountId: String
    let callerDeviceId: String
    let calleeAccountId: String
    let state: String
    let offeredProtocolVersions: [Int]
    let offeredMediaProfileVersions: [Int]
    let protocolVersion: Int?
    let mediaProfileVersion: Int?
    let callerCommitment: String
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
    let latestEventSeq: Int64
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
    let call: CloudCallSnapshot
}

nonisolated struct CloudCallCreateResponse: Codable, Equatable, Sendable {
    let call: CloudCallSnapshot
    let ringTargetCount: Int
}

nonisolated struct CloudActiveCallsResponse: Codable, Equatable, Sendable {
    let calls: [CloudCallSnapshot]
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
