import Foundation
import XCTest
@testable import Toj

final class GroupCallCryptoTests: XCTestCase {
    func testEpochEnvelopeRoundTripsAndRejectsCiphertextTampering() throws {
        let fixture = try GroupCallCryptoFixture()

        let opened = try GroupCallCrypto.open(
            envelope: fixture.envelope,
            snapshot: fixture.snapshot,
            localIdentity: fixture.recipientIdentity
        )
        XCTAssertEqual(opened, fixture.material)

        var ciphertext = try XCTUnwrap(Data(base64Encoded: fixture.envelope.ciphertext))
        ciphertext[ciphertext.startIndex] ^= 0x01
        let tampered = CloudGroupCallEpochEnvelope(
            epoch: fixture.envelope.epoch,
            senderPublicKey: fixture.envelope.senderPublicKey,
            recipientPublicKey: fixture.envelope.recipientPublicKey,
            ciphertext: ciphertext.base64EncodedString()
        )
        XCTAssertThrowsError(try GroupCallCrypto.open(
            envelope: tampered,
            snapshot: fixture.snapshot,
            localIdentity: fixture.recipientIdentity
        )) { error in
            XCTAssertEqual(error as? GroupCallCryptoError, .authenticationFailed)
        }
    }

    func testTranscriptRejectsParticipantSetTampering() throws {
        let fixture = try GroupCallCryptoFixture()
        try GroupCallCrypto.verifySnapshotTranscript(fixture.snapshot)

        let tampered = fixture.snapshot(participantSetHash: Data(repeating: 0xA5, count: 32))
        XCTAssertThrowsError(try GroupCallCrypto.verifySnapshotTranscript(tampered)) { error in
            XCTAssertEqual(error as? GroupCallCryptoError, .invalidParticipantSet)
        }
    }
}

final class GroupCallMediaReducerTests: XCTestCase {
    func testStalePermissionCallbackCannotRestartCapture() {
        var reducer = GroupCallMediaReducer()
        let staleGeneration = reducer.generation
        let generation = reducer.beginRuntime()
        reducer.setCameraIntent(true)
        reducer.setSecureMediaReady(true, generation: generation)

        reducer.setPermissions(camera: .granted, generation: staleGeneration)
        XCTAssertFalse(reducer.decision(now: .init(timeIntervalSince1970: 0)).cameraActive)

        reducer.setPermissions(camera: .granted, generation: generation)
        XCTAssertTrue(reducer.decision(now: .init(timeIntervalSince1970: 0)).cameraActive)

        reducer.endRuntime()
        reducer.setPermissions(camera: .granted, generation: generation)
        XCTAssertFalse(reducer.decision(now: .init(timeIntervalSince1970: 0)).cameraActive)
    }

    func testQualityHysteresisUsesExactBadHealthyAndMissingSampleCounts() {
        var reducer = GroupCallMediaReducer()
        let bad = GroupCallSenderSample(
            packetLossPercent: 8.01,
            roundTripMilliseconds: 100,
            jitterMilliseconds: 10,
            availableOutgoingBitrate: 2_000_000
        )
        reducer.recordSenderSample(bad)
        reducer.recordSenderSample(bad)
        XCTAssertEqual(reducer.qualityTier, .high)
        reducer.recordSenderSample(bad)
        XCTAssertEqual(reducer.qualityTier, .medium)

        let healthyForHigh = GroupCallSenderSample(
            packetLossPercent: 1.99,
            roundTripMilliseconds: 249,
            jitterMilliseconds: 29,
            availableOutgoingBitrate: 1_875_000
        )
        for _ in 0..<9 { reducer.recordSenderSample(healthyForHigh) }
        XCTAssertEqual(reducer.qualityTier, .medium)
        reducer.recordSenderSample(healthyForHigh)
        XCTAssertEqual(reducer.qualityTier, .high)

        reducer.recordSenderSample(nil)
        reducer.recordSenderSample(nil)
        XCTAssertEqual(reducer.qualityTier, .high)
        reducer.recordSenderSample(nil)
        XCTAssertEqual(reducer.qualityTier, .low)
    }

    func testStarvationPauseAndRecoveryProtectCameraIntent() {
        var reducer = readyCameraReducer()
        let starved = GroupCallSenderSample(
            packetLossPercent: 0,
            roundTripMilliseconds: 50,
            jitterMilliseconds: 5,
            availableOutgoingBitrate: 79_999
        )
        for _ in 0..<4 { reducer.recordSenderSample(starved) }
        XCTAssertTrue(reducer.decision(now: .init(timeIntervalSince1970: 0)).cameraActive)
        reducer.recordSenderSample(starved)
        XCTAssertEqual(
            reducer.decision(now: .init(timeIntervalSince1970: 0)).cameraPauseReason,
            "network"
        )

        let recovered = GroupCallSenderSample(
            packetLossPercent: 1,
            roundTripMilliseconds: 100,
            jitterMilliseconds: 10,
            availableOutgoingBitrate: 800_000
        )
        for _ in 0..<9 { reducer.recordSenderSample(recovered) }
        XCTAssertFalse(reducer.decision(now: .init(timeIntervalSince1970: 0)).cameraActive)
        reducer.recordSenderSample(recovered)
        XCTAssertTrue(reducer.decision(now: .init(timeIntervalSince1970: 0)).cameraActive)
    }

    func testThermalRecoveryRequiresTwentySecondsAtFairOrNominal() {
        var reducer = readyCameraReducer()
        let start = Date(timeIntervalSince1970: 1_000)
        reducer.setThermalState(.critical, now: start)
        XCTAssertEqual(reducer.decision(now: start).cameraPauseReason, "thermal")

        reducer.setThermalState(.fair, now: start.addingTimeInterval(1))
        XCTAssertFalse(reducer.decision(now: start.addingTimeInterval(20)).cameraActive)
        XCTAssertTrue(reducer.decision(now: start.addingTimeInterval(21)).cameraActive)
    }

    func testDataPolicyAndConstrainedPathsCapVideoTier() {
        var reducer = readyCameraReducer()
        reducer.setDataUsagePolicy(.cellularOnly)
        reducer.setNetworkClass(.cellular)
        XCTAssertEqual(reducer.decision(now: .now).qualityTier, .medium)

        reducer.setNetworkClass(.wifi)
        XCTAssertEqual(reducer.decision(now: .now).qualityTier, .high)

        reducer.setDataUsagePolicy(.always)
        XCTAssertEqual(reducer.decision(now: .now).qualityTier, .medium)

        reducer.setNetworkClass(.constrained)
        XCTAssertEqual(reducer.decision(now: .now).qualityTier, .low)
    }

    func testRekeySecurityFencePausesAllPublicationWithoutLosingUserIntent() {
        var reducer = GroupCallMediaReducer()
        let generation = reducer.beginRuntime()
        reducer.setCameraIntent(true)
        reducer.setMicrophoneIntent(true)
        reducer.setPermissions(camera: .granted, microphone: .granted, generation: generation)
        reducer.setSecureMediaReady(true, generation: generation)

        let ready = reducer.decision(now: .init(timeIntervalSince1970: 0))
        XCTAssertTrue(ready.cameraActive)
        XCTAssertTrue(ready.microphoneActive)

        reducer.setSecureMediaReady(false, generation: generation)
        let rekeying = reducer.decision(now: .init(timeIntervalSince1970: 1))
        XCTAssertFalse(rekeying.cameraActive)
        XCTAssertFalse(rekeying.microphoneActive)
        XCTAssertEqual(rekeying.cameraPauseReason, "security")
        XCTAssertTrue(reducer.userWantsCamera)
        XCTAssertTrue(reducer.userWantsMicrophone)

        reducer.setSecureMediaReady(true, generation: generation)
        let restored = reducer.decision(now: .init(timeIntervalSince1970: 2))
        XCTAssertTrue(restored.cameraActive)
        XCTAssertTrue(restored.microphoneActive)
    }

    func testScreenSharePolicyFailsClosedForSecurityThermalAndOfflineState() {
        var reducer = GroupCallMediaReducer()
        let generation = reducer.beginRuntime()
        reducer.setSecureMediaReady(true, generation: generation)
        reducer.setScreenExtensionReady(true)
        reducer.setScreenLeaseHeld(true, generation: generation)
        reducer.setScreenShareIntent(true)
        XCTAssertTrue(reducer.decision(now: .now).screenShareAllowed)

        reducer.setThermalState(.critical, now: .now)
        XCTAssertFalse(reducer.decision(now: .now).screenShareAllowed)
        reducer.setThermalState(.nominal, now: .now.addingTimeInterval(21))
        reducer.setNetworkClass(.offline)
        XCTAssertFalse(reducer.decision(now: .now).screenShareAllowed)
        reducer.setNetworkClass(.wifi)
        reducer.setSecureMediaReady(false, generation: generation)
        XCTAssertFalse(reducer.decision(now: .now).screenShareAllowed)
    }

    private func readyCameraReducer() -> GroupCallMediaReducer {
        var reducer = GroupCallMediaReducer()
        let generation = reducer.beginRuntime()
        reducer.setCameraIntent(true)
        reducer.setPermissions(camera: .granted, generation: generation)
        reducer.setSecureMediaReady(true, generation: generation)
        return reducer
    }
}

final class GroupCallEpochKeySlotTests: XCTestCase {
    func testDelayedRetirementCannotEraseAReusedSlot() {
        var slots = GroupCallEpochKeySlots()
        for epoch in 1...18 { _ = slots.install(Int64(epoch)) }

        XCTAssertEqual(slots.occupants[1], 17)
        XCTAssertNil(slots.retire(1, currentEpoch: 18))
        XCTAssertEqual(slots.occupants[1], 17)

        XCTAssertEqual(slots.retire(17, currentEpoch: 18), 1)
        XCTAssertNil(slots.occupants[1])
        XCTAssertNil(slots.retire(18, currentEpoch: 18))
        XCTAssertEqual(slots.occupants[2], 18)
    }
}

@MainActor
final class GroupCallCoordinatorTests: XCTestCase {
    private let session = CloudSession(
        accountId: "3ff50c1f-06b3-46c0-9a20-a9c63f6f1b10",
        deviceId: "d7297d21-c1eb-436a-8f4e-202689ccba88",
        token: "coordinator-test-token"
    )

    func testSecondStartKeepsTheExistingRuntimeAndLeaveStopsMediaBeforeNetworkCleanup() async throws {
        let api = FakeGroupCallAPI(session: session)
        let engine = FakeGroupCallEngine()
        let coordinator = makeCoordinator(api: api, engine: engine)

        await coordinator.start(
            dialogId: "ba448af9-2c3a-4e17-ab3c-2ff865de27b9",
            title: "Primary call",
            initialKind: .video
        )
        XCTAssertTrue(coordinator.hasActiveCall)
        XCTAssertEqual(engine.connectCount, 1)
        let originalCallId = try XCTUnwrap(coordinator.activeCall?.id)

        await coordinator.start(
            dialogId: "fc891e21-9606-4b6d-9340-c7e19486a2c5",
            title: "Replacement attempt",
            initialKind: .voice
        )
        let startCount = await api.startCount
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(coordinator.activeCall?.id, originalCallId)
        XCTAssertEqual(engine.connectCount, 1)

        await api.setSuspendLeave(true)
        await coordinator.leave()
        XCTAssertEqual(coordinator.state, .ended)
        XCTAssertFalse(coordinator.hasActiveCall)
        XCTAssertEqual(engine.disconnectCount, 1)
        XCTAssertFalse(engine.isConnected)
        let leaveStarted = await eventually { await api.leaveStarted }
        XCTAssertTrue(leaveStarted)
        await api.resumeLeave()
    }

    func testStaleAcceptedStartIsCompensatedAfterUnbind() async throws {
        let api = FakeGroupCallAPI(session: session)
        await api.setSuspendStart(true)
        let engine = FakeGroupCallEngine()
        let coordinator = makeCoordinator(api: api, engine: engine)

        let startTask = Task { @MainActor in
            await coordinator.start(
                dialogId: "91d038e0-00eb-45c3-b54f-18e2566f9f9e",
                title: "Stale start",
                initialKind: .video
            )
        }
        let startSuspended = await eventually { await api.startSuspended }
        XCTAssertTrue(startSuspended)
        await coordinator.unbind()
        await api.resumeStart()
        await startTask.value

        let compensated = await eventually { await api.leaveCount == 1 }
        XCTAssertTrue(compensated)
        XCTAssertFalse(coordinator.hasActiveCall)
        XCTAssertEqual(engine.connectCount, 0)
    }

    func testEncryptionClaimRequiresAggregateProofForTheCurrentEpoch() async throws {
        let api = FakeGroupCallAPI(session: session)
        let engine = FakeGroupCallEngine()
        engine.automaticallyVerifyEncryption = false
        let coordinator = makeCoordinator(api: api, engine: engine)

        await coordinator.start(
            dialogId: "0aa7481d-75c6-4c43-9c24-2399936a0d75",
            title: "Proof test",
            initialKind: .voice
        )
        XCTAssertEqual(coordinator.state, .connected)
        XCTAssertEqual(coordinator.securityState, .keyReady)

        engine.emit(.encryptionState(
            epoch: 1,
            expectedTrackIds: ["audio", "camera"],
            verifiedTrackIds: ["audio"]
        ))
        XCTAssertEqual(coordinator.securityState, .keyReady)
        engine.emit(.encryptionState(
            epoch: 1,
            expectedTrackIds: ["audio", "camera"],
            verifiedTrackIds: ["audio", "camera"]
        ))
        XCTAssertEqual(coordinator.securityState, .verified)

        engine.emit(.encryptionFailure(epoch: 0, trackId: "stale", reason: "old epoch"))
        await Task.yield()
        XCTAssertTrue(coordinator.hasActiveCall)
        XCTAssertEqual(coordinator.securityState, .verified)

        engine.emit(.encryptionWarning(epoch: 1, trackId: "camera", reason: "attaching"))
        XCTAssertEqual(coordinator.securityState, .keyReady)
        engine.emit(.encryptionFailure(epoch: 1, trackId: "camera", reason: "failed"))
        let failed = await eventually { coordinator.state == .failed }
        XCTAssertTrue(failed)
    }

    func testStaleEngineCallbackCannotCloseAReplacementRuntime() async throws {
        let api = FakeGroupCallAPI(session: session)
        let engine = FakeGroupCallEngine()
        let coordinator = makeCoordinator(api: api, engine: engine)
        await coordinator.start(
            dialogId: "12933dc5-a0a7-41b3-a91e-34db722516de",
            title: "First call",
            initialKind: .voice
        )
        let staleHandler = try XCTUnwrap(engine.onEvent)
        await coordinator.leave()

        await coordinator.start(
            dialogId: "e913d182-bf78-47b6-a812-59888cc67613",
            title: "Replacement call",
            initialKind: .voice
        )
        XCTAssertTrue(coordinator.hasActiveCall)
        staleHandler(.encryptionFailure(epoch: 1, trackId: "old", reason: "stale callback"))
        await Task.yield()
        XCTAssertTrue(coordinator.hasActiveCall)
        XCTAssertEqual(coordinator.state, .connected)
        XCTAssertEqual(coordinator.securityState, .verified)
    }

    func testNegotiatedCapabilityCanDisableScreenSharingOnASupportedDevice() {
        let api = FakeGroupCallAPI(session: session)
        let engine = FakeGroupCallEngine()
        let coordinator = makeCoordinator(
            api: api,
            engine: engine,
            screenSharingNegotiated: false
        )
        XCTAssertFalse(coordinator.canShareScreen)
    }

    func testCameraLeaseCompletingAfterUnbindCannotRestartCapture() async throws {
        let api = FakeGroupCallAPI(session: session)
        let engine = FakeGroupCallEngine()
        let coordinator = makeCoordinator(api: api, engine: engine)
        await coordinator.start(
            dialogId: "41a14a9b-0c73-4bbd-b5ab-621b353b0b0e",
            title: "Camera fence",
            initialKind: .video
        )
        await api.setSuspendCameraAcquire(true)
        let cameraTask = Task { @MainActor in await coordinator.toggleCamera() }
        let cameraAcquireSuspended = await eventually { await api.cameraAcquireSuspended }
        XCTAssertTrue(cameraAcquireSuspended)

        await coordinator.unbind()
        await api.resumeCameraAcquire()
        await cameraTask.value

        XCTAssertFalse(coordinator.hasActiveCall)
        XCTAssertEqual(engine.cameraStates.last, false)
        let cameraReleased = await eventually { await api.cameraReleaseCount == 1 }
        XCTAssertTrue(cameraReleased)
    }

    func testScreenActivationCompletingAfterUnbindIsCompensated() async throws {
        let api = FakeGroupCallAPI(session: session)
        let engine = FakeGroupCallEngine()
        let coordinator = makeCoordinator(api: api, engine: engine)
        await coordinator.start(
            dialogId: "4d2eff8b-91ad-420f-9798-c28739b768b7",
            title: "Screen fence",
            initialKind: .video
        )
        engine.suspendNextScreenEnable()
        let screenTask = Task { @MainActor in await coordinator.toggleScreenShare() }
        let screenEnableSuspended = await eventually { engine.screenEnableSuspended }
        XCTAssertTrue(screenEnableSuspended)

        await coordinator.unbind()
        engine.resumeScreenEnable(active: true)
        await screenTask.value

        XCTAssertFalse(coordinator.hasActiveCall)
        XCTAssertEqual(engine.screenShareStates.last, false)
        let screenReleased = await eventually { await api.screenReleaseCount == 1 }
        XCTAssertTrue(screenReleased)
    }

    func testOutOfOrderSnapshotCannotRollBackAuthorizationState() async throws {
        let api = FakeGroupCallAPI(session: session)
        let engine = FakeGroupCallEngine()
        let coordinator = makeCoordinator(api: api, engine: engine)
        await coordinator.start(
            dialogId: "35982790-e385-4330-a7a9-8f452e43cf36",
            title: "Revision test",
            initialKind: .voice
        )
        let base = try XCTUnwrap(coordinator.activeCall)
        let older = copySnapshot(base, stateRevision: 2)
        let newer = copySnapshot(base, stateRevision: 3)
        await api.suspendNextGroupCall(returning: older)

        let olderTask = Task { @MainActor in
            await coordinator.handle(GroupCallSocketHint(
                type: "group_call",
                callId: base.id,
                stateRevision: 2
            ))
        }
        let groupCallSuspended = await eventually { await api.groupCallSuspended }
        XCTAssertTrue(groupCallSuspended)
        await api.setCurrentSnapshot(newer)
        await coordinator.handle(GroupCallSocketHint(
            type: "group_call",
            callId: base.id,
            stateRevision: 3
        ))
        XCTAssertEqual(coordinator.activeCall?.stateRevision, 3)

        await api.resumeGroupCall()
        await olderTask.value
        XCTAssertEqual(coordinator.activeCall?.stateRevision, 3)
        XCTAssertEqual(engine.authorizedParticipantSets.last, Set([base.participants[0].participantId]))
    }

    func testNonLeaderRekeyImmediatelyFailsClosedForAllPublication() async throws {
        let api = FakeGroupCallAPI(session: session)
        let engine = FakeGroupCallEngine()
        let coordinator = makeCoordinator(api: api, engine: engine)
        await coordinator.start(
            dialogId: "f6ada0aa-4a11-4bb8-88f6-6cc451628e78",
            title: "Rekey test",
            initialKind: .video
        )
        await coordinator.toggleCamera()
        await coordinator.toggleScreenShare()
        XCTAssertEqual(engine.cameraStates.last, true)
        XCTAssertEqual(engine.screenShareStates.last, true)
        let base = try XCTUnwrap(coordinator.activeCall)
        let remoteIdentity = GroupCallJoinIdentity()
        let selfParticipant = copyParticipant(
            base.participants[0],
            isKeyLeader: false
        )
        let remoteDeviceId = "8efdb983-20bb-469d-955f-c579db30ace8"
        let remote = CloudGroupCallParticipant(
            accountId: "07280888-7e40-45c6-bb86-c9be81cc9cbd",
            deviceId: remoteDeviceId,
            participantId: "remote-key-leader",
            status: .pendingKey,
            joinPublicKey: remoteIdentity.publicKey.base64EncodedString(),
            joinNonce: remoteIdentity.nonce.base64EncodedString(),
            joinedMembershipRevision: 2,
            readyMediaEpoch: nil,
            joinedAt: "2026-08-02T00:00:01.000Z",
            isSelf: false,
            isKeyLeader: true
        )
        let rekeying = copySnapshot(
            base,
            stateRevision: 2,
            membershipRevision: 2,
            keyLeaderDeviceId: remoteDeviceId,
            rekeyRequired: true,
            participants: [selfParticipant, remote]
        )
        await api.setCurrentSnapshot(rekeying)
        await api.setSuspendCameraRelease(true)
        let hintTask = Task { @MainActor in
            await coordinator.handle(GroupCallSocketHint(
                type: "group_call",
                callId: base.id,
                stateRevision: 2
            ))
        }
        let cameraReleaseSuspended = await eventually { await api.cameraReleaseSuspended }
        XCTAssertTrue(cameraReleaseSuspended)

        XCTAssertEqual(coordinator.state, .waitingForKey)
        XCTAssertEqual(coordinator.securityState, .rekeying)
        XCTAssertEqual(engine.microphoneStates.last, false)
        XCTAssertEqual(engine.cameraStates.last, false)
        XCTAssertEqual(engine.screenShareStates.last, false)
        XCTAssertFalse(coordinator.isScreenSharing)
        XCTAssertTrue(engine.isConnected)
        await api.resumeCameraRelease()
        await hintTask.value
        await coordinator.leave()
    }

    func testEpochActivationReconnectsWithCredentialsForTheNewMediaEpoch() async throws {
        let api = FakeGroupCallAPI(session: session)
        let engine = FakeGroupCallEngine()
        let coordinator = makeCoordinator(api: api, engine: engine)
        await coordinator.start(
            dialogId: "1ccb7448-6bbf-4bbc-bbaf-82af09817416",
            title: "Credential fence",
            initialKind: .voice
        )

        let base = try XCTUnwrap(coordinator.activeCall)
        let remoteIdentity = GroupCallJoinIdentity()
        let remote = CloudGroupCallParticipant(
            accountId: "4a77c741-70bf-47f4-b76c-b6cb121d5184",
            deviceId: "01992718-7053-42e5-8f6e-e80ad7bb95c4",
            participantId: "new-epoch-participant",
            status: .pendingKey,
            joinPublicKey: remoteIdentity.publicKey.base64EncodedString(),
            joinNonce: remoteIdentity.nonce.base64EncodedString(),
            joinedMembershipRevision: 2,
            readyMediaEpoch: nil,
            joinedAt: "2026-08-02T00:00:01.000Z",
            isSelf: false,
            isKeyLeader: false
        )
        let rekeying = copySnapshot(
            base,
            stateRevision: 2,
            membershipRevision: 2,
            keyLeaderDeviceId: session.deviceId,
            rekeyRequired: true,
            participants: [base.participants[0], remote]
        )
        await api.setCurrentSnapshot(rekeying)

        await coordinator.handle(GroupCallSocketHint(
            type: "group_call",
            callId: base.id,
            stateRevision: rekeying.stateRevision
        ))

        let reconnected = await eventually {
            engine.connectCount == 2 && coordinator.activeCall?.mediaEpoch == 2
        }
        XCTAssertTrue(reconnected)
        XCTAssertEqual(engine.installedEpochs, [1, 2])
        XCTAssertEqual(engine.connectedCredentialEpochs, [1, 2])
        let credentialEpochs = await api.credentialEpochs
        XCTAssertEqual(credentialEpochs, [2])
        XCTAssertEqual(coordinator.state, .connected)
        await coordinator.leave()
    }

    func testStaleReconnectFailureCannotTearDownANewerConnection() async throws {
        let api = FakeGroupCallAPI(session: session)
        let engine = FakeGroupCallEngine()
        let coordinator = makeCoordinator(api: api, engine: engine)
        await coordinator.start(
            dialogId: "6829427d-4be8-4f37-86d2-2f71bfda52e8",
            title: "Reconnect race",
            initialKind: .voice
        )

        let base = try XCTUnwrap(coordinator.activeCall)
        let remoteIdentity = GroupCallJoinIdentity()
        let remote = CloudGroupCallParticipant(
            accountId: "3ca11c15-750c-4ef4-ae26-03f6323b75e6",
            deviceId: "15645402-5e5c-4f56-b943-b83972d9605f",
            participantId: "reconnect-race-participant",
            status: .pendingKey,
            joinPublicKey: remoteIdentity.publicKey.base64EncodedString(),
            joinNonce: remoteIdentity.nonce.base64EncodedString(),
            joinedMembershipRevision: 2,
            readyMediaEpoch: nil,
            joinedAt: "2026-08-02T00:00:01.000Z",
            isSelf: false,
            isKeyLeader: false
        )
        let rekeying = copySnapshot(
            base,
            stateRevision: 2,
            membershipRevision: 2,
            keyLeaderDeviceId: session.deviceId,
            rekeyRequired: true,
            participants: [base.participants[0], remote]
        )
        await api.setCurrentSnapshot(rekeying)
        engine.suspendNextConnect()

        let staleReconnect = Task { @MainActor in
            await coordinator.handle(GroupCallSocketHint(
                type: "group_call",
                callId: base.id,
                stateRevision: rekeying.stateRevision
            ))
        }
        let connectSuspended = await eventually { engine.connectSuspended }
        XCTAssertTrue(connectSuspended)

        await coordinator.reconcileAfterSocketReconnect()
        XCTAssertEqual(engine.connectCount, 3)
        XCTAssertEqual(coordinator.state, .connected)
        XCTAssertEqual(coordinator.activeCall?.mediaEpoch, 2)

        engine.resumeConnect(throwing: GroupCallEngineError.notConnected)
        await staleReconnect.value
        await Task.yield()

        XCTAssertTrue(coordinator.hasActiveCall)
        XCTAssertTrue(engine.isConnected)
        XCTAssertEqual(coordinator.state, .connected)
        XCTAssertEqual(coordinator.activeCall?.mediaEpoch, 2)
        await coordinator.leave()
    }

    private func makeCoordinator(
        api: FakeGroupCallAPI,
        engine: FakeGroupCallEngine,
        screenSharingNegotiated: Bool = true
    ) -> GroupCallCoordinator {
        let coordinator = GroupCallCoordinator(
            permissions: AllowingCallPermissions(),
            clock: SystemCallClock(),
            installSystemObservers: false,
            engineAvailable: { true },
            screenShareAvailable: { true },
            engineFactory: { engine }
        )
        coordinator.configure(
            api: api,
            session: session,
            screenSharingNegotiated: { screenSharingNegotiated }
        ) { accountId, _ in accountId }
        return coordinator
    }

    private func eventually(
        _ predicate: @escaping () async -> Bool
    ) async -> Bool {
        for _ in 0..<1_000 {
            if await predicate() { return true }
            await Task.yield()
        }
        return false
    }
}

@MainActor
private final class AllowingCallPermissions: CallPermissionProviding {
    var microphonePermissionDenied: Bool { false }
    func microphoneAllowed() async -> Bool { true }
    var cameraPermission: CallCameraPermissionState { .authorized }
    func requestCameraAccess() async -> Bool { true }
}

@MainActor
private final class FakeGroupCallEngine: GroupCallMediaEngine {
    var onEvent: ((GroupCallEngineEvent) -> Void)?
    var automaticallyVerifyEncryption = true
    private(set) var isConnected = false
    private(set) var connectCount = 0
    private(set) var connectedCredentialEpochs: [Int64] = []
    private(set) var disconnectCount = 0
    private(set) var installedEpochs: [Int64] = []
    private(set) var authorizedParticipantSets: [Set<String>] = []
    private(set) var microphoneStates: [Bool] = []
    private(set) var cameraStates: [Bool] = []
    private(set) var screenShareStates: [Bool] = []
    private var currentEpoch: Int64?
    private var shouldSuspendNextConnect = false
    private var pendingConnect: CheckedContinuation<Void, Error>?
    private var shouldSuspendNextScreenEnable = false
    private var pendingScreenEnable: CheckedContinuation<Bool, Never>?
    var connectSuspended: Bool { pendingConnect != nil }
    var screenEnableSuspended: Bool { pendingScreenEnable != nil }

    func installEpoch(_ material: GroupCallEpochMaterial) throws {
        installedEpochs.append(material.epoch)
        currentEpoch = material.epoch
    }

    func retireEpoch(_ epoch: Int64) { _ = epoch }

    func setAuthorizedParticipants(
        _ participantIds: Set<String>,
        cameraPublishers: Set<String>,
        screenPublisher: String?
    ) async throws {
        _ = (cameraPublishers, screenPublisher)
        authorizedParticipantSets.append(participantIds)
    }

    func connect(credentials: CloudGroupCallCredentials) async throws {
        connectCount += 1
        connectedCredentialEpochs.append(credentials.mediaEpoch)
        if shouldSuspendNextConnect {
            shouldSuspendNextConnect = false
            try await withCheckedThrowingContinuation {
                pendingConnect = $0
            }
        }
        isConnected = true
        onEvent?(.connection(.connected))
        if automaticallyVerifyEncryption, let currentEpoch {
            onEvent?(.encryptionState(
                epoch: currentEpoch,
                expectedTrackIds: ["local-audio"],
                verifiedTrackIds: ["local-audio"]
            ))
        }
    }

    func suspendNextConnect() {
        shouldSuspendNextConnect = true
    }

    func resumeConnect(throwing error: Error? = nil) {
        guard let pendingConnect else { return }
        self.pendingConnect = nil
        if let error {
            pendingConnect.resume(throwing: error)
        } else {
            pendingConnect.resume(returning: ())
        }
    }

    func setMicrophone(enabled: Bool) async throws {
        microphoneStates.append(enabled)
    }

    func setCamera(
        enabled: Bool,
        position: GroupCallCameraPosition,
        tier: GroupCallQualityTier
    ) async throws {
        _ = (position, tier)
        cameraStates.append(enabled)
    }

    func switchCamera(to position: GroupCallCameraPosition) async throws { _ = position }
    func senderSample() async -> GroupCallSenderSample? { nil }
    func setScreenShare(enabled: Bool) async throws -> Bool {
        screenShareStates.append(enabled)
        if enabled, shouldSuspendNextScreenEnable {
            shouldSuspendNextScreenEnable = false
            return await withCheckedContinuation { pendingScreenEnable = $0 }
        }
        return enabled
    }

    func suspendNextScreenEnable() {
        shouldSuspendNextScreenEnable = true
    }

    func resumeScreenEnable(active: Bool) {
        guard let pendingScreenEnable else { return }
        self.pendingScreenEnable = nil
        pendingScreenEnable.resume(returning: active)
    }

    func disconnect() async {
        disconnectCount += 1
        isConnected = false
        onEvent?(.connection(.disconnected))
    }

    func emit(_ event: GroupCallEngineEvent) {
        onEvent?(event)
    }
}

private actor FakeGroupCallAPI: GroupCallAPITransport {
    private let session: CloudSession
    private var currentSnapshot: CloudGroupCallSnapshot?
    private var latestStartResponse: CloudGroupCallStartResponse?
    private var shouldSuspendStart = false
    private var shouldSuspendLeave = false
    private var shouldSuspendCameraRelease = false
    private var shouldSuspendCameraAcquire = false
    private var pendingStart: CheckedContinuation<CloudGroupCallStartResponse, Error>?
    private var pendingLeave: CheckedContinuation<CloudGroupCallJoinResponse, Error>?
    private var pendingGroupCall: CheckedContinuation<CloudGroupCallResponse, Error>?
    private var pendingCameraRelease: CheckedContinuation<Void, Never>?
    private var pendingCameraAcquire: CheckedContinuation<CloudGroupCallCameraLeaseResponse, Error>?
    private var pendingCameraAcquireResponse: CloudGroupCallCameraLeaseResponse?
    private var suspendedGroupCallResponse: CloudGroupCallResponse?
    private(set) var startCount = 0
    private(set) var leaveCount = 0
    private(set) var leaveStarted = false
    private(set) var cameraReleaseCount = 0
    private(set) var screenReleaseCount = 0
    private(set) var credentialEpochs: [Int64] = []

    var startSuspended: Bool { pendingStart != nil }
    var groupCallSuspended: Bool { pendingGroupCall != nil }
    var cameraReleaseSuspended: Bool { pendingCameraRelease != nil }
    var cameraAcquireSuspended: Bool { pendingCameraAcquire != nil }

    init(session: CloudSession) {
        self.session = session
    }

    func setSuspendStart(_ value: Bool) { shouldSuspendStart = value }
    func setSuspendLeave(_ value: Bool) { shouldSuspendLeave = value }
    func setSuspendCameraRelease(_ value: Bool) { shouldSuspendCameraRelease = value }
    func setSuspendCameraAcquire(_ value: Bool) { shouldSuspendCameraAcquire = value }
    func setCurrentSnapshot(_ snapshot: CloudGroupCallSnapshot) { currentSnapshot = snapshot }

    func suspendNextGroupCall(returning snapshot: CloudGroupCallSnapshot) {
        suspendedGroupCallResponse = CloudGroupCallResponse(call: snapshot)
    }

    func resumeStart() {
        guard let pendingStart, let latestStartResponse else { return }
        self.pendingStart = nil
        pendingStart.resume(returning: latestStartResponse)
    }

    func resumeLeave() {
        guard let pendingLeave, let snapshot = currentSnapshot else { return }
        self.pendingLeave = nil
        pendingLeave.resume(returning: CloudGroupCallJoinResponse(call: snapshot, duplicate: false))
    }

    func resumeGroupCall() {
        guard let pendingGroupCall, let response = suspendedGroupCallResponse else { return }
        self.pendingGroupCall = nil
        suspendedGroupCallResponse = nil
        pendingGroupCall.resume(returning: response)
    }

    func resumeCameraRelease() {
        guard let pendingCameraRelease else { return }
        self.pendingCameraRelease = nil
        pendingCameraRelease.resume()
    }

    func resumeCameraAcquire() {
        guard let pendingCameraAcquire, let pendingCameraAcquireResponse else { return }
        self.pendingCameraAcquire = nil
        self.pendingCameraAcquireResponse = nil
        pendingCameraAcquire.resume(returning: pendingCameraAcquireResponse)
    }

    func startGroupCall(
        _ body: StartCloudGroupCallRequest,
        token: String
    ) async throws -> CloudGroupCallStartResponse {
        _ = token
        startCount += 1
        let response = try Self.makeStartResponse(body: body, session: session)
        latestStartResponse = response
        currentSnapshot = response.call
        guard shouldSuspendStart else { return response }
        shouldSuspendStart = false
        return try await withCheckedThrowingContinuation { pendingStart = $0 }
    }

    func activeGroupCall(dialogId: String, token: String) async throws -> CloudActiveGroupCallResponse {
        _ = (dialogId, token)
        return CloudActiveGroupCallResponse(call: currentSnapshot)
    }

    func groupCall(id: String, token: String) async throws -> CloudGroupCallResponse {
        _ = (id, token)
        if suspendedGroupCallResponse != nil, pendingGroupCall == nil {
            return try await withCheckedThrowingContinuation { pendingGroupCall = $0 }
        }
        return CloudGroupCallResponse(call: try requiredSnapshot())
    }

    func joinGroupCall(
        id: String,
        body: JoinCloudGroupCallRequest,
        token: String
    ) async throws -> CloudGroupCallJoinResponse {
        _ = (id, body, token)
        return CloudGroupCallJoinResponse(call: try requiredSnapshot(), duplicate: false)
    }

    func activateGroupCallEpoch(
        id: String,
        body: ActivateCloudGroupCallEpochRequest,
        token: String
    ) async throws -> CloudGroupCallJoinResponse {
        _ = (id, token)
        let snapshot = try requiredSnapshot()
        let participants = snapshot.participants.map { participant in
            CloudGroupCallParticipant(
                accountId: participant.accountId,
                deviceId: participant.deviceId,
                participantId: participant.participantId,
                status: .active,
                joinPublicKey: participant.joinPublicKey,
                joinNonce: participant.joinNonce,
                joinedMembershipRevision: participant.joinedMembershipRevision,
                readyMediaEpoch: body.epoch,
                joinedAt: participant.joinedAt,
                isSelf: participant.isSelf,
                isKeyLeader: participant.deviceId == snapshot.keyLeaderDeviceId
            )
        }
        let activated = CloudGroupCallSnapshot(
            id: snapshot.id,
            dialogId: snapshot.dialogId,
            initialKind: snapshot.initialKind,
            state: snapshot.state,
            participantLimit: snapshot.participantLimit,
            publisherLimit: snapshot.publisherLimit,
            membershipRevision: snapshot.membershipRevision,
            stateRevision: snapshot.stateRevision + 1,
            selfRole: snapshot.selfRole,
            mediaEpoch: body.epoch,
            keyLeaderDeviceId: snapshot.keyLeaderDeviceId,
            rekeyRequired: false,
            epoch: CloudGroupCallEpoch(
                epoch: body.epoch,
                membershipRevision: body.expectedMembershipRevision,
                keyCommitment: body.keyCommitment,
                participantSetHash: body.participantSetHash,
                activatedAt: "2026-08-02T00:00:02.000Z",
                previousEpochGraceExpiresAt: "2026-08-02T00:00:12.000Z"
            ),
            participants: participants,
            selfEnvelope: nil,
            cameraPublishers: [],
            screenShare: nil,
            createdAt: snapshot.createdAt,
            endedAt: snapshot.endedAt,
            endReason: snapshot.endReason
        )
        currentSnapshot = activated
        return CloudGroupCallJoinResponse(call: activated, duplicate: false)
    }

    func groupCallCredentials(
        id: String,
        token: String
    ) async throws -> CloudGroupCallCredentialsResponse {
        _ = (id, token)
        let snapshot = try requiredSnapshot()
        credentialEpochs.append(snapshot.mediaEpoch)
        return CloudGroupCallCredentialsResponse(credentials: try credentials())
    }

    func heartbeatGroupCall(
        id: String,
        token: String
    ) async throws -> CloudGroupCallHeartbeatResponse {
        _ = (id, token)
        let snapshot = try requiredSnapshot()
        return CloudGroupCallHeartbeatResponse(state: snapshot.state, stateRevision: snapshot.stateRevision)
    }

    func leaveGroupCall(id: String, token: String) async throws -> CloudGroupCallJoinResponse {
        _ = (id, token)
        leaveCount += 1
        leaveStarted = true
        let response = CloudGroupCallJoinResponse(call: try requiredSnapshot(), duplicate: false)
        guard shouldSuspendLeave else { return response }
        shouldSuspendLeave = false
        return try await withCheckedThrowingContinuation { pendingLeave = $0 }
    }

    func endGroupCall(
        id: String,
        reason: String,
        token: String
    ) async throws -> CloudGroupCallJoinResponse {
        _ = (id, reason, token)
        return CloudGroupCallJoinResponse(call: try requiredSnapshot(), duplicate: false)
    }

    func removeGroupCallParticipant(
        callId: String,
        deviceId: String,
        token: String
    ) async throws -> CloudGroupCallResponse {
        _ = (callId, deviceId, token)
        return CloudGroupCallResponse(call: try requiredSnapshot())
    }

    func acquireGroupCamera(
        callId: String,
        generation: String,
        token: String
    ) async throws -> CloudGroupCallCameraLeaseResponse {
        _ = (callId, token)
        let response = CloudGroupCallCameraLeaseResponse(
            generation: generation,
            expiresAt: "2026-08-02T00:01:00.000Z",
            call: currentSnapshot
        )
        guard shouldSuspendCameraAcquire else { return response }
        shouldSuspendCameraAcquire = false
        pendingCameraAcquireResponse = response
        return try await withCheckedThrowingContinuation { pendingCameraAcquire = $0 }
    }

    func heartbeatGroupCamera(
        callId: String,
        generation: String,
        token: String
    ) async throws -> CloudGroupCallCameraLeaseResponse {
        try await acquireGroupCamera(callId: callId, generation: generation, token: token)
    }

    func releaseGroupCamera(
        callId: String,
        generation: String,
        token: String
    ) async throws -> CloudGroupCallScreenReleaseResponse {
        _ = (callId, generation, token)
        cameraReleaseCount += 1
        if shouldSuspendCameraRelease {
            shouldSuspendCameraRelease = false
            await withCheckedContinuation { pendingCameraRelease = $0 }
        }
        return CloudGroupCallScreenReleaseResponse(released: true)
    }

    func acquireGroupScreenShare(
        callId: String,
        generation: String,
        token: String
    ) async throws -> CloudGroupCallScreenLeaseResponse {
        _ = (callId, token)
        return CloudGroupCallScreenLeaseResponse(
            generation: generation,
            expiresAt: "2026-08-02T00:01:00.000Z",
            call: currentSnapshot
        )
    }

    func heartbeatGroupScreenShare(
        callId: String,
        generation: String,
        token: String
    ) async throws -> CloudGroupCallScreenLeaseResponse {
        try await acquireGroupScreenShare(callId: callId, generation: generation, token: token)
    }

    func releaseGroupScreenShare(
        callId: String,
        generation: String,
        token: String
    ) async throws -> CloudGroupCallScreenReleaseResponse {
        _ = (callId, generation, token)
        screenReleaseCount += 1
        return CloudGroupCallScreenReleaseResponse(released: true)
    }

    private func requiredSnapshot() throws -> CloudGroupCallSnapshot {
        guard let currentSnapshot else { throw GroupCallEngineError.notConnected }
        return currentSnapshot
    }

    private func credentials() throws -> CloudGroupCallCredentials {
        let snapshot = try requiredSnapshot()
        return CloudGroupCallCredentials(
            url: "wss://group-media.test.toj.example",
            token: "room-scoped-test-token",
            participantId: try XCTUnwrap(snapshot.selfParticipant?.participantId),
            expiresAt: "2026-08-02T00:05:00.000Z",
            mediaEpoch: snapshot.mediaEpoch
        )
    }

    private static func makeStartResponse(
        body: StartCloudGroupCallRequest,
        session: CloudSession
    ) throws -> CloudGroupCallStartResponse {
        let participantId = UUID().uuidString.lowercased()
        let participant = CloudGroupCallParticipant(
            accountId: session.accountId,
            deviceId: session.deviceId,
            participantId: participantId,
            status: .active,
            joinPublicKey: body.joinPublicKey,
            joinNonce: body.joinNonce,
            joinedMembershipRevision: 1,
            readyMediaEpoch: 1,
            joinedAt: "2026-08-02T00:00:00.000Z",
            isSelf: true,
            isKeyLeader: true
        )
        let participantHash = try GroupCallCrypto.participantSetHash([participant])
        let snapshot = CloudGroupCallSnapshot(
            id: body.callId,
            dialogId: body.dialogId,
            initialKind: body.initialKind,
            state: "active",
            participantLimit: 32,
            publisherLimit: 16,
            membershipRevision: 1,
            stateRevision: 1,
            selfRole: "owner",
            mediaEpoch: 1,
            keyLeaderDeviceId: session.deviceId,
            rekeyRequired: false,
            epoch: CloudGroupCallEpoch(
                epoch: 1,
                membershipRevision: 1,
                keyCommitment: body.epochKeyCommitment,
                participantSetHash: participantHash.base64EncodedString(),
                activatedAt: "2026-08-02T00:00:00.000Z",
                previousEpochGraceExpiresAt: nil
            ),
            participants: [participant],
            selfEnvelope: nil,
            cameraPublishers: [],
            screenShare: nil,
            createdAt: "2026-08-02T00:00:00.000Z",
            endedAt: nil,
            endReason: nil
        )
        return CloudGroupCallStartResponse(
            call: snapshot,
            credentials: CloudGroupCallCredentials(
                url: "wss://group-media.test.toj.example",
                token: "room-scoped-test-token",
                participantId: participantId,
                expiresAt: "2026-08-02T00:05:00.000Z",
                mediaEpoch: 1
            ),
            duplicate: false
        )
    }
}

private func copyParticipant(
    _ participant: CloudGroupCallParticipant,
    isKeyLeader: Bool
) -> CloudGroupCallParticipant {
    CloudGroupCallParticipant(
        accountId: participant.accountId,
        deviceId: participant.deviceId,
        participantId: participant.participantId,
        status: participant.status,
        joinPublicKey: participant.joinPublicKey,
        joinNonce: participant.joinNonce,
        joinedMembershipRevision: participant.joinedMembershipRevision,
        readyMediaEpoch: participant.readyMediaEpoch,
        joinedAt: participant.joinedAt,
        isSelf: participant.isSelf,
        isKeyLeader: isKeyLeader
    )
}

private func copySnapshot(
    _ snapshot: CloudGroupCallSnapshot,
    stateRevision: Int64,
    membershipRevision: Int64? = nil,
    keyLeaderDeviceId: String? = nil,
    rekeyRequired: Bool? = nil,
    participants: [CloudGroupCallParticipant]? = nil
) -> CloudGroupCallSnapshot {
    CloudGroupCallSnapshot(
        id: snapshot.id,
        dialogId: snapshot.dialogId,
        initialKind: snapshot.initialKind,
        state: snapshot.state,
        participantLimit: snapshot.participantLimit,
        publisherLimit: snapshot.publisherLimit,
        membershipRevision: membershipRevision ?? snapshot.membershipRevision,
        stateRevision: stateRevision,
        selfRole: snapshot.selfRole,
        mediaEpoch: snapshot.mediaEpoch,
        keyLeaderDeviceId: keyLeaderDeviceId ?? snapshot.keyLeaderDeviceId,
        rekeyRequired: rekeyRequired ?? snapshot.rekeyRequired,
        epoch: snapshot.epoch,
        participants: participants ?? snapshot.participants,
        selfEnvelope: snapshot.selfEnvelope,
        cameraPublishers: snapshot.cameraPublishers,
        screenShare: snapshot.screenShare,
        createdAt: snapshot.createdAt,
        endedAt: snapshot.endedAt,
        endReason: snapshot.endReason
    )
}

private struct GroupCallCryptoFixture {
    let callId = "6b83f95a-62c6-4f20-8adf-0902b65fd72a"
    let dialogId = "8df58f51-6662-43c0-bca5-23a4ae34e59c"
    let leaderDeviceId = "1160d93b-36d3-47fc-813f-036b48bb653a"
    let recipientDeviceId = "b79f6f5b-48c3-4383-b0af-8e5bb9422be2"
    let leaderIdentity: GroupCallJoinIdentity
    let recipientIdentity: GroupCallJoinIdentity
    let participants: [CloudGroupCallParticipant]
    let material: GroupCallEpochMaterial
    let envelope: CloudGroupCallEpochEnvelope
    let snapshot: CloudGroupCallSnapshot

    init() throws {
        leaderIdentity = GroupCallJoinIdentity()
        recipientIdentity = GroupCallJoinIdentity()
        participants = [
            Self.participant(
                accountId: "leader-account",
                deviceId: leaderDeviceId,
                participantId: "gc_leader",
                identity: leaderIdentity,
                isSelf: false,
                isKeyLeader: true
            ),
            Self.participant(
                accountId: "recipient-account",
                deviceId: recipientDeviceId,
                participantId: "gc_recipient",
                identity: recipientIdentity,
                isSelf: true,
                isKeyLeader: false
            ),
        ]
        let participantHash = try GroupCallCrypto.participantSetHash(participants)
        material = try GroupCallCrypto.makeEpoch(
            callId: callId,
            dialogId: dialogId,
            epoch: 1,
            membershipRevision: 2,
            participantSetHash: participantHash,
            mediaKey: Data((0..<32).map(UInt8.init))
        )
        let sealed = try GroupCallCrypto.seal(
            epoch: material,
            callId: callId,
            dialogId: dialogId,
            senderDeviceId: leaderDeviceId,
            senderIdentity: leaderIdentity,
            recipient: participants[1]
        )
        envelope = CloudGroupCallEpochEnvelope(
            epoch: material.epoch,
            senderPublicKey: leaderIdentity.publicKey.base64EncodedString(),
            recipientPublicKey: recipientIdentity.publicKey.base64EncodedString(),
            ciphertext: sealed.ciphertext.base64EncodedString()
        )
        snapshot = Self.makeSnapshot(
            callId: callId,
            dialogId: dialogId,
            leaderDeviceId: leaderDeviceId,
            participants: participants,
            material: material,
            envelope: envelope,
            participantSetHash: participantHash
        )
    }

    func snapshot(participantSetHash: Data) -> CloudGroupCallSnapshot {
        Self.makeSnapshot(
            callId: callId,
            dialogId: dialogId,
            leaderDeviceId: leaderDeviceId,
            participants: participants,
            material: material,
            envelope: envelope,
            participantSetHash: participantSetHash
        )
    }

    private static func participant(
        accountId: String,
        deviceId: String,
        participantId: String,
        identity: GroupCallJoinIdentity,
        isSelf: Bool,
        isKeyLeader: Bool
    ) -> CloudGroupCallParticipant {
        CloudGroupCallParticipant(
            accountId: accountId,
            deviceId: deviceId,
            participantId: participantId,
            status: .active,
            joinPublicKey: identity.publicKey.base64EncodedString(),
            joinNonce: identity.nonce.base64EncodedString(),
            joinedMembershipRevision: 1,
            readyMediaEpoch: 1,
            joinedAt: "2026-08-02T00:00:00.000Z",
            isSelf: isSelf,
            isKeyLeader: isKeyLeader
        )
    }

    private static func makeSnapshot(
        callId: String,
        dialogId: String,
        leaderDeviceId: String,
        participants: [CloudGroupCallParticipant],
        material: GroupCallEpochMaterial,
        envelope: CloudGroupCallEpochEnvelope,
        participantSetHash: Data
    ) -> CloudGroupCallSnapshot {
        CloudGroupCallSnapshot(
            id: callId,
            dialogId: dialogId,
            initialKind: .video,
            state: "active",
            participantLimit: 32,
            publisherLimit: 16,
            membershipRevision: 2,
            stateRevision: 2,
            selfRole: "member",
            mediaEpoch: 1,
            keyLeaderDeviceId: leaderDeviceId,
            rekeyRequired: false,
            epoch: CloudGroupCallEpoch(
                epoch: 1,
                membershipRevision: 2,
                keyCommitment: material.keyCommitment.base64EncodedString(),
                participantSetHash: participantSetHash.base64EncodedString(),
                activatedAt: "2026-08-02T00:00:00.000Z",
                previousEpochGraceExpiresAt: nil
            ),
            participants: participants,
            selfEnvelope: envelope,
            cameraPublishers: [],
            screenShare: nil,
            createdAt: "2026-08-02T00:00:00.000Z",
            endedAt: nil,
            endReason: nil
        )
    }
}
