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
                        token: "token"
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
            token: "token"
        )
        XCTAssertEqual(local, "saved-coalesced")
        XCTAssertEqual(requestCounter.value, 1)
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
