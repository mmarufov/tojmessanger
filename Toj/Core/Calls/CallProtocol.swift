import CryptoKit
import Foundation

nonisolated enum CallProtocolVersion {
    static let current: UInt16 = 1
    static let supported: [UInt16] = [current]
}

/// Independently versioned from the cryptographic protocol so codec and
/// transport behavior cannot be silently downgraded.
nonisolated enum CallMediaProfileVersion {
    static let current: UInt16 = 1
    static let supported: [UInt16] = [current]
}

nonisolated enum CallSignalKind: String, Codable, CaseIterable, Sendable {
    case offer
    case answer
    case iceCandidate = "ice_candidate"
    case iceRestart = "ice_restart"
    case hangup
    case control
}

/// Public, per-call material. All three values must be fresh for every call.
/// The fingerprint is the raw 32-byte SHA-256 digest, not its SDP rendering.
nonisolated struct CallKeyMaterialV1: Codable, Equatable, Sendable {
    let publicKey: Data
    let nonce: Data
    let dtlsFingerprintSHA256: Data

    enum CodingKeys: String, CodingKey {
        case publicKey = "public_key"
        case nonce
        case dtlsFingerprintSHA256 = "dtls_fingerprint_sha256"
    }
}

nonisolated struct CallHandshakeContextV1: Codable, Equatable, Sendable {
    let identity: CallIdentity
    let offeredProtocolVersions: [UInt16]
    let offeredMediaProfileVersions: [UInt16]

    enum CodingKeys: String, CodingKey {
        case identity
        case offeredProtocolVersions = "offered_protocol_versions"
        case offeredMediaProfileVersions = "offered_media_profile_versions"
    }
}

/// Initial request. The caller's public key, nonce and DTLS fingerprint are
/// intentionally omitted until the callee has committed its own material.
nonisolated struct CallInviteV1: Codable, Equatable, Sendable {
    let version: UInt16
    let callId: String
    let dialogId: String
    let callerAccountId: String
    let callerDeviceId: String
    let calleeAccountId: String
    let offeredProtocolVersions: [UInt16]
    let offeredMediaProfileVersions: [UInt16]
    let callerCommitment: Data
    let expiresAtMilliseconds: Int64

    enum CodingKeys: String, CodingKey {
        case version
        case callId = "call_id"
        case dialogId = "dialog_id"
        case callerAccountId = "caller_account_id"
        case callerDeviceId = "caller_device_id"
        case calleeAccountId = "callee_account_id"
        case offeredProtocolVersions = "offered_protocol_versions"
        case offeredMediaProfileVersions = "offered_media_profile_versions"
        case callerCommitment = "caller_commitment"
        case expiresAtMilliseconds = "expires_at_ms"
    }
}

/// The accepting device is selected atomically by the server. Its key
/// material remains hidden until the caller reveal has been validated.
nonisolated struct CallAcceptV1: Codable, Equatable, Sendable {
    let version: UInt16
    let callId: String
    let calleeDeviceId: String
    let selectedProtocolVersion: UInt16
    let selectedMediaProfileVersion: UInt16
    let calleeCommitment: Data

    enum CodingKeys: String, CodingKey {
        case version
        case callId = "call_id"
        case calleeDeviceId = "callee_device_id"
        case selectedProtocolVersion = "selected_protocol_version"
        case selectedMediaProfileVersion = "selected_media_profile_version"
        case calleeCommitment = "callee_commitment"
    }
}

nonisolated struct CallRevealV1: Codable, Equatable, Sendable {
    let version: UInt16
    let callId: String
    let role: CallRole
    let publicKey: Data
    let nonce: Data
    let dtlsFingerprintSHA256: Data

    enum CodingKeys: String, CodingKey {
        case version
        case callId = "call_id"
        case role
        case publicKey = "public_key"
        case nonce
        case dtlsFingerprintSHA256 = "dtls_fingerprint_sha256"
    }

    var keyMaterial: CallKeyMaterialV1 {
        CallKeyMaterialV1(
            publicKey: publicKey,
            nonce: nonce,
            dtlsFingerprintSHA256: dtlsFingerprintSHA256
        )
    }
}

nonisolated struct CallConfirmationV1: Codable, Equatable, Sendable {
    let version: UInt16
    let callId: String
    let role: CallRole
    let confirmationTag: Data

    enum CodingKeys: String, CodingKey {
        case version
        case callId = "call_id"
        case role
        case confirmationTag = "confirmation_tag"
    }
}

/// Opaque encrypted signaling persisted and relayed by the server. `Data`
/// fields use Codable's base64 JSON representation.
nonisolated struct CallEncryptedSignalV1: Codable, Equatable, Sendable {
    let version: UInt16
    let callId: String
    let senderDeviceId: String
    let kind: CallSignalKind
    let sequence: UInt64
    let ciphertext: Data
    let expiresAtMilliseconds: Int64

    enum CodingKeys: String, CodingKey {
        case version
        case callId = "call_id"
        case senderDeviceId = "sender_device_id"
        case kind
        case sequence
        case ciphertext
        case expiresAtMilliseconds = "expires_at_ms"
    }
}

nonisolated enum CallProtocolError: Error, Equatable {
    case emptyIdentifier(String)
    case identifierTooLong(String)
    case invalidVersionOffer
    case unsupportedSelectedVersion(UInt16)
    case unsupportedSelectedMediaProfileVersion(UInt16)
    case invalidKeyMaterial
    case invalidCommitment
}

/// Canonical binary encoding used for commitments, key derivation and
/// cross-platform test vectors. Every variable-length field has a UInt32
/// big-endian byte length. Integers are big-endian. Field order is immutable.
nonisolated enum CallProtocolV1 {
    static func callerCommitment(
        context: CallHandshakeContextV1,
        material: CallKeyMaterialV1
    ) throws -> Data {
        try validate(context: context)
        try validate(material: material)

        var encoder = CallBinaryEncoder()
        try encoder.append("toj-call-v1/caller-commitment")
        try append(context: context, to: &encoder)
        try append(material: material, to: &encoder)
        return Data(SHA256.hash(data: encoder.data))
    }

    static func calleeCommitment(
        context: CallHandshakeContextV1,
        callerCommitment: Data,
        callee: CallParty,
        selectedProtocolVersion: UInt16,
        selectedMediaProfileVersion: UInt16,
        material: CallKeyMaterialV1
    ) throws -> Data {
        try validate(context: context)
        try validate(commitment: callerCommitment)
        try validate(party: callee)
        try validate(selectedProtocolVersion, in: context)
        try validateMediaProfile(selectedMediaProfileVersion, in: context)
        try validate(material: material)

        var encoder = CallBinaryEncoder()
        try encoder.append("toj-call-v1/callee-commitment")
        try append(context: context, to: &encoder)
        try encoder.append(callerCommitment)
        try append(party: callee, to: &encoder)
        encoder.append(selectedProtocolVersion)
        encoder.append(selectedMediaProfileVersion)
        try append(material: material, to: &encoder)
        return Data(SHA256.hash(data: encoder.data))
    }

    static func transcript(
        context: CallHandshakeContextV1,
        callerCommitment: Data,
        callerMaterial: CallKeyMaterialV1,
        calleeCommitment: Data,
        callee: CallParty,
        calleeMaterial: CallKeyMaterialV1,
        selectedProtocolVersion: UInt16,
        selectedMediaProfileVersion: UInt16
    ) throws -> Data {
        try validate(context: context)
        try validate(commitment: callerCommitment)
        try validate(commitment: calleeCommitment)
        try validate(material: callerMaterial)
        try validate(material: calleeMaterial)
        try validate(party: callee)
        try validate(selectedProtocolVersion, in: context)
        try validateMediaProfile(selectedMediaProfileVersion, in: context)

        let expectedCaller = try self.callerCommitment(
            context: context,
            material: callerMaterial
        )
        guard expectedCaller == callerCommitment else {
            throw CallProtocolError.invalidCommitment
        }
        let expectedCallee = try self.calleeCommitment(
            context: context,
            callerCommitment: callerCommitment,
            callee: callee,
            selectedProtocolVersion: selectedProtocolVersion,
            selectedMediaProfileVersion: selectedMediaProfileVersion,
            material: calleeMaterial
        )
        guard expectedCallee == calleeCommitment else {
            throw CallProtocolError.invalidCommitment
        }

        var encoder = CallBinaryEncoder()
        try encoder.append("toj-call-v1/transcript")
        try append(context: context, to: &encoder)
        try encoder.append(callerCommitment)
        try append(material: callerMaterial, to: &encoder)
        try encoder.append(calleeCommitment)
        try append(party: callee, to: &encoder)
        try append(material: calleeMaterial, to: &encoder)
        encoder.append(selectedProtocolVersion)
        encoder.append(selectedMediaProfileVersion)
        return encoder.data
    }

    static func signalAdditionalAuthenticatedData(
        version: UInt16,
        callId: String,
        senderDeviceId: String,
        kind: CallSignalKind,
        sequence: UInt64,
        expiresAtMilliseconds: Int64
    ) throws -> Data {
        try validate(identifier: callId, name: "call_id")
        try validate(identifier: senderDeviceId, name: "sender_device_id")

        var encoder = CallBinaryEncoder()
        try encoder.append("toj-call-v1/signal-aad")
        encoder.append(version)
        try encoder.append(callId)
        try encoder.append(senderDeviceId)
        try encoder.append(kind.rawValue)
        encoder.append(sequence)
        encoder.append(UInt64(bitPattern: expiresAtMilliseconds))
        return encoder.data
    }

    private static func append(
        context: CallHandshakeContextV1,
        to encoder: inout CallBinaryEncoder
    ) throws {
        try encoder.append(context.identity.callId)
        try encoder.append(context.identity.dialogId)
        try append(party: context.identity.caller, to: &encoder)
        try encoder.append(context.identity.calleeAccountId)
        encoder.append(UInt16(context.offeredProtocolVersions.count))
        context.offeredProtocolVersions.forEach { encoder.append($0) }
        encoder.append(UInt16(context.offeredMediaProfileVersions.count))
        context.offeredMediaProfileVersions.forEach { encoder.append($0) }
    }

    private static func append(party: CallParty, to encoder: inout CallBinaryEncoder) throws {
        try encoder.append(party.accountId)
        try encoder.append(party.deviceId)
    }

    private static func append(
        material: CallKeyMaterialV1,
        to encoder: inout CallBinaryEncoder
    ) throws {
        try encoder.append(material.publicKey)
        try encoder.append(material.nonce)
        try encoder.append(material.dtlsFingerprintSHA256)
    }

    private static func validate(context: CallHandshakeContextV1) throws {
        try validate(identifier: context.identity.callId, name: "call_id")
        try validate(identifier: context.identity.dialogId, name: "dialog_id")
        try validate(party: context.identity.caller)
        try validate(identifier: context.identity.calleeAccountId, name: "callee_account_id")

        let versions = context.offeredProtocolVersions
        guard !versions.isEmpty,
              versions.count <= 16,
              versions == versions.sorted(),
              Set(versions).count == versions.count else {
            throw CallProtocolError.invalidVersionOffer
        }
        let mediaProfiles = context.offeredMediaProfileVersions
        guard !mediaProfiles.isEmpty,
              mediaProfiles.count <= 16,
              mediaProfiles == mediaProfiles.sorted(),
              Set(mediaProfiles).count == mediaProfiles.count else {
            throw CallProtocolError.invalidVersionOffer
        }
    }

    private static func validate(party: CallParty) throws {
        try validate(identifier: party.accountId, name: "account_id")
        try validate(identifier: party.deviceId, name: "device_id")
    }

    private static func validate(identifier: String, name: String) throws {
        guard !identifier.isEmpty else {
            throw CallProtocolError.emptyIdentifier(name)
        }
        guard identifier.utf8.count <= 256 else {
            throw CallProtocolError.identifierTooLong(name)
        }
    }

    private static func validate(material: CallKeyMaterialV1) throws {
        guard material.publicKey.count == 32,
              material.nonce.count == 32,
              material.dtlsFingerprintSHA256.count == 32 else {
            throw CallProtocolError.invalidKeyMaterial
        }
    }

    private static func validate(commitment: Data) throws {
        guard commitment.count == 32 else {
            throw CallProtocolError.invalidCommitment
        }
    }

    private static func validate(
        _ selectedProtocolVersion: UInt16,
        in context: CallHandshakeContextV1
    ) throws {
        guard context.offeredProtocolVersions.contains(selectedProtocolVersion) else {
            throw CallProtocolError.unsupportedSelectedVersion(selectedProtocolVersion)
        }
    }

    private static func validateMediaProfile(
        _ selectedMediaProfileVersion: UInt16,
        in context: CallHandshakeContextV1
    ) throws {
        guard context.offeredMediaProfileVersions.contains(selectedMediaProfileVersion) else {
            throw CallProtocolError.unsupportedSelectedMediaProfileVersion(
                selectedMediaProfileVersion
            )
        }
    }
}

private nonisolated struct CallBinaryEncoder {
    private(set) var data = Data()

    mutating func append(_ value: String) throws {
        try append(Data(value.utf8))
    }

    mutating func append(_ value: Data) throws {
        guard value.count <= Int(UInt32.max) else {
            throw CallProtocolError.identifierTooLong("binary_field")
        }
        append(UInt32(value.count))
        data.append(value)
    }

    mutating func append(_ value: UInt16) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    mutating func append(_ value: UInt32) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    mutating func append(_ value: UInt64) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }
}
