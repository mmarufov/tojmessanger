import XCTest
import GRDB
import Security
@testable import Toj

final class CloudLocalStoreTests: XCTestCase {
    func testCapabilitiesEndpointIsPublicAndDecodesContract() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudAPIMockURLProtocol.self]
        let api = CloudAPI(
            config: CloudConfig(baseURL: try XCTUnwrap(URL(string: "https://cloud.example.test/cloud"))),
            session: URLSession(configuration: configuration)
        )
        CloudAPIMockURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/cloud/v1/capabilities")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (
                try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: ["content-type": "application/json"]
                )),
                Data("{\"api_version\":2,\"capabilities\":[\"media_uploads\",\"voice_notes\"]}".utf8)
            )
        }
        defer { CloudAPIMockURLProtocol.handler = nil }

        let response = try await api.capabilities()
        XCTAssertEqual(response.apiVersion, 2)
        XCTAssertEqual(response.capabilities, ["media_uploads", "voice_notes"])
    }

    func testCloudFailureClassificationRetriesOnlyRecoverableFailures() {
        XCTAssertEqual(cloudFailureDisposition(URLError(.notConnectedToInternet)), .transient(retryAfter: nil))
        XCTAssertEqual(
            cloudFailureDisposition(CloudAPIError(status: 429, message: "slow", retryAfter: 17)),
            .transient(retryAfter: 17)
        )
        XCTAssertEqual(
            cloudFailureDisposition(CloudAPIError(status: 401, message: "expired", retryAfter: nil)),
            .authenticationRequired
        )
        XCTAssertEqual(
            cloudFailureDisposition(CloudAPIError(status: 404, message: "missing", retryAfter: nil)),
            .unsupportedServer
        )
        XCTAssertEqual(
            cloudFailureDisposition(CloudAPIError(status: 413, message: "too large", retryAfter: nil)),
            .permanent
        )
        let missing = CloudAPIError(status: 404, message: "message missing", retryAfter: nil)
        XCTAssertEqual(
            cloudOperationFailureDisposition(missing, serverAdvertisesFeature: false),
            .unsupportedServer
        )
        XCTAssertEqual(
            cloudOperationFailureDisposition(missing, serverAdvertisesFeature: true),
            .permanent
        )
    }

    func testPendingMutationsPersistAndTerminalFailuresDoNotLoop() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "cloud.sqlite").path
        let key = Data("durable-mutation-key".utf8)
        let first = try CloudLocalStore(path: path, key: key)
        try await first.enqueueMessageMutation(
            clientMutationId: "mutation-1", operation: "edit", dialogId: "dialog-1",
            msgId: 9, body: "corrected", expectedEditVersion: 2
        )

        let reopened = try CloudLocalStore(path: path, key: key)
        var ready = try await reopened.pendingMessageMutationsReady()
        XCTAssertEqual(ready.map(\.clientMutationId), ["mutation-1"])
        XCTAssertEqual(ready.first?.body, "corrected")
        try await reopened.markMessageMutationFailed(
            clientMutationId: "mutation-1", error: "invalid", retryAfter: nil, terminal: true
        )
        let terminalReady = try await reopened.pendingMessageMutationsReady()
        XCTAssertTrue(terminalReady.isEmpty)
        try await reopened.retryMessageMutation(clientMutationId: "mutation-1")
        ready = try await reopened.pendingMessageMutationsReady()
        XCTAssertEqual(ready.first?.retryCount, 1)
    }

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
        let deleted = response.deleted
        XCTAssertTrue(deleted)
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

    @MainActor
    func testReactionAndForwardRequestsCarryStableSourceAndMutationIdentifiers() async throws {
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
            if request.url!.path.hasSuffix("react") {
                return (response, Data("""
                {"dialogId":"dialog-1","msgId":7,"actorPts":9,"duplicate":false,"message":{
                  "dialog_id":"dialog-1","msg_id":7,"sender_account_id":"account-a",
                  "client_msg_id":"11111111-1111-1111-1111-111111111111","kind":"text",
                  "text":"hello","reply_to_msg_id":null,"reactions":[{"account_id":"account-b","emoji":"❤️"}],
                  "edit_version":0,"state":"visible","server_ts":"2026-07-12T00:00:00Z"}}
                """.utf8))
            }
            return (response, Data("""
            {"dialogId":"dialog-2","clientMsgId":"33333333-3333-3333-3333-333333333333",
             "msgId":8,"senderPts":10,"duplicate":false,"serverTs":"2026-07-12T00:00:01Z","text":"hello"}
            """.utf8))
        }
        defer { CloudAPIMockURLProtocol.handler = nil }

        _ = try await api.setReaction(
            dialogId: "dialog-1", msgId: 7,
            clientMutationId: "22222222-2222-2222-2222-222222222222",
            emoji: "❤️", token: "session-token"
        )
        _ = try await api.forwardMessage(
            dialogId: "dialog-2",
            clientMsgId: "33333333-3333-3333-3333-333333333333",
            sourceDialogId: "dialog-1", sourceMsgId: 7, token: "session-token"
        )

        XCTAssertEqual(requests.map(\.0), ["/cloud/v1/messages/react", "/cloud/v1/messages/send"])
        XCTAssertEqual(requests[0].1["clientMutationId"] as? String, "22222222-2222-2222-2222-222222222222")
        XCTAssertEqual(requests[0].1["emoji"] as? String, "❤️")
        let source = try XCTUnwrap(requests[1].1["forwardedFrom"] as? [String: Any])
        XCTAssertEqual(source["dialogId"] as? String, "dialog-1")
        XCTAssertEqual(source["msgId"] as? Int, 7)
        XCTAssertNil(requests[1].1["body"])
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

        try await store.markFailed(clientMsgId: clientMsgId, terminal: true)
        dueOutbox = try await store.pendingOutboxReady()
        XCTAssertTrue(dueOutbox.isEmpty, "Permanent failures must not loop")
        let terminalOutboxDelay = try await store.nextPendingOutboxDelay()
        XCTAssertNil(terminalOutboxDelay)
        try await store.markRetrying(clientMsgId: clientMsgId)
        dueOutbox = try await store.pendingOutboxReady()
        XCTAssertEqual(dueOutbox.map(\.clientMsgId), [clientMsgId], "Manual retry clears terminal state")

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

        let deleteMutationId = UUID().uuidString
        try await store.enqueueMessageMutation(
            clientMutationId: deleteMutationId,
            operation: "delete",
            dialogId: dialogId,
            msgId: 2
        )
        var dialogs = try await store.dialogs(accountId: accountId)
        XCTAssertEqual(dialogs.first?.lastText, "after", "Pending deletion hides the latest message preview")
        XCTAssertEqual(dialogs.first?.lastState, "visible")

        let deletedReply = CloudMessage(
            dialogId: dialogId, msgId: 2, senderAccountId: accountId,
            clientMsgId: replyClientId, kind: "text", text: "",
            replyToMsgId: 1, editVersion: 0, state: "deleted_for_all", serverTs: "2026-07-12T10:00:01Z"
        )
        try await store.applyDifference(update(4, type: "message.deleted", message: deletedReply), accountId: accountId)
        try await store.completeMessageMutation(clientMutationId: deleteMutationId)

        let messages = try await store.messages(dialogId: dialogId)
        XCTAssertEqual(messages.map(\.text), ["after", ""])
        XCTAssertEqual(messages[0].editVersion, 1)
        XCTAssertEqual(messages[1].replyToMsgId, 1)
        XCTAssertEqual(messages[1].state, "deleted_for_all")
        let savedPts = try await store.loadPts(accountId: accountId)
        dialogs = try await store.dialogs(accountId: accountId)
        XCTAssertEqual(savedPts, 4)
        XCTAssertEqual(dialogs.first?.lastText, "after")
        XCTAssertEqual(dialogs.first?.lastState, "visible")
    }

    @MainActor
    func testReactionsForwardProvenanceAndForwardOutboxPersistInEncryptedReplica() async throws {
        let store = try makeStore()
        let accountId = "account-me"
        let dialogId = "dialog-source"
        let targetDialogId = "dialog-target"
        let message = CloudMessage(
            dialogId: dialogId,
            msgId: 4,
            senderAccountId: "account-peer",
            clientMsgId: UUID().uuidString,
            kind: "text",
            text: "forward me",
            forwardedFromAccountId: "account-original",
            forwardedFromDialogId: "dialog-original",
            forwardedFromMsgId: 2,
            isForwarded: true,
            reactions: [
                CloudReaction(accountId: accountId, emoji: "❤️"),
                CloudReaction(accountId: "account-peer", emoji: "❤️"),
            ],
            editVersion: 0,
            state: "visible",
            serverTs: "2026-07-12T12:00:00Z"
        )
        try await store.applyDifference(
            DifferenceResponse(
                kind: "difference",
                state: DifferenceResponse.State(pts: 5),
                updates: [CloudUpdate(
                    pts: 5,
                    ptsCount: 1,
                    type: "reaction.updated",
                    dialogId: dialogId,
                    dialogTitle: "Peer",
                    message: message,
                    readerAccountId: nil,
                    maxReadMsgId: nil
                )],
                hasMore: false
            ),
            accountId: accountId
        )

        let storedMessages = try await store.messages(dialogId: dialogId)
        let stored = try XCTUnwrap(storedMessages.first)
        XCTAssertEqual(stored.forwardedFromAccountId, "account-original")
        XCTAssertEqual(stored.forwardedFromDialogId, "dialog-original")
        XCTAssertEqual(stored.forwardedFromMsgId, 2)
        XCTAssertTrue(stored.isForwarded)
        XCTAssertEqual(stored.reactions, message.reactions)

        let clientMsgId = UUID().uuidString.lowercased()
        _ = try await store.insertSending(
            dialogId: targetDialogId,
            clientMsgId: clientMsgId,
            text: stored.text,
            senderAccountId: accountId,
            forwardedFromAccountId: stored.senderAccountId,
            forwardedFromDialogId: dialogId,
            forwardedFromMsgId: stored.msgId
        )
        let pendingItems = try await store.pendingOutboxReady()
        let pending = try XCTUnwrap(pendingItems.first)
        XCTAssertEqual(pending.forwardedFromDialogId, dialogId)
        XCTAssertEqual(pending.forwardedFromMsgId, 4)
        let optimisticMessages = try await store.messages(dialogId: targetDialogId)
        let optimistic = try XCTUnwrap(optimisticMessages.first)
        XCTAssertEqual(optimistic.text, "forward me")
        XCTAssertEqual(optimistic.forwardedFromDialogId, dialogId)
        XCTAssertEqual(optimistic.forwardedFromMsgId, 4)
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

    func testMediaCacheEncryptsPendingFilesAndSurvivesCacheReset() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let cache = try EncryptedMediaCache(
            root: directory,
            keyData: Data(repeating: 0x2a, count: 32),
            limitBytes: 2 * 1024 * 1024
        )
        let plaintext = Data("a private media payload that must never appear on disk".utf8)
        let thumbnail = Data("private thumbnail".utf8)

        let prepared = try await cache.prepareUpload(
            data: plaintext, kind: "file", contentType: "application/octet-stream",
            fileName: "notes.bin", thumbnail: thumbnail
        )
        let encrypted = try Data(contentsOf: URL(filePath: prepared.encryptedSourcePath))
        XCTAssertNotEqual(encrypted, plaintext)
        XCTAssertNil(encrypted.range(of: plaintext))
        let decrypted = try await cache.preparedData(transferId: prepared.transferId)
        let decryptedThumbnail = try await cache.preparedThumbnail(transferId: prepared.transferId)
        XCTAssertEqual(decrypted, plaintext)
        XCTAssertEqual(decryptedThumbnail, thumbnail)

        let downloadedMediaId = UUID().uuidString.lowercased()
        try await cache.storeDownloadChunk(plaintext, mediaId: downloadedMediaId, offset: 0)
        try await cache.storeThumbnail(thumbnail, mediaId: downloadedMediaId)
        let preview = try await cache.createTemporaryPreview(plaintext, fileExtension: "../../unsafe")
        XCTAssertEqual(preview.pathExtension, "bin")
        XCTAssertTrue(FileManager.default.fileExists(atPath: preview.path))
        let usageBeforeClear = try await cache.downloadedUsageBytes()
        XCTAssertGreaterThan(usageBeforeClear, 0)
        try await cache.clearDownloaded()
        let retainedUpload = try await cache.preparedData(transferId: prepared.transferId)
        let clearedOffset = try await cache.contiguousDownloadOffset(mediaId: downloadedMediaId)
        let usageAfterClear = try await cache.downloadedUsageBytes()
        XCTAssertEqual(retainedUpload, plaintext)
        XCTAssertEqual(clearedOffset, 0)
        XCTAssertEqual(usageAfterClear, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: preview.path))

        try await cache.clearAll()
        let second = try await cache.prepareUpload(
            data: plaintext, kind: "voice", contentType: "audio/mp4",
            fileName: "voice.m4a", durationMs: 900
        )
        let decryptedAfterReset = try await cache.preparedData(transferId: second.transferId)
        XCTAssertEqual(decryptedAfterReset, plaintext)
    }

    func testCachedByteRangeAssemblesChunksAndDetectsGaps() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let cache = try EncryptedMediaCache(
            root: directory, keyData: Data(repeating: 0x2a, count: 32), limitBytes: 4 * 1024 * 1024
        )

        // 15 distinct bytes stored as three 5-byte chunks, written out of order.
        let mediaId = UUID().uuidString.lowercased()
        try await cache.storeDownloadChunk(Data("ABCDE".utf8), mediaId: mediaId, offset: 10)
        try await cache.storeDownloadChunk(Data("01234".utf8), mediaId: mediaId, offset: 0)
        try await cache.storeDownloadChunk(Data("56789".utf8), mediaId: mediaId, offset: 5)

        let wholeData = try await cache.cachedByteRange(mediaId: mediaId, offset: 0, length: 15)
        XCTAssertEqual(String(decoding: try XCTUnwrap(wholeData), as: UTF8.self), "0123456789ABCDE")
        let straddleData = try await cache.cachedByteRange(mediaId: mediaId, offset: 3, length: 5)
        XCTAssertEqual(String(decoding: try XCTUnwrap(straddleData), as: UTF8.self), "34567")
        let tailData = try await cache.cachedByteRange(mediaId: mediaId, offset: 12, length: 3)
        XCTAssertEqual(String(decoding: try XCTUnwrap(tailData), as: UTF8.self), "CDE")
        let coverageEnd = try await cache.coverageEnd(mediaId: mediaId, from: 0)
        XCTAssertEqual(coverageEnd, 15)

        // A missing middle chunk breaks coverage across the gap but not ranges that avoid it.
        let gapMedia = UUID().uuidString.lowercased()
        try await cache.storeDownloadChunk(Data("01234".utf8), mediaId: gapMedia, offset: 0)
        try await cache.storeDownloadChunk(Data("ABCDE".utf8), mediaId: gapMedia, offset: 10)
        let coveredData = try await cache.cachedByteRange(mediaId: gapMedia, offset: 0, length: 5)
        XCTAssertEqual(String(decoding: try XCTUnwrap(coveredData), as: UTF8.self), "01234")
        let acrossGap = try await cache.cachedByteRange(mediaId: gapMedia, offset: 0, length: 8)
        XCTAssertNil(acrossGap)
        let afterGapData = try await cache.cachedByteRange(mediaId: gapMedia, offset: 10, length: 5)
        XCTAssertEqual(String(decoding: try XCTUnwrap(afterGapData), as: UTF8.self), "ABCDE")
        let gapCoverageFromStart = try await cache.coverageEnd(mediaId: gapMedia, from: 0)
        let gapCoverageAfter = try await cache.coverageEnd(mediaId: gapMedia, from: 10)
        XCTAssertEqual(gapCoverageFromStart, 5)
        XCTAssertEqual(gapCoverageAfter, 15)
    }

    func testMediaCacheRefusesToEvictPendingUploadsForNewSelections() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let cache = try EncryptedMediaCache(
            root: directory,
            keyData: Data(repeating: 0x31, count: 32),
            limitBytes: 300
        )
        _ = try await cache.prepareUpload(
            data: Data(repeating: 0x11, count: 100), kind: "file",
            contentType: "application/octet-stream", fileName: "first.bin"
        )

        do {
            _ = try await cache.prepareUpload(
                data: Data(repeating: 0x22, count: 100), kind: "file",
                contentType: "application/octet-stream", fileName: "second.bin"
            )
            XCTFail("Expected the protected pending upload to consume the local quota")
        } catch let error as MediaCacheError {
            guard case .localQuotaExceeded = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testMediaCacheInvalidatesCorruptDownloadsAndRestartsFromZero() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let cache = try EncryptedMediaCache(
            root: directory, keyData: Data(repeating: 0x52, count: 32), limitBytes: 1_000_000
        )
        let mediaId = UUID().uuidString.lowercased()
        try await cache.storeDownloadChunk(Data("valid chunk".utf8), mediaId: mediaId, offset: 0)
        let encryptedChunk = directory.appending(path: "downloads/\(mediaId)/0.tojchunk")
        try Data("corrupt".utf8).write(to: encryptedChunk, options: .atomic)

        let restartedOffset = try await cache.contiguousDownloadOffset(mediaId: mediaId)
        XCTAssertEqual(restartedOffset, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: encryptedChunk.path))
    }

    func testMediaDownloadRejectsInconsistentServerOffsets() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudAPIMockURLProtocol.self]
        let mediaId = "11111111-1111-1111-1111-111111111111"
        CloudAPIMockURLProtocol.handler = { request in
            let response = try XCTUnwrap(HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: [
                    "content-type": "application/octet-stream",
                    "x-media-next-offset": "999",
                    "x-media-total-size": "999",
                ]
            ))
            return (response, Data("tiny".utf8))
        }
        defer { CloudAPIMockURLProtocol.handler = nil }
        let api = CloudMediaAPI(
            config: CloudConfig(baseURL: try XCTUnwrap(URL(string: "https://cloud.example.test/cloud"))),
            session: URLSession(configuration: configuration)
        )

        do {
            _ = try await api.downloadChunk(mediaId: mediaId, offset: 0, token: "session-token")
            XCTFail("A malformed offset contract must not be cached")
        } catch let error as CloudAPIError {
            XCTAssertEqual(error.status, -1)
        }
    }

    func testMediaTransferPersistsAcrossBootstrapAndUsesProvisionalMedia() async throws {
        let store = try makeStore()
        let transferId = UUID().uuidString.lowercased()
        let clientMsgId = UUID().uuidString.lowercased()
        let prepared = PreparedMediaUpload(
            transferId: transferId, kind: "photo", contentType: "image/jpeg",
            fileName: "photo.jpg", byteSize: 123, sha256: String(repeating: "a", count: 64),
            durationMs: nil, width: 20, height: 10,
            encryptedSourcePath: "/private/pending.tojmedia",
            encryptedThumbnailPath: "/private/pending.thumb"
        )
        try await store.insertMediaTransfer(
            prepared: prepared, dialogId: "dialog-media", clientMsgId: clientMsgId,
            caption: "caption", replyToMsgId: nil
        )
        let storedTransfer = try await store.mediaTransfer(id: transferId)
        let transfer = try XCTUnwrap(storedTransfer)
        XCTAssertEqual(transfer.media.id, "pending:\(transferId)")
        try await store.insertSendingMedia(transfer, senderAccountId: "account-me")
        let optimisticMessages = try await store.messages(dialogId: "dialog-media")
        let optimisticMedia = optimisticMessages.first?.media
        let expectedMedia = transfer.media
        XCTAssertEqual(optimisticMedia, expectedMedia)

        try await store.markMediaTerminal(clientMsgId: clientMsgId, error: "File is too large")
        let terminalTransfers = try await store.mediaTransfers(dialogId: "dialog-media")
        let terminalTransfer = try XCTUnwrap(terminalTransfers.first)
        XCTAssertTrue(terminalTransfer.terminal)
        XCTAssertEqual(terminalTransfer.lastError, "File is too large")
        let terminalMediaDelay = try await store.nextMediaTransferDelay()
        XCTAssertNil(terminalMediaDelay)
        try await store.markMediaRetrying(clientMsgId: clientMsgId)
        let retriedTransfer = try await store.mediaTransfer(id: transferId)
        XCTAssertFalse(try XCTUnwrap(retriedTransfer).terminal)

        try await store.beginBootstrap(accountId: "account-me")
        let retained = try await store.mediaTransfer(id: transferId)
        XCTAssertNotNil(retained)
        try await store.markMediaRetrying(clientMsgId: clientMsgId)
        try await store.updateMediaTransfer(
            transferId: transferId, mediaId: "11111111-1111-1111-1111-111111111111",
            uploadOffset: 123, state: "ready_to_send", error: nil
        )
        let storedReady = try await store.mediaTransfer(id: transferId)
        let ready = try XCTUnwrap(storedReady)
        XCTAssertEqual(ready.media.id, "11111111-1111-1111-1111-111111111111")
        try await store.resetMediaUpload(transferId: transferId)
        let reset = try await store.mediaTransfer(id: transferId)
        XCTAssertEqual(reset?.media.id, "pending:\(transferId)")
        XCTAssertEqual(reset?.uploadOffset, 0)
        try await store.completeMediaTransfer(transferId: transferId)
        let completed = try await store.mediaTransfer(id: transferId)
        XCTAssertNil(completed)
    }

    func testCancellingMediaTransferRemovesDurableRetryAndOptimisticBubble() async throws {
        let store = try makeStore()
        let transferId = UUID().uuidString.lowercased()
        let clientMsgId = UUID().uuidString.lowercased()
        let prepared = PreparedMediaUpload(
            transferId: transferId, kind: "file", contentType: "application/octet-stream",
            fileName: "cancel.bin", byteSize: 12, sha256: String(repeating: "b", count: 64),
            durationMs: nil, width: nil, height: nil,
            encryptedSourcePath: "/private/cancel.tojmedia", encryptedThumbnailPath: nil
        )
        try await store.insertMediaTransfer(
            prepared: prepared, dialogId: "dialog-cancel", clientMsgId: clientMsgId,
            caption: "wrong file", replyToMsgId: nil
        )
        let storedTransfer = try await store.mediaTransfer(id: transferId)
        let transfer = try XCTUnwrap(storedTransfer)
        try await store.insertSendingMedia(transfer, senderAccountId: "account-me")

        try await store.cancelMediaTransfer(transferId: transferId, clientMsgId: clientMsgId)

        let cancelledTransfer = try await store.mediaTransfer(id: transferId)
        let remainingMessages = try await store.messages(dialogId: "dialog-cancel")
        let nextRetry = try await store.nextMediaTransferDelay()
        XCTAssertNil(cancelledTransfer)
        XCTAssertTrue(remainingMessages.isEmpty)
        XCTAssertNil(nextRetry)
    }

    func testMediaTransferEngineResumesFromServerOffsetAndPersistsEveryChunk() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let cache = try EncryptedMediaCache(
            root: directory.appending(path: "cache", directoryHint: .isDirectory),
            keyData: Data(repeating: 0x42, count: 32), limitBytes: 1_000_000
        )
        let payload = Data("abcdef".utf8)
        let prepared = try await cache.prepareUpload(
            data: payload, kind: "file", contentType: "application/octet-stream", fileName: "resume.bin"
        )
        let store = try CloudLocalStore(
            path: directory.appending(path: "cloud.sqlite").path,
            key: Data("media-transfer-test-key".utf8)
        )
        let clientMsgId = UUID().uuidString.lowercased()
        let mediaId = "11111111-1111-1111-1111-111111111111"
        try await store.insertMediaTransfer(
            prepared: prepared, dialogId: "dialog-resume", clientMsgId: clientMsgId,
            caption: "", replyToMsgId: nil
        )
        try await store.updateMediaTransfer(
            transferId: prepared.transferId, mediaId: mediaId,
            uploadOffset: 0, state: "uploading", error: nil
        )
        let stored = try await store.mediaTransfer(id: prepared.transferId)
        let transfer = try XCTUnwrap(stored)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudAPIMockURLProtocol.self]
        let recorder = LockedMediaRequests()
        CloudAPIMockURLProtocol.handler = { request in
            let response = try XCTUnwrap(HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["content-type": "application/json"]
            ))
            if request.httpMethod == "GET" {
                return (response, Data("""
                {"mediaId":"\(mediaId)","uploadOffset":2,"byteSize":6,"status":"uploading",
                 "expiresAt":"2026-07-14T00:00:00Z","chunkSize":2}
                """.utf8))
            }
            if request.url?.path.hasSuffix("/chunks") == true {
                let offset = try XCTUnwrap(request.value(forHTTPHeaderField: "Upload-Offset").flatMap(Int64.init))
                let bytes = try XCTUnwrap(CloudAPIMockURLProtocol.bodyData(from: request))
                recorder.append(offset: offset, bytes: bytes)
                return (response, Data("""
                {"mediaId":"\(mediaId)","uploadOffset":\(offset + Int64(bytes.count)),
                 "complete":\(offset + Int64(bytes.count) == 6),"duplicate":false}
                """.utf8))
            }
            if request.httpMethod == "DELETE" {
                return (response, Data("""
                {"mediaId":"\(mediaId)","cancelled":true}
                """.utf8))
            }
            return (response, Data("""
            {"mediaId":"\(mediaId)","ready":true,"duplicate":false}
            """.utf8))
        }
        defer { CloudAPIMockURLProtocol.handler = nil }
        let engine = CloudMediaTransferEngine(
            config: CloudConfig(baseURL: try XCTUnwrap(URL(string: "https://cloud.example.test/cloud"))),
            cache: cache, session: URLSession(configuration: configuration)
        )

        let uploadedId = try await engine.upload(
            transfer: transfer, token: "session-token", localStore: store, progress: { _ in }
        )
        XCTAssertEqual(uploadedId, mediaId)
        let recorded = recorder.snapshot()
        XCTAssertEqual(recorded.map(\.offset), [2, 4])
        XCTAssertEqual(recorded.map(\.bytes), [Data("cd".utf8), Data("ef".utf8)])
        let updated = try await store.mediaTransfer(id: prepared.transferId)
        XCTAssertEqual(updated?.uploadOffset, 6)
        await engine.cancelUpload(transfer, token: "session-token")
        do {
            _ = try await cache.preparedData(transferId: prepared.transferId)
            XCTFail("Cancelled upload plaintext must be removed from the encrypted outbox")
        } catch {
            // Expected: the encrypted source file was removed.
        }
    }

    func testMultipartMediaResumesOnlyMissingParts() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let partSize = 256 * 1024
        let payload = Data((0..<(partSize * 3 + 19)).map { UInt8($0 % 251) })
        let cache = try EncryptedMediaCache(
            root: directory.appending(path: "cache", directoryHint: .isDirectory),
            keyData: Data(repeating: 0x52, count: 32), limitBytes: 3_000_000
        )
        let prepared = try await cache.prepareUpload(
            data: payload, kind: "file", contentType: "application/octet-stream", fileName: "parallel.bin"
        )
        let store = try CloudLocalStore(
            path: directory.appending(path: "cloud.sqlite").path,
            key: Data("multipart-transfer-test-key".utf8)
        )
        let mediaId = "22222222-2222-2222-2222-222222222222"
        try await store.insertMediaTransfer(
            prepared: prepared, dialogId: "dialog-parallel", clientMsgId: UUID().uuidString,
            caption: "", replyToMsgId: nil
        )
        try await store.updateMediaTransfer(
            transferId: prepared.transferId, mediaId: mediaId,
            uploadOffset: Int64(partSize), state: "uploading", error: nil
        )
        let storedTransfer = try await store.mediaTransfer(id: prepared.transferId)
        let transfer = try XCTUnwrap(storedTransfer)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudAPIMockURLProtocol.self]
        configuration.httpMaximumConnectionsPerHost = 3
        let recorder = LockedMultipartRequests()
        CloudAPIMockURLProtocol.handler = { request in
            let response = try XCTUnwrap(HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/2",
                headerFields: ["content-type": "application/json"]
            ))
            if request.httpMethod == "GET" {
                return (response, Data("""
                {"mediaId":"\(mediaId)","uploadOffset":\(partSize),"byteSize":\(payload.count),
                 "status":"uploading","expiresAt":"2026-07-15T00:00:00Z","chunkSize":1048576,
                 "uploadProtocol":"parts_v2","partSize":\(partSize),"totalParts":4,"receivedParts":[1]}
                """.utf8))
            }
            if request.url?.path.contains("/parts/") == true {
                let component = try XCTUnwrap(request.url?.lastPathComponent)
                let partIndex = try XCTUnwrap(Int(component))
                let bytes = try XCTUnwrap(CloudAPIMockURLProtocol.bodyData(from: request))
                recorder.begin(partIndex: partIndex, bytes: bytes)
                Thread.sleep(forTimeInterval: 0.05)
                recorder.end()
                return (response, Data("""
                {"mediaId":"\(mediaId)","partIndex":\(partIndex),"receivedBytes":\(payload.count),
                 "complete":false,"duplicate":false}
                """.utf8))
            }
            return (response, Data("""
            {"mediaId":"\(mediaId)","ready":true,"duplicate":false}
            """.utf8))
        }
        defer { CloudAPIMockURLProtocol.handler = nil }
        let engine = CloudMediaTransferEngine(
            config: CloudConfig(baseURL: try XCTUnwrap(URL(string: "https://cloud.example.test/cloud"))),
            cache: cache, session: URLSession(configuration: configuration)
        )
        let progress = LockedProgressValues()
        let uploaded = try await engine.upload(
            transfer: transfer, token: "session-token", localStore: store,
            useMultipartV2: true, progress: { progress.append($0) }
        )

        XCTAssertEqual(uploaded, mediaId)
        XCTAssertEqual(Set(recorder.snapshot().map(\.partIndex)), Set([0, 2, 3]))
        let completedTransfer = try await store.mediaTransfer(id: prepared.transferId)
        XCTAssertEqual(completedTransfer?.uploadOffset, Int64(payload.count))
        XCTAssertEqual(progress.snapshot().last, 1)
        XCTAssertTrue(progress.snapshot().allSatisfy { (0...1).contains($0) })
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

private final class LockedMediaRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [(offset: Int64, bytes: Data)] = []

    func append(offset: Int64, bytes: Data) {
        lock.lock()
        requests.append((offset, bytes))
        lock.unlock()
    }

    func snapshot() -> [(offset: Int64, bytes: Data)] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
}

private final class LockedMultipartRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [(partIndex: Int, bytes: Data)] = []
    private var active = 0
    private(set) var maximumConcurrent = 0

    func begin(partIndex: Int, bytes: Data) {
        lock.lock()
        requests.append((partIndex, bytes))
        active += 1
        maximumConcurrent = max(maximumConcurrent, active)
        lock.unlock()
    }

    func end() {
        lock.lock()
        active -= 1
        lock.unlock()
    }

    func snapshot() -> [(partIndex: Int, bytes: Data)] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
}

private final class LockedProgressValues: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []

    func append(_ value: Double) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func snapshot() -> [Double] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}
