import XCTest
import GRDB
import Security
@testable import Toj

final class CloudLocalStoreTests: XCTestCase {
    func testAccountDeletionRequestUsesBearerAndPurposeCodeBody() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudAPIMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let config = CloudConfig(baseURL: try XCTUnwrap(URL(string: "https://cloud.example.test/cloud")))
        let api = CloudAPI(config: config, session: session)
        CloudAPIMockURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(request.url?.path, "/cloud/v1/account")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer session-token")
            let body = try XCTUnwrap(CloudAPIMockURLProtocol.bodyData(from: request))
            XCTAssertEqual(try JSONSerialization.jsonObject(with: body) as? [String: String], ["code": "123456"])
            let response = try XCTUnwrap(HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["content-type": "application/json"]
            ))
            return (response, Data("{\"deleted\":true}".utf8))
        }
        defer { CloudAPIMockURLProtocol.handler = nil }

        let response = try await api.deleteAccount(code: "123456", token: "session-token")
        XCTAssertTrue(response.deleted)
    }

    func testAPNsDeviceTokenUsesLowercaseTwoDigitHex() {
        let token = PushRegistrationCenter.hexadecimalToken(from: Data([0x00, 0x01, 0x0f, 0xa0, 0xff]))
        XCTAssertEqual(token, "00010fa0ff")
    }

    func testPushActivationIsFrozenByDefault() {
        XCTAssertFalse(PushRegistrationCenter.isEnabled)
    }

    func testCloudWebSocketURLDoesNotContainBearerToken() throws {
        let config = CloudConfig(baseURL: try XCTUnwrap(URL(string: "https://cloud.example.test/cloud")))
        let url = config.wsURL()
        XCTAssertEqual(url.absoluteString, "wss://cloud.example.test/cloud/v1/ws")
        XCTAssertNil(URLComponents(url: url, resolvingAgainstBaseURL: false)?.query)
    }

    @MainActor
    func testMessageMutationRequestsCarryStableIdentifiersAndVersions() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudAPIMockURLProtocol.self]
        let api = CloudAPI(
            config: CloudConfig(baseURL: try XCTUnwrap(URL(string: "https://cloud.example.test/cloud"))),
            session: URLSession(configuration: configuration)
        )
        var requests: [(String, [String: Any])] = []
        CloudAPIMockURLProtocol.handler = { request in
            let body = try XCTUnwrap(CloudAPIMockURLProtocol.bodyData(from: request))
            requests.append((request.url!.path, try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])))
            let response = try XCTUnwrap(HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["content-type": "application/json"]
            ))
            let state = request.url!.path.hasSuffix("delete") ? "deleted_for_all" : "visible"
            let text = state == "visible" ? "corrected" : ""
            return (response, Data("""
            {"dialogId":"dialog-1","msgId":7,"actorPts":9,"duplicate":false,"message":{
              "dialog_id":"dialog-1","msg_id":7,"sender_account_id":"account-a",
              "client_msg_id":"11111111-1111-1111-1111-111111111111","kind":"text",
              "text":"\(text)","reply_to_msg_id":null,"edit_version":1,"state":"\(state)",
              "server_ts":"2026-07-12T00:00:00Z"}}
            """.utf8))
        }
        defer { CloudAPIMockURLProtocol.handler = nil }

        _ = try await api.editMessage(
            dialogId: "dialog-1", msgId: 7,
            clientMutationId: "22222222-2222-2222-2222-222222222222",
            expectedEditVersion: 0, body: "corrected", token: "session-token"
        )
        _ = try await api.deleteMessage(
            dialogId: "dialog-1", msgId: 7,
            clientMutationId: "33333333-3333-3333-3333-333333333333",
            token: "session-token"
        )

        XCTAssertEqual(requests.map(\.0), ["/cloud/v1/messages/edit", "/cloud/v1/messages/delete"])
        XCTAssertEqual(requests[0].1["expectedEditVersion"] as? Int, 0)
        XCTAssertEqual(requests[0].1["clientMutationId"] as? String, "22222222-2222-2222-2222-222222222222")
        XCTAssertEqual(requests[1].1["msgId"] as? Int, 7)
    }

    func testPendingSessionRevocationTokenPersistsSeparately() async throws {
        let store = TokenStore()
        try? await store.clearPendingRevocationToken()
        try await store.savePendingRevocationToken("test-revocation-token")
        let loaded = try await store.loadPendingRevocationToken()
        XCTAssertEqual(loaded, "test-revocation-token")
        try await store.clearPendingRevocationToken()
        let cleared = try await store.loadPendingRevocationToken()
        XCTAssertNil(cleared)
    }

    func testCloudConfigPersistsInjectedURLForManualRelaunch() throws {
        let suiteName = "CloudConfigTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let expected = try XCTUnwrap(URL(string: "https://cloud.example.test/cloud"))

        let injected = CloudConfig.resolve(
            environment: ["TOJ_CLOUD_BASE_URL": expected.absoluteString],
            defaults: defaults
        )
        let restored = CloudConfig.resolve(environment: [:], defaults: defaults)

        XCTAssertEqual(injected.baseURL, expected)
        XCTAssertEqual(restored.baseURL, expected)
    }

    func testLocalDatabaseKeyPersistsAcrossLookups() throws {
        let service = "com.toj.tests.cloud-db.\(UUID().uuidString)"
        let account = "sqlcipher-key"
        let store = LocalDatabaseKeyStore(service: service, account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        defer { SecItemDelete(query as CFDictionary) }

        let created = try store.loadOrCreateKey()
        let loaded = try store.loadOrCreateKey()

        XCTAssertEqual(loaded, created)
    }

    @MainActor
    func testLocalStorePersistsSendReconcileAndDifference() async throws {
        let store = try makeStore()
        let accountId = "account-a"
        let peerId = "account-b"
        let dialogId = "dialog-1"
        let clientMsgId = UUID().uuidString.lowercased()

        let initialPts = try await store.loadPts(accountId: accountId)
        XCTAssertEqual(initialPts, 0)
        try await store.upsertDialog(dialogId: dialogId, title: "Bob")

        let pending = try await store.insertSending(
            dialogId: dialogId,
            clientMsgId: clientMsgId,
            text: "local first",
            senderAccountId: accountId
        )
        let pendingState = pending.localState
        let pendingMsgId = pending.msgId
        XCTAssertEqual(pendingState, "sending")
        XCTAssertNil(pendingMsgId)

        var dueOutbox = try await store.pendingOutboxReady()
        XCTAssertEqual(dueOutbox.map(\.clientMsgId), [clientMsgId])

        try await store.markFailed(clientMsgId: clientMsgId, retryAfter: 60)
        dueOutbox = try await store.pendingOutboxReady()
        let retryDelay = try await store.nextPendingOutboxDelay()
        XCTAssertTrue(dueOutbox.isEmpty)
        XCTAssertNotNil(retryDelay)

        try await store.markRetrying(clientMsgId: clientMsgId)
        dueOutbox = try await store.pendingOutboxReady()
        XCTAssertEqual(dueOutbox.map(\.clientMsgId), [clientMsgId])

        try await store.markSent(
            SendMessageResponse(
                dialogId: dialogId,
                clientMsgId: clientMsgId,
                msgId: 1,
                senderPts: 2,
                duplicate: false,
                serverTs: "2026-07-09T00:00:00Z",
                text: "local first"
            ),
            senderAccountId: accountId
        )

        var messages = try await store.messages(dialogId: dialogId)
        XCTAssertEqual(messages.count, 1)
        let sentMsgId = messages[0].msgId
        let sentState = messages[0].localState
        XCTAssertEqual(sentMsgId, 1)
        XCTAssertEqual(sentState, "sent")
        dueOutbox = try await store.pendingOutboxReady()
        XCTAssertTrue(dueOutbox.isEmpty)

        let remote = CloudMessage(
            dialogId: dialogId,
            msgId: 2,
            senderAccountId: peerId,
            clientMsgId: UUID().uuidString.lowercased(),
            kind: "text",
            text: "remote reply",
            editVersion: 0,
            state: "visible",
            serverTs: "2026-07-09T00:00:01Z"
        )
        let update = CloudUpdate(
            pts: 3,
            ptsCount: 1,
            type: "message.new",
            dialogId: dialogId,
            dialogTitle: "Bob",
            message: remote,
            readerAccountId: nil,
            maxReadMsgId: nil
        )
        try await store.applyDifference(
            DifferenceResponse(
                kind: "difference",
                state: DifferenceResponse.State(pts: 3),
                updates: [update],
                hasMore: false
            ),
            accountId: accountId
        )
        let readUpdate = CloudUpdate(
            pts: 4,
            ptsCount: 1,
            type: "read.updated",
            dialogId: dialogId,
            dialogTitle: "Bob",
            message: nil,
            readerAccountId: peerId,
            maxReadMsgId: 1
        )
        try await store.applyDifference(
            DifferenceResponse(
                kind: "difference",
                state: DifferenceResponse.State(pts: 4),
                updates: [readUpdate],
                hasMore: false
            ),
            accountId: accountId
        )

        messages = try await store.messages(dialogId: dialogId)
        let texts = messages.map(\.text)
        let finalPts = try await store.loadPts(accountId: accountId)
        let latestDialogId = try await store.latestDialogId()
        let peerReadMsgId = try await store.maxPeerReadMsgId(dialogId: dialogId, excluding: accountId)
        XCTAssertEqual(texts, ["local first", "remote reply"])
        XCTAssertEqual(finalPts, 4)
        XCTAssertEqual(latestDialogId, dialogId)
        XCTAssertEqual(peerReadMsgId, 1)

        let dialogs = try await store.dialogs(accountId: accountId)
        XCTAssertEqual(dialogs.map(\.title), ["Bob"])
        XCTAssertEqual(dialogs.map(\.lastText), ["remote reply"])
    }

    @MainActor
    func testDifferencePersistsDirectPeerTitle() async throws {
        let store = try makeStore()
        let accountId = "account-a"
        let dialogId = "dialog-incoming"

        try await store.applyDifference(
            DifferenceResponse(
                kind: "difference",
                state: DifferenceResponse.State(pts: 1),
                updates: [
                    CloudUpdate(
                        pts: 1,
                        ptsCount: 1,
                        type: "dialog.created",
                        dialogId: dialogId,
                        dialogTitle: "Bob",
                        message: nil,
                        readerAccountId: nil,
                        maxReadMsgId: nil
                    )
                ],
                hasMore: false
            ),
            accountId: accountId
        )

        let dialogs = try await store.dialogs(accountId: accountId)
        XCTAssertEqual(dialogs.map(\.dialogId), [dialogId])
        XCTAssertEqual(dialogs.map(\.title), ["Bob"])
    }

    @MainActor
    func testBootstrapPageDoesNotAdvancePtsUntilFinished() async throws {
        let store = try makeStore()
        let accountId = "account-a"
        let peerId = "account-b"
        let dialogId = "dialog-bootstrap"
        let bootstrapMessage = CloudMessage(
            dialogId: dialogId,
            msgId: 9,
            senderAccountId: peerId,
            clientMsgId: UUID().uuidString.lowercased(),
            kind: "text",
            text: "snapshot message",
            editVersion: 0,
            state: "visible",
            serverTs: "2026-07-09T00:00:09Z"
        )
        let page = BootstrapDialogsPage(
            token: "bootstrap-token",
            state: BootstrapDialogsPage.State(pts: 44),
            dialogs: [
                BootstrapDialog(
                    dialogId: dialogId,
                    type: "direct",
                    title: "Alice",
                    lastMsgId: 9,
                    updatedAt: "2026-07-09T00:00:09Z",
                    members: [
                        BootstrapDialogMember(accountId: accountId, role: "member", lastReadMsgId: 0),
                        BootstrapDialogMember(accountId: peerId, role: "member", lastReadMsgId: 0)
                    ],
                    messages: [bootstrapMessage]
                )
            ],
            nextCursor: nil,
            hasMore: false
        )

        try await store.savePts(17, accountId: accountId)
        try await store.beginBootstrap(accountId: accountId)
        try await store.applyBootstrapPage(page)
        let olderMessage = CloudMessage(
            dialogId: dialogId,
            msgId: 3,
            senderAccountId: accountId,
            clientMsgId: UUID().uuidString.lowercased(),
            kind: "text",
            text: "older message",
            editVersion: 0,
            state: "visible",
            serverTs: "2026-07-09T00:00:03Z"
        )
        try await store.applyHistoryPage(
            HistoryPageResponse(
                dialogId: dialogId,
                messages: [olderMessage],
                nextBeforeMsgId: nil,
                hasMore: false
            )
        )

        let messages = try await store.messages(dialogId: dialogId)
        let oldestMsgId = try await store.oldestServerMsgId(dialogId: dialogId)
        let ptsBeforeFinish = try await store.loadPts(accountId: accountId)
        XCTAssertEqual(messages.map(\.text), ["older message", "snapshot message"])
        XCTAssertEqual(oldestMsgId, 3)
        XCTAssertEqual(ptsBeforeFinish, 0)

        try await store.finishBootstrap(accountId: accountId, pts: page.state.pts)
        let ptsAfterFinish = try await store.loadPts(accountId: accountId)
        let latestDialogId = try await store.latestDialogId()
        let dialogs = try await store.dialogs(accountId: accountId)
        XCTAssertEqual(ptsAfterFinish, 44)
        XCTAssertEqual(latestDialogId, dialogId)
        XCTAssertEqual(dialogs.first?.title, "Alice")
        XCTAssertEqual(dialogs.first?.lastText, "snapshot message")
    }

    @MainActor
    func testUnreadCountsOnlyVisiblePeerMessagesAfterReadPosition() async throws {
        let store = try makeStore()
        let accountId = "account-me"
        let peerId = "account-peer"
        let dialogId = "dialog-unread"

        try await store.upsertDialog(dialogId: dialogId, title: "Mehrona")
        try await store.saveMembers(dialogId: dialogId, members: [
            BootstrapDialogMember(accountId: accountId, role: "member", lastReadMsgId: 0),
            BootstrapDialogMember(accountId: peerId, role: "member", lastReadMsgId: 0),
        ])

        let messages = [
            CloudMessage(
                dialogId: dialogId,
                msgId: 1,
                senderAccountId: peerId,
                clientMsgId: UUID().uuidString,
                kind: "text",
                text: "peer one",
                editVersion: 0,
                state: "visible",
                serverTs: "2026-07-12T10:00:00Z"
            ),
            CloudMessage(
                dialogId: dialogId,
                msgId: 2,
                senderAccountId: accountId,
                clientMsgId: UUID().uuidString,
                kind: "text",
                text: "my reply",
                editVersion: 0,
                state: "visible",
                serverTs: "2026-07-12T10:00:01Z"
            ),
            CloudMessage(
                dialogId: dialogId,
                msgId: 3,
                senderAccountId: peerId,
                clientMsgId: UUID().uuidString,
                kind: "text",
                text: "peer two",
                editVersion: 0,
                state: "visible",
                serverTs: "2026-07-12T10:00:02Z"
            ),
        ]

        for (index, message) in messages.enumerated() {
            try await store.applyDifference(
                DifferenceResponse(
                    kind: "difference",
                    state: DifferenceResponse.State(pts: Int64(index + 1)),
                    updates: [
                        CloudUpdate(
                            pts: Int64(index + 1),
                            ptsCount: 1,
                            type: "message.new",
                            dialogId: dialogId,
                            dialogTitle: "Mehrona",
                            message: message,
                            readerAccountId: nil,
                            maxReadMsgId: nil
                        )
                    ],
                    hasMore: false
                ),
                accountId: accountId
            )
        }

        var dialogs = try await store.dialogs(accountId: accountId)
        XCTAssertEqual(dialogs.first?.unreadCount, 2, "The current user's own message must not count as unread")

        try await store.markRead(dialogId: dialogId, accountId: accountId, maxReadMsgId: 1)
        dialogs = try await store.dialogs(accountId: accountId)
        XCTAssertEqual(dialogs.first?.unreadCount, 1)

        try await store.markRead(dialogId: dialogId, accountId: accountId, maxReadMsgId: 3)
        dialogs = try await store.dialogs(accountId: accountId)
        XCTAssertEqual(dialogs.first?.unreadCount, 0)
    }

    @MainActor
    func testReplyEditAndDeletePersistAcrossLocalReplicaReloads() async throws {
        let store = try makeStore()
        let accountId = "account-me"
        let peerId = "account-peer"
        let dialogId = "dialog-actions"
        let originalClientId = UUID().uuidString
        let replyClientId = UUID().uuidString

        func update(_ pts: Int64, type: String, message: CloudMessage) -> DifferenceResponse {
            DifferenceResponse(
                kind: "difference",
                state: DifferenceResponse.State(pts: pts),
                updates: [CloudUpdate(
                    pts: pts,
                    ptsCount: 1,
                    type: type,
                    dialogId: dialogId,
                    dialogTitle: "Mehrona",
                    message: message,
                    readerAccountId: nil,
                    maxReadMsgId: nil
                )],
                hasMore: false
            )
        }

        let original = CloudMessage(
            dialogId: dialogId, msgId: 1, senderAccountId: peerId,
            clientMsgId: originalClientId, kind: "text", text: "before",
            editVersion: 0, state: "visible", serverTs: "2026-07-12T10:00:00Z"
        )
        let reply = CloudMessage(
            dialogId: dialogId, msgId: 2, senderAccountId: accountId,
            clientMsgId: replyClientId, kind: "text", text: "reply",
            replyToMsgId: 1, editVersion: 0, state: "visible", serverTs: "2026-07-12T10:00:01Z"
        )
        try await store.applyDifference(update(1, type: "message.new", message: original), accountId: accountId)
        try await store.applyDifference(update(2, type: "message.new", message: reply), accountId: accountId)

        let edited = CloudMessage(
            dialogId: dialogId, msgId: 1, senderAccountId: peerId,
            clientMsgId: originalClientId, kind: "text", text: "after",
            editVersion: 1, state: "visible", serverTs: "2026-07-12T10:00:00Z"
        )
        try await store.applyDifference(update(3, type: "message.edited", message: edited), accountId: accountId)

        let deletedReply = CloudMessage(
            dialogId: dialogId, msgId: 2, senderAccountId: accountId,
            clientMsgId: replyClientId, kind: "text", text: "",
            replyToMsgId: 1, editVersion: 0, state: "deleted_for_all", serverTs: "2026-07-12T10:00:01Z"
        )
        try await store.applyDifference(update(4, type: "message.deleted", message: deletedReply), accountId: accountId)

        let messages = try await store.messages(dialogId: dialogId)
        XCTAssertEqual(messages.map(\.text), ["after", ""])
        XCTAssertEqual(messages[0].editVersion, 1)
        XCTAssertEqual(messages[1].replyToMsgId, 1)
        XCTAssertEqual(messages[1].state, "deleted_for_all")
        let savedPts = try await store.loadPts(accountId: accountId)
        let dialogs = try await store.dialogs(accountId: accountId)
        XCTAssertEqual(savedPts, 4)
        XCTAssertEqual(dialogs.first?.lastState, "deleted_for_all")
    }

    @MainActor
    func testExistingSQLCipherReplicaMigratesReplyAndEditColumnsWithoutDataLoss() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "cloud.sqlite").path
        let key = Data("legacy-test-passphrase".utf8)

        do {
            var configuration = Configuration()
            configuration.prepareDatabase { db in
                try db.usePassphrase(key)
                try db.execute(sql: "PRAGMA foreign_keys = ON")
            }
            let legacy = try DatabaseQueue(path: path, configuration: configuration)
            try await legacy.write { db in
                try db.execute(sql: """
                CREATE TABLE messages (
                  local_id TEXT PRIMARY KEY,
                  dialog_id TEXT NOT NULL,
                  msg_id INTEGER,
                  client_msg_id TEXT NOT NULL UNIQUE,
                  sender_account_id TEXT NOT NULL,
                  kind TEXT NOT NULL,
                  text TEXT NOT NULL,
                  state TEXT NOT NULL,
                  server_ts TEXT,
                  local_state TEXT NOT NULL
                );
                CREATE TABLE pending_outbox (
                  client_msg_id TEXT PRIMARY KEY,
                  dialog_id TEXT NOT NULL,
                  body TEXT NOT NULL,
                  retry_count INTEGER NOT NULL DEFAULT 0,
                  next_retry_at TEXT,
                  created_at TEXT NOT NULL DEFAULT (datetime('now'))
                );
                INSERT INTO messages (
                  local_id, dialog_id, msg_id, client_msg_id, sender_account_id,
                  kind, text, state, server_ts, local_state
                ) VALUES (
                  'dialog-legacy:1', 'dialog-legacy', 1, 'legacy-client-id', 'account-peer',
                  'text', 'preserve me', 'visible', '2026-07-12T09:00:00Z', 'sent'
                );
                """)
            }
        }

        let store = try CloudLocalStore(path: path, key: key)
        let preserved = try await store.messages(dialogId: "dialog-legacy")
        XCTAssertEqual(preserved.first?.text, "preserve me")
        XCTAssertNil(preserved.first?.replyToMsgId)
        XCTAssertEqual(preserved.first?.editVersion, 0)

        _ = try await store.insertSending(
            dialogId: "dialog-legacy",
            clientMsgId: UUID().uuidString,
            text: "reply after upgrade",
            senderAccountId: "account-me",
            replyToMsgId: 1
        )
        let outbox = try await store.pendingOutboxReady()
        XCTAssertEqual(outbox.first?.replyToMsgId, 1)
    }

    private func makeStore() throws -> CloudLocalStore {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }

        return try CloudLocalStore(
            path: directory.appending(path: "cloud.sqlite").path,
            key: Data("test-passphrase".utf8)
        )
    }
}

private final class CloudAPIMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { return nil }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

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
