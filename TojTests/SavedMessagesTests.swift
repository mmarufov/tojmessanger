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
            "Saved to Saved Messages",
            "Setting up…",
            "Synced across your devices",
            "Try offline copy again",
            "Unavailable",
            "Unavailable on this server",
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
