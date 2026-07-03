import XCTest
import LibSignalClient
@testable import Toj

/// Milestone 1's riskiest unknown, proven first: libsignal on iOS doing
/// keygen → PQXDH prekey bundle → Double Ratchet session → encrypt/decrypt.
final class CryptoSpikeTests: XCTestCase {
    func testAliceMessagesBobBothDirections() async throws {
        let alice = try CryptoEngine(userId: "alice")
        let bob = try CryptoEngine(userId: "bob")

        let bobBundle = try await bob.makeLocalBundle()
        try await alice.establishSession(with: "bob", bundle: bobBundle)

        let hasSession = try await alice.hasSession(with: "bob")
        XCTAssertTrue(hasSession)

        // First message rides the prekey handshake (X3DH/PQXDH).
        let first = try await alice.encrypt("Салом, Бобҷон!", for: "bob")
        XCTAssertEqual(first.type, CiphertextMessage.MessageType.preKey.rawValue)
        let firstDecrypted = try await bob.decrypt(type: first.type, ciphertext: first.ciphertext, from: "alice")
        XCTAssertEqual(firstDecrypted, "Салом, Бобҷон!")

        // Reply flows over the established ratchet (whisper message).
        let reply = try await bob.encrypt("Ва алейкум салом!", for: "alice")
        XCTAssertEqual(reply.type, CiphertextMessage.MessageType.whisper.rawValue)
        let replyDecrypted = try await alice.decrypt(type: reply.type, ciphertext: reply.ciphertext, from: "bob")
        XCTAssertEqual(replyDecrypted, "Ва алейкум салом!")
    }

    func testOutOfOrderDeliveryDecrypts() async throws {
        let alice = try CryptoEngine(userId: "alice")
        let bob = try CryptoEngine(userId: "bob")
        try await alice.establishSession(with: "bob", bundle: bob.makeLocalBundle())

        let m1 = try await alice.encrypt("one", for: "bob")
        let m2 = try await alice.encrypt("two", for: "bob")
        let m3 = try await alice.encrypt("three", for: "bob")

        // The transport may reorder delivery; the ratchet must cope.
        let r1 = try await bob.decrypt(type: m1.type, ciphertext: m1.ciphertext, from: "alice")
        let r3 = try await bob.decrypt(type: m3.type, ciphertext: m3.ciphertext, from: "alice")
        let r2 = try await bob.decrypt(type: m2.type, ciphertext: m2.ciphertext, from: "alice")
        XCTAssertEqual([r1, r2, r3], ["one", "two", "three"])
    }

    func testCiphertextDoesNotContainPlaintext() async throws {
        let alice = try CryptoEngine(userId: "alice")
        let bob = try CryptoEngine(userId: "bob")
        try await alice.establishSession(with: "bob", bundle: bob.makeLocalBundle())

        let secret = "the server must never see this"
        let sealed = try await alice.encrypt(secret, for: "bob")
        XCTAssertNil(
            sealed.ciphertext.range(of: Data(secret.utf8)),
            "plaintext bytes leaked into ciphertext"
        )
    }

    func testTamperedCiphertextFailsToDecrypt() async throws {
        let alice = try CryptoEngine(userId: "alice")
        let bob = try CryptoEngine(userId: "bob")
        try await alice.establishSession(with: "bob", bundle: bob.makeLocalBundle())

        let sealed = try await alice.encrypt("integrity matters", for: "bob")
        var tampered = sealed.ciphertext
        tampered[tampered.count - 1] ^= 0xFF

        do {
            _ = try await bob.decrypt(type: sealed.type, ciphertext: tampered, from: "alice")
            XCTFail("tampered ciphertext must not decrypt")
        } catch {
            // expected
        }
    }

    func testThirdPartyCannotDecrypt() async throws {
        let alice = try CryptoEngine(userId: "alice")
        let bob = try CryptoEngine(userId: "bob")
        let eve = try CryptoEngine(userId: "eve")
        try await alice.establishSession(with: "bob", bundle: bob.makeLocalBundle())

        let sealed = try await alice.encrypt("not for eve", for: "bob")
        do {
            _ = try await eve.decrypt(type: sealed.type, ciphertext: sealed.ciphertext, from: "alice")
            XCTFail("a third party must not be able to decrypt")
        } catch {
            // expected
        }
    }
}
