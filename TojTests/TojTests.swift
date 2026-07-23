import CryptoKit
import Foundation
import XCTest
@testable import Toj

final class SmokeTests: XCTestCase {
    func testHarnessRuns() {
        XCTAssertTrue(true)
    }
}

final class ContactsFeatureTests: XCTestCase {
    func testPhoneNormalizationKeepsInternationalPrefixAndDigits() {
        XCTAssertEqual(TojContactsStore.normalized("+992 90 123-45-67"), "+992901234567")
        XCTAssertEqual(TojContactsStore.normalized("(408) 555-3514"), "4085553514")
    }

    func testContactsSortByNameAutomatically() {
        let contacts = [
            TojAddressBookContact(id: "z", givenName: "Zarina", familyName: "", phoneNumbers: ["+3"], thumbnailData: nil),
            TojAddressBookContact(id: "a", givenName: "Aziz", familyName: "", phoneNumbers: ["+1"], thumbnailData: nil),
            TojAddressBookContact(id: "m", givenName: "Madina", familyName: "", phoneNumbers: ["+2"], thumbnailData: nil)
        ]

        XCTAssertEqual(TojAddressBookContact.sorted(contacts).map { $0.id }, ["a", "m", "z"])
    }
}

final class ChatSearchDrawerBehaviorTests: XCTestCase {
    func testReturningFromScrolledChatsCannotRevealSearchInTheSameGesture() {
        let revealWasArmed = ChatSearchDrawerBehavior.revealIsArmed(startingAt: 160)

        XCTAssertFalse(revealWasArmed)
        XCTAssertEqual(
            ChatSearchDrawerBehavior.revealProgress(at: 30, revealWasArmed: revealWasArmed),
            0
        )
        XCTAssertFalse(
            ChatSearchDrawerBehavior.shouldOpen(
                wasOpen: false,
                revealWasArmed: revealWasArmed,
                offset: 30
            )
        )
    }

    func testFreshPullFromTopOpensOnlyAfterRevealThreshold() {
        let revealWasArmed = ChatSearchDrawerBehavior.revealIsArmed(
            startingAt: ChatSearchDrawerBehavior.height
        )

        XCTAssertTrue(revealWasArmed)
        XCTAssertFalse(
            ChatSearchDrawerBehavior.shouldOpen(
                wasOpen: false,
                revealWasArmed: revealWasArmed,
                offset: 31
            )
        )
        XCTAssertTrue(
            ChatSearchDrawerBehavior.shouldOpen(
                wasOpen: false,
                revealWasArmed: revealWasArmed,
                offset: 30
            )
        )
    }
}

final class CallProtocolTests: XCTestCase {
    func testCrossPlatformHandshakeVector() async throws {
        let vector = try CallTestVector()

        XCTAssertEqual(
            vector.callerKeyPair.publicKey.hex,
            "8f40c5adb68f25624ae5b214ea767a6ec94d829d3d7b5e1ad1ba6f3e2138285f"
        )
        XCTAssertEqual(
            vector.calleeKeyPair.publicKey.hex,
            "358072d6365880d1aeea329adf9121383851ed21a28e3b75e965d0d2cd166254"
        )
        XCTAssertEqual(
            vector.callerCommitment.hex,
            "72af3dc7b2dc7adc92b31af69f240bc4f280052f0f6828aa51d6f21fdaf78411"
        )
        XCTAssertEqual(
            vector.calleeCommitment.hex,
            "8b077d9791a6db5e2eb6efdc9f4d53590bd281f50caf6dc51d667b9a2ca4bca0"
        )
        XCTAssertEqual(vector.transcript.count, 457)
        XCTAssertEqual(
            Data(SHA256.hash(data: vector.transcript)).hex,
            "9af82960c6cb3a1c60a2244c4cf964f3ed83bcefc5d5577eb9be7fcb25c9ae1f"
        )

        let caller = try vector.makeCallerSession()
        let callee = try vector.makeCalleeSession()
        let callerTag = await caller.localConfirmationTag()
        let calleeTag = await callee.localConfirmationTag()
        XCTAssertEqual(
            callerTag.hex,
            "a544281010b262d21373c4d16f4cc098f0704ae68622d10ab91a424bb8bd70f4"
        )
        XCTAssertEqual(
            calleeTag.hex,
            "42a57a6900391f3b692a74b7c943ca4f8a1e417e4bab1599b86f3aa434b75d2f"
        )
        let callerVerified = await caller.verifyRemoteConfirmationTag(calleeTag)
        let calleeVerified = await callee.verifyRemoteConfirmationTag(callerTag)
        XCTAssertTrue(callerVerified)
        XCTAssertTrue(calleeVerified)
        var tamperedTag = calleeTag
        tamperedTag[0] ^= 0x01
        let acceptedTamperedTag = await caller.verifyRemoteConfirmationTag(tamperedTag)
        XCTAssertFalse(acceptedTamperedTag)
        let callerEmojis = await caller.securityEmojis()
        let calleeEmojis = await callee.securityEmojis()
        XCTAssertEqual(callerEmojis, ["🐅️", "🍠️", "🌊️", "😥️"])
        XCTAssertEqual(callerEmojis, calleeEmojis)
    }

    func testCommitmentRejectsTamperingAndMediaDowngrade() throws {
        let vector = try CallTestVector()
        var tamperedNonce = vector.callerMaterial.nonce
        tamperedNonce[0] ^= 0x01
        let tamperedMaterial = CallKeyMaterialV1(
            publicKey: vector.callerMaterial.publicKey,
            nonce: tamperedNonce,
            dtlsFingerprintSHA256: vector.callerMaterial.dtlsFingerprintSHA256
        )

        XCTAssertThrowsError(try CallProtocolV1.transcript(
            context: vector.context,
            callerCommitment: vector.callerCommitment,
            callerMaterial: tamperedMaterial,
            calleeCommitment: vector.calleeCommitment,
            callee: vector.callee,
            calleeMaterial: vector.calleeMaterial,
            selectedProtocolVersion: 1,
            selectedMediaProfileVersion: 1
        )) { error in
            XCTAssertEqual(error as? CallProtocolError, .invalidCommitment)
        }

        XCTAssertThrowsError(try CallProtocolV1.calleeCommitment(
            context: vector.context,
            callerCommitment: vector.callerCommitment,
            callee: vector.callee,
            selectedProtocolVersion: 1,
            selectedMediaProfileVersion: 2,
            material: vector.calleeMaterial
        )) { error in
            XCTAssertEqual(
                error as? CallProtocolError,
                .unsupportedSelectedMediaProfileVersion(2)
            )
        }
    }

    func testProtocolDTOUsesSnakeCaseAndBase64() throws {
        let invite = CallInviteV1(
            version: 1,
            callId: "call",
            dialogId: "dialog",
            callerAccountId: "alice",
            callerDeviceId: "alice-device",
            calleeAccountId: "bob",
            offeredProtocolVersions: [1],
            offeredMediaProfileVersions: [1],
            callerCommitment: Data([0xDE, 0xAD]),
            expiresAtMilliseconds: 123
        )
        let encoded = try JSONEncoder().encode(invite)
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertTrue(json.contains(#""call_id":"call""#))
        XCTAssertTrue(json.contains(#""offered_media_profile_versions":[1]"#))
        XCTAssertTrue(json.contains(Data([0xDE, 0xAD]).base64EncodedString()))
        XCTAssertEqual(try JSONDecoder().decode(CallInviteV1.self, from: encoded), invite)
    }

    func testAllZeroLowOrderX25519PointIsRejected() throws {
        let local = CallEphemeralKeyPair()
        XCTAssertThrowsError(try CallCrypto.deriveSessionKeys(
            localPrivateKey: local.privateKey,
            remotePublicKey: Data(repeating: 0, count: 32),
            transcript: Data("bound transcript".utf8)
        )) { error in
            XCTAssertEqual(error as? CallCryptoError, .weakSharedSecret)
        }
    }
}

final class CallCipherSessionTests: XCTestCase {
    func testBidirectionalEncryptionOutOfOrderAndReplayRejection() async throws {
        let vector = try CallTestVector()
        let caller = try vector.makeCallerSession()
        let callee = try vector.makeCalleeSession()

        let first = try await caller.seal(
            Data("one".utf8), kind: .offer, expiresAtMilliseconds: 10_000
        )
        let second = try await caller.seal(
            Data("two".utf8), kind: .iceCandidate, expiresAtMilliseconds: 10_000
        )
        let third = try await caller.seal(
            Data("three".utf8), kind: .iceCandidate, expiresAtMilliseconds: 10_000
        )

        let openedFirst = try await callee.open(first, nowMilliseconds: 1)
        let openedThird = try await callee.open(third, nowMilliseconds: 1)
        let openedSecond = try await callee.open(second, nowMilliseconds: 1)
        XCTAssertEqual(openedFirst, Data("one".utf8))
        XCTAssertEqual(openedThird, Data("three".utf8))
        XCTAssertEqual(openedSecond, Data("two".utf8))
        do {
            _ = try await callee.open(second, nowMilliseconds: 1)
            XCTFail("replayed signaling must be rejected")
        } catch {
            XCTAssertEqual(error as? CallCryptoError, .replayedSequence)
        }

        let answer = try await callee.seal(
            Data("answer".utf8), kind: .answer, expiresAtMilliseconds: 10_000
        )
        let openedAnswer = try await caller.open(answer, nowMilliseconds: 1)
        XCTAssertEqual(openedAnswer, Data("answer".utf8))
    }

    func testTamperAndWrongNonceDoNotConsumeSequence() async throws {
        let vector = try CallTestVector()
        let caller = try vector.makeCallerSession()
        let callee = try vector.makeCalleeSession()
        let valid = try await caller.seal(
            Data("candidate".utf8), kind: .iceCandidate, expiresAtMilliseconds: 10_000
        )

        var wrongNonceCiphertext = valid.ciphertext
        wrongNonceCiphertext[0] ^= 0x01
        let wrongNonce = valid.replacing(ciphertext: wrongNonceCiphertext)
        do {
            _ = try await callee.open(wrongNonce, nowMilliseconds: 1)
            XCTFail("a non-derived embedded nonce must be rejected")
        } catch {
            XCTAssertEqual(error as? CallCryptoError, .invalidNonce)
        }

        var damagedCiphertext = valid.ciphertext
        damagedCiphertext[damagedCiphertext.count - 1] ^= 0x80
        let tampered = valid.replacing(ciphertext: damagedCiphertext)
        do {
            _ = try await callee.open(tampered, nowMilliseconds: 1)
            XCTFail("tampered ciphertext must be rejected")
        } catch {
            XCTAssertEqual(error as? CallCryptoError, .authenticationFailed)
        }

        let opened = try await callee.open(valid, nowMilliseconds: 1)
        XCTAssertEqual(opened, Data("candidate".utf8))
    }

    func testAuthenticatedMetadataAndExpiry() async throws {
        let vector = try CallTestVector()
        let caller = try vector.makeCallerSession()
        let callee = try vector.makeCalleeSession()
        let valid = try await caller.seal(
            Data("offer".utf8), kind: .offer, expiresAtMilliseconds: 100
        )

        let relabeled = CallEncryptedSignalV1(
            version: valid.version,
            callId: valid.callId,
            senderDeviceId: valid.senderDeviceId,
            kind: .answer,
            sequence: valid.sequence,
            ciphertext: valid.ciphertext,
            expiresAtMilliseconds: valid.expiresAtMilliseconds
        )
        do {
            _ = try await callee.open(relabeled, nowMilliseconds: 1)
            XCTFail("AAD relabeling must fail")
        } catch {
            XCTAssertEqual(error as? CallCryptoError, .authenticationFailed)
        }
        do {
            _ = try await callee.open(valid, nowMilliseconds: 101)
            XCTFail("expired signaling must fail")
        } catch {
            XCTAssertEqual(error as? CallCryptoError, .expired)
        }
    }

    func testMaximumPlaintextBoundary() async throws {
        let vector = try CallTestVector()
        let caller = try vector.makeCallerSession()
        let callee = try vector.makeCalleeSession()
        let maximum = Data(repeating: 0xA5, count: CallCipherSession.maximumPlaintextBytes)
        let envelope = try await caller.seal(
            maximum, kind: .control, expiresAtMilliseconds: 10_000
        )
        XCTAssertEqual(envelope.ciphertext.count, maximum.count + 28)
        let opened = try await callee.open(envelope, nowMilliseconds: 1)
        XCTAssertEqual(opened, maximum)

        do {
            _ = try await caller.seal(
                maximum + Data([0]), kind: .control, expiresAtMilliseconds: 10_000
            )
            XCTFail("oversized signaling must fail before encryption")
        } catch {
            XCTAssertEqual(error as? CallCryptoError, .plaintextTooLarge)
        }
    }

    func testReplayWindowRequiresCatchupForLargeGap() throws {
        var window = CallReplayWindow()
        try window.validate(1)
        window.record(1)
        XCTAssertThrowsError(try window.validate(5_000)) { error in
            XCTAssertEqual(error as? CallCryptoError, .sequenceTooFarAhead)
        }
    }
}

final class CallStateMachineTests: XCTestCase {
    func testOutgoingHappyPathReconnectAndEnd() throws {
        var machine = CallStateMachine()
        try machine.handle(.startOutgoing)
        try machine.handle(.outgoingStarted)
        try machine.handle(.remoteAccepted)
        try machine.handle(.keysConfirmed)
        try machine.handle(.mediaConnected)
        XCTAssertEqual(machine.state, .active)
        XCTAssertEqual(machine.direction, .outgoing)

        try machine.handle(.mediaDisconnected)
        XCTAssertEqual(machine.state, .reconnecting)
        try machine.handle(.mediaRecovered)
        XCTAssertEqual(machine.state, .active)
        try machine.handle(.endRequested)
        try machine.handle(.terminated(.remoteEnded))
        XCTAssertEqual(machine.endReason, .remoteEnded)
        try machine.handle(.reset)
        XCTAssertEqual(machine, CallStateMachine())
    }

    func testIncomingPathAndInvalidTransition() throws {
        var machine = CallStateMachine()
        try machine.handle(.receiveIncoming)
        try machine.handle(.accept)
        try machine.handle(.keysConfirmed)
        try machine.handle(.mediaConnected)
        XCTAssertEqual(machine.state, .active)
        XCTAssertEqual(machine.direction, .incoming)

        XCTAssertThrowsError(try machine.handle(.startOutgoing)) { error in
            XCTAssertEqual(
                error as? CallStateMachineError,
                .invalidTransition(state: .active, event: .startOutgoing)
            )
        }
    }

    func testDuplicateEventsAreIdempotentAndFirstEndReasonWins() throws {
        var machine = CallStateMachine()
        try machine.handle(.startOutgoing)
        try machine.handle(.startOutgoing)
        try machine.handle(.outgoingStarted)
        try machine.handle(.outgoingStarted)
        try machine.handle(.terminated(.cancelled))
        try machine.handle(.terminated(.remoteEnded))
        XCTAssertEqual(machine.state, .ended)
        XCTAssertEqual(machine.endReason, .cancelled)
    }
}

final class WebRTCEngineContractTests: XCTestCase {
    func testColdLaunchBootstrapRejectsSessionAlreadyMarkedForRevocation() {
        let session = CloudSession(accountId: "account", deviceId: "device", token: "token")
        let stored = StoredCloudSession(session: session, phone: "+992", displayName: "Alice")

        XCTAssertEqual(
            CallLaunchSessionPolicy.session(from: stored, pendingRevocationToken: nil),
            session
        )
        XCTAssertEqual(
            CallLaunchSessionPolicy.session(from: stored, pendingRevocationToken: "older-token"),
            session
        )
        XCTAssertNil(
            CallLaunchSessionPolicy.session(from: stored, pendingRevocationToken: "token")
        )
        XCTAssertNil(
            CallLaunchSessionPolicy.session(from: nil, pendingRevocationToken: nil)
        )
    }

    func testPrivacyModeMapsToICEPolicy() {
        XCTAssertEqual(CallPrivacyMode.fastestRoute.iceTransportPolicy, .all)
        XCTAssertEqual(CallPrivacyMode.relayOnly.iceTransportPolicy, .relayOnly)
    }

    func testRelayOnlyPolicyDropsPeerHostAndReflexiveCandidatesWithoutRejectingRelay() {
        let host = "candidate:1 1 UDP 2122260223 192.0.2.10 50000 typ host"
        let reflexive = "candidate:2 1 UDP 1686052607 198.51.100.10 51000 typ srflx raddr 0.0.0.0 rport 0"
        let relay = "candidate:3\t1 UDP 1677734910 203.0.113.10 52000 typ relay raddr 0.0.0.0 rport 0"

        XCTAssertTrue(CallICECandidatePolicy.permits(host, transportPolicy: .all))
        XCTAssertTrue(CallICECandidatePolicy.permits(reflexive, transportPolicy: .all))
        XCTAssertFalse(CallICECandidatePolicy.permits(host, transportPolicy: .relayOnly))
        XCTAssertFalse(CallICECandidatePolicy.permits(reflexive, transportPolicy: .relayOnly))
        XCTAssertTrue(CallICECandidatePolicy.permits(relay, transportPolicy: .relayOnly))
    }

    @MainActor
    func testUnavailableEngineFailsClosed() async {
        let engine = UnavailableWebRTCEngine()
        do {
            _ = try await engine.prepareLocalIdentity()
            XCTFail("placeholder must not pretend a call is secure or connected")
        } catch {
            XCTAssertEqual(error as? WebRTCEngineError, .frameworkUnavailable)
        }
        let events = await engine.events()
        var iterator = events.makeAsyncIterator()
        let event = await iterator.next()
        XCTAssertNil(event)
    }

    #if canImport(WebRTC)
    @MainActor
    func testProfileTwoConfigurationIsOneShotAndOwnsIndependentRenderers() async throws {
        XCTAssertTrue(WebRTCEngineFactory.supportsCameraVideoProfile)
        for _ in 0..<3 {
            let engine = WebRTCCallEngine()
            _ = try await engine.prepareLocalIdentity()
            try await engine.updateICEConfiguration(CallICEConfiguration(
                servers: [CallICEServer(
                    urls: ["turn:turn.invalid:3478"],
                    username: "test",
                    credential: "test"
                )],
                transportPolicy: .all
            ))
            try await engine.configureMediaProfile(CallMediaProfileVersion.cameraVideo,
                                                   initialCameraIntent: false)
            try await engine.configureMediaProfile(CallMediaProfileVersion.cameraVideo,
                                                   initialCameraIntent: false)
            do {
                try await engine.configureMediaProfile(CallMediaProfileVersion.cameraVideo,
                                                       initialCameraIntent: true)
                XCTFail("changing one-shot media configuration must fail closed")
            } catch {
                XCTAssertEqual(error as? WebRTCEngineError, .mediaProfileAlreadyConfigured)
            }

            let local = try await engine.makeVideoRenderer(source: .local)
            let remoteMain = try await engine.makeVideoRenderer(source: .remote)
            let remotePiP = try await engine.makeVideoRenderer(source: .remote)
            XCTAssertEqual(Set([local.id, remoteMain.id, remotePiP.id]).count, 3)
            await engine.releaseVideoRenderer(remotePiP)
            await engine.releaseVideoRenderer(remoteMain)
            await engine.releaseVideoRenderer(local)
            await engine.stop()
        }
    }

    @MainActor
    func testPinnedArtifactPreservesStrictProfileOneOffer() async throws {
        let engine = WebRTCCallEngine()
        let identity = try await engine.prepareLocalIdentity()
        try await engine.updateICEConfiguration(CallICEConfiguration(
            servers: [CallICEServer(
                urls: ["turn:turn.invalid:3478"],
                username: "test",
                credential: "test"
            )],
            transportPolicy: .all
        ))
        try await engine.configureMediaProfile(
            CallMediaProfileVersion.voice,
            initialCameraIntent: false
        )
        let offer = try await engine.makeOffer(iceRestart: false)
        XCTAssertTrue(WebRTCCallEngine.validatesMediaSDPForTesting(
            offer.sdp,
            profile: CallMediaProfileVersion.voice,
            type: .offer,
            expectedFingerprint: identity.dtlsFingerprintSHA256
        ))
        XCTAssertFalse(offer.sdp.contains("m=video "))
        await engine.stop()
    }

    @MainActor
    func testPinnedArtifactGeneratesAndAcceptsStrictProfileTwoOfferAndAnswer() async throws {
        let caller = WebRTCCallEngine()
        let callee = WebRTCCallEngine()
        let callerIdentity = try await caller.prepareLocalIdentity()
        let calleeIdentity = try await callee.prepareLocalIdentity()
        let ice = CallICEConfiguration(
            servers: [CallICEServer(
                urls: ["turn:turn.invalid:3478"],
                username: "test",
                credential: "test"
            )],
            transportPolicy: .all
        )
        try await caller.updateICEConfiguration(ice)
        try await callee.updateICEConfiguration(ice)
        try await caller.configureMediaProfile(
            CallMediaProfileVersion.cameraVideo,
            initialCameraIntent: false
        )
        try await callee.configureMediaProfile(
            CallMediaProfileVersion.cameraVideo,
            initialCameraIntent: false
        )

        let offer: CallSessionDescription
        do {
            offer = try await caller.makeOffer(iceRestart: false)
        } catch {
            XCTFail("Generated profile-2 offer was rejected: \(error); validator: \(WebRTCCallEngine.lastSDPValidationFailureForTesting ?? "unknown")\n\(WebRTCCallEngine.lastGeneratedSDPForTesting ?? "missing SDP")")
            await caller.stop()
            await callee.stop()
            return
        }
        XCTAssertTrue(WebRTCCallEngine.validatesMediaSDPForTesting(
            offer.sdp,
            profile: CallMediaProfileVersion.cameraVideo,
            type: .offer,
            expectedFingerprint: callerIdentity.dtlsFingerprintSHA256
        ))
        do {
            try await callee.setRemoteDescription(
                offer,
                expectedDTLSFingerprintSHA256: callerIdentity.dtlsFingerprintSHA256
            )
        } catch {
            XCTFail("Profile-2 offer could not be installed: \(error); media graph: \(WebRTCCallEngine.lastMediaReassertFailureForTesting ?? "unknown")")
            await caller.stop()
            await callee.stop()
            return
        }
        let answer: CallSessionDescription
        do {
            answer = try await callee.makeAnswer()
        } catch {
            XCTFail("Generated profile-2 answer was rejected: \(error); validator: \(WebRTCCallEngine.lastSDPValidationFailureForTesting ?? "unknown")\n\(WebRTCCallEngine.lastGeneratedSDPForTesting ?? "missing SDP")")
            await caller.stop()
            await callee.stop()
            return
        }
        XCTAssertTrue(WebRTCCallEngine.validatesMediaSDPForTesting(
            answer.sdp,
            profile: CallMediaProfileVersion.cameraVideo,
            type: .answer,
            expectedFingerprint: calleeIdentity.dtlsFingerprintSHA256
        ))
        try await caller.setRemoteDescription(
            answer,
            expectedDTLSFingerprintSHA256: calleeIdentity.dtlsFingerprintSHA256
        )

        let restartOffer = try await caller.makeOffer(iceRestart: true)
        XCTAssertTrue(WebRTCCallEngine.validatesMediaSDPForTesting(
            restartOffer.sdp,
            profile: CallMediaProfileVersion.cameraVideo,
            type: .offer,
            expectedFingerprint: callerIdentity.dtlsFingerprintSHA256
        ))

        // The permanent video track can remain off after descriptions are installed; this
        // exercises the same sender without producing another offer or answer.
        try await caller.setCameraEnabled(false, position: .front)
        try await callee.setCameraEnabled(false, position: .front)
        await caller.stop()
        await callee.stop()
    }

    @MainActor
    func testProfileTwoStrictSDPRejectsDowngradesAndUnexpectedMedia() {
        let fixture = profileTwoSDP(setup: "actpass")
        XCTAssertTrue(WebRTCCallEngine.validatesMediaSDPForTesting(
            fixture.sdp,
            profile: CallMediaProfileVersion.cameraVideo,
            type: .offer,
            expectedFingerprint: fixture.fingerprint
        ))

        let invalid: [String] = [
            fixture.sdp.replacingOccurrences(of: "m=video 9", with: "m=video 0"),
            fixture.sdp.replacingOccurrences(of: "m=video 9 UDP/TLS/RTP/SAVPF",
                                             with: "m=video 9 RTP/SAVPF"),
            fixture.sdp.replacingOccurrences(of: "a=group:BUNDLE 0 1", with: "a=group:BUNDLE 0"),
            fixture.sdp.replacingOccurrences(
                of: "a=group:BUNDLE 0 1",
                with: "a=group:BUNDLE 0 1\r\na=group:BUNDLE 0 1"
            ),
            fixture.sdp.replacingOccurrences(of: "a=mid:1", with: "a=mid:0"),
            fixture.sdp.replacingOccurrences(of: "a=ice-ufrag:bundle", with: "a=ice-ufrag:"),
            fixture.sdp.replacingOccurrences(
                of: "a=ice-ufrag:bundle\r\na=ice-pwd:bundle-password\r\na=setup:actpass\r\na=rtpmap:96",
                with: "a=ice-ufrag:other\r\na=ice-pwd:other-password\r\na=setup:actpass\r\na=rtpmap:96"
            ),
            fixture.sdp.replacingOccurrences(of: "a=fmtp:97 apt=96", with: "a=fmtp:97 apt=120"),
            fixture.sdp.replacingOccurrences(of: "profile-level-id=42e01f", with: "profile-level-id=42e0zz"),
            fixture.sdp.replacingOccurrences(of: "profile-level-id=42e01f", with: "profile-level-id=42e0"),
            fixture.sdp.replacingOccurrences(
                of: "profile-level-id=42e01f",
                with: "profile-level-id=42e01f;packetization-mode=1"
            ),
            fixture.sdp.replacingOccurrences(
                of: "a=fmtp:96 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f",
                with: "a=fmtp:96 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f\r\na=fmtp:96 packetization-mode=1"
            ),
            fixture.sdp + "m=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n",
            fixture.sdp + "a=crypto:1 AES_CM_128_HMAC_SHA1_80 inline:secret\r\n",
            fixture.sdp.replacingOccurrences(
                of: "m=video 9 UDP/TLS/RTP/SAVPF 96 97 98 99",
                with: "m=video 9 UDP/TLS/RTP/SAVPF 96 97 98 99 100"
            ) + "a=rtpmap:100 VP8/90000\r\n",
            fixture.sdp.replacingOccurrences(
                of: "a=mid:1\r\na=sendrecv",
                with: "a=mid:1\r\na=inactive"
            ),
        ]
        for sdp in invalid {
            XCTAssertFalse(WebRTCCallEngine.validatesMediaSDPForTesting(
                sdp,
                profile: CallMediaProfileVersion.cameraVideo,
                type: .offer,
                expectedFingerprint: fixture.fingerprint
            ))
        }
        XCTAssertFalse(WebRTCCallEngine.validatesMediaSDPForTesting(
            fixture.sdp,
            profile: CallMediaProfileVersion.cameraVideo,
            type: .offer,
            expectedFingerprint: Data(repeating: 0xFF, count: 32)
        ))
        let rejectedVideo = fixture.sdp.replacingOccurrences(
            of: "m=video 9",
            with: "m=video 0"
        )
        XCTAssertFalse(WebRTCCallEngine.validatesMediaSDPForTesting(
            rejectedVideo,
            profile: CallMediaProfileVersion.cameraVideo,
            type: .offer,
            expectedFingerprint: fixture.fingerprint
        ))
    }

    private func profileTwoSDP(setup: String) -> (sdp: String, fingerprint: Data) {
        let fingerprint = Data((0..<32).map(UInt8.init))
        let fingerprintText = fingerprint.map { String(format: "%02X", $0) }.joined(separator: ":")
        let lines = [
            "v=0", "o=- 1 1 IN IP4 127.0.0.1", "s=-", "t=0 0",
            "a=group:BUNDLE 0 1", "a=fingerprint:sha-256 \(fingerprintText)",
            "m=audio 9 UDP/TLS/RTP/SAVPF 111", "c=IN IP4 0.0.0.0", "a=mid:0",
            "a=sendrecv", "a=rtcp-mux", "a=ice-ufrag:bundle", "a=ice-pwd:bundle-password",
            "a=setup:\(setup)", "a=rtpmap:111 opus/48000/2",
            "m=video 9 UDP/TLS/RTP/SAVPF 96 97 98 99", "c=IN IP4 0.0.0.0", "a=mid:1",
            "a=sendrecv", "a=rtcp-mux", "a=ice-ufrag:bundle", "a=ice-pwd:bundle-password",
            "a=setup:\(setup)", "a=rtpmap:96 H264/90000",
            "a=fmtp:96 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f",
            "a=rtpmap:97 rtx/90000", "a=fmtp:97 apt=96", "a=rtpmap:98 red/90000",
            "a=rtpmap:99 ulpfec/90000",
        ]
        return (lines.joined(separator: "\r\n") + "\r\n", fingerprint)
    }
    #endif
}

final class CallVideoStateReducerTests: XCTestCase {
    @MainActor
    func testCaptureRequiresAuthenticatedMediaPermissionAndOwningScene() {
        var reducer = CallVideoStateReducer()
        let generation = reducer.beginRuntime(initialCameraIntent: true)
        XCTAssertEqual(reducer.decision().effectiveState, .inactive)
        reducer.setPermission(.authorized, generation: generation)
        reducer.setSecureMediaReady(true, generation: generation)
        XCTAssertEqual(reducer.decision().genericPauseReason, .background)
        reducer.setScene(
            foreground: true,
            pictureInPicture: false,
            backgroundCameraAvailable: false,
            generation: generation
        )
        XCTAssertEqual(reducer.decision(), CallVideoCaptureDecision(
            shouldCapture: true,
            effectiveState: .active,
            genericPauseReason: nil,
            preferredCameraPosition: .front
        ))
        reducer.setNetworkStarved(true, generation: generation)
        XCTAssertEqual(reducer.decision().genericPauseReason, .network)
        reducer.setUserWantsCamera(false, generation: generation)
        XCTAssertEqual(reducer.decision().effectiveState, .inactive)
    }

    @MainActor
    func testGenerationFenceIgnoresLatePermissionAndCaptureCallbacks() {
        var reducer = CallVideoStateReducer()
        let old = reducer.beginRuntime(initialCameraIntent: true)
        let current = reducer.beginRuntime(initialCameraIntent: false)
        reducer.setPermission(.authorized, generation: old)
        reducer.setSecureMediaReady(true, generation: old)
        reducer.setCaptureHealth(
            interrupted: true,
            runtimeFailed: true,
            cameraAvailable: false,
            pressureCritical: true,
            generation: old
        )
        XCTAssertEqual(reducer.generation, current)
        XCTAssertFalse(reducer.userWantsCamera)
        XCTAssertEqual(reducer.permission, .notDetermined)
        XCTAssertEqual(reducer.decision().effectiveState, .inactive)
    }

    @MainActor
    func testCriticalThermalRecoveryRequiresTwentyStableSeconds() {
        var reducer = CallVideoStateReducer()
        let generation = reducer.beginRuntime(initialCameraIntent: true)
        reducer.setPermission(.authorized, generation: generation)
        reducer.setSecureMediaReady(true, generation: generation)
        reducer.setScene(
            foreground: true,
            pictureInPicture: false,
            backgroundCameraAvailable: false,
            generation: generation
        )
        let now = Date(timeIntervalSince1970: 1_000)
        reducer.setThermalState(.critical, now: now, generation: generation)
        XCTAssertEqual(reducer.decision(now: now).effectiveState, .paused)
        reducer.setThermalState(.serious, now: now.addingTimeInterval(1), generation: generation)
        reducer.setThermalState(.fair, now: now.addingTimeInterval(2), generation: generation)
        XCTAssertEqual(reducer.decision(now: now.addingTimeInterval(21.999)).effectiveState, .paused)
        XCTAssertEqual(reducer.decision(now: now.addingTimeInterval(22)).effectiveState, .active)
    }

    @MainActor
    func testForegroundUserRetryClearsOnlyLatchedRuntimeFailure() {
        var reducer = CallVideoStateReducer()
        let generation = reducer.beginRuntime(initialCameraIntent: true)
        reducer.setPermission(.authorized, generation: generation)
        reducer.setSecureMediaReady(true, generation: generation)
        reducer.setScene(
            foreground: true,
            pictureInPicture: false,
            backgroundCameraAvailable: false,
            generation: generation
        )
        reducer.setCaptureHealth(
            interrupted: true,
            runtimeFailed: true,
            cameraAvailable: true,
            pressureCritical: false,
            generation: generation
        )
        reducer.retryCaptureAfterRuntimeFailure(generation: generation)
        XCTAssertFalse(reducer.captureRuntimeFailed)
        XCTAssertTrue(reducer.captureIsInterrupted)
        XCTAssertEqual(reducer.decision().effectiveState, .paused)
    }

    func testRevisionPolicyRejectsOverflowAndStaleRemoteUpdates() throws {
        XCTAssertEqual(try CallMediaRevisionPolicy.advanced(after: 1), 2)
        XCTAssertThrowsError(try CallMediaRevisionPolicy.advanced(after: .max)) { error in
            XCTAssertEqual(error as? CallCryptoError, .sequenceExhausted)
        }
        XCTAssertTrue(CallMediaRevisionPolicy.accepts(remote: 4, highestAccepted: 3))
        XCTAssertFalse(CallMediaRevisionPolicy.accepts(remote: 3, highestAccepted: 3))
        XCTAssertFalse(CallMediaRevisionPolicy.accepts(remote: 2, highestAccepted: 3))
    }
}

final class CallVideoQualityReducerTests: XCTestCase {
    private let ordinaryWiFi = CallVideoPathPolicy(
        kind: .wifi,
        isConstrained: false,
        isLowDataMode: false,
        isRoaming: false
    )

    func testThreeBadIntervalSamplesReduceExactlyOneTier() {
        var reducer = CallVideoQualityReducer()
        ingestSender(&reducer, second: 0, lost: 0, sent: 0, bitrate: 2_000_000)
        for second in 1...3 {
            ingestSender(&reducer, second: second, lost: Int64(second * 100),
                         sent: Int64(second * 900), bitrate: 500_000, rtt: 451, jitter: 61)
        }
        XCTAssertEqual(reducer.senderTier, .medium)
    }

    func testExactBadThresholdsAreNotTreatedAsBad() {
        var reducer = CallVideoQualityReducer()
        ingestSender(&reducer, second: 0, lost: 0, sent: 0, bitrate: 2_000_000)
        for second in 1...3 {
            ingestSender(&reducer, second: second, lost: Int64(second * 80),
                         sent: Int64(second * 1_000), bitrate: 1_500_000 * 0.70,
                         rtt: 450, jitter: 60)
        }
        XCTAssertEqual(reducer.senderTier, .high)
    }

    func testIncompleteSamplesBreakConsecutiveSenderAndReceiverRuns() {
        var sender = CallVideoQualityReducer()
        ingestSender(&sender, second: 0, lost: 0, sent: 0, bitrate: 2_000_000)
        for second in 1...2 {
            ingestSender(&sender, second: second, lost: Int64(second * 100),
                         sent: Int64(second * 900), bitrate: 500_000, rtt: 451, jitter: 61)
        }
        sender.ingestSender(CallVideoSenderStats(
            timestamp: 3,
            packetsLost: nil,
            packetsSent: nil,
            roundTripTimeMilliseconds: 500,
            jitterMilliseconds: 70,
            availableOutgoingBitrate: 10_000
        ), policy: .never, path: ordinaryWiFi, thermal: .nominal,
        peerMaximumReceiveTier: .high)
        ingestSender(&sender, second: 4, lost: 400, sent: 3_600,
                     bitrate: 500_000, rtt: 451, jitter: 61)
        XCTAssertEqual(sender.senderTier, .high)

        var receiver = CallVideoQualityReducer()
        receiver.ingestReceiver(receiverSample(
            second: 0, lost: 0, received: 0, freeze: 0, frames: 0
        ), policy: .never, path: ordinaryWiFi, thermal: .nominal)
        for second in 1...2 {
            receiver.ingestReceiver(receiverSample(
                second: second,
                lost: Int64(second * 100),
                received: Int64(second * 900),
                freeze: Double(second * 600),
                frames: Int64(second * 5)
            ), policy: .never, path: ordinaryWiFi, thermal: .nominal)
        }
        receiver.ingestReceiver(CallVideoReceiverStats(
            timestamp: 3,
            packetsLost: nil,
            packetsReceived: nil,
            jitterMilliseconds: nil,
            totalFreezeMilliseconds: nil,
            totalFramesDecoded: nil
        ), policy: .never, path: ordinaryWiFi, thermal: .nominal)
        receiver.ingestReceiver(receiverSample(
            second: 4, lost: 400, received: 3_600, freeze: 2_400, frames: 20
        ), policy: .never, path: ordinaryWiFi, thermal: .nominal)
        XCTAssertEqual(receiver.requestedReceiveTier, .high)
    }

    func testMissingSamplesDataCapsStarvationAndRecovery() {
        var missing = CallVideoQualityReducer()
        for _ in 0..<3 {
            missing.ingestSender(nil, policy: .never, path: ordinaryWiFi,
                                 thermal: .nominal, peerMaximumReceiveTier: .high)
        }
        XCTAssertEqual(missing.senderTier, .low)

        var capped = CallVideoQualityReducer()
        capped.ingestSender(nil, policy: .always, path: ordinaryWiFi,
                            thermal: .nominal, peerMaximumReceiveTier: .high)
        XCTAssertEqual(capped.senderTier, .medium)
        let constrained = CallVideoPathPolicy(
            kind: .cellular, isConstrained: true, isLowDataMode: true, isRoaming: true
        )
        capped.ingestSender(nil, policy: .never, path: constrained,
                            thermal: .nominal, peerMaximumReceiveTier: .high)
        XCTAssertEqual(capped.senderTier, .low)

        var receiveCapped = CallVideoQualityReducer()
        receiveCapped.ingestReceiver(nil, policy: .always, path: ordinaryWiFi, thermal: .nominal)
        XCTAssertEqual(receiveCapped.requestedReceiveTier, .medium)
        receiveCapped.ingestReceiver(nil, policy: .never, path: constrained, thermal: .nominal)
        XCTAssertEqual(receiveCapped.requestedReceiveTier, .low)

        var missingReceiver = CallVideoQualityReducer()
        for _ in 0..<3 {
            missingReceiver.ingestReceiver(
                nil,
                policy: .never,
                path: ordinaryWiFi,
                thermal: .nominal
            )
        }
        XCTAssertEqual(missingReceiver.requestedReceiveTier, .low)

        var starving = CallVideoQualityReducer()
        ingestSender(&starving, second: 0, lost: 0, sent: 0, bitrate: 70_000)
        for second in 1...5 {
            ingestSender(&starving, second: second, lost: 0,
                         sent: Int64(second * 1_000), bitrate: 70_000)
        }
        XCTAssertTrue(starving.outgoingVideoPaused)
        for second in 6...15 {
            ingestSender(&starving, second: second, lost: 0,
                         sent: Int64(second * 1_000), bitrate: 800_000, rtt: 200, jitter: 10)
        }
        XCTAssertFalse(starving.outgoingVideoPaused)
    }

    func testPeerCapAndReceiverHysteresisAreBidirectional() {
        var sender = CallVideoQualityReducer()
        sender.ingestSender(nil, policy: .never, path: ordinaryWiFi,
                            thermal: .nominal, peerMaximumReceiveTier: .low)
        XCTAssertEqual(sender.senderTier, .low)

        var receiver = CallVideoQualityReducer()
        receiver.ingestReceiver(receiverSample(second: 0, lost: 0, received: 0,
                                               freeze: 0, frames: 0),
                                policy: .never, path: ordinaryWiFi, thermal: .nominal)
        for second in 1...3 {
            receiver.ingestReceiver(receiverSample(
                second: second,
                lost: Int64(second * 100),
                received: Int64(second * 900),
                freeze: Double(second * 600),
                frames: Int64(second * 5)
            ), policy: .never, path: ordinaryWiFi, thermal: .nominal)
        }
        XCTAssertEqual(receiver.requestedReceiveTier, .medium)
        receiver.resetBaselines()
        receiver.ingestReceiver(receiverSample(second: 10, lost: 300, received: 2_700,
                                               freeze: 1_800, frames: 15),
                                policy: .never, path: ordinaryWiFi, thermal: .nominal)
        for second in 11...20 {
            receiver.ingestReceiver(receiverSample(
                second: second,
                lost: 300,
                received: 2_700 + Int64((second - 10) * 1_000),
                freeze: 1_800,
                frames: 15 + Int64((second - 10) * 24)
            ), policy: .never, path: ordinaryWiFi, thermal: .nominal)
        }
        XCTAssertEqual(receiver.requestedReceiveTier, .high)
    }

    private func ingestSender(
        _ reducer: inout CallVideoQualityReducer,
        second: Int,
        lost: Int64,
        sent: Int64,
        bitrate: Double,
        rtt: Double = 200,
        jitter: Double = 10
    ) {
        reducer.ingestSender(CallVideoSenderStats(
            timestamp: Double(second), packetsLost: lost, packetsSent: sent,
            roundTripTimeMilliseconds: rtt, jitterMilliseconds: jitter,
            availableOutgoingBitrate: bitrate
        ), policy: .never, path: ordinaryWiFi, thermal: .nominal,
        peerMaximumReceiveTier: .high)
    }

    private func receiverSample(
        second: Int,
        lost: Int64,
        received: Int64,
        freeze: Double,
        frames: Int64
    ) -> CallVideoReceiverStats {
        CallVideoReceiverStats(
            timestamp: Double(second), packetsLost: lost, packetsReceived: received,
            jitterMilliseconds: 10, totalFreezeMilliseconds: freeze,
            totalFramesDecoded: frames
        )
    }
}

final class CallGlarePolicyTests: XCTestCase {
    func testPushBeforeBusyDefersTheIncomingWinnerAndReusesItsCallKitReport() {
        let outgoing = UUID()
        let incoming = UUID()
        XCTAssertEqual(
            CallGlarePolicy.pushDisposition(
                activeCallId: outgoing,
                incomingCallId: incoming,
                activeDirection: .outgoing,
                activePeerAccountId: "bob",
                incomingCallerAccountId: "bob",
                activeCallReachedServer: false
            ),
            .deferForServerWinner
        )
        XCTAssertEqual(
            CallGlarePolicy.pivotSource(
                existingCallId: incoming,
                deferredInvitationIds: [incoming]
            ),
            .alreadyReportedInvitation
        )
    }

    func testBusyBeforePushSynthesizesTheServerSelectedInvitation() {
        let existing = UUID()
        XCTAssertEqual(
            CallGlarePolicy.pivotSource(
                existingCallId: existing,
                deferredInvitationIds: []
            ),
            .syntheticInvitation
        )
        XCTAssertEqual(
            CallGlarePolicy.pushDisposition(
                activeCallId: UUID(),
                incomingCallId: UUID(),
                activeDirection: .outgoing,
                activePeerAccountId: "bob",
                incomingCallerAccountId: "bob",
                activeCallReachedServer: true
            ),
            .declineAsBusy
        )
    }
}

private struct CallTestVector {
    let context: CallHandshakeContextV1
    let callee: CallParty
    let callerKeyPair: CallEphemeralKeyPair
    let calleeKeyPair: CallEphemeralKeyPair
    let callerMaterial: CallKeyMaterialV1
    let calleeMaterial: CallKeyMaterialV1
    let callerCommitment: Data
    let calleeCommitment: Data
    let transcript: Data

    init() throws {
        context = CallHandshakeContextV1(
            identity: CallIdentity(
                callId: "00000000-0000-0000-0000-000000000001",
                dialogId: "00000000-0000-0000-0000-000000000002",
                caller: CallParty(accountId: "alice", deviceId: "alice-ios-1"),
                calleeAccountId: "bob"
            ),
            offeredProtocolVersions: [1],
            offeredMediaProfileVersions: [1]
        )
        callee = CallParty(accountId: "bob", deviceId: "bob-ios-1")
        callerKeyPair = try CallEphemeralKeyPair(
            privateKey: Data((0..<32).map(UInt8.init))
        )
        calleeKeyPair = try CallEphemeralKeyPair(
            privateKey: Data((32..<64).map(UInt8.init))
        )
        callerMaterial = try CallCrypto.keyMaterial(
            keyPair: callerKeyPair,
            nonce: Data((64..<96).map(UInt8.init)),
            dtlsFingerprintSHA256: Data((96..<128).map(UInt8.init))
        )
        calleeMaterial = try CallCrypto.keyMaterial(
            keyPair: calleeKeyPair,
            nonce: Data((128..<160).map(UInt8.init)),
            dtlsFingerprintSHA256: Data((160..<192).map(UInt8.init))
        )
        callerCommitment = try CallProtocolV1.callerCommitment(
            context: context,
            material: callerMaterial
        )
        calleeCommitment = try CallProtocolV1.calleeCommitment(
            context: context,
            callerCommitment: callerCommitment,
            callee: callee,
            selectedProtocolVersion: 1,
            selectedMediaProfileVersion: 1,
            material: calleeMaterial
        )
        transcript = try CallProtocolV1.transcript(
            context: context,
            callerCommitment: callerCommitment,
            callerMaterial: callerMaterial,
            calleeCommitment: calleeCommitment,
            callee: callee,
            calleeMaterial: calleeMaterial,
            selectedProtocolVersion: 1,
            selectedMediaProfileVersion: 1
        )
    }

    func makeCallerSession() throws -> CallCipherSession {
        CallCipherSession(
            callId: context.identity.callId,
            localDeviceId: context.identity.caller.deviceId,
            remoteDeviceId: callee.deviceId,
            localRole: .caller,
            keys: try CallCrypto.deriveSessionKeys(
                localPrivateKey: callerKeyPair.privateKey,
                remotePublicKey: calleeKeyPair.publicKey,
                transcript: transcript
            )
        )
    }

    func makeCalleeSession() throws -> CallCipherSession {
        CallCipherSession(
            callId: context.identity.callId,
            localDeviceId: callee.deviceId,
            remoteDeviceId: context.identity.caller.deviceId,
            localRole: .callee,
            keys: try CallCrypto.deriveSessionKeys(
                localPrivateKey: calleeKeyPair.privateKey,
                remotePublicKey: callerKeyPair.publicKey,
                transcript: transcript
            )
        )
    }
}

private extension CallEncryptedSignalV1 {
    func replacing(ciphertext: Data) -> CallEncryptedSignalV1 {
        CallEncryptedSignalV1(
            version: version,
            callId: callId,
            senderDeviceId: senderDeviceId,
            kind: kind,
            sequence: sequence,
            ciphertext: ciphertext,
            expiresAtMilliseconds: expiresAtMilliseconds
        )
    }
}

private extension Data {
    var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

final class CallPlatformContractTests: XCTestCase {
    func testEncryptedControlPayloadRoundTripsICERestartRequest() throws {
        let encoded = try JSONEncoder().encode(CallCoordinator.CallWirePayload(
            description: nil,
            candidate: nil,
            control: .requestICERestart
        ))
        let decoded = try JSONDecoder().decode(CallCoordinator.CallWirePayload.self, from: encoded)

        XCTAssertNil(decoded.description)
        XCTAssertNil(decoded.candidate)
        XCTAssertEqual(decoded.control, .requestICERestart)
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains("request_ice_restart"))
    }

    func testEncryptedMediaStatePayloadRoundTripsAndKeepsRevisionsIndependent() throws {
        let update = CallMediaStateUpdateV1(
            version: 1,
            revision: 17,
            desiredCameraState: true,
            effectiveState: .paused,
            genericPauseReason: .network,
            requestedMaximumReceiveTier: .low
        )
        let encoded = try JSONEncoder().encode(CallCoordinator.CallWirePayload(
            description: nil,
            candidate: nil,
            mediaState: update
        ))
        let decoded = try JSONDecoder().decode(CallCoordinator.CallWirePayload.self, from: encoded)
        XCTAssertEqual(decoded.mediaState, update)
        XCTAssertNil(decoded.control)
    }

    func testCallKitKeepsStartIntentImmutableWhileHasVideoMayUpgrade() {
        XCTAssertFalse(CallKitVideoContract.immutableStartActionIsVideo(for: .voice))
        XCTAssertFalse(CallKitVideoContract.initialUpdateHasVideo(for: .voice))
        XCTAssertTrue(CallKitVideoContract.immutableStartActionIsVideo(for: .video))
        XCTAssertTrue(CallKitVideoContract.initialUpdateHasVideo(for: .video))
        XCTAssertTrue(CallKitVideoContract.shouldAutoEnableSpeaker(for: .builtInReceiver))
        XCTAssertTrue(CallKitVideoContract.shouldAutoEnableSpeaker(for: .unknown))
        XCTAssertFalse(CallKitVideoContract.shouldAutoEnableSpeaker(for: .wired))
        XCTAssertFalse(CallKitVideoContract.shouldAutoEnableSpeaker(for: .bluetooth))
        XCTAssertFalse(CallKitVideoContract.shouldAutoEnableSpeaker(for: .airPlay))
    }

    func testEveryTerminalLifecycleProjectionMapsToACallKitEndReason() {
        let cases: [(String?, CallEndReason)] = [
            ("answered_elsewhere", .answeredElsewhere),
            ("declined", .declined),
            ("unanswered", .unanswered),
            ("expired", .unanswered),
            ("cancelled", .cancelled),
            ("caller_cancelled", .cancelled),
            ("busy", .busy),
            ("network_lost", .networkLost),
            ("security_error", .securityError),
            ("local_ended", .remoteEnded),
            (nil, .remoteEnded),
        ]

        for (rawReason, expected) in cases {
            XCTAssertEqual(
                CallLifecycleProjectionPolicy.terminalReason(
                    view: .lifecycle,
                    state: "ended",
                    endReason: rawReason
                ),
                expected
            )
        }
        XCTAssertNil(CallLifecycleProjectionPolicy.terminalReason(
            view: .full,
            state: "ended",
            endReason: "declined"
        ))
        XCTAssertNil(CallLifecycleProjectionPolicy.terminalReason(
            view: .lifecycle,
            state: "active",
            endReason: "declined"
        ))
    }

    func testEncryptedSignalKindMustAgreeWithInnerSDPType() {
        XCTAssertTrue(CallSignalDescriptionPolicy.accepts(
            kind: .offer,
            descriptionType: .offer
        ))
        XCTAssertTrue(CallSignalDescriptionPolicy.accepts(
            kind: .iceRestart,
            descriptionType: .offer
        ))
        XCTAssertTrue(CallSignalDescriptionPolicy.accepts(
            kind: .answer,
            descriptionType: .answer
        ))
        XCTAssertFalse(CallSignalDescriptionPolicy.accepts(
            kind: .offer,
            descriptionType: .answer
        ))
        XCTAssertFalse(CallSignalDescriptionPolicy.accepts(
            kind: .iceRestart,
            descriptionType: .answer
        ))
        XCTAssertFalse(CallSignalDescriptionPolicy.accepts(
            kind: .answer,
            descriptionType: .offer
        ))
    }

    func testLifecycleCallViewDecodesOnlyWithoutNegotiationSecrets() throws {
        let response = try JSONDecoder().decode(CloudCallResponse.self, from: Data(#"""
        {"call":{"view":"lifecycle","id":"call","dialogId":"dialog","callerAccountId":"alice","callerDeviceId":"alice-phone","calleeAccountId":"bob","state":"ended","offeredProtocolVersions":[],"offeredMediaProfileVersions":[],"selectableMediaProfileVersions":[],"initialKind":"video","protocolVersion":null,"mediaProfileVersion":null,"callerCommitment":null,"calleeCommitment":null,"callerFingerprint":null,"acceptedDeviceId":null,"calleePublicKey":null,"calleeNonce":null,"calleeFingerprint":null,"callerPublicKey":null,"callerNonce":null,"createdAt":"2026-01-01T00:00:00Z","expiresAt":"2026-01-01T00:01:00Z","acceptedAt":null,"confirmedAt":null,"endedAt":"2026-01-01T00:00:10Z","endReason":"answered_elsewhere","localRingStatus":"answered_elsewhere","latestEventSeq":0}}
        """#.utf8))

        guard case .lifecycle(let snapshot) = response.callView else {
            return XCTFail("Expected a lifecycle projection")
        }
        XCTAssertEqual(snapshot.initialKind, .video)
        XCTAssertEqual(snapshot.localRingStatus, "answered_elsewhere")
    }

    func testLifecycleCallViewFailsClosedIfServerLeaksNegotiationState() throws {
        let leaked = Data(#"""
        {"call":{"view":"lifecycle","id":"call","dialogId":"dialog","callerAccountId":"alice","callerDeviceId":"alice-phone","calleeAccountId":"bob","state":"ended","offeredProtocolVersions":[1],"offeredMediaProfileVersions":[],"selectableMediaProfileVersions":[],"initialKind":"video","protocolVersion":null,"mediaProfileVersion":null,"callerCommitment":"secret","calleeCommitment":null,"callerFingerprint":null,"acceptedDeviceId":null,"calleePublicKey":null,"calleeNonce":null,"calleeFingerprint":null,"callerPublicKey":null,"callerNonce":null,"createdAt":"2026-01-01T00:00:00Z","expiresAt":"2026-01-01T00:01:00Z","acceptedAt":null,"confirmedAt":null,"endedAt":"2026-01-01T00:00:10Z","endReason":"answered_elsewhere","localRingStatus":"answered_elsewhere","latestEventSeq":0}}
        """#.utf8)

        XCTAssertThrowsError(try JSONDecoder().decode(CloudCallResponse.self, from: leaked))
    }

    @MainActor
    func testSignalOutboxPreservesSubmissionOrderAcrossSuspension() async throws {
        let outbox = OrderedCallSignalOutbox()
        let firstGate = CallTestGate()
        var order: [String] = []

        let first = Task { @MainActor in
            try await outbox.perform {
                order.append("first-started")
                await firstGate.wait()
                order.append("first-finished")
            }
        }
        while !firstGate.isWaiting { await Task.yield() }

        var secondSubmitted = false
        let second = Task { @MainActor in
            secondSubmitted = true
            try await outbox.perform { order.append("second") }
        }
        while !secondSubmitted { await Task.yield() }
        await Task.yield()

        var thirdSubmitted = false
        let third = Task { @MainActor in
            thirdSubmitted = true
            try await outbox.perform { order.append("third") }
        }
        while !thirdSubmitted { await Task.yield() }
        await Task.yield()

        XCTAssertEqual(order, ["first-started"])
        firstGate.open()
        try await first.value
        try await second.value
        try await third.value
        XCTAssertEqual(order, ["first-started", "first-finished", "second", "third"])
    }

    @MainActor
    func testSignalOutboxCancellationStopsRunningAndQueuedOperations() async {
        let outbox = OrderedCallSignalOutbox()
        let firstGate = CallTestGate()
        var firstPassedCancellationCheck = false
        var queuedOperationRan = false

        let first = Task { @MainActor in
            try await outbox.perform {
                await firstGate.wait()
                try Task.checkCancellation()
                firstPassedCancellationCheck = true
            }
        }
        while !firstGate.isWaiting { await Task.yield() }

        var queuedSubmitted = false
        let queued = Task { @MainActor in
            queuedSubmitted = true
            try await outbox.perform { queuedOperationRan = true }
        }
        while !queuedSubmitted { await Task.yield() }
        await Task.yield()

        outbox.cancel()
        firstGate.open()

        await XCTAssertThrowsCancellation(first)
        await XCTAssertThrowsCancellation(queued)
        XCTAssertFalse(firstPassedCancellationCheck)
        XCTAssertFalse(queuedOperationRan)
    }

    @MainActor
    func testSignalOutboxPropagatesCallerCancellationAndRejectsWorkAfterClose() async throws {
        let outbox = OrderedCallSignalOutbox()
        let gate = CallTestGate()
        var cancelledOperationFinished = false

        let caller = Task { @MainActor in
            try await outbox.perform {
                await gate.wait()
                try Task.checkCancellation()
                cancelledOperationFinished = true
            }
        }
        while !gate.isWaiting { await Task.yield() }
        caller.cancel()
        gate.open()
        await XCTAssertThrowsCancellation(caller)
        XCTAssertFalse(cancelledOperationFinished)

        var followupRan = false
        try await outbox.perform { followupRan = true }
        XCTAssertTrue(followupRan)

        outbox.cancel()
        let rejected = Task { @MainActor in
            try await outbox.perform { XCTFail("A closed outbox must not run new work") }
        }
        await XCTAssertThrowsCancellation(rejected)
    }

    func testVoIPInvitationAcceptsVersionedNestedPayload() throws {
        let id = UUID()
        let invitation = try XCTUnwrap(VoIPPushInvitation(payload: [
            "aps": ["content-available": 1],
            "toj": [
                "v": 1,
                "type": "voice_call",
                "callId": id.uuidString.lowercased(),
                "callerAccountId": UUID().uuidString.lowercased(),
                "expiresAt": "2099-01-01T00:00:00Z",
            ],
        ]))
        XCTAssertEqual(invitation.callId, id)
        XCTAssertEqual(invitation.initialKind, .voice)
    }

    func testVoIPInvitationAuthenticatesVideoKindFromVersionedPayload() throws {
        let id = UUID()
        let invitation = try XCTUnwrap(VoIPPushInvitation(payload: [
            "aps": ["content-available": 1],
            "toj": [
                "v": 1,
                "type": "video_call",
                "callId": id.uuidString.lowercased(),
                "callerAccountId": UUID().uuidString.lowercased(),
                "expiresAt": "2099-01-01T00:00:00Z",
            ],
        ]))
        XCTAssertEqual(invitation.callId, id)
        XCTAssertEqual(invitation.initialKind, .video)
    }

    func testVoIPInvitationPreservesExpiredCallForMandatoryCallKitReporting() throws {
        let common: [String: Any] = [
            "type": "voice_call",
            "callId": UUID().uuidString.lowercased(),
            "callerAccountId": UUID().uuidString.lowercased(),
            "expiresAt": "2020-01-01T00:00:00Z",
        ]
        let stale = try XCTUnwrap(
            VoIPPushInvitation(payload: ["toj": common.merging(["v": 1]) { _, new in new }])
        )
        XCTAssertLessThan(try XCTUnwrap(stale.expiresAt), Date())
        XCTAssertNil(VoIPPushInvitation(payload: ["toj": common.merging(["v": 2]) { _, new in new }]))
    }

    func testInvalidVoIPPayloadRequiresFallbackCallKitReport() {
        let decision = VoIPPushRoutingDecision(payload: [
            "toj": [
                "v": 2,
                "type": "not_a_voice_call",
                "callId": "not-a-uuid",
            ],
        ])
        XCTAssertEqual(decision, .invalidPayloadRequiresFallbackReport)
    }

    func testCallHistoryServiceMessageIsHumanReadable() {
        let payload = #"{"v":1,"type":"voice_call","callId":"call","outcome":"completed","durationSeconds":65}"#
        let presentation = VoiceCallServicePresentation.parse(body: payload, callerIsCurrentAccount: true)
        XCTAssertEqual(presentation.title, "Outgoing voice call")
        XCTAssertEqual(presentation.duration, "01:05")
    }

    func testVideoCallHistoryUsesImmutableInitialKind() {
        let payload = #"{"v":1,"type":"video_call","callId":"call","callerAccountId":"alice","outcome":"completed","durationSeconds":65}"#
        let presentation = VoiceCallServicePresentation.parse(
            body: payload,
            callerIsCurrentAccount: false,
            currentAccountId: "alice"
        )
        XCTAssertEqual(presentation.title, "Outgoing video call")
        XCTAssertEqual(presentation.systemImage, "video.fill")
        XCTAssertEqual(presentation.duration, "01:05")
    }

    func testCallHistoryUsesAuthenticatedCallerAccountIdOverDirectionFallback() {
        let payload = #"{"v":1,"type":"voice_call","callId":"call","callerAccountId":"bob","outcome":"completed","durationSeconds":4}"#
        let presentation = VoiceCallServicePresentation.parse(
            body: payload,
            callerIsCurrentAccount: true,
            currentAccountId: "alice"
        )
        XCTAssertEqual(presentation.title, "Incoming voice call")
        XCTAssertEqual(presentation.systemImage, "phone.arrow.down.left.fill")
        XCTAssertEqual(
            VoiceCallServicePresentation.callerIsCurrentAccount(
                body: payload,
                currentAccountId: "alice"
            ),
            false
        )
    }

    func testCallHistoryFallsBackForLegacyPayloadWithoutCallerAccountId() {
        let payload = #"{"v":1,"type":"voice_call","callId":"call","outcome":"completed","durationSeconds":4}"#
        let presentation = VoiceCallServicePresentation.parse(
            body: payload,
            callerIsCurrentAccount: true,
            currentAccountId: "alice"
        )
        XCTAssertEqual(presentation.title, "Outgoing voice call")
        XCTAssertNil(
            VoiceCallServicePresentation.callerIsCurrentAccount(
                body: payload,
                currentAccountId: "alice"
            )
        )
    }

    func testEncryptedEventRequestCarriesEveryAADField() throws {
        let request = SendCloudCallEventRequest(
            version: 1,
            kind: "ice_candidate",
            senderSequence: 7,
            ciphertext: "AQID",
            expiresAtMilliseconds: 123_456
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
        )
        XCTAssertEqual(object["version"] as? Int, 1)
        XCTAssertEqual(object["kind"] as? String, "ice_candidate")
        XCTAssertEqual(object["senderSequence"] as? Int, 7)
        XCTAssertEqual(object["expiresAtMilliseconds"] as? Int, 123_456)
    }
}

final class CallTelemetryTests: XCTestCase {
    func testTimeBucketBoundaries() {
        XCTAssertEqual(CallTelemetry.timeBucket(nil), "none")
        XCTAssertEqual(CallTelemetry.timeBucket(-1), "none")
        XCTAssertEqual(CallTelemetry.timeBucket(0.5), "le_1s")
        XCTAssertEqual(CallTelemetry.timeBucket(1), "le_1s")
        XCTAssertEqual(CallTelemetry.timeBucket(1.001), "le_2s")
        XCTAssertEqual(CallTelemetry.timeBucket(3), "le_3s")
        XCTAssertEqual(CallTelemetry.timeBucket(5), "le_5s")
        XCTAssertEqual(CallTelemetry.timeBucket(5.1), "gt_5s")
    }

    func testNetworkBuckets() {
        XCTAssertEqual(CallTelemetry.rttBucket(nil), "none")
        XCTAssertEqual(CallTelemetry.rttBucket(100), "le_100")
        XCTAssertEqual(CallTelemetry.rttBucket(101), "le_200")
        XCTAssertEqual(CallTelemetry.rttBucket(801), "gt_800")
        XCTAssertEqual(CallTelemetry.jitterBucket(10), "le_10")
        XCTAssertEqual(CallTelemetry.jitterBucket(61), "gt_60")
        XCTAssertEqual(CallTelemetry.bitrateBucket(bitsPerSecond: 16_000), "le_16")
        XCTAssertEqual(CallTelemetry.bitrateBucket(bitsPerSecond: 33_000), "le_48")
        XCTAssertEqual(CallTelemetry.bitrateBucket(bitsPerSecond: 64_000), "gt_48")
        XCTAssertEqual(CallTelemetry.lossBucket(packetsLost: nil, packetsReceived: 100), "none")
        XCTAssertEqual(CallTelemetry.lossBucket(packetsLost: 0, packetsReceived: 0), "none")
        XCTAssertEqual(CallTelemetry.lossBucket(packetsLost: 1, packetsReceived: 99), "le_1")
        XCTAssertEqual(CallTelemetry.lossBucket(packetsLost: 30, packetsReceived: 70), "gt_20")
    }

    func testReportBucketsStatsAndMapsEnums() {
        let stats = CallNetworkStats(
            roundTripTimeMilliseconds: 180,
            jitterMilliseconds: 25,
            packetsLost: 4,
            packetsReceived: 96,
            availableOutgoingBitrate: 40_000,
            audioBitrate: 30_000
        )
        let report = CallTelemetry.report(
            outcome: "completed", role: .caller, privacyMode: .relayOnly, routeClass: "relay_tls",
            setupSeconds: 2.4, recoverySeconds: nil, recoveryCount: 1, stats: stats, appVersion: "0.1.0.0"
        )
        XCTAssertEqual(report.outcome, "completed")
        XCTAssertEqual(report.role, "caller")
        XCTAssertEqual(report.privacyMode, "relay_only")
        XCTAssertEqual(report.routeClass, "relay_tls")
        XCTAssertEqual(report.setupBucket, "le_3s")
        XCTAssertEqual(report.recoveryBucket, "none")
        XCTAssertEqual(report.rttBucket, "le_200")
        XCTAssertEqual(report.lossBucket, "le_5")
        XCTAssertEqual(report.jitterBucket, "le_30")
        XCTAssertEqual(report.bitrateBucket, "le_32")
        XCTAssertEqual(report.recoveryCount, 1)
        XCTAssertEqual(report.appVersion, "0.1.0.0")
        XCTAssertNil(report.region)
    }

    func testReportWithoutStatsUsesNoneBuckets() {
        let report = CallTelemetry.report(
            outcome: "unanswered", role: .callee, privacyMode: .fastestRoute, routeClass: nil,
            setupSeconds: nil, recoverySeconds: nil, recoveryCount: 0, stats: nil, appVersion: nil
        )
        XCTAssertEqual(report.outcome, "unanswered")
        XCTAssertEqual(report.role, "callee")
        XCTAssertEqual(report.privacyMode, "fastest_route")
        XCTAssertNil(report.routeClass)
        for bucket in [report.setupBucket, report.recoveryBucket, report.rttBucket,
                       report.lossBucket, report.jitterBucket, report.bitrateBucket] {
            XCTAssertEqual(bucket, "none")
        }
    }

    func testRequestEncodesCamelCaseKeysMatchingServer() throws {
        let report = CallTelemetry.report(
            outcome: "completed", role: .caller, privacyMode: .fastestRoute, routeClass: nil,
            setupSeconds: 1, recoverySeconds: nil, recoveryCount: 3, stats: nil, appVersion: "1.2.3"
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any]
        )
        XCTAssertEqual(object["outcome"] as? String, "completed")
        XCTAssertEqual(object["privacyMode"] as? String, "fastest_route")
        XCTAssertEqual(object["setupBucket"] as? String, "le_1s")
        XCTAssertEqual(object["rttBucket"] as? String, "none")
        XCTAssertEqual(object["recoveryCount"] as? Int, 3)
        XCTAssertEqual(object["appVersion"] as? String, "1.2.3")
    }
}

@MainActor
private final class CallTestGate {
    private var continuation: CheckedContinuation<Void, Never>?

    var isWaiting: Bool { continuation != nil }

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}

private func XCTAssertThrowsCancellation(
    _ task: Task<Void, Error>,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await task.value
        XCTFail("Expected cancellation", file: file, line: line)
    } catch is CancellationError {
        // Expected.
    } catch {
        XCTFail("Expected CancellationError, got \(error)", file: file, line: line)
    }
}
