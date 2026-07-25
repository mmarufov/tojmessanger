import Foundation
import XCTest
@testable import Toj

final class CloudDraftsV1Tests: XCTestCase {
    func testCoordinatorDebouncesToOneLatestMutationWithoutCancellingItsOwnFlush() async throws {
        let fixture = try makeStoreFixture()
        let store = try CloudLocalStore(path: fixture.path, key: fixture.key)
        let requests = LockedDraftRequests()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DraftMockURLProtocol.self]
        let api = CloudAPI(
            config: CloudConfig(
                baseURL: try XCTUnwrap(URL(string: "https://drafts.example.test/cloud"))
            ),
            session: URLSession(configuration: configuration)
        )
        DraftMockURLProtocol.handler = { request in
            let body = try XCTUnwrap(DraftMockURLProtocol.bodyData(from: request))
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            let operationId = try XCTUnwrap(json["operation_id"] as? String)
            let text = try XCTUnwrap(json["text"] as? String)
            requests.append(operationId: operationId, text: text)
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["content-type": "application/json"]
                )
            )
            let responseBody = try JSONSerialization.data(withJSONObject: [
                "draft": [
                    "dialog_id": "dialog-a",
                    "revision": 9,
                    "state": "active",
                    "text": text,
                    "mentions": [],
                    "attachments": [],
                    "operation_id": operationId,
                    "updated_at": "2026-07-25T12:00:00.000Z",
                ],
                "duplicate": false,
            ])
            return (response, responseBody)
        }
        defer { DraftMockURLProtocol.handler = nil }

        let coordinator = DraftSyncCoordinator(api: api)
        await coordinator.configure(
            store: store,
            session: CloudSession(
                accountId: "account-a",
                deviceId: "device-a",
                token: "session-token"
            ),
            cloudEnabled: true
        )
        for text in ["first", "second", "latest"] {
            _ = try await coordinator.mutate(
                dialogId: "dialog-a",
                text: text,
                replyToMsgId: nil,
                replyPreview: nil,
                mentions: []
            )
        }
        try await Task.sleep(for: .milliseconds(900))

        XCTAssertEqual(requests.snapshot().map(\.text), ["latest"])
        XCTAssertNil(
            try await store.pendingDraftMutation(
                accountId: "account-a",
                dialogId: "dialog-a"
            )
        )
    }

    func testCoordinatorCapsDraftAttachmentUploadsAtTwo() async throws {
        let coordinator = DraftSyncCoordinator(
            api: CloudAPI(config: CloudConfig(baseURL: URL(string: "https://example.test")!))
        )
        let probe = UploadConcurrencyProbe()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    try await coordinator.withAttachmentUploadPermit {
                        await probe.enter()
                        try await Task.sleep(for: .milliseconds(40))
                        await probe.leave()
                    }
                }
            }
            try await group.waitForAll()
        }
        let maximum = await probe.maximum()
        XCTAssertEqual(maximum, 2)
    }

    func testRawDraftAndCoalescedMutationSurviveReopen() async throws {
        let fixture = try makeStoreFixture()
        let raw = "  exact whitespace\nand a second line  "
        do {
            let store = try CloudLocalStore(path: fixture.path, key: fixture.key)
            _ = try await store.saveLocalDraft(
                accountId: "account-a",
                dialogId: "dialog-a",
                text: raw,
                replyToMsgId: nil,
                replyPreview: nil,
                mentions: []
            )
            _ = try await store.saveLocalDraft(
                accountId: "account-a",
                dialogId: "dialog-a",
                text: raw + "!",
                replyToMsgId: nil,
                replyPreview: nil,
                mentions: []
            )
            XCTAssertEqual(try await store.pendingDraftMutationsReady().count, 1)
        }

        let reopened = try CloudLocalStore(path: fixture.path, key: fixture.key)
        let draft = try await reopened.loadDraft(accountId: "account-a", dialogId: "dialog-a")
        XCTAssertEqual(draft?.text, raw + "!")
        XCTAssertEqual(draft?.state, "active")
        XCTAssertEqual(try await reopened.pendingDraftMutationsReady().count, 1)
    }

    func testStaleAcknowledgementPreservesNewerLocalOverlay() async throws {
        let fixture = try makeStoreFixture()
        let store = try CloudLocalStore(path: fixture.path, key: fixture.key)
        let first = try await store.saveLocalDraft(
            accountId: "account-a",
            dialogId: "dialog-a",
            text: "first device generation",
            replyToMsgId: nil,
            replyPreview: nil,
            mentions: []
        )
        let newer = try await store.saveLocalDraft(
            accountId: "account-a",
            dialogId: "dialog-a",
            text: "newer local generation",
            replyToMsgId: nil,
            replyPreview: nil,
            mentions: []
        )

        try await store.acknowledgeDraftMutation(
            DraftMutationResponse(
                draft: CloudDraft(
                    dialogId: "dialog-a",
                    revision: 41,
                    state: "active",
                    text: "first device generation",
                    replyToMsgId: nil,
                    replyPreview: nil,
                    mentions: [],
                    attachments: [],
                    operationId: first.operationId,
                    updatedAt: "2026-07-25T12:00:00.000Z"
                ),
                duplicate: false
            ),
            accountId: "account-a",
            attemptedOperationId: first.operationId
        )

        let visible = try await store.loadDraft(accountId: "account-a", dialogId: "dialog-a")
        XCTAssertEqual(visible?.text, "newer local generation")
        XCTAssertEqual(visible?.operationId, newer.operationId)
        XCTAssertEqual(try await store.pendingDraftMutationsReady().first?.operationId, newer.operationId)
    }

    func testReadyAttachmentsConvertAtomicallyToGroupAndRestoreAfterInvalidReply() async throws {
        let fixture = try makeStoreFixture()
        let store = try CloudLocalStore(path: fixture.path, key: fixture.key)
        _ = try await store.saveLocalDraft(
            accountId: "account-a",
            dialogId: "dialog-a",
            text: "album caption",
            replyToMsgId: 17,
            replyPreview: CloudDraftReplyPreview(
                msgId: 17,
                senderAccountId: "account-b",
                text: "original",
                unavailable: false
            ),
            mentions: []
        )
        for position in 0..<3 {
            let prepared = preparedUpload(position)
            _ = try await store.stageDraftAttachment(
                prepared: prepared,
                accountId: "account-a",
                dialogId: "dialog-a",
                attachmentId: "attachment-\(position)",
                position: position
            )
            try await store.updateDraftAttachment(
                transferId: prepared.transferId,
                mediaId: "media-\(position)",
                state: "ready",
                progress: 1,
                error: nil
            )
        }
        let ready = try XCTUnwrap(
            try await store.loadDraft(accountId: "account-a", dialogId: "dialog-a")
        )

        let group = try await store.consumeDraftAsMediaGroup(
            accountId: "account-a",
            dialogId: "dialog-a",
            operationId: ready.operationId
        )
        XCTAssertEqual(group.payload.items.count, 3)
        XCTAssertEqual(group.payload.caption, "album caption")
        XCTAssertEqual(group.payload.replyToMsgId, 17)
        XCTAssertEqual(try await store.pendingMediaGroupSendsReady().map(\.clientGroupId), [
            group.clientGroupId,
        ])
        let consumed = try await store.loadDraft(accountId: "account-a", dialogId: "dialog-a")
        XCTAssertEqual(consumed?.state, "cleared")
        XCTAssertTrue(consumed?.attachments.isEmpty == true)

        let snapshot = try await store.conversationSnapshot(dialogId: "dialog-a", window: .initial)
        XCTAssertEqual(snapshot.timeline.messages.count, 3)
        XCTAssertEqual(Set(snapshot.timeline.messages.compactMap(\.mediaGroupId)), [group.clientGroupId])
        XCTAssertEqual(snapshot.timeline.messages.compactMap(\.mediaGroupIndex).sorted(), [0, 1, 2])

        let restored = try await store.restoreMediaGroupAsDraftWithoutReply(group)
        XCTAssertEqual(restored.state, "active")
        XCTAssertEqual(restored.text, "album caption")
        XCTAssertNil(restored.replyToMsgId)
        XCTAssertEqual(restored.attachments.count, 3)
        XCTAssertTrue(try await store.pendingMediaGroupSendsReady().isEmpty)
    }

    func testGroupAcknowledgementKeepsAlbumFieldsAcrossReopen() async throws {
        let fixture = try makeStoreFixture()
        let group: PendingMediaGroupSend
        do {
            let store = try CloudLocalStore(path: fixture.path, key: fixture.key)
            _ = try await store.saveLocalDraft(
                accountId: "account-a",
                dialogId: "dialog-a",
                text: "caption",
                replyToMsgId: nil,
                replyPreview: nil,
                mentions: []
            )
            for position in 0..<2 {
                let prepared = preparedUpload(position)
                _ = try await store.stageDraftAttachment(
                    prepared: prepared,
                    accountId: "account-a",
                    dialogId: "dialog-a",
                    attachmentId: "attachment-\(position)",
                    position: position
                )
                try await store.updateDraftAttachment(
                    transferId: prepared.transferId,
                    mediaId: "media-\(position)",
                    state: "ready",
                    progress: 1,
                    error: nil
                )
            }
            let draft = try XCTUnwrap(
                try await store.loadDraft(accountId: "account-a", dialogId: "dialog-a")
            )
            group = try await store.consumeDraftAsMediaGroup(
                accountId: "account-a",
                dialogId: "dialog-a",
                operationId: draft.operationId
            )
            let messages = group.payload.items.enumerated().map { index, item in
                CloudMessage(
                    dialogId: "dialog-a",
                    msgId: Int64(100 + index),
                    senderAccountId: "account-a",
                    clientMsgId: item.clientMsgId,
                    kind: item.media.kind,
                    text: index == 0 ? "caption" : "",
                    media: item.media,
                    mediaGroupId: group.clientGroupId,
                    mediaGroupIndex: index,
                    mediaGroupCount: 2,
                    editVersion: 0,
                    state: "visible",
                    serverTs: "2026-07-25T12:00:0\(index).000Z"
                )
            }
            try await store.completeMediaGroupSend(
                MediaGroupSendResponse(
                    dialogId: "dialog-a",
                    clientGroupId: group.clientGroupId,
                    messages: messages,
                    senderPts: 52,
                    clearedDraftRevision: 52,
                    duplicate: false
                ),
                senderAccountId: "account-a",
                attemptedOperationId: group.draftConsumeOperationId
            )
        }

        let reopened = try CloudLocalStore(path: fixture.path, key: fixture.key)
        let snapshot = try await reopened.conversationSnapshot(dialogId: "dialog-a", window: .initial)
        XCTAssertEqual(snapshot.timeline.messages.compactMap(\.mediaGroupIndex).sorted(), [0, 1])
        XCTAssertEqual(snapshot.timeline.messages.map(\.mediaGroupCount), [2, 2])
        XCTAssertTrue(try await reopened.pendingMediaGroupSendsReady().isEmpty)
    }

    func testSingleMediaInvalidReplyRestoresCaptionMentionsAndAttachment() async throws {
        let fixture = try makeStoreFixture()
        let store = try CloudLocalStore(path: fixture.path, key: fixture.key)
        let mentions = [CloudMention(accountId: "account-b", offset: 0, length: 7)]
        _ = try await store.saveLocalDraft(
            accountId: "account-a",
            dialogId: "dialog-a",
            text: "@friend exact caption  ",
            replyToMsgId: 19,
            replyPreview: CloudDraftReplyPreview(
                msgId: 19,
                senderAccountId: "account-b",
                text: "soon deleted",
                unavailable: false
            ),
            mentions: mentions
        )
        let prepared = preparedUpload(0)
        _ = try await store.stageDraftAttachment(
            prepared: prepared,
            accountId: "account-a",
            dialogId: "dialog-a",
            attachmentId: "attachment-only",
            position: 0
        )
        try await store.updateDraftAttachment(
            transferId: prepared.transferId,
            mediaId: "media-only",
            state: "ready",
            progress: 1,
            error: nil
        )
        let draft = try XCTUnwrap(
            try await store.loadDraft(accountId: "account-a", dialogId: "dialog-a")
        )
        let transfer = try await store.consumeDraftAsSingleMedia(
            accountId: "account-a",
            dialogId: "dialog-a",
            operationId: draft.operationId
        )
        XCTAssertEqual(transfer.mentions, mentions)

        let restored = try await store.restoreSingleMediaAsDraftWithoutReply(
            transfer,
            accountId: "account-a"
        )
        XCTAssertEqual(restored.text, "@friend exact caption  ")
        XCTAssertEqual(restored.mentions, mentions)
        XCTAssertNil(restored.replyToMsgId)
        XCTAssertEqual(restored.attachments.map(\.mediaId), ["media-only"])
        XCTAssertTrue(
            try await store.conversationSnapshot(dialogId: "dialog-a", window: .initial)
                .timeline.messages.isEmpty
        )
    }

    func testTextInvalidReplyRestoresOnlyTheExactConsumedDraft() async throws {
        let fixture = try makeStoreFixture()
        let store = try CloudLocalStore(path: fixture.path, key: fixture.key)
        let mentions = [CloudMention(accountId: "account-b", offset: 0, length: 7)]
        let draft = try await store.saveLocalDraft(
            accountId: "account-a",
            dialogId: "dialog-a",
            text: "@friend exact text  ",
            replyToMsgId: 44,
            replyPreview: CloudDraftReplyPreview(
                msgId: 44,
                senderAccountId: "account-b",
                text: "deleted",
                unavailable: false
            ),
            mentions: mentions
        )
        _ = try await store.insertSending(
            dialogId: "dialog-a",
            clientMsgId: "text-send-a",
            text: draft.text,
            senderAccountId: "account-a",
            replyToMsgId: 44,
            mentions: mentions,
            draftConsumeOperationId: draft.operationId,
            requiresCloudDraftSync: false
        )
        XCTAssertNil(
            try await store.pendingDraftMutation(
                accountId: "account-a",
                dialogId: "dialog-a"
            )
        )

        let outcome = try await store.recoverTextSendAfterInvalidReply(
            clientMsgId: "text-send-a",
            accountId: "account-a"
        )
        XCTAssertEqual(outcome, .restoredDraft(dialogId: "dialog-a"))
        let restored = try await store.loadDraft(accountId: "account-a", dialogId: "dialog-a")
        XCTAssertEqual(restored?.text, "@friend exact text  ")
        XCTAssertNil(restored?.replyToMsgId)
        XCTAssertEqual(restored?.mentions, mentions)
        XCTAssertTrue(
            try await store.conversationSnapshot(dialogId: "dialog-a", window: .initial)
                .timeline.messages.isEmpty
        )
    }

    func testStaleTextInvalidReplyKeepsNewerDraftAndRetryableOldContent() async throws {
        let fixture = try makeStoreFixture()
        let store = try CloudLocalStore(path: fixture.path, key: fixture.key)
        let attempted = try await store.saveLocalDraft(
            accountId: "account-a",
            dialogId: "dialog-a",
            text: "old content",
            replyToMsgId: 12,
            replyPreview: nil,
            mentions: []
        )
        _ = try await store.insertSending(
            dialogId: "dialog-a",
            clientMsgId: "text-send-stale",
            text: attempted.text,
            senderAccountId: "account-a",
            replyToMsgId: 12,
            draftConsumeOperationId: attempted.operationId
        )
        _ = try await store.saveLocalDraft(
            accountId: "account-a",
            dialogId: "dialog-a",
            text: "newer draft",
            replyToMsgId: nil,
            replyPreview: nil,
            mentions: []
        )

        let outcome = try await store.recoverTextSendAfterInvalidReply(
            clientMsgId: "text-send-stale",
            accountId: "account-a"
        )
        XCTAssertEqual(outcome, .keptFailedMessage(dialogId: "dialog-a"))
        XCTAssertEqual(
            try await store.loadDraft(accountId: "account-a", dialogId: "dialog-a")?.text,
            "newer draft"
        )
        let failed = try await store.conversationSnapshot(dialogId: "dialog-a", window: .initial)
            .timeline.messages
        XCTAssertEqual(failed.first?.localState, "failed")
        XCTAssertNil(failed.first?.replyToMsgId)

        try await store.markRetrying(clientMsgId: "text-send-stale")
        let retry = try XCTUnwrap(try await store.pendingOutboxReady().first)
        XCTAssertEqual(retry.body, "old content")
        XCTAssertNil(retry.replyToMsgId)
    }

    private func preparedUpload(_ index: Int) -> PreparedMediaUpload {
        PreparedMediaUpload(
            transferId: "transfer-\(index)",
            kind: index.isMultiple(of: 2) ? "photo" : "video",
            contentType: index.isMultiple(of: 2) ? "image/jpeg" : "video/mp4",
            fileName: "item-\(index)",
            byteSize: 128,
            sha256: String(repeating: "\(index)", count: 64),
            durationMs: index.isMultiple(of: 2) ? nil : 1_000,
            width: 100,
            height: 100,
            encryptedSourcePath: "/tmp/item-\(index).tojmedia",
            encryptedThumbnailPath: "/tmp/item-\(index)-thumb.tojmedia"
        )
    }

    private func makeStoreFixture() throws -> (path: String, key: Data) {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return (
            directory.appending(path: "cloud-drafts.sqlite").path,
            Data("cloud-drafts-v1-test-key".utf8)
        )
    }
}

private final class DraftMockURLProtocol: URLProtocol {
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

private final class LockedDraftRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [(operationId: String, text: String)] = []

    func append(operationId: String, text: String) {
        lock.lock()
        requests.append((operationId, text))
        lock.unlock()
    }

    func snapshot() -> [(operationId: String, text: String)] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
}

private actor UploadConcurrencyProbe {
    private var active = 0
    private var peak = 0

    func enter() {
        active += 1
        peak = max(peak, active)
    }

    func leave() {
        active -= 1
    }

    func maximum() -> Int {
        peak
    }
}
