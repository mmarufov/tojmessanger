import XCTest
import GRDB
@testable import Toj

final class CloudLocalStoreTests: XCTestCase {
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

        let dialogs = try await store.dialogs()
        XCTAssertEqual(dialogs.map(\.title), ["Bob"])
        XCTAssertEqual(dialogs.map(\.lastText), ["remote reply"])
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
                    title: nil,
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
        let dialogs = try await store.dialogs()
        XCTAssertEqual(ptsAfterFinish, 44)
        XCTAssertEqual(latestDialogId, dialogId)
        XCTAssertEqual(dialogs.first?.lastText, "snapshot message")
    }

    private func makeStore() throws -> CloudLocalStore {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }

        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.usePassphrase("test-passphrase")
        }

        return try CloudLocalStore(
            path: directory.appending(path: "cloud.sqlite").path,
            configuration: configuration
        )
    }
}
