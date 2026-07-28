import XCTest
import UIKit
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
        let purgeJobs = try await store.pendingAccessPurgeJobs()
        for job in purgeJobs {
            try await store.markAccessPurgeFilesDeleted(id: job.id)
            try await store.finalizeAccessPurge(id: job.id)
        }
        let timeline = try await store.timeline(dialogId: dialogId)
        let cache = try await store.mediaCacheEntry(mediaId: media.id, variant: "full")
        XCTAssertTrue(visibleDialogs.isEmpty)
        XCTAssertTrue(outbox.isEmpty)
        XCTAssertFalse(purgeJobs.isEmpty)
        XCTAssertTrue(timeline.messages.isEmpty)
        XCTAssertNil(cache)
    }

    @MainActor
    func testLegacyReceiptReplayAfterReconciliationCannotRestoreDialogOrProfile() async throws {
        let fixture = try makeStoreFixture()
        let store = try CloudLocalStore(path: fixture.path, key: fixture.key)
        let accountId = "legacy-rogue"
        let ownerId = "saved-owner-profile"
        let dialogId = "legacy-reconciled-saved"
        let authorizedDialogId = "legacy-authorized-direct"
        let authorizedPeerId = "legacy-authorized-peer"
        try await store.ensureSavedDialog(dialogId: dialogId, accountId: accountId, updatedAt: nil)
        let message = CloudMessage(
            dialogId: dialogId, msgId: 1, senderAccountId: ownerId,
            clientMsgId: UUID().uuidString.lowercased(), kind: "text",
            text: "private legacy receipt", editVersion: 0, state: "visible",
            serverTs: "2026-07-27T00:00:00Z"
        )
        let authorizedMessage = CloudMessage(
            dialogId: authorizedDialogId, msgId: 1, senderAccountId: authorizedPeerId,
            clientMsgId: UUID().uuidString.lowercased(), kind: "text",
            text: "authorized receipt", editVersion: 0, state: "visible",
            serverTs: "2026-07-27T00:00:01Z"
        )
        let receipt = DifferenceResponse(
            kind: "difference", state: .init(pts: 3),
            updates: [
                CloudUpdate(
                    pts: 1, ptsCount: 1, type: "message.new", dialogId: dialogId,
                    dialogTitle: "Saved Messages", dialogType: "saved", message: message,
                    readerAccountId: nil, maxReadMsgId: nil
                ),
                CloudUpdate(
                    pts: 2, ptsCount: 1, type: "dialog.access_revoked", dialogId: dialogId,
                    dialogTitle: nil, dialogType: "saved", message: nil,
                    readerAccountId: nil, maxReadMsgId: nil
                ),
                CloudUpdate(
                    pts: 3, ptsCount: 1, type: "message.new",
                    dialogId: authorizedDialogId, dialogTitle: "Authorized",
                    dialogType: "direct", message: authorizedMessage,
                    readerAccountId: nil, maxReadMsgId: nil
                ),
            ],
            profiles: [
                CloudProfile(
                    accountId: ownerId, firstName: "Private", lastName: "Owner",
                    displayName: "Private Owner", bio: "must not persist", birthday: nil,
                    colorIndex: 3, updatedAt: "2026-07-27T00:00:00Z"
                ),
                CloudProfile(
                    accountId: authorizedPeerId, firstName: "Authorized", lastName: "Peer",
                    displayName: "Authorized Peer", bio: "", birthday: nil,
                    colorIndex: 4, updatedAt: "2026-07-27T00:00:01Z"
                ),
            ],
            hasMore: false
        )
        try await store.applyDifference(receipt, accountId: accountId)
        let profilePersistedBeforeDrain = try await store.containsProfile(accountId: ownerId)
        let authorizedProfilePersisted = try await store.containsProfile(
            accountId: authorizedPeerId
        )
        XCTAssertFalse(profilePersistedBeforeDrain)
        XCTAssertTrue(authorizedProfilePersisted)

        let cache = try EncryptedMediaCache(
            root: URL(fileURLWithPath: fixture.path).deletingLastPathComponent()
                .appending(path: "legacy-replay-cache", directoryHint: .isDirectory),
            keyData: Data(repeating: 0x31, count: 32), limitBytes: 1_000_000
        )
        _ = try await AccessPurgeCoordinator().drain(
            scope: AccessPurgeScope(
                accountId: accountId, token: "legacy-token", generation: 1, store: store
            ),
            store: store,
            mediaEngine: CloudMediaTransferEngine(cache: cache),
            isCurrent: { true },
            invalidatePresentation: { _ in }
        )

        try await store.applyDifference(receipt, accountId: accountId)
        let replayDialogs = try await store.dialogs(accountId: accountId)
        let replayTimeline = try await store.timeline(dialogId: dialogId)
        let replayProfilePersisted = try await store.containsProfile(accountId: ownerId)
        let replayPurgeCount = try await store.pendingAccessPurgeCount()
        XCTAssertEqual(replayDialogs.map(\.dialogId), [authorizedDialogId])
        XCTAssertTrue(replayTimeline.messages.isEmpty)
        XCTAssertFalse(replayProfilePersisted)
        XCTAssertEqual(replayPurgeCount, 0)
    }

    func testDelayedHistoryMutationAndDifferenceWritesRespectRevocationFence() async throws {
        let fixture = try makeStoreFixture()
        let store = try CloudLocalStore(path: fixture.path, key: fixture.key)
        let accountId = "delayed-writes-account"
        let dialogId = "delayed-writes-saved"
        let clientMsgId = UUID().uuidString.lowercased()
        try await store.ensureSavedDialog(dialogId: dialogId, accountId: accountId, updatedAt: nil)
        try await Self.applyRevocation(
            store: store, accountId: accountId, dialogId: dialogId, pts: 1
        )
        let delayed = CloudMessage(
            dialogId: dialogId, msgId: 7, senderAccountId: accountId,
            clientMsgId: clientMsgId, kind: "text", text: "must stay revoked",
            editVersion: 1, state: "visible", serverTs: "2026-07-27T00:00:01Z"
        )
        let profile = CloudProfile(
            accountId: "revoked-profile", firstName: "Revoked", lastName: "Profile",
            displayName: "Revoked Profile", bio: "", birthday: nil, colorIndex: 1,
            updatedAt: "2026-07-27T00:00:01Z"
        )
        try await store.applyHistoryPage(HistoryPageResponse(
            dialogId: dialogId, messages: [delayed], profiles: [profile],
            nextBeforeMsgId: nil, hasMore: false
        ))
        try await store.applyTargetedHistoryPage(HistoryPageResponse(
            dialogId: dialogId, messages: [delayed], profiles: [profile],
            nextBeforeMsgId: nil, hasMore: false
        ))
        try await store.applyMessageMutation(MessageMutationResponse(
            dialogId: dialogId, msgId: 7, actorPts: 2, duplicate: false, message: delayed
        ))
        try await store.markSent(SendMessageResponse(
            dialogId: dialogId, clientMsgId: clientMsgId, msgId: 7,
            senderPts: 2, duplicate: false, serverTs: delayed.serverTs, text: delayed.text
        ), senderAccountId: accountId)
        try await store.applyDifference(DifferenceResponse(
            kind: "difference", state: .init(pts: 3),
            updates: [CloudUpdate(
                pts: 3, ptsCount: 1, type: "message.new", dialogId: dialogId,
                dialogTitle: "Saved Messages", dialogType: "saved", message: delayed,
                readerAccountId: nil, maxReadMsgId: nil
            )],
            profiles: [profile], hasMore: false
        ), accountId: accountId)
        do {
            _ = try await store.insertSending(
                dialogId: dialogId, clientMsgId: UUID().uuidString.lowercased(),
                text: "rejected", senderAccountId: accountId
            )
            XCTFail("revoked outbox write must be rejected")
        } catch CloudLocalStoreAccessError.revoked {
            // Expected.
        }
        do {
            try await store.enqueueMessageMutation(
                clientMutationId: UUID().uuidString.lowercased(), operation: "delete",
                dialogId: dialogId, msgId: 7
            )
            XCTFail("revoked mutation write must be rejected")
        } catch CloudLocalStoreAccessError.revoked {
            // Expected.
        }
        let delayedTimeline = try await store.timeline(dialogId: dialogId)
        let delayedProfilePersisted = try await store.containsProfile(
            accountId: profile.accountId
        )
        XCTAssertTrue(delayedTimeline.messages.isEmpty)
        XCTAssertFalse(delayedProfilePersisted)
    }

    @MainActor
    func testLateForegroundBackgroundStreamingAndPresentationWritesAreFenced() async throws {
        let fixture = try makeStoreFixture()
        let mediaId = "late-revoked-media"
        let cache = try EncryptedMediaCache(
            root: URL(fileURLWithPath: fixture.path).deletingLastPathComponent()
                .appending(path: "late-write-cache", directoryHint: .isDirectory),
            keyData: Data(repeating: 0x41, count: 32), limitBytes: 1_000_000
        )
        try await cache.storeDownloadChunk(Data([1, 2, 3]), mediaId: mediaId, offset: 0)
        try await cache.purgeRevokedMedia(mediaIds: [mediaId], additionalEncryptedPaths: [])

        for operation in [
            { try await cache.storeDownloadChunk(Data([4]), mediaId: mediaId, offset: 0) },
            { try await cache.storeThumbnail(Data([5]), mediaId: mediaId) },
            {
                try await cache.storeRepresentation(
                    Data([6]), mediaId: mediaId, variant: .bubble720
                )
            },
            { try await cache.beginAccess(mediaId: mediaId) },
        ] {
            do {
                try await operation()
                XCTFail("late media write must be rejected")
            } catch MediaCacheError.accessRevoked {
                // Foreground, background callback, streaming, and representation share this fence.
            }
        }

        let presentation = MediaPresentationCache.shared
        presentation.removeAll()
        let gate = SavedMessagesAsyncGate()
        let key = MediaPresentationKey(mediaId: mediaId, variant: .bubble720)
        let delayedPresentation = Task {
            await presentation.image(for: key) {
                await gate.wait()
                return SafeDecodedImage(image: UIImage(), pixelWidth: 1, pixelHeight: 1)
            }
        }
        await gate.waitUntilBlocked()
        presentation.revoke(mediaIds: [mediaId])
        await gate.open()
        let delayedImage = await delayedPresentation.value
        XCTAssertNil(delayedImage)
        XCTAssertFalse(presentation.contains(key))
        presentation.resetForSession()
    }

    @MainActor
    func testRevokingChatADoesNotCancelChatBUploadTask() async throws {
        let model = CloudAppModel(
            config: CloudConfig(baseURL: try XCTUnwrap(URL(string: "https://task-scope.invalid"))),
            useDefaultLocalStore: false,
            capabilityDefaults: UserDefaults(suiteName: UUID().uuidString)!
        )
        let aCancelled = SavedMessagesCancellationProbe()
        let bCancelled = SavedMessagesCancellationProbe()
        let taskA = Task {
            do { try await Task.sleep(for: .seconds(30)) }
            catch { await aCancelled.markCancelled() }
        }
        let taskB = Task {
            do { try await Task.sleep(for: .seconds(30)) }
            catch { await bCancelled.markCancelled() }
        }
        model.testTrackMediaTransferTask(transferId: "upload-a", dialogId: "chat-a", task: taskA)
        model.testTrackMediaTransferTask(transferId: "upload-b", dialogId: "chat-b", task: taskB)
        await model.testInvalidatePresentationForAccessPurge(AccessPurgeJob(
            id: "purge-a", dialogId: "chat-a", allMediaIds: ["media-a"],
            purgeMediaIds: ["media-a"], encryptedPaths: [], phase: .staged,
            attempts: 0, lastError: nil
        ))

        let didCancelA = await aCancelled.value
        let didCancelB = await bCancelled.value
        XCTAssertTrue(didCancelA)
        XCTAssertFalse(didCancelB)
        XCTAssertFalse(model.testHasTrackedMediaTransfer("upload-a"))
        XCTAssertTrue(model.testHasTrackedMediaTransfer("upload-b"))
        await model.testCancelTrackedMediaTransfer("upload-b")
    }

    @MainActor
    func testPurgeJobFailureIsIsolatedAndDurableForNextLaunch() async throws {
        let fixture = try makeStoreFixture()
        let store = try CloudLocalStore(path: fixture.path, key: fixture.key)
        for dialogId in ["bad-purge", "good-purge"] {
            try await store.upsertDialog(dialogId: dialogId, type: "group", title: dialogId)
            try await store.revokeGroupAccess(dialogId: dialogId, reason: "dialog.access_revoked")
        }
        let cache = try EncryptedMediaCache(
            root: URL(fileURLWithPath: fixture.path).deletingLastPathComponent()
                .appending(path: "isolated-purge-cache", directoryHint: .isDirectory),
            keyData: Data(repeating: 0x42, count: 32), limitBytes: 1_000_000
        )
        let result = try await AccessPurgeCoordinator().drain(
            scope: AccessPurgeScope(
                accountId: "isolation-account", token: "token", generation: 1, store: store
            ),
            store: store,
            mediaEngine: CloudMediaTransferEngine(cache: cache),
            isCurrent: { true },
            invalidatePresentation: { _ in },
            purgeFilesOverride: { job in
                if job.dialogId == "bad-purge" { throw SavedMessagesInjectedPurgeError() }
            }
        )
        XCTAssertEqual(result.finalized, 1)
        XCTAssertEqual(result.failed, 1)
        let remaining = try await store.pendingAccessPurgeJobs()
        XCTAssertEqual(remaining.map(\.dialogId), ["bad-purge"])
        XCTAssertEqual(remaining.first?.attempts, 1)
        XCTAssertNotNil(remaining.first?.lastError)
        let goodTimeline = try await store.timeline(dialogId: "good-purge")
        XCTAssertTrue(goodTimeline.messages.isEmpty)
    }

    @MainActor
    func testLargeMediaBearingLaunchPurgeDrainsEveryBatchBeforePublishing() async throws {
        let fixture = try makeStoreFixture()
        let store = try CloudLocalStore(path: fixture.path, key: fixture.key)
        let accountId = "large-launch-account"
        let cacheRoot = URL(fileURLWithPath: fixture.path).deletingLastPathComponent()
            .appending(path: "large-launch-cache", directoryHint: .isDirectory)
        let cache = try EncryptedMediaCache(
            root: cacheRoot, keyData: Data(repeating: 0x43, count: 32),
            limitBytes: 5_000_000
        )
        for index in 0..<25 {
            let dialogId = "large-revoked-\(index)"
            let mediaId = "large-media-\(index)"
            let media = CloudMedia(
                id: mediaId, kind: "file", contentType: "application/octet-stream",
                fileName: "\(index).bin", byteSize: 32, durationMs: nil,
                width: nil, height: nil, hasThumbnail: false
            )
            try await cache.storeDownloadChunk(
                Data(repeating: UInt8(index), count: 32), mediaId: mediaId, offset: 0
            )
            try await store.upsertMediaCacheEntry(MediaCacheEntry(
                mediaId: mediaId, variant: "full",
                encryptedPath: cacheRoot.appending(path: "downloads/\(mediaId)").path,
                byteSize: 32, cachedBytes: 60, contiguousOffset: 32, state: "complete",
                lastAccessedAt: "2026-07-27 00:00:00", protectedUntil: nil
            ))
            try await store.upsertDialog(dialogId: dialogId, type: "group", title: "Revoked")
            try await Self.applyCanonicalMedia(
                store: store, accountId: accountId, dialogId: dialogId,
                dialogType: "group", media: media, pts: Int64(index + 1), msgId: 1
            )
            try await store.revokeGroupAccess(dialogId: dialogId, reason: "dialog.access_revoked")
        }
        let stagedPurgeCount = try await store.pendingAccessPurgeCount()
        XCTAssertEqual(stagedPurgeCount, 25)

        let tokenStore = TokenStore(service: "com.toj.large-launch.\(UUID().uuidString)")
        try await tokenStore.save(StoredCloudSession(
            session: CloudSession(
                accountId: accountId, deviceId: "large-device", token: "large-token"
            ),
            phone: "+992900000099", displayName: "Large Launch"
        ))
        let model = CloudAppModel(
            config: CloudConfig(
                baseURL: try XCTUnwrap(URL(string: "https://large-launch.invalid"))
            ),
            tokenStore: tokenStore,
            localStore: store,
            useDefaultLocalStore: false,
            mediaEngine: CloudMediaTransferEngine(cache: cache),
            capabilityDefaults: UserDefaults(suiteName: UUID().uuidString)!
        )
        await model.prepareForBackgroundRuntime()

        XCTAssertEqual(model.launchPhase, .localReady)
        XCTAssertTrue(model.dialogs.isEmpty)
        let remainingPurgeCount = try await store.pendingAccessPurgeCount()
        XCTAssertEqual(remainingPurgeCount, 0)
        for index in 0..<25 {
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: cacheRoot.appending(path: "downloads/large-media-\(index)").path
            ))
        }
        try await tokenStore.clear()
    }

    @MainActor
    func testAccessPurgeDeletesRealEncryptedFilesDuringPlaybackAndZerosPayloads() async throws {
        let fixture = try makeStoreFixture()
        let store = try CloudLocalStore(path: fixture.path, key: fixture.key)
        let cacheRoot = URL(fileURLWithPath: fixture.path)
            .deletingLastPathComponent()
            .appending(path: "encrypted-media", directoryHint: .isDirectory)
        let cache = try EncryptedMediaCache(
            root: cacheRoot,
            keyData: Data(repeating: 0x51, count: 32),
            limitBytes: 2 * 1024 * 1024
        )
        let engine = CloudMediaTransferEngine(cache: cache)
        let coordinator = AccessPurgeCoordinator()
        let accountId = "purge-account"
        let dialogId = "purge-saved"
        let mediaId = "revoked-active-media"
        let media = CloudMedia(
            id: mediaId, kind: "voice", contentType: "audio/ogg",
            fileName: nil, byteSize: 64, durationMs: 1_000, width: nil, height: nil,
            hasThumbnail: false
        )
        let payload = Data(repeating: 0x52, count: 64)
        try await cache.storeDownloadChunk(payload, mediaId: mediaId, offset: 0)
        let downloadPath = cacheRoot.appending(path: "downloads/\(mediaId)")
        try await store.upsertMediaCacheEntry(MediaCacheEntry(
            mediaId: mediaId, variant: "full", encryptedPath: downloadPath.path,
            byteSize: 64, cachedBytes: 92, contiguousOffset: 64, state: "complete",
            lastAccessedAt: "2026-07-27 00:00:00", protectedUntil: nil
        ))
        try await store.ensureSavedDialog(dialogId: dialogId, accountId: accountId, updatedAt: nil)
        try await Self.applyCanonicalMedia(
            store: store, accountId: accountId, dialogId: dialogId,
            dialogType: "saved", media: media, pts: 1, msgId: 1
        )

        let prepared = try await cache.prepareUpload(
            data: Data("revoked upload source".utf8),
            kind: "file",
            contentType: "application/octet-stream",
            fileName: "private.bin"
        )
        let latePrepared = try await cache.prepareUpload(
            data: Data("late revoked upload source".utf8),
            kind: "file",
            contentType: "application/octet-stream",
            fileName: "late-private.bin"
        )
        try await store.insertMediaTransfer(
            prepared: prepared, dialogId: dialogId,
            clientMsgId: UUID().uuidString.lowercased(), caption: "", replyToMsgId: nil
        )
        _ = try await store.insertSending(
            dialogId: dialogId,
            clientMsgId: UUID().uuidString.lowercased(),
            text: "plaintext outbox must disappear",
            senderAccountId: accountId
        )
        await engine.beginMediaAccess(mediaId)

        try await Self.applyRevocation(
            store: store, accountId: accountId, dialogId: dialogId, pts: 2
        )
        let stagedOutbox = try await store.pendingOutboxReady()
        let stagedTransfers = try await store.mediaTransfers(dialogId: dialogId)
        XCTAssertTrue(stagedOutbox.isEmpty)
        XCTAssertTrue(stagedTransfers.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: downloadPath.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.encryptedSourcePath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: latePrepared.encryptedSourcePath))

        let scope = AccessPurgeScope(
            accountId: accountId, token: "token-a", generation: 1, store: store
        )
        let result = try await coordinator.drain(
            scope: scope,
            store: store,
            mediaEngine: engine,
            isCurrent: { true },
            invalidatePresentation: { _ in
                // Model prepare returning after revocation. The transactional fence rejects the
                // SQL row and the producer immediately relinquishes the newly encrypted bytes.
                do {
                    try await store.insertMediaTransfer(
                        prepared: latePrepared,
                        dialogId: dialogId,
                        clientMsgId: UUID().uuidString.lowercased(),
                        caption: "",
                        replyToMsgId: nil
                    )
                    XCTFail("late prepared transfer must be rejected")
                } catch CloudLocalStoreAccessError.revoked {
                    await engine.discardPrepared(latePrepared)
                } catch {
                    XCTFail("unexpected late prepare error: \(error)")
                }
            }
        )

        XCTAssertEqual(result, AccessPurgeDrainResult(finalized: 1, batches: 1))
        let remainingJobs = try await store.pendingAccessPurgeCount()
        let purgedTimeline = try await store.timeline(dialogId: dialogId)
        let purgedCache = try await store.mediaCacheEntry(mediaId: mediaId, variant: "full")
        let cacheUsage = try await cache.usageSnapshot()
        XCTAssertEqual(remainingJobs, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: downloadPath.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.encryptedSourcePath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: latePrepared.encryptedSourcePath))
        XCTAssertEqual(cacheUsage.protectedUploadBytes, 0)
        XCTAssertTrue(purgedTimeline.messages.isEmpty)
        XCTAssertNil(purgedCache)
    }

    @MainActor
    func testAccessPurgePreservesEncryptedMediaReferencedByForwardedCopy() async throws {
        let fixture = try makeStoreFixture()
        let store = try CloudLocalStore(path: fixture.path, key: fixture.key)
        let cacheRoot = URL(fileURLWithPath: fixture.path)
            .deletingLastPathComponent()
            .appending(path: "forwarded-cache", directoryHint: .isDirectory)
        let cache = try EncryptedMediaCache(
            root: cacheRoot,
            keyData: Data(repeating: 0x61, count: 32),
            limitBytes: 2 * 1024 * 1024
        )
        let engine = CloudMediaTransferEngine(cache: cache)
        let accountId = "shared-account"
        let savedId = "shared-saved"
        let targetId = "shared-target"
        let mediaId = "forwarded-shared-media"
        let media = CloudMedia(
            id: mediaId, kind: "video", contentType: "video/mp4",
            fileName: "shared.mp4", byteSize: 80, durationMs: 2_000,
            width: 320, height: 240, hasThumbnail: false
        )
        try await cache.storeDownloadChunk(Data(repeating: 0x62, count: 80), mediaId: mediaId, offset: 0)
        let downloadPath = cacheRoot.appending(path: "downloads/\(mediaId)")
        try await store.upsertMediaCacheEntry(MediaCacheEntry(
            mediaId: mediaId, variant: "full", encryptedPath: downloadPath.path,
            byteSize: 80, cachedBytes: 108, contiguousOffset: 80, state: "complete",
            lastAccessedAt: "2026-07-27 00:00:00", protectedUntil: nil
        ))
        try await store.ensureSavedDialog(dialogId: savedId, accountId: accountId, updatedAt: nil)
        try await store.upsertDialog(dialogId: targetId, type: "direct", title: "Peer")
        try await Self.applyCanonicalMedia(
            store: store, accountId: accountId, dialogId: savedId,
            dialogType: "saved", media: media, pts: 1, msgId: 1
        )
        try await Self.applyCanonicalMedia(
            store: store, accountId: accountId, dialogId: targetId,
            dialogType: "direct", media: media, pts: 2, msgId: 1, forwarded: true
        )
        try await Self.applyRevocation(
            store: store, accountId: accountId, dialogId: savedId, pts: 3
        )
        let stagedJobs = try await store.pendingAccessPurgeJobs()
        let job = try XCTUnwrap(stagedJobs.first)
        XCTAssertEqual(job.allMediaIds, Set([mediaId]))
        XCTAssertTrue(job.purgeMediaIds.isEmpty)

        let coordinator = AccessPurgeCoordinator()
        _ = try await coordinator.drain(
            scope: AccessPurgeScope(
                accountId: accountId, token: "token-shared", generation: 1, store: store
            ),
            store: store,
            mediaEngine: engine,
            isCurrent: { true },
            invalidatePresentation: { _ in }
        )

        let sharedCache = try await store.mediaCacheEntry(mediaId: mediaId, variant: "full")
        let targetTimeline = try await store.timeline(dialogId: targetId)
        let savedTimeline = try await store.timeline(dialogId: savedId)
        XCTAssertTrue(FileManager.default.fileExists(atPath: downloadPath.path))
        XCTAssertNotNil(sharedCache)
        XCTAssertEqual(targetTimeline.messages.first?.media, media)
        XCTAssertTrue(savedTimeline.messages.isEmpty)
    }

    @MainActor
    func testAccessPurgeDrainsMoreThanTwentyJobsInBoundedBatches() async throws {
        let fixture = try makeStoreFixture()
        let store = try CloudLocalStore(path: fixture.path, key: fixture.key)
        for index in 0..<41 {
            let dialogId = "revoked-\(index)"
            try await store.upsertDialog(dialogId: dialogId, type: "group", title: "Revoked")
            try await store.revokeGroupAccess(
                dialogId: dialogId, reason: "dialog.access_revoked"
            )
        }
        let stagedCount = try await store.pendingAccessPurgeCount()
        XCTAssertEqual(stagedCount, 41)
        let cache = try EncryptedMediaCache(
            root: URL(fileURLWithPath: fixture.path)
                .deletingLastPathComponent()
                .appending(path: "batch-cache", directoryHint: .isDirectory),
            keyData: Data(repeating: 0x71, count: 32),
            limitBytes: 1_000_000
        )
        let result = try await AccessPurgeCoordinator().drain(
            scope: AccessPurgeScope(
                accountId: "batch-account", token: "batch-token", generation: 1, store: store
            ),
            store: store,
            mediaEngine: CloudMediaTransferEngine(cache: cache),
            isCurrent: { true },
            invalidatePresentation: { _ in }
        )
        XCTAssertEqual(result.finalized, 41)
        XCTAssertEqual(result.batches, 3)
        let remainingCount = try await store.pendingAccessPurgeCount()
        XCTAssertEqual(remainingCount, 0)
    }

    @MainActor
    func testAccessPurgeResumesAfterFilesDeletedCrashBoundary() async throws {
        let fixture = try makeStoreFixture()
        do {
            let firstStore = try CloudLocalStore(path: fixture.path, key: fixture.key)
            try await firstStore.upsertDialog(
                dialogId: "crash-dialog", type: "group", title: "Crash"
            )
            try await firstStore.revokeGroupAccess(
                dialogId: "crash-dialog", reason: "dialog.access_revoked"
            )
            let jobs = try await firstStore.pendingAccessPurgeJobs()
            let job = try XCTUnwrap(jobs.first)
            try await firstStore.markAccessPurgeFilesDeleted(id: job.id)
            let pendingCount = try await firstStore.pendingAccessPurgeCount()
            XCTAssertEqual(pendingCount, 1)
        }

        let relaunched = try CloudLocalStore(path: fixture.path, key: fixture.key)
        let cache = try EncryptedMediaCache(
            root: URL(fileURLWithPath: fixture.path)
                .deletingLastPathComponent()
                .appending(path: "crash-cache", directoryHint: .isDirectory),
            keyData: Data(repeating: 0x72, count: 32),
            limitBytes: 1_000_000
        )
        let result = try await AccessPurgeCoordinator().drain(
            scope: AccessPurgeScope(
                accountId: "crash-account", token: "crash-token", generation: 2,
                store: relaunched
            ),
            store: relaunched,
            mediaEngine: CloudMediaTransferEngine(cache: cache),
            isCurrent: { true },
            invalidatePresentation: { _ in }
        )
        XCTAssertEqual(result.finalized, 1)
        let remainingCount = try await relaunched.pendingAccessPurgeCount()
        let timeline = try await relaunched.timeline(dialogId: "crash-dialog")
        XCTAssertEqual(remainingCount, 0)
        XCTAssertTrue(timeline.messages.isEmpty)
    }

    @MainActor
    func testOfflineLaunchDrainsRevokedArchiveBeforePublishingSnapshot() async throws {
        let fixture = try makeStoreFixture()
        let store = try CloudLocalStore(path: fixture.path, key: fixture.key)
        let accountId = "offline-launch-account"
        let dialogId = "offline-launch-saved"
        try await store.ensureSavedDialog(dialogId: dialogId, accountId: accountId, updatedAt: nil)
        _ = try await store.insertSending(
            dialogId: dialogId, clientMsgId: UUID().uuidString.lowercased(),
            text: "must never flash on launch", senderAccountId: accountId
        )
        try await store.revokeGroupAccess(dialogId: dialogId, reason: "dialog.access_revoked")
        let stagedJobs = try await store.pendingAccessPurgeJobs()
        XCTAssertEqual(stagedJobs.count, 1)

        let tokenStore = TokenStore(service: "com.toj.offline-purge.\(UUID().uuidString)")
        try await tokenStore.save(StoredCloudSession(
            session: CloudSession(
                accountId: accountId, deviceId: "offline-device", token: "offline-token"
            ),
            phone: "+992900000002",
            displayName: "Offline Account"
        ))
        let config = CloudConfig(
            baseURL: try XCTUnwrap(URL(string: "https://offline-purge.invalid"))
        )
        let model = CloudAppModel(
            config: config,
            tokenStore: tokenStore,
            localStore: store,
            useDefaultLocalStore: false,
            capabilityDefaults: UserDefaults(suiteName: "offline-purge-\(UUID().uuidString)")!
        )

        await model.prepareForBackgroundRuntime()

        let remainingJobs = try await store.pendingAccessPurgeCount()
        let timeline = try await store.timeline(dialogId: dialogId)
        XCTAssertEqual(model.launchPhase, .localReady)
        XCTAssertFalse(model.dialogs.contains { $0.id == dialogId })
        XCTAssertEqual(remainingJobs, 0)
        XCTAssertTrue(timeline.messages.isEmpty)
        try await tokenStore.clear()
    }

    @MainActor
    func testAccessPurgeAccountSwitchCancelsAndAwaitsExactOldScope() async throws {
        let oldFixture = try makeStoreFixture()
        let newFixture = try makeStoreFixture()
        let oldStore = try CloudLocalStore(path: oldFixture.path, key: oldFixture.key)
        let newStore = try CloudLocalStore(path: newFixture.path, key: newFixture.key)
        try await oldStore.upsertDialog(dialogId: "old-revoked", type: "group", title: "Old")
        try await oldStore.revokeGroupAccess(
            dialogId: "old-revoked", reason: "dialog.access_revoked"
        )
        try await newStore.upsertDialog(dialogId: "new-revoked", type: "group", title: "New")
        try await newStore.revokeGroupAccess(
            dialogId: "new-revoked", reason: "dialog.access_revoked"
        )
        let oldCache = try EncryptedMediaCache(
            root: URL(fileURLWithPath: oldFixture.path)
                .deletingLastPathComponent().appending(path: "cache", directoryHint: .isDirectory),
            keyData: Data(repeating: 0x73, count: 32), limitBytes: 1_000_000
        )
        let newCache = try EncryptedMediaCache(
            root: URL(fileURLWithPath: newFixture.path)
                .deletingLastPathComponent().appending(path: "cache", directoryHint: .isDirectory),
            keyData: Data(repeating: 0x74, count: 32), limitBytes: 1_000_000
        )
        let coordinator = AccessPurgeCoordinator()
        let oldPurgeGate = SavedMessagesAsyncGate()
        let cancellationObserved = SavedMessagesAsyncGate()
        let oldTask = Task {
            try await coordinator.drain(
                scope: AccessPurgeScope(
                    accountId: "old-account", token: "old-token", generation: 1, store: oldStore
                ),
                store: oldStore,
                mediaEngine: CloudMediaTransferEngine(cache: oldCache),
                isCurrent: { true },
                invalidatePresentation: { _ in
                    await withTaskCancellationHandler {
                        await oldPurgeGate.wait()
                    } onCancel: {
                        Task { await cancellationObserved.open() }
                    }
                }
            )
        }
        await oldPurgeGate.waitUntilBlocked()
        let newTask = Task {
            try await coordinator.drain(
                scope: AccessPurgeScope(
                    accountId: "new-account", token: "new-token", generation: 2, store: newStore
                ),
                store: newStore,
                mediaEngine: CloudMediaTransferEngine(cache: newCache),
                isCurrent: { true },
                invalidatePresentation: { _ in }
            )
        }
        await cancellationObserved.wait()
        await oldPurgeGate.open()
        let newResult = try await newTask.value
        do {
            _ = try await oldTask.value
            XCTFail("old account purge must be cancelled")
        } catch is CancellationError {
            // Expected: the exact old task was cancelled and awaited before the new scope ran.
        }
        XCTAssertEqual(newResult.finalized, 1)
        let oldCount = try await oldStore.pendingAccessPurgeCount()
        let newCount = try await newStore.pendingAccessPurgeCount()
        XCTAssertEqual(oldCount, 1)
        XCTAssertEqual(newCount, 0)
    }

    @MainActor
    func testComposerPreparationIsAwaitedBeforePurgeFinalization() async throws {
        let fixture = try makeStoreFixture()
        let store = try CloudLocalStore(path: fixture.path, key: fixture.key)
        let dialogId = "composer-revoked"
        try await store.upsertDialog(dialogId: dialogId, type: "group", title: "Composer")
        try await store.revokeGroupAccess(dialogId: dialogId, reason: "dialog.access_revoked")
        let cache = try EncryptedMediaCache(
            root: URL(fileURLWithPath: fixture.path).deletingLastPathComponent()
                .appending(path: "composer-cache", directoryHint: .isDirectory),
            keyData: Data(repeating: 0x75, count: 32), limitBytes: 1_000_000
        )
        let model = CloudAppModel(
            config: CloudConfig(baseURL: try XCTUnwrap(URL(string: "https://composer.invalid"))),
            useDefaultLocalStore: false,
            capabilityDefaults: UserDefaults(suiteName: UUID().uuidString)!
        )
        let preparationGate = SavedMessagesAsyncGate()
        let cancellationObserved = SavedMessagesAsyncGate()
        let released = SavedMessagesCompletionProbe()
        let preparation = Task {
            await withTaskCancellationHandler {
                await preparationGate.wait()
            } onCancel: {
                Task { await cancellationObserved.open() }
            }
            await released.markCompleted()
        }
        await preparationGate.waitUntilBlocked()
        model.testTrackComposerPreparation(dialogId: dialogId, task: preparation)
        let coordinator = AccessPurgeCoordinator()
        let drain = Task {
            try await coordinator.drain(
                scope: AccessPurgeScope(
                    accountId: "composer-account", token: "token", generation: 1, store: store
                ),
                store: store,
                mediaEngine: CloudMediaTransferEngine(cache: cache),
                isCurrent: { true },
                invalidatePresentation: { job in
                    await model.testInvalidatePresentationForAccessPurge(job)
                },
                purgeFilesOverride: { _ in
                    guard await released.value else {
                        throw SavedMessagesInjectedPurgeError()
                    }
                }
            )
        }
        await cancellationObserved.wait()
        let pendingBeforeRelease = try await store.pendingAccessPurgeCount()
        XCTAssertEqual(pendingBeforeRelease, 1)
        await preparationGate.open()
        let drainResult = try await drain.value
        let pendingAfterRelease = try await store.pendingAccessPurgeCount()
        XCTAssertEqual(drainResult.finalized, 1)
        XCTAssertEqual(pendingAfterRelease, 0)
    }

    func testRevokedDialogRejectsPreparedAndSendingMediaAndPreparedBytesAreDiscarded() async throws {
        let fixture = try makeStoreFixture()
        let store = try CloudLocalStore(path: fixture.path, key: fixture.key)
        let dialogId = "late-prepared-media"
        try await store.upsertDialog(dialogId: dialogId, type: "group", title: "Revoked")
        try await store.revokeGroupAccess(dialogId: dialogId, reason: "dialog.access_revoked")
        let cache = try EncryptedMediaCache(
            root: URL(fileURLWithPath: fixture.path).deletingLastPathComponent()
                .appending(path: "prepared-rejection-cache", directoryHint: .isDirectory),
            keyData: Data(repeating: 0x76, count: 32), limitBytes: 1_000_000
        )
        let engine = CloudMediaTransferEngine(cache: cache)
        let prepared = try await engine.prepare(
            data: Data("newly prepared bytes".utf8),
            kind: "file",
            contentType: "application/octet-stream",
            fileName: "late.bin"
        )
        do {
            try await store.insertMediaTransfer(
                prepared: prepared,
                dialogId: dialogId,
                clientMsgId: UUID().uuidString.lowercased(),
                caption: "",
                replyToMsgId: nil
            )
            XCTFail("revoked dialog accepted a prepared transfer")
        } catch CloudLocalStoreAccessError.revoked {
            await engine.discardPrepared(prepared)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.encryptedSourcePath))

        let transfer = MediaTransferRecord(
            transferId: prepared.transferId,
            dialogId: dialogId,
            clientMsgId: UUID().uuidString.lowercased(),
            caption: "",
            replyToMsgId: nil,
            kind: prepared.kind,
            contentType: prepared.contentType,
            fileName: prepared.fileName,
            byteSize: prepared.byteSize,
            sha256: prepared.sha256,
            durationMs: nil,
            width: nil,
            height: nil,
            encryptedSourcePath: prepared.encryptedSourcePath,
            encryptedThumbnailPath: nil,
            mediaId: nil,
            uploadOffset: 0,
            state: "pending",
            retryCount: 0,
            nextRetryAt: nil,
            lastError: nil,
            terminal: false
        )
        do {
            try await store.insertSendingMedia(transfer, senderAccountId: "account-me")
            XCTFail("revoked dialog accepted an optimistic media row")
        } catch CloudLocalStoreAccessError.revoked {
            // Expected.
        }
    }

    @MainActor
    func testConcurrentResetCallersAwaitOneUncooperativePurgeBarrier() async throws {
        let fixture = try makeStoreFixture()
        let store = try CloudLocalStore(path: fixture.path, key: fixture.key)
        try await store.upsertDialog(dialogId: "reset-revoked", type: "group", title: "Reset")
        try await store.revokeGroupAccess(
            dialogId: "reset-revoked", reason: "dialog.access_revoked"
        )
        let cache = try EncryptedMediaCache(
            root: URL(fileURLWithPath: fixture.path).deletingLastPathComponent()
                .appending(path: "reset-cache", directoryHint: .isDirectory),
            keyData: Data(repeating: 0x77, count: 32), limitBytes: 1_000_000
        )
        let purgeGate = SavedMessagesAsyncGate()
        let cancellationObserved = SavedMessagesAsyncGate()
        let coordinator = AccessPurgeCoordinator()
        let drain = Task {
            try await coordinator.drain(
                scope: AccessPurgeScope(
                    accountId: "reset-account", token: "token", generation: 1, store: store
                ),
                store: store,
                mediaEngine: CloudMediaTransferEngine(cache: cache),
                isCurrent: { true },
                invalidatePresentation: { _ in
                    await withTaskCancellationHandler {
                        await purgeGate.wait()
                    } onCancel: {
                        Task { await cancellationObserved.open() }
                    }
                }
            )
        }
        await purgeGate.waitUntilBlocked()
        let firstCompleted = SavedMessagesCompletionProbe()
        let secondCompleted = SavedMessagesCompletionProbe()
        let firstReset = Task {
            await coordinator.reset()
            await firstCompleted.markCompleted()
        }
        await cancellationObserved.wait()
        while !(await coordinator.testHasResetBarrier()) { await Task.yield() }
        let secondReset = Task {
            await coordinator.reset()
            await secondCompleted.markCompleted()
        }
        await Task.yield()
        let firstFinishedEarly = await firstCompleted.value
        let secondFinishedEarly = await secondCompleted.value
        XCTAssertFalse(firstFinishedEarly)
        XCTAssertFalse(secondFinishedEarly)
        await purgeGate.open()
        await firstReset.value
        await secondReset.value
        let firstFinished = await firstCompleted.value
        let secondFinished = await secondCompleted.value
        XCTAssertTrue(firstFinished)
        XCTAssertTrue(secondFinished)
        do {
            _ = try await drain.value
            XCTFail("reset must cancel the shared purge")
        } catch is CancellationError {
            // Expected.
        }
    }

    @MainActor
    func testConcurrentClearLocalSessionCallersAwaitOneUncooperativeBarrier() async throws {
        let model = CloudAppModel(
            config: CloudConfig(baseURL: try XCTUnwrap(URL(string: "https://clear.invalid"))),
            tokenStore: TokenStore(service: "com.toj.clear.\(UUID().uuidString)"),
            useDefaultLocalStore: false,
            capabilityDefaults: UserDefaults(suiteName: UUID().uuidString)!
        )
        let composerGate = SavedMessagesAsyncGate()
        let cancellationObserved = SavedMessagesAsyncGate()
        let composer = Task {
            await withTaskCancellationHandler {
                await composerGate.wait()
            } onCancel: {
                Task { await cancellationObserved.open() }
            }
        }
        await composerGate.waitUntilBlocked()
        model.testTrackComposerPreparation(dialogId: "clear-dialog", task: composer)

        let firstCompleted = SavedMessagesCompletionProbe()
        let secondCompleted = SavedMessagesCompletionProbe()
        let firstClear = Task { @MainActor in
            await model.testClearLocalSession()
            await firstCompleted.markCompleted()
        }
        await cancellationObserved.wait()
        XCTAssertTrue(model.testHasSessionClearBarrier())
        let secondClear = Task { @MainActor in
            await model.testClearLocalSession()
            await secondCompleted.markCompleted()
        }
        await Task.yield()
        let firstFinishedEarly = await firstCompleted.value
        let secondFinishedEarly = await secondCompleted.value
        XCTAssertFalse(firstFinishedEarly)
        XCTAssertFalse(secondFinishedEarly)

        await composerGate.open()
        await firstClear.value
        await secondClear.value
        let firstFinished = await firstCompleted.value
        let secondFinished = await secondCompleted.value
        XCTAssertTrue(firstFinished)
        XCTAssertTrue(secondFinished)
        XCTAssertFalse(model.testHasSessionClearBarrier())
    }

    func testCancelledTemporaryPreviewDeletesPlaintextBeforeOwnershipTransfer() async throws {
        let fixture = try makeStoreFixture()
        let cache = try EncryptedMediaCache(
            root: URL(fileURLWithPath: fixture.path).deletingLastPathComponent()
                .appending(path: "preview-cache", directoryHint: .isDirectory),
            keyData: Data(repeating: 0x78, count: 32), limitBytes: 1_000_000
        )
        let engine = CloudMediaTransferEngine(cache: cache)
        let ownershipGate = SavedMessagesAsyncGate()
        let recorder = SavedMessagesURLRecorder()
        let previewTask = Task {
            try await engine.temporaryPreview(
                data: Data("plaintext preview".utf8),
                fileExtension: "bin"
            ) { url in
                await recorder.record(url)
                await ownershipGate.wait()
                return !Task.isCancelled
            }
        }
        let url = await recorder.waitForURL()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        previewTask.cancel()
        await ownershipGate.open()
        let transferred = try await previewTask.value
        XCTAssertFalse(transferred)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
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
            "Media access was revoked",
            "Offline conversation could not be opened",
            "Save something for yourself",
            "Saved Messages could not be set up",
            "Saved Messages access ended",
            "Saved to Saved Messages",
            "Setting up…",
            "Synced across your devices",
            "The dialog is no longer authorized for this account",
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

    private static func applyCanonicalMedia(
        store: CloudLocalStore,
        accountId: String,
        dialogId: String,
        dialogType: String,
        media: CloudMedia,
        pts: Int64,
        msgId: Int64,
        forwarded: Bool = false
    ) async throws {
        try await store.applyDifference(
            DifferenceResponse(
                kind: "difference",
                state: .init(pts: pts),
                updates: [CloudUpdate(
                    pts: pts, ptsCount: 1, type: "message.new",
                    dialogId: dialogId,
                    dialogTitle: dialogType == "saved" ? "Saved Messages" : "Peer",
                    dialogType: dialogType,
                    message: CloudMessage(
                        dialogId: dialogId, msgId: msgId, senderAccountId: accountId,
                        clientMsgId: UUID().uuidString.lowercased(), kind: media.kind,
                        text: "", isForwarded: forwarded, media: media, editVersion: 0,
                        state: "visible", serverTs: "2026-07-27T00:00:00Z"
                    ),
                    readerAccountId: nil, maxReadMsgId: nil
                )],
                hasMore: false
            ),
            accountId: accountId
        )
    }

    private static func applyRevocation(
        store: CloudLocalStore,
        accountId: String,
        dialogId: String,
        pts: Int64
    ) async throws {
        try await store.applyDifference(
            DifferenceResponse(
                kind: "difference",
                state: .init(pts: pts),
                updates: [CloudUpdate(
                    pts: pts, ptsCount: 1, type: "dialog.access_revoked",
                    dialogId: dialogId, dialogTitle: nil, dialogType: "saved",
                    message: nil, readerAccountId: nil, maxReadMsgId: nil
                )],
                hasMore: false
            ),
            accountId: accountId
        )
    }
}

private struct SavedMessagesInjectedPurgeError: LocalizedError {
    var errorDescription: String? { "deterministic purge failure" }
}

private actor SavedMessagesCancellationProbe {
    private var cancelled = false

    func markCancelled() {
        cancelled = true
    }

    var value: Bool { cancelled }
}

private actor SavedMessagesCompletionProbe {
    private var completed = false

    func markCompleted() {
        completed = true
    }

    var value: Bool { completed }
}

private actor SavedMessagesURLRecorder {
    private var url: URL?
    private var waiters: [CheckedContinuation<URL, Never>] = []

    func record(_ value: URL) {
        url = value
        let waiting = waiters
        waiters.removeAll()
        waiting.forEach { $0.resume(returning: value) }
    }

    func waitForURL() async -> URL {
        if let url { return url }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private actor SavedMessagesAsyncGate {
    private var waitContinuation: CheckedContinuation<Void, Never>?
    private var blockedContinuation: CheckedContinuation<Void, Never>?
    private var isBlocked = false
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        isBlocked = true
        blockedContinuation?.resume()
        blockedContinuation = nil
        await withCheckedContinuation { continuation in
            waitContinuation = continuation
        }
    }

    func waitUntilBlocked() async {
        if isBlocked { return }
        await withCheckedContinuation { continuation in
            blockedContinuation = continuation
        }
    }

    func open() {
        isOpen = true
        waitContinuation?.resume()
        waitContinuation = nil
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
