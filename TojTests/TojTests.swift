import CryptoKit
import Foundation
import XCTest
@testable import Toj

final class SmokeTests: XCTestCase {
    func testHarnessRuns() {
        XCTAssertTrue(true)
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
