import CryptoKit
import Foundation

nonisolated enum GroupCallCryptoError: Error, Equatable {
    case invalidIdentifier
    case invalidPrivateKey
    case invalidPublicKey
    case invalidNonce
    case invalidEpoch
    case invalidRevision
    case invalidParticipantSet
    case invalidCommitment
    case invalidEnvelope
    case weakSharedSecret
    case authenticationFailed
    case recipientMismatch
    case senderMismatch
}

nonisolated struct GroupCallJoinIdentity: @unchecked Sendable {
    let privateKey: Data
    let publicKey: Data
    let nonce: Data

    init() {
        let key = Curve25519.KeyAgreement.PrivateKey()
        privateKey = key.rawRepresentation
        publicKey = key.publicKey.rawRepresentation
        nonce = GroupCallCrypto.randomBytes(count: 32)
    }

    init(privateKey: Data, nonce: Data) throws {
        guard privateKey.count == 32,
              let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey)
        else { throw GroupCallCryptoError.invalidPrivateKey }
        guard nonce.count == 32, !nonce.allSatisfy({ $0 == 0 }) else {
            throw GroupCallCryptoError.invalidNonce
        }
        self.privateKey = key.rawRepresentation
        publicKey = key.publicKey.rawRepresentation
        self.nonce = nonce
    }
}

nonisolated struct GroupCallEpochMaterial: @unchecked Sendable, Equatable {
    let epoch: Int64
    let membershipRevision: Int64
    let mediaKey: Data
    let participantSetHash: Data
    let keyCommitment: Data
}

nonisolated struct GroupCallSealedEpoch: Equatable, Sendable {
    let recipientDeviceId: String
    let ciphertext: Data
}

/// Group media keys never leave the participants in plaintext. The backend stores only a
/// commitment and per-device X25519/ChaChaPoly envelopes; the SFU receives encrypted frames.
nonisolated enum GroupCallCrypto {
    static let mediaKeyByteCount = 32

    static func randomBytes(count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in
            UInt8.random(in: UInt8.min...UInt8.max, using: &generator)
        })
    }

    static func participantSetHash(_ participants: [CloudGroupCallParticipant]) throws -> Data {
        let canonical = try participants.map { participant -> CanonicalParticipant in
            guard UUID(uuidString: participant.deviceId) != nil,
                  !participant.accountId.isEmpty,
                  let publicKey = Data(base64Encoded: participant.joinPublicKey),
                  publicKey.count == 32,
                  !publicKey.allSatisfy({ $0 == 0 }),
                  let nonce = Data(base64Encoded: participant.joinNonce),
                  nonce.count == 32,
                  !nonce.allSatisfy({ $0 == 0 })
            else { throw GroupCallCryptoError.invalidParticipantSet }
            return CanonicalParticipant(
                accountId: participant.accountId,
                deviceId: participant.deviceId.lowercased(),
                publicKey: publicKey,
                nonce: nonce
            )
        }
        return participantSetHash(canonical)
    }

    static func participantSetHash(
        accountId: String,
        deviceId: String,
        publicKey: Data,
        nonce: Data
    ) throws -> Data {
        guard !accountId.isEmpty,
              UUID(uuidString: deviceId) != nil,
              publicKey.count == 32,
              !publicKey.allSatisfy({ $0 == 0 }),
              nonce.count == 32,
              !nonce.allSatisfy({ $0 == 0 })
        else { throw GroupCallCryptoError.invalidParticipantSet }
        return participantSetHash([
            CanonicalParticipant(
                accountId: accountId,
                deviceId: deviceId.lowercased(),
                publicKey: publicKey,
                nonce: nonce
            ),
        ])
    }

    static func makeEpoch(
        callId: String,
        dialogId: String,
        epoch: Int64,
        membershipRevision: Int64,
        participantSetHash: Data,
        mediaKey: Data = randomBytes(count: mediaKeyByteCount)
    ) throws -> GroupCallEpochMaterial {
        try validateContext(
            callId: callId,
            dialogId: dialogId,
            epoch: epoch,
            membershipRevision: membershipRevision,
            participantSetHash: participantSetHash
        )
        guard mediaKey.count == mediaKeyByteCount,
              !mediaKey.allSatisfy({ $0 == 0 }) else {
            throw GroupCallCryptoError.invalidCommitment
        }
        let commitment = keyCommitment(
            callId: callId,
            dialogId: dialogId,
            epoch: epoch,
            membershipRevision: membershipRevision,
            participantSetHash: participantSetHash,
            mediaKey: mediaKey
        )
        return GroupCallEpochMaterial(
            epoch: epoch,
            membershipRevision: membershipRevision,
            mediaKey: mediaKey,
            participantSetHash: participantSetHash,
            keyCommitment: commitment
        )
    }

    static func seal(
        epoch material: GroupCallEpochMaterial,
        callId: String,
        dialogId: String,
        senderDeviceId: String,
        senderIdentity: GroupCallJoinIdentity,
        recipient: CloudGroupCallParticipant
    ) throws -> GroupCallSealedEpoch {
        guard let recipientPublicKey = Data(base64Encoded: recipient.joinPublicKey),
              recipientPublicKey.count == 32,
              let recipientNonce = Data(base64Encoded: recipient.joinNonce),
              recipientNonce.count == 32
        else { throw GroupCallCryptoError.invalidPublicKey }
        let key = try envelopeKey(
            localPrivateKey: senderIdentity.privateKey,
            remotePublicKey: recipientPublicKey,
            callId: callId,
            dialogId: dialogId,
            material: material,
            senderDeviceId: senderDeviceId,
            senderPublicKey: senderIdentity.publicKey,
            senderNonce: senderIdentity.nonce,
            recipientDeviceId: recipient.deviceId,
            recipientPublicKey: recipientPublicKey,
            recipientNonce: recipientNonce
        )
        let aad = try envelopeAAD(
            callId: callId,
            dialogId: dialogId,
            material: material,
            senderDeviceId: senderDeviceId,
            senderPublicKey: senderIdentity.publicKey,
            senderNonce: senderIdentity.nonce,
            recipientDeviceId: recipient.deviceId,
            recipientPublicKey: recipientPublicKey,
            recipientNonce: recipientNonce
        )
        let box = try ChaChaPoly.seal(
            material.mediaKey,
            using: key,
            authenticating: aad
        )
        return GroupCallSealedEpoch(
            recipientDeviceId: recipient.deviceId,
            ciphertext: box.combined
        )
    }

    static func open(
        envelope: CloudGroupCallEpochEnvelope,
        snapshot: CloudGroupCallSnapshot,
        localIdentity: GroupCallJoinIdentity
    ) throws -> GroupCallEpochMaterial {
        guard envelope.epoch == snapshot.mediaEpoch,
              let senderPublicKey = Data(base64Encoded: envelope.senderPublicKey),
              senderPublicKey.count == 32,
              let recipientPublicKey = Data(base64Encoded: envelope.recipientPublicKey),
              recipientPublicKey == localIdentity.publicKey,
              let ciphertext = Data(base64Encoded: envelope.ciphertext),
              ciphertext.count >= 48,
              let participantHash = Data(base64Encoded: snapshot.epoch.participantSetHash),
              participantHash.count == 32,
              let commitment = Data(base64Encoded: snapshot.epoch.keyCommitment),
              commitment.count == 32,
              let sender = snapshot.participants.first(where: {
                  $0.deviceId == snapshot.keyLeaderDeviceId
              }),
              let selfParticipant = snapshot.selfParticipant,
              let senderNonce = Data(base64Encoded: sender.joinNonce),
              senderNonce.count == 32
        else { throw GroupCallCryptoError.invalidEnvelope }
        guard sender.joinPublicKey == envelope.senderPublicKey else {
            throw GroupCallCryptoError.senderMismatch
        }
        guard selfParticipant.joinPublicKey == envelope.recipientPublicKey,
              selfParticipant.joinNonce == localIdentity.nonce.base64EncodedString() else {
            throw GroupCallCryptoError.recipientMismatch
        }
        let placeholder = try makeEpoch(
            callId: snapshot.id,
            dialogId: snapshot.dialogId,
            epoch: snapshot.mediaEpoch,
            membershipRevision: snapshot.epoch.membershipRevision,
            participantSetHash: participantHash,
            mediaKey: Data(repeating: 1, count: mediaKeyByteCount)
        )
        let key = try envelopeKey(
            localPrivateKey: localIdentity.privateKey,
            remotePublicKey: senderPublicKey,
            callId: snapshot.id,
            dialogId: snapshot.dialogId,
            material: placeholder,
            senderDeviceId: sender.deviceId,
            senderPublicKey: senderPublicKey,
            senderNonce: senderNonce,
            recipientDeviceId: selfParticipant.deviceId,
            recipientPublicKey: localIdentity.publicKey,
            recipientNonce: localIdentity.nonce
        )
        let aad = try envelopeAAD(
            callId: snapshot.id,
            dialogId: snapshot.dialogId,
            material: placeholder,
            senderDeviceId: sender.deviceId,
            senderPublicKey: senderPublicKey,
            senderNonce: senderNonce,
            recipientDeviceId: selfParticipant.deviceId,
            recipientPublicKey: localIdentity.publicKey,
            recipientNonce: localIdentity.nonce
        )
        let mediaKey: Data
        do {
            mediaKey = try ChaChaPoly.open(
                ChaChaPoly.SealedBox(combined: ciphertext),
                using: key,
                authenticating: aad
            )
        } catch {
            throw GroupCallCryptoError.authenticationFailed
        }
        let material = try makeEpoch(
            callId: snapshot.id,
            dialogId: snapshot.dialogId,
            epoch: snapshot.mediaEpoch,
            membershipRevision: snapshot.epoch.membershipRevision,
            participantSetHash: participantHash,
            mediaKey: mediaKey
        )
        guard constantTimeEqual(material.keyCommitment, commitment) else {
            throw GroupCallCryptoError.invalidCommitment
        }
        return material
    }

    static func verifySnapshotTranscript(_ snapshot: CloudGroupCallSnapshot) throws {
        guard let supplied = Data(base64Encoded: snapshot.epoch.participantSetHash),
              supplied.count == 32,
              snapshot.epoch.membershipRevision <= snapshot.membershipRevision,
              snapshot.epoch.epoch == snapshot.mediaEpoch
        else { throw GroupCallCryptoError.invalidParticipantSet }
        // During a membership transition the current participant list intentionally differs from
        // the previous epoch transcript. The leader binds the complete new list when activating
        // the next epoch. Once revisions match, every client must reproduce the exact hash.
        if snapshot.epoch.membershipRevision == snapshot.membershipRevision {
            let computed = try participantSetHash(snapshot.participants)
            guard constantTimeEqual(computed, supplied) else {
                throw GroupCallCryptoError.invalidParticipantSet
            }
        }
    }

    static func safetyEmojis(
        callId: String,
        epoch: GroupCallEpochMaterial
    ) -> [String] {
        var encoder = BinaryEncoder()
        encoder.append("toj-group-call-safety-v1")
        encoder.append(callId)
        encoder.append(epoch.participantSetHash)
        encoder.append(epoch.keyCommitment)
        let digest = Data(SHA256.hash(data: encoder.data))
        return (0..<4).map { emojiTable[Int(digest[$0]) % emojiTable.count] }
    }

    private struct CanonicalParticipant {
        let accountId: String
        let deviceId: String
        let publicKey: Data
        let nonce: Data
    }

    private static func participantSetHash(_ participants: [CanonicalParticipant]) -> Data {
        var encoder = BinaryEncoder()
        encoder.append("toj-group-participants-v1")
        for participant in participants.sorted(by: { $0.deviceId < $1.deviceId }) {
            encoder.append(participant.accountId)
            encoder.append(participant.deviceId)
            encoder.append(participant.publicKey)
            encoder.append(participant.nonce)
        }
        return Data(SHA256.hash(data: encoder.data))
    }

    private static func keyCommitment(
        callId: String,
        dialogId: String,
        epoch: Int64,
        membershipRevision: Int64,
        participantSetHash: Data,
        mediaKey: Data
    ) -> Data {
        var encoder = BinaryEncoder()
        encoder.append("toj-group-media-key-commitment-v1")
        encoder.append(callId.lowercased())
        encoder.append(dialogId.lowercased())
        encoder.append(UInt64(epoch))
        encoder.append(UInt64(membershipRevision))
        encoder.append(participantSetHash)
        encoder.append(mediaKey)
        return Data(SHA256.hash(data: encoder.data))
    }

    private static func envelopeKey(
        localPrivateKey: Data,
        remotePublicKey: Data,
        callId: String,
        dialogId: String,
        material: GroupCallEpochMaterial,
        senderDeviceId: String,
        senderPublicKey: Data,
        senderNonce: Data,
        recipientDeviceId: String,
        recipientPublicKey: Data,
        recipientNonce: Data
    ) throws -> SymmetricKey {
        guard let privateKey = try? Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: localPrivateKey
        ) else { throw GroupCallCryptoError.invalidPrivateKey }
        guard let publicKey = try? Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: remotePublicKey
        ) else { throw GroupCallCryptoError.invalidPublicKey }
        let shared: SharedSecret
        do {
            shared = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
        } catch {
            throw GroupCallCryptoError.weakSharedSecret
        }
        let aad = try envelopeAAD(
            callId: callId,
            dialogId: dialogId,
            material: material,
            senderDeviceId: senderDeviceId,
            senderPublicKey: senderPublicKey,
            senderNonce: senderNonce,
            recipientDeviceId: recipientDeviceId,
            recipientPublicKey: recipientPublicKey,
            recipientNonce: recipientNonce
        )
        return shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(SHA256.hash(data: aad)),
            sharedInfo: Data("toj-group-call-envelope-key-v1".utf8),
            outputByteCount: 32
        )
    }

    private static func envelopeAAD(
        callId: String,
        dialogId: String,
        material: GroupCallEpochMaterial,
        senderDeviceId: String,
        senderPublicKey: Data,
        senderNonce: Data,
        recipientDeviceId: String,
        recipientPublicKey: Data,
        recipientNonce: Data
    ) throws -> Data {
        try validateContext(
            callId: callId,
            dialogId: dialogId,
            epoch: material.epoch,
            membershipRevision: material.membershipRevision,
            participantSetHash: material.participantSetHash
        )
        guard UUID(uuidString: senderDeviceId) != nil,
              UUID(uuidString: recipientDeviceId) != nil,
              senderPublicKey.count == 32,
              recipientPublicKey.count == 32,
              senderNonce.count == 32,
              recipientNonce.count == 32
        else { throw GroupCallCryptoError.invalidEnvelope }
        var encoder = BinaryEncoder()
        encoder.append("toj-group-call-envelope-v1")
        encoder.append(callId.lowercased())
        encoder.append(dialogId.lowercased())
        encoder.append(UInt64(material.epoch))
        encoder.append(UInt64(material.membershipRevision))
        encoder.append(material.participantSetHash)
        encoder.append(senderDeviceId.lowercased())
        encoder.append(senderPublicKey)
        encoder.append(senderNonce)
        encoder.append(recipientDeviceId.lowercased())
        encoder.append(recipientPublicKey)
        encoder.append(recipientNonce)
        return encoder.data
    }

    private static func validateContext(
        callId: String,
        dialogId: String,
        epoch: Int64,
        membershipRevision: Int64,
        participantSetHash: Data
    ) throws {
        guard UUID(uuidString: callId) != nil, UUID(uuidString: dialogId) != nil else {
            throw GroupCallCryptoError.invalidIdentifier
        }
        guard epoch > 0 else { throw GroupCallCryptoError.invalidEpoch }
        guard membershipRevision > 0 else { throw GroupCallCryptoError.invalidRevision }
        guard participantSetHash.count == 32 else {
            throw GroupCallCryptoError.invalidParticipantSet
        }
    }

    private static func constantTimeEqual(_ left: Data, _ right: Data) -> Bool {
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices { difference |= left[index] ^ right[index] }
        return difference == 0
    }

    private static let emojiTable = [
        "🐅", "🦊", "🐋", "🦉", "🌲", "🌊", "🌙", "☀️",
        "🍀", "🌻", "🍎", "🥑", "🚲", "🚀", "🎧", "🎨",
        "⚽️", "🎲", "💎", "🔑", "🧭", "🛡️", "🔥", "❄️",
        "⭐️", "☕️", "🏔️", "🏝️", "🪁", "🎈", "🦋", "🐬",
    ]
}

private nonisolated struct BinaryEncoder {
    private(set) var data = Data()

    mutating func append(_ value: String) { append(Data(value.utf8)) }

    mutating func append(_ value: Data) {
        precondition(value.count <= Int(UInt32.max))
        var length = UInt32(value.count).bigEndian
        Swift.withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(value)
    }

    mutating func append(_ value: UInt64) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }
}
