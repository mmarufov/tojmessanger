import Foundation
import LibSignalClient

nonisolated enum CryptoEngineError: Error {
    case unsupportedMessageType(UInt8)
    case notUTF8Plaintext
}

/// The public half of a device's prekeys, published to the relay so peers can
/// establish a session (X3DH/PQXDH). JSON-encodable; contains no secrets.
nonisolated struct PreKeyBundlePayload: Codable, Sendable, Equatable {
    var registrationId: UInt32
    var deviceId: UInt32
    var identityKey: Data
    var preKeyId: UInt32
    var preKey: Data
    var signedPreKeyId: UInt32
    var signedPreKey: Data
    var signedPreKeySignature: Data
    var kyberPreKeyId: UInt32
    var kyberPreKey: Data
    var kyberPreKeySignature: Data

    func makeBundle() throws -> PreKeyBundle {
        try PreKeyBundle(
            registrationId: registrationId,
            deviceId: deviceId,
            prekeyId: preKeyId,
            prekey: PublicKey(preKey),
            signedPrekeyId: signedPreKeyId,
            signedPrekey: PublicKey(signedPreKey),
            signedPrekeySignature: signedPreKeySignature,
            identity: IdentityKey(bytes: identityKey),
            kyberPrekeyId: kyberPreKeyId,
            kyberPrekey: KEMPublicKey(kyberPreKey),
            kyberPrekeySignature: kyberPreKeySignature
        )
    }
}

/// One device's Signal Protocol engine for the M1 walking skeleton.
/// State lives in libsignal's in-memory store — persistence is milestone 4.
/// All libsignal handles stay confined to this actor; only Sendable values cross.
actor CryptoEngine {
    let userId: String
    private let deviceId: UInt32 = 1
    private let address: ProtocolAddress
    private let store = InMemorySignalProtocolStore()
    private let context = NullContext()

    init(userId: String) throws {
        self.userId = userId
        self.address = try ProtocolAddress(name: userId, deviceId: deviceId)
    }

    /// Generates one-time, signed, and Kyber (post-quantum) prekeys, stores the
    /// private halves, and returns the public bundle to publish.
    func makeLocalBundle() throws -> PreKeyBundlePayload {
        let identity = try store.identityKeyPair(context: context)
        let registrationId = try store.localRegistrationId(context: context)
        let timestamp = UInt64(Date().timeIntervalSince1970 * 1000)

        let preKeyId = UInt32.random(in: 1..<0x00FF_FFFF)
        let preKeyPrivate = PrivateKey.generate()
        try store.storePreKey(
            PreKeyRecord(id: preKeyId, privateKey: preKeyPrivate),
            id: preKeyId,
            context: context
        )

        let signedPreKeyId = UInt32.random(in: 1..<0x00FF_FFFF)
        let signedPreKeyPrivate = PrivateKey.generate()
        let signedPreKeySignature = identity.privateKey.generateSignature(
            message: signedPreKeyPrivate.publicKey.serialize()
        )
        try store.storeSignedPreKey(
            SignedPreKeyRecord(
                id: signedPreKeyId,
                timestamp: timestamp,
                privateKey: signedPreKeyPrivate,
                signature: signedPreKeySignature
            ),
            id: signedPreKeyId,
            context: context
        )

        let kyberPreKeyId = UInt32.random(in: 1..<0x00FF_FFFF)
        let kyberKeyPair = KEMKeyPair.generate()
        let kyberSignature = identity.privateKey.generateSignature(
            message: kyberKeyPair.publicKey.serialize()
        )
        try store.storeKyberPreKey(
            KyberPreKeyRecord(
                id: kyberPreKeyId,
                timestamp: timestamp,
                keyPair: kyberKeyPair,
                signature: kyberSignature
            ),
            id: kyberPreKeyId,
            context: context
        )

        return PreKeyBundlePayload(
            registrationId: registrationId,
            deviceId: deviceId,
            identityKey: identity.identityKey.serialize(),
            preKeyId: preKeyId,
            preKey: preKeyPrivate.publicKey.serialize(),
            signedPreKeyId: signedPreKeyId,
            signedPreKey: signedPreKeyPrivate.publicKey.serialize(),
            signedPreKeySignature: signedPreKeySignature,
            kyberPreKeyId: kyberPreKeyId,
            kyberPreKey: kyberKeyPair.publicKey.serialize(),
            kyberPreKeySignature: kyberSignature
        )
    }

    /// X3DH/PQXDH: turn the peer's published bundle into a Double Ratchet session.
    func establishSession(with peerId: String, bundle payload: PreKeyBundlePayload) throws {
        let peer = try ProtocolAddress(name: peerId, deviceId: payload.deviceId)
        try processPreKeyBundle(
            payload.makeBundle(),
            for: peer,
            ourAddress: address,
            sessionStore: store,
            identityStore: store,
            context: context
        )
    }

    func hasSession(with peerId: String, deviceId peerDevice: UInt32 = 1) throws -> Bool {
        let peer = try ProtocolAddress(name: peerId, deviceId: peerDevice)
        return try store.loadSession(for: peer, context: context) != nil
    }

    func encrypt(
        _ plaintext: String,
        for peerId: String,
        deviceId peerDevice: UInt32 = 1
    ) throws -> (type: UInt8, ciphertext: Data) {
        let peer = try ProtocolAddress(name: peerId, deviceId: peerDevice)
        let message = try signalEncrypt(
            message: Data(plaintext.utf8),
            for: peer,
            localAddress: address,
            sessionStore: store,
            identityStore: store,
            context: context
        )
        return (message.messageType.rawValue, message.serialize())
    }

    func decrypt(
        type: UInt8,
        ciphertext: Data,
        from peerId: String,
        deviceId peerDevice: UInt32 = 1
    ) throws -> String {
        let peer = try ProtocolAddress(name: peerId, deviceId: peerDevice)
        let plaintext: Data
        switch CiphertextMessage.MessageType(rawValue: type) {
        case .preKey:
            plaintext = try signalDecryptPreKey(
                message: PreKeySignalMessage(bytes: ciphertext),
                from: peer,
                localAddress: address,
                sessionStore: store,
                identityStore: store,
                preKeyStore: store,
                signedPreKeyStore: store,
                kyberPreKeyStore: store,
                context: context
            )
        case .whisper:
            plaintext = try signalDecrypt(
                message: SignalMessage(bytes: ciphertext),
                from: peer,
                to: address,
                sessionStore: store,
                identityStore: store,
                context: context
            )
        default:
            throw CryptoEngineError.unsupportedMessageType(type)
        }
        guard let text = String(data: plaintext, encoding: .utf8) else {
            throw CryptoEngineError.notUTF8Plaintext
        }
        return text
    }
}
