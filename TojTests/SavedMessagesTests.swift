import XCTest
@testable import Toj

final class SavedMessagesTests: XCTestCase {
    func testEnsureEndpointUsesAuthenticatedEmptyPostAndDecodesResponse() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SavedMessagesMockURLProtocol.self]
        let api = CloudAPI(
            config: CloudConfig(baseURL: try XCTUnwrap(URL(string: "https://cloud.example.test/cloud"))),
            session: URLSession(configuration: configuration)
        )
        SavedMessagesMockURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/cloud/v1/dialogs/saved")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            return (
                try XCTUnwrap(HTTPURLResponse(
                    url: request.url!,
                    statusCode: 201,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["content-type": "application/json"]
                )),
                Data("""
                {"dialogId":"saved-1","type":"saved","created":true,"repaired":false,"eventPts":7}
                """.utf8)
            )
        }
        defer { SavedMessagesMockURLProtocol.handler = nil }

        let response = try await api.ensureSavedMessages(token: "test-token")
        XCTAssertEqual(response, SavedDialogResponse(
            dialogId: "saved-1",
            type: "saved",
            created: true,
            repaired: false,
            eventPts: 7
        ))
    }

    func testSavedDialogPersistsAcrossReopenWithOwnerAndExactZeroUnread() async throws {
        let fixture = try makeStoreFixture()
        let dialogId = "saved-dialog"
        let accountId = "account-me"
        do {
            let store = try CloudLocalStore(path: fixture.path, key: fixture.key)
            try await store.ensureSavedDialog(
                dialogId: dialogId,
                accountId: accountId,
                updatedAt: "2026-07-25T12:00:00Z"
            )
            try await store.upsertDialog(
                dialogId: dialogId,
                type: "direct",
                title: "must not downgrade",
                lastMsgId: 9,
                updatedAt: "2026-07-25T12:01:00Z"
            )
        }

        let reopened = try CloudLocalStore(path: fixture.path, key: fixture.key)
        let persistedDialogId = try await reopened.savedMessagesDialogId(accountId: accountId)
        XCTAssertEqual(persistedDialogId, dialogId)
        let dialogs = try await reopened.dialogs(accountId: accountId)
        XCTAssertEqual(dialogs.count, 1)
        XCTAssertEqual(dialogs[0].type, "saved")
        XCTAssertEqual(dialogs[0].memberCount, 1)
        XCTAssertEqual(dialogs[0].selfRole, "owner")
        XCTAssertEqual(dialogs[0].unreadCount, 0)
        XCTAssertEqual(dialogs[0].lastMsgId, 9)
    }

    func testSavedDialogCreationEventUsesSameLocalInvariantHelper() async throws {
        let fixture = try makeStoreFixture()
        let store = try CloudLocalStore(path: fixture.path, key: fixture.key)
        let accountId = "account-me"
        try await store.applyDifference(
            DifferenceResponse(
                kind: "difference",
                state: .init(pts: 1),
                updates: [
                    CloudUpdate(
                        pts: 1,
                        ptsCount: 1,
                        type: "dialog.created",
                        dialogId: "saved-event-dialog",
                        dialogTitle: "Saved Messages",
                        dialogType: "saved",
                        message: nil,
                        readerAccountId: nil,
                        maxReadMsgId: nil
                    ),
                ],
                hasMore: false
            ),
            accountId: accountId
        )

        let savedDialogId = try await store.savedMessagesDialogId(accountId: accountId)
        XCTAssertEqual(savedDialogId, "saved-event-dialog")
        let dialogs = try await store.dialogs(accountId: accountId)
        let dialog = try XCTUnwrap(dialogs.first)
        XCTAssertEqual(dialog.type, "saved")
        XCTAssertEqual(dialog.memberCount, 1)
        XCTAssertEqual(dialog.selfRole, "owner")
        XCTAssertEqual(dialog.unreadCount, 0)
    }

    func testServiceCoalescesConcurrentProvisioningAndThenUsesLocalRow() async throws {
        let fixture = try makeStoreFixture()
        let store = try CloudLocalStore(path: fixture.path, key: fixture.key)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SavedMessagesMockURLProtocol.self]
        let api = CloudAPI(
            config: CloudConfig(baseURL: try XCTUnwrap(URL(string: "https://cloud.example.test"))),
            session: URLSession(configuration: configuration)
        )
        let requestCounter = LockedRequestCounter()
        SavedMessagesMockURLProtocol.handler = { request in
            requestCounter.increment()
            return (
                try XCTUnwrap(HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["content-type": "application/json"]
                )),
                Data("""
                {"dialogId":"saved-coalesced","type":"saved","created":false,"repaired":false}
                """.utf8)
            )
        }
        defer { SavedMessagesMockURLProtocol.handler = nil }
        let service = SavedMessagesService()

        let ids = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    try await service.ensure(
                        api: api,
                        store: store,
                        accountId: "account-me",
                        token: "token",
                        generation: 1
                    )
                }
            }
            var values: [String] = []
            for try await id in group { values.append(id) }
            return values
        }
        XCTAssertEqual(Set(ids), ["saved-coalesced"])
        XCTAssertEqual(requestCounter.value, 1)

        let local = try await service.ensure(
            api: api,
            store: store,
            accountId: "account-me",
            token: "token",
            generation: 1
        )
        XCTAssertEqual(local, "saved-coalesced")
        XCTAssertEqual(requestCounter.value, 1)
    }

    func testLogoutCancelsAndAwaitsProvisionBeforeSQLCipherPersistence() async throws {
        let fixture = try makeStoreFixture()
        let store = try CloudLocalStore(path: fixture.path, key: fixture.key)
        let client = DelayedSavedMessagesClient(delays: ["old-token": .seconds(30)])
        let service = SavedMessagesService()
        let provision = Task {
            try await service.ensure(
                api: client,
                store: store,
                accountId: "account-old",
                token: "old-token",
                generation: 1
            )
        }
        await client.waitForRequest(token: "old-token")

        await service.reset()
        let result = await provision.result
        guard case let .failure(error) = result else {
            return XCTFail("The invalidated provisioning task unexpectedly succeeded")
        }
        XCTAssertTrue(error is CancellationError)
        let oldDialogId = try await store.savedMessagesDialogId(accountId: "account-old")
        XCTAssertNil(oldDialogId)
        let oldFinished = await client.didFinish(token: "old-token")
        XCTAssertTrue(oldFinished)
    }

    func testConcurrentServiceResetsShareOneNonReentrantCancellationBarrier() async throws {
        let fixture = try makeStoreFixture()
        let store = try CloudLocalStore(path: fixture.path, key: fixture.key)
        let client = DelayedSavedMessagesClient(delays: ["old-token": .seconds(30)])
        let service = SavedMessagesService()
        let provision = Task {
            try await service.ensure(
                api: client, store: store, accountId: "account-old",
                token: "old-token", generation: 1
            )
        }
        await client.waitForRequest(token: "old-token")
        async let firstReset: Void = service.reset()
        async let secondReset: Void = service.reset()
        _ = await (firstReset, secondReset)
        guard case .failure = await provision.result else {
            return XCTFail("Provisioning survived concurrent teardown")
        }
        let newDialog = try await service.ensure(
            api: client, store: store, accountId: "account-new",
            token: "new-token", generation: 2
        )
        let oldPersisted = try await store.savedMessagesDialogId(accountId: "account-old")
        let newPersisted = try await store.savedMessagesDialogId(accountId: "account-new")
        XCTAssertEqual(newDialog, "saved-new-token")
        XCTAssertNil(oldPersisted)
        XCTAssertEqual(newPersisted, newDialog)
    }

    func testAccountSwitchAwaitsOldTaskAndPublishesOnlyNewScope() async throws {
        let oldFixture = try makeStoreFixture()
        let newFixture = try makeStoreFixture()
        let oldStore = try CloudLocalStore(path: oldFixture.path, key: oldFixture.key)
        let newStore = try CloudLocalStore(path: newFixture.path, key: newFixture.key)
        let client = DelayedSavedMessagesClient(delays: ["old-token": .seconds(30)])
        let service = SavedMessagesService()
        let oldProvision = Task {
            try await service.ensure(
                api: client,
                store: oldStore,
                accountId: "account-old",
                token: "old-token",
                generation: 10
            )
        }
        await client.waitForRequest(token: "old-token")

        let newDialogId = try await service.ensure(
            api: client,
            store: newStore,
            accountId: "account-new",
            token: "new-token",
            generation: 11
        )
        XCTAssertEqual(newDialogId, "saved-new-token")
        guard case let .failure(oldError) = await oldProvision.result else {
            return XCTFail("The old account task unexpectedly published")
        }
        XCTAssertTrue(oldError is CancellationError)
        let oldDialogId = try await oldStore.savedMessagesDialogId(accountId: "account-old")
        let persistedNewDialogId = try await newStore.savedMessagesDialogId(accountId: "account-new")
        XCTAssertNil(oldDialogId)
        XCTAssertEqual(persistedNewDialogId, newDialogId)
        let oldFinished = await client.didFinish(token: "old-token")
        let requestedTokens = await client.requestedTokens()
        XCTAssertTrue(oldFinished)
        XCTAssertEqual(requestedTokens, ["old-token", "new-token"])
    }

    @MainActor
    func testCloudAppModelTeardownSynchronouslyRejectsAndAwaitsSavedOperations() async throws {
        let fixture = try makeStoreFixture()
        let store = try CloudLocalStore(path: fixture.path, key: fixture.key)
        let tokenStore = TokenStore(service: "com.toj.saved-teardown.\(UUID().uuidString)")
        let session = StoredCloudSession(
            session: CloudSession(accountId: "account-old", deviceId: "device-old", token: "old-token"),
            phone: "+992900000000",
            displayName: "Old Account"
        )
        try await tokenStore.save(session)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HeldSavedMessagesURLProtocol.self]
        let config = CloudConfig(
            baseURL: try XCTUnwrap(URL(string: "https://teardown.example.test"))
        )
        let model = CloudAppModel(
            config: config,
            api: CloudAPI(config: config, session: URLSession(configuration: configuration)),
            tokenStore: tokenStore,
            localStore: store,
            useDefaultLocalStore: false,
            capabilityDefaults: UserDefaults(suiteName: "saved-teardown-\(UUID().uuidString)")!
        )
        HeldSavedMessagesURLProtocol.reset()
        await model.prepareForBackgroundRuntime()
        let setup = Task { await model.ensureSavedMessages(presentsFailure: false) }
        await HeldSavedMessagesURLProtocol.waitUntilStarted()

        await model.signOut()
        let setupResult = await setup.value
        XCTAssertNil(setupResult)
        XCTAssertTrue(model.sessionTeardownActive)
        XCTAssertTrue(HeldSavedMessagesURLProtocol.savedRequestWasStopped)

        let source = CloudAppModel.Line(
            id: "source:1", dialogId: "source", msgId: 1,
            clientMsgId: UUID().uuidString.lowercased(), text: "must be rejected",
            mine: true, delivery: .sent, timestamp: "2026-07-26T00:00:00Z"
        )
        let rejectedEnsure = await model.ensureSavedMessages(presentsFailure: false)
        await model.saveMessage(source)
        await model.forwardMessage(source, to: "target")
        let outboxAfterTeardown = try await store.pendingOutboxReady()
        let dialogsAfterTeardown = try await store.dialogs(accountId: "account-old")
        XCTAssertNil(rejectedEnsure)
        XCTAssertEqual(HeldSavedMessagesURLProtocol.savedRequestCount, 1)
        XCTAssertTrue(outboxAfterTeardown.isEmpty)
        XCTAssertTrue(dialogsAfterTeardown.isEmpty)
        try await tokenStore.clear()
    }

    @MainActor
    func testCloudAppModelTeardownCancelsForwardBeforeSQLCipherErasure() async throws {
        let fixture = try makeStoreFixture()
        let store = try CloudLocalStore(path: fixture.path, key: fixture.key)
        let tokenStore = TokenStore(service: "com.toj.forward-teardown.\(UUID().uuidString)")
        let accountId = "account-forward"
        let session = StoredCloudSession(
            session: CloudSession(accountId: accountId, deviceId: "device-forward", token: "token-forward"),
            phone: "+992900000001",
            displayName: "Forward Account"
        )
        try await tokenStore.save(session)
        try await store.ensureSavedDialog(
            dialogId: "saved-forward", accountId: accountId, updatedAt: nil
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HeldSavedMessagesURLProtocol.self]
        let config = CloudConfig(
            baseURL: try XCTUnwrap(URL(string: "https://forward-teardown.example.test"))
        )
        let model = CloudAppModel(
            config: config,
            api: CloudAPI(config: config, session: URLSession(configuration: configuration)),
            tokenStore: tokenStore,
            localStore: store,
            useDefaultLocalStore: false,
            capabilityDefaults: UserDefaults(suiteName: "forward-teardown-\(UUID().uuidString)")!
        )
        HeldSavedMessagesURLProtocol.reset()
        await model.prepareForBackgroundRuntime()
        let source = CloudAppModel.Line(
            id: "source:2", dialogId: "source", msgId: 2,
            clientMsgId: UUID().uuidString.lowercased(), text: "cancel this forward",
            mine: true, delivery: .sent, timestamp: "2026-07-26T00:00:00Z"
        )
        let forwarding = Task { await model.forwardMessage(source, to: "saved-forward") }
        await HeldSavedMessagesURLProtocol.waitUntilForwardStarted()

        await model.signOut()
        await forwarding.value
        XCTAssertTrue(HeldSavedMessagesURLProtocol.forwardRequestWasStopped)
        let outbox = try await store.pendingOutboxReady()
        let dialogs = try await store.dialogs(accountId: accountId)
        XCTAssertTrue(outbox.isEmpty)
        XCTAssertTrue(dialogs.isEmpty)
        try await tokenStore.clear()
    }

    func testTransientFirstProvisionFailureCanRetryWithoutLeavingLocalState() async throws {
        let fixture = try makeStoreFixture()
        let store = try CloudLocalStore(path: fixture.path, key: fixture.key)
        let client = FlakySavedMessagesClient()
        let service = SavedMessagesService()
        do {
            _ = try await service.ensure(
                api: client,
                store: store,
                accountId: "account-me",
                token: "retry-token",
                generation: 1
            )
            XCTFail("The first offline request unexpectedly succeeded")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .notConnectedToInternet)
        }
        let missingAfterFailure = try await store.savedMessagesDialogId(accountId: "account-me")
        XCTAssertNil(missingAfterFailure)

        let dialogId = try await service.ensure(
            api: client,
            store: store,
            accountId: "account-me",
            token: "retry-token",
            generation: 1
        )
        XCTAssertEqual(dialogId, "saved-after-retry")
        let persistedAfterRetry = try await store.savedMessagesDialogId(accountId: "account-me")
        XCTAssertEqual(persistedAfterRetry, dialogId)
        let requestCount = await client.requestCount()
        XCTAssertEqual(requestCount, 2)
    }

    func testSavedForwardOutboxSurvivesKillAndRelaunch() async throws {
        let fixture = try makeStoreFixture()
        let accountId = "account-me"
        let savedDialogId = "saved-outbox"
        let clientMsgId = UUID().uuidString.lowercased()
        do {
            let store = try CloudLocalStore(path: fixture.path, key: fixture.key)
            try await store.ensureSavedDialog(
                dialogId: savedDialogId,
                accountId: accountId,
                updatedAt: "2026-07-25T12:00:00Z"
            )
            _ = try await store.insertSending(
                dialogId: savedDialogId,
                clientMsgId: clientMsgId,
                text: "forwarded offline",
                senderAccountId: accountId,
                forwardedFromAccountId: "source-author",
                forwardedFromDialogId: "source-dialog",
                forwardedFromMsgId: 42
            )
        }

        let reopened = try CloudLocalStore(path: fixture.path, key: fixture.key)
        let outbox = try await reopened.pendingOutboxReady()
        XCTAssertEqual(outbox.count, 1)
        XCTAssertEqual(outbox[0].clientMsgId, clientMsgId)
        XCTAssertEqual(outbox[0].dialogId, savedDialogId)
        XCTAssertEqual(outbox[0].forwardedFromDialogId, "source-dialog")
        XCTAssertEqual(outbox[0].forwardedFromMsgId, 42)
        let savedMessages = try await reopened.messages(dialogId: savedDialogId)
        XCTAssertEqual(savedMessages.count, 1)
        XCTAssertTrue(savedMessages[0].isForwarded)
        XCTAssertEqual(savedMessages[0].localState, "sending")
        let dialogs = try await reopened.dialogs(accountId: accountId)
        XCTAssertEqual(dialogs.first(where: { $0.dialogId == savedDialogId })?.type, "saved")
    }

    func testSavedMediaCloneSurvivesOfflineAndResponseSuccessRelaunchForEveryKind() async throws {
        for (offset, kind) in ["photo", "video", "file", "voice"].enumerated() {
            let fixture = try makeStoreFixture()
            let accountId = "account-me"
            let savedDialogId = "saved-\(kind)"
            let media = CloudMedia(
                id: "media-\(kind)", kind: kind,
                contentType: kind == "photo" ? "image/jpeg" : "application/octet-stream",
                fileName: kind == "file" ? "proof.bin" : nil,
                byteSize: 4_096, durationMs: ["video", "voice"].contains(kind) ? 8_000 : nil,
                width: ["photo", "video"].contains(kind) ? 640 : nil,
                height: ["photo", "video"].contains(kind) ? 480 : nil,
                hasThumbnail: ["photo", "video"].contains(kind)
            )
            let clientMsgId = UUID().uuidString.lowercased()
            do {
                let store = try CloudLocalStore(path: fixture.path, key: fixture.key)
                try await store.ensureSavedDialog(
                    dialogId: savedDialogId, accountId: accountId, updatedAt: nil
                )
                try await store.upsertMediaCacheEntry(MediaCacheEntry(
                    mediaId: media.id, variant: "full", encryptedPath: "/encrypted/\(kind)",
                    byteSize: media.byteSize, cachedBytes: media.byteSize,
                    contiguousOffset: media.byteSize, state: "complete",
                    lastAccessedAt: "2026-07-26 00:00:00", protectedUntil: nil
                ))
                _ = try await store.insertSending(
                    dialogId: savedDialogId, clientMsgId: clientMsgId, text: "",
                    senderAccountId: accountId, forwardedFromAccountId: accountId,
                    forwardedFromDialogId: "source-\(kind)", forwardedFromMsgId: 7,
                    kind: kind, media: media
                )
            }

            do {
                let reopened = try CloudLocalStore(path: fixture.path, key: fixture.key)
                let pending = try await reopened.messages(dialogId: savedDialogId)
                XCTAssertEqual(pending.first?.kind, kind)
                XCTAssertEqual(pending.first?.media, media)
                let pendingMedia = try await reopened.messageMedia(localId: "pending:\(clientMsgId)")
                let pendingOutbox = try await reopened.pendingOutboxReady()
                XCTAssertEqual(pendingMedia?.media, media)
                XCTAssertEqual(pendingOutbox.map(\.clientMsgId), [clientMsgId])
                try await reopened.markSent(
                    SendMessageResponse(
                        dialogId: savedDialogId, clientMsgId: clientMsgId,
                        msgId: Int64(offset + 1), senderPts: Int64(offset + 1),
                        duplicate: false, serverTs: "2026-07-26T00:00:00Z", text: ""
                    ),
                    senderAccountId: accountId
                )
            }

            let responseRelaunch = try CloudLocalStore(path: fixture.path, key: fixture.key)
            let sent = try await responseRelaunch.messages(dialogId: savedDialogId)
            let sentMedia = try await responseRelaunch.messageMedia(
                localId: "\(savedDialogId):\(offset + 1)"
            )
            let retainedCache = try await responseRelaunch.mediaCacheEntry(
                mediaId: media.id, variant: "full"
            )
            XCTAssertEqual(sent.first?.media, media)
            XCTAssertEqual(sent.first?.localState, "sent")
            XCTAssertEqual(sentMedia?.media, media)
            XCTAssertNotNil(retainedCache)
        }
    }

    func testCanonicalDifferenceClearsForwardOutboxAndAtomicRemoveKeepsSharedCache() async throws {
        let fixture = try makeStoreFixture()
        let store = try CloudLocalStore(path: fixture.path, key: fixture.key)
        let accountId = "account-me"
        let dialogId = "saved-media"
        let media = CloudMedia(
            id: "shared-media", kind: "file", contentType: "application/octet-stream",
            fileName: "shared.bin", byteSize: 99, durationMs: nil, width: nil, height: nil,
            hasThumbnail: false
        )
        try await store.ensureSavedDialog(dialogId: dialogId, accountId: accountId, updatedAt: nil)
        try await store.upsertMediaCacheEntry(MediaCacheEntry(
            mediaId: media.id, variant: "full", encryptedPath: "/encrypted/shared",
            byteSize: 99, cachedBytes: 99, contiguousOffset: 99, state: "complete",
            lastAccessedAt: "2026-07-26 00:00:00", protectedUntil: nil
        ))

        let reconciledClientId = UUID().uuidString.lowercased()
        _ = try await store.insertSending(
            dialogId: dialogId, clientMsgId: reconciledClientId, text: "",
            senderAccountId: accountId, forwardedFromAccountId: accountId,
            forwardedFromDialogId: "source", forwardedFromMsgId: 8,
            kind: "file", media: media
        )
        try await store.applyDifference(
            DifferenceResponse(
                kind: "difference", state: .init(pts: 1),
                updates: [CloudUpdate(
                    pts: 1, ptsCount: 1, type: "message.new", dialogId: dialogId,
                    dialogTitle: "Saved Messages", dialogType: "saved",
                    message: CloudMessage(
                        dialogId: dialogId, msgId: 1, senderAccountId: accountId,
                        clientMsgId: reconciledClientId, kind: "file", text: "",
                        isForwarded: true, media: media, editVersion: 0, state: "visible",
                        serverTs: "2026-07-26T00:00:00Z"
                    ),
                    readerAccountId: nil, maxReadMsgId: nil
                )],
                hasMore: false
            ),
            accountId: accountId
        )
        let reconciledOutbox = try await store.pendingOutboxReady()
        let reconciledMedia = try await store.messageMedia(localId: "\(dialogId):1")
        XCTAssertTrue(reconciledOutbox.isEmpty)
        XCTAssertEqual(reconciledMedia?.media, media)

        let removedClientId = UUID().uuidString.lowercased()
        _ = try await store.insertSending(
            dialogId: dialogId, clientMsgId: removedClientId, text: "",
            senderAccountId: accountId, forwardedFromAccountId: accountId,
            forwardedFromDialogId: "source", forwardedFromMsgId: 9,
            kind: "file", media: media
        )
        try await store.markFailed(clientMsgId: removedClientId, terminal: true)
        try await store.removePendingOutboxMessage(clientMsgId: removedClientId)
        let remaining = try await store.messages(dialogId: dialogId)
        let removedMedia = try await store.messageMedia(localId: "pending:\(removedClientId)")
        let sharedCache = try await store.mediaCacheEntry(mediaId: media.id, variant: "full")
        XCTAssertFalse(remaining.contains { $0.clientMsgId == removedClientId })
        XCTAssertNil(removedMedia)
        XCTAssertNotNil(sharedCache)
    }

    func testSavedAccessRevocationHidesArchiveAndPurgesLocalMessagesAndMedia() async throws {
        let fixture = try makeStoreFixture()
        let store = try CloudLocalStore(path: fixture.path, key: fixture.key)
        let accountId = "unauthorized-account"
        let dialogId = "unauthorized-saved"
        let media = CloudMedia(
            id: "private-saved-media", kind: "photo", contentType: "image/jpeg",
            fileName: nil, byteSize: 128, durationMs: nil, width: 10, height: 10,
            hasThumbnail: true
        )
        try await store.ensureSavedDialog(dialogId: dialogId, accountId: accountId, updatedAt: nil)
        try await store.upsertMediaCacheEntry(MediaCacheEntry(
            mediaId: media.id, variant: "full", encryptedPath: "/encrypted/private",
            byteSize: 128, cachedBytes: 128, contiguousOffset: 128, state: "complete",
            lastAccessedAt: "2026-07-26 00:00:00", protectedUntil: nil
        ))
        _ = try await store.insertSending(
            dialogId: dialogId, clientMsgId: UUID().uuidString.lowercased(), text: "",
            senderAccountId: accountId, kind: "photo", media: media
        )

        try await store.applyDifference(
            DifferenceResponse(
                kind: "difference", state: .init(pts: 3),
                updates: [CloudUpdate(
                    pts: 3, ptsCount: 1, type: "dialog.access_revoked",
                    dialogId: dialogId, dialogTitle: nil, dialogType: "saved",
                    message: nil, readerAccountId: nil, maxReadMsgId: nil
                )],
                hasMore: false
            ),
            accountId: accountId
        )

        let visibleDialogs = try await store.dialogs(accountId: accountId)
        let outbox = try await store.pendingOutboxReady()
        let purgeCount = try await store.drainPendingPurges()
        let timeline = try await store.timeline(dialogId: dialogId)
        let cache = try await store.mediaCacheEntry(mediaId: media.id, variant: "full")
        XCTAssertTrue(visibleDialogs.isEmpty)
        XCTAssertTrue(outbox.isEmpty)
        XCTAssertGreaterThan(purgeCount, 0)
        XCTAssertTrue(timeline.messages.isEmpty)
        XCTAssertNil(cache)
    }

    func testSavedMessagesStringsHaveRussianAndTajikTranslations() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let catalogURL = sourceRoot
            .appending(path: "Toj", directoryHint: .isDirectory)
            .appending(path: "Localizable.xcstrings")
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any]
        )
        let strings = try XCTUnwrap(object["strings"] as? [String: Any])
        let requiredKeys = [
            "Save",
            "Saved Messages",
            "Connect once to set up Saved Messages",
            "Connect to set up",
            "Keep notes, media, links and files here. Downloaded items stay available offline.",
            "Offline conversation could not be opened",
            "Save something for yourself",
            "Saved Messages could not be set up",
            "Saved Messages access ended",
            "Saved to Saved Messages",
            "Setting up…",
            "Synced across your devices",
            "The unauthorized Saved Messages offline copy was removed.",
            "Try offline copy again",
            "Unavailable",
            "Unavailable on this server",
            "Remove",
        ]

        for key in requiredKeys {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], "Missing localization key: \(key)")
            let localizations = try XCTUnwrap(
                entry["localizations"] as? [String: Any],
                "Missing localizations for: \(key)"
            )
            for language in ["ru", "tg"] {
                let localization = try XCTUnwrap(
                    localizations[language] as? [String: Any],
                    "Missing \(language) localization for: \(key)"
                )
                let stringUnit = try XCTUnwrap(
                    localization["stringUnit"] as? [String: Any],
                    "Missing \(language) string unit for: \(key)"
                )
                let value = try XCTUnwrap(
                    stringUnit["value"] as? String,
                    "Missing \(language) value for: \(key)"
                )
                XCTAssertFalse(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func makeStoreFixture() throws -> (path: String, key: Data) {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "toj-saved-messages-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return (
            directory.appending(path: "cloud.sqlite").path,
            Data("saved-messages-test-key".utf8)
        )
    }
}

private final class SavedMessagesMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let handler = try XCTUnwrap(Self.handler)
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class LockedRequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private actor DelayedSavedMessagesClient: SavedMessagesProvisioningClient {
    private let delays: [String: Duration]
    private var requests: [String] = []
    private var finished: Set<String> = []

    init(delays: [String: Duration]) {
        self.delays = delays
    }

    func ensureSavedMessages(token: String) async throws -> SavedDialogResponse {
        requests.append(token)
        defer { finished.insert(token) }
        if let delay = delays[token] {
            try await Task.sleep(for: delay)
        }
        try Task.checkCancellation()
        return SavedDialogResponse(
            dialogId: "saved-\(token)",
            type: "saved",
            created: true,
            repaired: false,
            eventPts: 1
        )
    }

    func waitForRequest(token: String) async {
        while !requests.contains(token) {
            await Task.yield()
        }
    }

    func didFinish(token: String) -> Bool {
        finished.contains(token)
    }

    func requestedTokens() -> [String] {
        requests
    }
}

private actor FlakySavedMessagesClient: SavedMessagesProvisioningClient {
    private var count = 0

    func ensureSavedMessages(token: String) async throws -> SavedDialogResponse {
        count += 1
        if count == 1 {
            throw URLError(.notConnectedToInternet)
        }
        return SavedDialogResponse(
            dialogId: "saved-after-retry",
            type: "saved",
            created: true,
            repaired: false,
            eventPts: 1
        )
    }

    func requestCount() -> Int {
        count
    }
}

private final class HeldSavedMessagesURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var started = 0
    nonisolated(unsafe) private static var stopped = 0
    nonisolated(unsafe) private static var forwardStarted = 0
    nonisolated(unsafe) private static var forwardStopped = 0

    static func reset() {
        lock.lock()
        started = 0
        stopped = 0
        forwardStarted = 0
        forwardStopped = 0
        lock.unlock()
    }

    static var savedRequestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return started
    }

    static var savedRequestWasStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped > 0
    }

    static var forwardRequestWasStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return forwardStopped > 0
    }

    static func waitUntilStarted() async {
        while savedRequestCount == 0 {
            await Task.yield()
        }
    }

    static func waitUntilForwardStarted() async {
        while true {
            lock.lock()
            let value = forwardStarted
            lock.unlock()
            if value > 0 { return }
            await Task.yield()
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if request.url?.path == "/v1/messages/send" {
            Self.lock.lock()
            Self.forwardStarted += 1
            Self.lock.unlock()
            return
        }
        guard request.url?.path == "/v1/dialogs/saved" else {
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["content-type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{}".utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        Self.lock.lock()
        Self.started += 1
        Self.lock.unlock()
        // Intentionally no response. URLSession must cancel this exact request during teardown.
    }

    override func stopLoading() {
        if request.url?.path == "/v1/messages/send" {
            Self.lock.lock()
            Self.forwardStopped += 1
            Self.lock.unlock()
            return
        }
        guard request.url?.path == "/v1/dialogs/saved" else { return }
        Self.lock.lock()
        Self.stopped += 1
        Self.lock.unlock()
    }
}
