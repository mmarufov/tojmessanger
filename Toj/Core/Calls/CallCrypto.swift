import CryptoKit
import Foundation

nonisolated enum CallCryptoError: Error, Equatable {
    case invalidPrivateKey
    case invalidPeerPublicKey
    case invalidTranscript
    case weakSharedSecret
    case plaintextTooLarge
    case invalidSequence
    case sequenceTooFarAhead
    case replayedSequence
    case sequenceExhausted
    case metadataMismatch
    case invalidNonce
    case expired
    case authenticationFailed
}

nonisolated struct CallEphemeralKeyPair: Sendable {
    let privateKey: Data
    let publicKey: Data

    init() {
        let key = Curve25519.KeyAgreement.PrivateKey()
        privateKey = key.rawRepresentation
        publicKey = key.publicKey.rawRepresentation
    }

    /// Internal deterministic initializer for protocol vectors. Production
    /// callers should use `init()` so CryptoKit obtains system randomness.
    init(privateKey: Data) throws {
        guard privateKey.count == 32,
              let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey) else {
            throw CallCryptoError.invalidPrivateKey
        }
        self.privateKey = key.rawRepresentation
        publicKey = key.publicKey.rawRepresentation
    }
}

/// Directional secrets derived from one ephemeral X25519 exchange. Values are
/// private and intentionally have no Codable or persistence conformance.
nonisolated struct CallSessionKeys: @unchecked Sendable {
    fileprivate let callerToCalleeKey: Data
    fileprivate let calleeToCallerKey: Data
    fileprivate let callerNoncePrefix: Data
    fileprivate let calleeNoncePrefix: Data
    fileprivate let callerConfirmationKey: Data
    fileprivate let calleeConfirmationKey: Data
    fileprivate let sasSeed: Data
    fileprivate let transcriptHash: Data
}

nonisolated enum CallCrypto {
    static func randomNonce() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<32).map { _ in
            UInt8.random(in: UInt8.min...UInt8.max, using: &generator)
        })
    }

    static func keyMaterial(
        keyPair: CallEphemeralKeyPair,
        nonce: Data = CallCrypto.randomNonce(),
        dtlsFingerprintSHA256: Data
    ) throws -> CallKeyMaterialV1 {
        guard nonce.count == 32, dtlsFingerprintSHA256.count == 32 else {
            throw CallProtocolError.invalidKeyMaterial
        }
        return CallKeyMaterialV1(
            publicKey: keyPair.publicKey,
            nonce: nonce,
            dtlsFingerprintSHA256: dtlsFingerprintSHA256
        )
    }

    static func deriveSessionKeys(
        localPrivateKey: Data,
        remotePublicKey: Data,
        transcript: Data
    ) throws -> CallSessionKeys {
        guard !transcript.isEmpty else {
            throw CallCryptoError.invalidTranscript
        }
        guard localPrivateKey.count == 32,
              let privateKey = try? Curve25519.KeyAgreement.PrivateKey(
                  rawRepresentation: localPrivateKey
              ) else {
            throw CallCryptoError.invalidPrivateKey
        }
        guard remotePublicKey.count == 32,
              let publicKey = try? Curve25519.KeyAgreement.PublicKey(
                  rawRepresentation: remotePublicKey
              ) else {
            throw CallCryptoError.invalidPeerPublicKey
        }

        let sharedSecret: SharedSecret
        do {
            sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
        } catch {
            // CryptoKit rejects low-order X25519 points, including all-zero
            // shared output. Keep that distinction visible to security logs.
            throw CallCryptoError.weakSharedSecret
        }

        let transcriptHash = Data(SHA256.hash(data: transcript))
        let masterKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: transcriptHash,
            sharedInfo: Data("toj-call-v1/master".utf8),
            outputByteCount: 32
        )

        func expand(_ label: String, count: Int) -> Data {
            let key = HKDF<SHA256>.deriveKey(
                inputKeyMaterial: masterKey,
                salt: transcriptHash,
                info: Data(label.utf8),
                outputByteCount: count
            )
            return key.withUnsafeBytes { Data($0) }
        }

        return CallSessionKeys(
            callerToCalleeKey: expand("toj-call-v1/caller-to-callee/key", count: 32),
            calleeToCallerKey: expand("toj-call-v1/callee-to-caller/key", count: 32),
            callerNoncePrefix: expand("toj-call-v1/caller-to-callee/nonce", count: 4),
            calleeNoncePrefix: expand("toj-call-v1/callee-to-caller/nonce", count: 4),
            callerConfirmationKey: expand("toj-call-v1/caller/confirmation", count: 32),
            calleeConfirmationKey: expand("toj-call-v1/callee/confirmation", count: 32),
            sasSeed: expand("toj-call-v1/security-emojis", count: 32),
            transcriptHash: transcriptHash
        )
    }
}

/// Owns per-direction nonce counters and the inbound replay window. Actor
/// isolation makes accidental value copies and concurrent nonce reuse
/// impossible. Never create a second instance with the same session keys.
actor CallCipherSession {
    static let maximumPlaintextBytes = 64 * 1024

    let callId: String
    let localDeviceId: String
    let remoteDeviceId: String
    let localRole: CallRole

    private let keys: CallSessionKeys
    private var nextOutboundSequence: UInt64 = 1
    private var inboundReplayWindow = CallReplayWindow()

    init(
        callId: String,
        localDeviceId: String,
        remoteDeviceId: String,
        localRole: CallRole,
        keys: CallSessionKeys
    ) {
        self.callId = callId
        self.localDeviceId = localDeviceId
        self.remoteDeviceId = remoteDeviceId
        self.localRole = localRole
        self.keys = keys
    }

    func seal(
        _ plaintext: Data,
        kind: CallSignalKind,
        expiresAtMilliseconds: Int64
    ) throws -> CallEncryptedSignalV1 {
        guard plaintext.count <= Self.maximumPlaintextBytes else {
            throw CallCryptoError.plaintextTooLarge
        }
        guard nextOutboundSequence != 0 else {
            throw CallCryptoError.sequenceExhausted
        }

        let sequence = nextOutboundSequence
        let aad = try CallProtocolV1.signalAdditionalAuthenticatedData(
            version: CallProtocolVersion.current,
            callId: callId,
            senderDeviceId: localDeviceId,
            kind: kind,
            sequence: sequence,
            expiresAtMilliseconds: expiresAtMilliseconds
        )
        let sealed = try ChaChaPoly.seal(
            plaintext,
            using: SymmetricKey(data: outboundKey),
            nonce: try ChaChaPoly.Nonce(data: outboundNoncePrefix + sequence.bigEndianData),
            authenticating: aad
        )

        if sequence == UInt64.max {
            nextOutboundSequence = 0
        } else {
            nextOutboundSequence += 1
        }

        return CallEncryptedSignalV1(
            version: CallProtocolVersion.current,
            callId: callId,
            senderDeviceId: localDeviceId,
            kind: kind,
            sequence: sequence,
            ciphertext: sealed.combined,
            expiresAtMilliseconds: expiresAtMilliseconds
        )
    }

    func open(
        _ envelope: CallEncryptedSignalV1,
        nowMilliseconds: Int64
    ) throws -> Data {
        guard envelope.version == CallProtocolVersion.current,
              envelope.callId == callId,
              envelope.senderDeviceId == remoteDeviceId else {
            throw CallCryptoError.metadataMismatch
        }
        guard envelope.expiresAtMilliseconds >= nowMilliseconds else {
            throw CallCryptoError.expired
        }
        guard envelope.sequence > 0 else {
            throw CallCryptoError.invalidSequence
        }
        // CryptoKit's combined form is nonce (12) + ciphertext + tag (16).
        guard envelope.ciphertext.count <= Self.maximumPlaintextBytes + 28 else {
            throw CallCryptoError.plaintextTooLarge
        }

        try inboundReplayWindow.validate(envelope.sequence)
        let aad = try CallProtocolV1.signalAdditionalAuthenticatedData(
            version: envelope.version,
            callId: envelope.callId,
            senderDeviceId: envelope.senderDeviceId,
            kind: envelope.kind,
            sequence: envelope.sequence,
            expiresAtMilliseconds: envelope.expiresAtMilliseconds
        )
        let expectedNonce = inboundNoncePrefix + envelope.sequence.bigEndianData
        guard envelope.ciphertext.prefix(12) == expectedNonce else {
            throw CallCryptoError.invalidNonce
        }

        let plaintext: Data
        do {
            let sealedBox = try ChaChaPoly.SealedBox(combined: envelope.ciphertext)
            plaintext = try ChaChaPoly.open(
                sealedBox,
                using: SymmetricKey(data: inboundKey),
                authenticating: aad
            )
        } catch {
            // An unauthenticated sequence must not consume replay-window state.
            throw CallCryptoError.authenticationFailed
        }
        inboundReplayWindow.record(envelope.sequence)
        return plaintext
    }

    func localConfirmationTag() -> Data {
        confirmationTag(using: localConfirmationKey)
    }

    func verifyRemoteConfirmationTag(_ tag: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(
            tag,
            authenticating: confirmationInput,
            using: SymmetricKey(data: remoteConfirmationKey)
        )
    }

    func securityEmojis() -> [String] {
        let symbols = CallSecurityEmojiTable.symbols
        let radix = UInt16(symbols.count)
        let rejectionLimit = UInt16.max - (UInt16.max % radix)
        var block = keys.sasSeed
        var offset = 0
        var counter: UInt32 = 0
        var result: [String] = []

        while result.count < 4 {
            if offset + 2 > block.count {
                var counterValue = counter.bigEndian
                let counterData = Swift.withUnsafeBytes(of: &counterValue) { Data($0) }
                block = Data(SHA256.hash(data: keys.sasSeed + counterData))
                offset = 0
                counter &+= 1
            }
            let sample = (UInt16(block[offset]) << 8) | UInt16(block[offset + 1])
            offset += 2
            if sample < rejectionLimit {
                result.append(symbols[Int(sample % radix)])
            }
        }
        return result
    }

    private var outboundKey: Data {
        localRole == .caller ? keys.callerToCalleeKey : keys.calleeToCallerKey
    }

    private var inboundKey: Data {
        localRole == .caller ? keys.calleeToCallerKey : keys.callerToCalleeKey
    }

    private var inboundNoncePrefix: Data {
        localRole == .caller ? keys.calleeNoncePrefix : keys.callerNoncePrefix
    }

    private var outboundNoncePrefix: Data {
        localRole == .caller ? keys.callerNoncePrefix : keys.calleeNoncePrefix
    }

    private var localConfirmationKey: Data {
        localRole == .caller ? keys.callerConfirmationKey : keys.calleeConfirmationKey
    }

    private var remoteConfirmationKey: Data {
        localRole == .caller ? keys.calleeConfirmationKey : keys.callerConfirmationKey
    }

    private var confirmationInput: Data {
        Data("toj-call-v1/key-confirmation".utf8) + keys.transcriptHash
    }

    private func confirmationTag(using key: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(
            for: confirmationInput,
            using: SymmetricKey(data: key)
        ))
    }
}

/// A 64-event sliding replay window with a bounded forward jump. Large gaps
/// require durable event catch-up instead of silently discarding state.
nonisolated struct CallReplayWindow: Equatable, Sendable {
    static let windowSize: UInt64 = 64
    static let maximumForwardJump: UInt64 = 4_096

    private(set) var highestSequence: UInt64?
    private var seenMask: UInt64 = 0

    func validate(_ sequence: UInt64) throws {
        guard sequence > 0 else {
            throw CallCryptoError.invalidSequence
        }
        guard let highestSequence else {
            guard sequence <= Self.maximumForwardJump else {
                throw CallCryptoError.sequenceTooFarAhead
            }
            return
        }
        if sequence > highestSequence {
            guard sequence - highestSequence <= Self.maximumForwardJump else {
                throw CallCryptoError.sequenceTooFarAhead
            }
            return
        }

        let distance = highestSequence - sequence
        guard distance < Self.windowSize,
              (seenMask & (UInt64(1) << distance)) == 0 else {
            throw CallCryptoError.replayedSequence
        }
    }

    mutating func record(_ sequence: UInt64) {
        if let highestSequence {
            if sequence > highestSequence {
                let distance = sequence - highestSequence
                seenMask = distance >= Self.windowSize ? 1 : (seenMask << distance) | 1
                self.highestSequence = sequence
            } else {
                seenMask |= UInt64(1) << (highestSequence - sequence)
            }
        } else {
            highestSequence = sequence
            seenMask = 1
        }
    }
}

private nonisolated extension UInt64 {
    var bigEndianData: Data {
        var value = bigEndian
        return Swift.withUnsafeBytes(of: &value) { Data($0) }
    }
}

/// Pinned v1 mapping. The scalar ranges are part of the protocol and must not
/// be reordered. They contain 333 stable pictographs, matching the entropy
/// target of Telegram-style four-emoji verification.
private nonisolated enum CallSecurityEmojiTable {
    static let symbols: [String] = {
        var codePoints: [UInt32] = []
        codePoints.append(contentsOf: UInt32(0x1F600)...UInt32(0x1F64F))
        codePoints.append(contentsOf: UInt32(0x1F680)...UInt32(0x1F6C5))
        codePoints.append(contentsOf: UInt32(0x1F300)...UInt32(0x1F321))
        codePoints.append(contentsOf: UInt32(0x1F330)...UInt32(0x1F37F))
        codePoints.append(contentsOf: UInt32(0x1F400)...UInt32(0x1F43E))
        codePoints.append(contentsOf: [0x2600, 0x2601, 0x2602, 0x2603, 0x260E, 0x2615])
        precondition(codePoints.count == 333)
        return codePoints.map { codePoint in
            String(UnicodeScalar(codePoint)!) + "\u{FE0F}"
        }
    }()
}
