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
        let remainingMutation = try await store.pendingDraftMutation(
            accountId: "account-a",
            dialogId: "dialog-a"
        )
        XCTAssertNil(remainingMutation)
    }

    func testCoordinatorCapsDraftAttachmentUploadsAtTwo() async throws {
        let fixture = try makeStoreFixture()
        let store = try CloudLocalStore(path: fixture.path, key: fixture.key)
        let coordinator = DraftSyncCoordinator(
            api: CloudAPI(config: CloudConfig(baseURL: URL(string: "https://example.test")!))
        )
        await coordinator.configure(
            store: store,
            session: CloudSession(accountId: "account-a", deviceId: "device-a", token: "token"),
            cloudEnabled: false
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
            let pendingCount = try await store.pendingDraftMutationsReady().count
            XCTAssertEqual(pendingCount, 1)
        }

        let reopened = try CloudLocalStore(path: fixture.path, key: fixture.key)
        let draft = try await reopened.loadDraft(accountId: "account-a", dialogId: "dialog-a")
        XCTAssertEqual(draft?.text, raw + "!")
        XCTAssertEqual(draft?.state, "active")
        let reopenedPendingCount = try await reopened.pendingDraftMutationsReady().count
        XCTAssertEqual(reopenedPendingCount, 1)
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
        let pendingOperationId = try await store.pendingDraftMutationsReady().first?.operationId
        XCTAssertEqual(pendingOperationId, newer.operationId)
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
        let loadedReady = try await store.loadDraft(accountId: "account-a", dialogId: "dialog-a")
        let ready = try XCTUnwrap(loadedReady)

        let group = try await store.consumeDraftAsMediaGroup(
            accountId: "account-a",
            dialogId: "dialog-a",
            operationId: ready.operationId
        )
        XCTAssertEqual(group.payload.items.count, 3)
        XCTAssertEqual(group.payload.caption, "album caption")
        XCTAssertEqual(group.payload.replyToMsgId, 17)
        let pendingGroupIds = try await store.pendingMediaGroupSendsReady().map(\.clientGroupId)
        XCTAssertEqual(pendingGroupIds, [
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
        let pendingGroupsAfterRestore = try await store.pendingMediaGroupSendsReady()
        XCTAssertTrue(pendingGroupsAfterRestore.isEmpty)
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
            let loadedDraft = try await store.loadDraft(
                accountId: "account-a",
                dialogId: "dialog-a"
            )
            let draft = try XCTUnwrap(loadedDraft)
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
        let reopenedPendingGroups = try await reopened.pendingMediaGroupSendsReady()
        XCTAssertTrue(reopenedPendingGroups.isEmpty)
    }

    func testPartialAlbumUsesStableMediaGroupIndexSlots() {
        let first = albumLine(id: "album-first", msgId: 101, index: 0, count: 3)
        let third = albumLine(id: "album-third", msgId: 103, index: 2, count: 3)
        let slots = AlbumSlotAssignment.linesBySlot([third, first])

        XCTAssertEqual(AlbumSlotAssignment.slotCount(lines: [third, first], expectedCount: 3), 3)
        XCTAssertEqual(slots[0]?.id, first.id)
        XCTAssertNil(slots[1])
        XCTAssertEqual(slots[2]?.id, third.id)
    }

    @MainActor
    func testSelectedAlbumItemBecomesReplyTarget() {
        let defaultsName = "CloudDraftsV1Tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let model = CloudAppModel(
            useDefaultLocalStore: false,
            capabilityDefaults: defaults
        )
        DraftModelRetainer.models.append(model)
        let selected = albumLine(id: "album-selected", msgId: 202, index: 1, count: 3)

        model.beginReply(to: selected)

        let composerMode = model.composerMode
        XCTAssertEqual(
            composerMode,
            .replying(messageId: selected.id, preview: selected.text)
        )
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
        let loadedDraft = try await store.loadDraft(accountId: "account-a", dialogId: "dialog-a")
        let draft = try XCTUnwrap(loadedDraft)
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
        let snapshotAfterRestore = try await store.conversationSnapshot(
            dialogId: "dialog-a",
            window: .initial
        )
        XCTAssertTrue(snapshotAfterRestore.timeline.messages.isEmpty)
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
        let pendingMutation = try await store.pendingDraftMutation(
            accountId: "account-a",
            dialogId: "dialog-a"
        )
        XCTAssertNil(pendingMutation)

        let outcome = try await store.recoverTextSendAfterInvalidReply(
            clientMsgId: "text-send-a",
            accountId: "account-a"
        )
        XCTAssertEqual(outcome, .restoredDraft(dialogId: "dialog-a"))
        let restored = try await store.loadDraft(accountId: "account-a", dialogId: "dialog-a")
        XCTAssertEqual(restored?.text, "@friend exact text  ")
        XCTAssertNil(restored?.replyToMsgId)
        XCTAssertEqual(restored?.mentions, mentions)
        let snapshotAfterRecovery = try await store.conversationSnapshot(
            dialogId: "dialog-a",
            window: .initial
        )
        XCTAssertTrue(snapshotAfterRecovery.timeline.messages.isEmpty)
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
        let visibleDraft = try await store.loadDraft(
            accountId: "account-a",
            dialogId: "dialog-a"
        )
        XCTAssertEqual(visibleDraft?.text, "newer draft")
        let failed = try await store.conversationSnapshot(dialogId: "dialog-a", window: .initial)
            .timeline.messages
        XCTAssertEqual(failed.first?.localState, "failed")
        XCTAssertNil(failed.first?.replyToMsgId)

        try await store.markRetrying(clientMsgId: "text-send-stale")
        let pendingRetry = try await store.pendingOutboxReady().first
        let retry = try XCTUnwrap(pendingRetry)
        XCTAssertEqual(retry.body, "old content")
        XCTAssertNil(retry.replyToMsgId)
    }

    func testDelayedAcknowledgementMaterializesHigherRevisionRemoteShadow() async throws {
        let fixture = try makeStoreFixture()
        let store = try CloudLocalStore(path: fixture.path, key: fixture.key)
        let attempted = try await store.saveLocalDraft(
            accountId: "account-a",
            dialogId: "dialog-a",
            text: "device A",
            replyToMsgId: nil,
            replyPreview: nil,
            mentions: []
        )
        try await store.applyCloudDraft(
            CloudDraft(
                dialogId: "dialog-a",
                revision: 90,
                state: "active",
                text: "newer device B",
                replyToMsgId: nil,
                replyPreview: nil,
                mentions: [],
                attachments: [],
                operationId: "operation-b",
                updatedAt: "2026-07-25T12:00:02.000Z"
            ),
            accountId: "account-a"
        )
        try await store.acknowledgeDraftMutation(
            DraftMutationResponse(
                draft: CloudDraft(
                    dialogId: "dialog-a",
                    revision: 80,
                    state: "active",
                    text: "device A",
                    replyToMsgId: nil,
                    replyPreview: nil,
                    mentions: [],
                    attachments: [],
                    operationId: attempted.operationId,
                    updatedAt: "2026-07-25T12:00:01.000Z"
                ),
                duplicate: false
            ),
            accountId: "account-a",
            attemptedOperationId: attempted.operationId
        )
        let converged = try await store.loadDraft(accountId: "account-a", dialogId: "dialog-a")
        XCTAssertEqual(converged?.text, "newer device B")
        XCTAssertEqual(converged?.serverRevision, 90)
        let remaining = try await store.pendingDraftMutation(
            accountId: "account-a",
            dialogId: "dialog-a"
        )
        XCTAssertNil(remaining)
    }

    func testLogoutAndAccountSwitchRejectStaleGenerationAfterAwait() async throws {
        let fixture = try makeStoreFixture()
        let store = try CloudLocalStore(path: fixture.path, key: fixture.key)
        let requestStarted = DispatchSemaphore(value: 0)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DraftMockURLProtocol.self]
        DraftMockURLProtocol.handler = { request in
            let body = try XCTUnwrap(DraftMockURLProtocol.bodyData(from: request))
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            let operationId = try XCTUnwrap(json["operation_id"] as? String)
            requestStarted.signal()
            Thread.sleep(forTimeInterval: 0.2)
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["content-type": "application/json"]
                )!,
                try JSONSerialization.data(withJSONObject: [
                    "draft": [
                        "dialog_id": "dialog-a",
                        "revision": 42,
                        "state": "active",
                        "text": "old account",
                        "mentions": [],
                        "attachments": [],
                        "operation_id": operationId,
                        "updated_at": "2026-07-25T12:00:00.000Z",
                    ],
                    "duplicate": false,
                ])
            )
        }
        defer { DraftMockURLProtocol.handler = nil }
        let coordinator = DraftSyncCoordinator(
            api: CloudAPI(
                config: CloudConfig(baseURL: URL(string: "https://drafts.example.test")!),
                session: URLSession(configuration: configuration)
            )
        )
        await coordinator.configure(
            store: store,
            session: CloudSession(accountId: "account-a", deviceId: "device-a", token: "token-a"),
            cloudEnabled: true
        )
        _ = try await coordinator.mutate(
            dialogId: "dialog-a",
            text: "old account",
            replyToMsgId: nil,
            replyPreview: nil,
            mentions: []
        )
        let oldFlush = Task {
            await coordinator.flush(dialogId: "dialog-a", force: true)
        }
        XCTAssertEqual(requestStarted.wait(timeout: .now() + 1), .success)

        await coordinator.cancelAndWait()
        await coordinator.configure(
            store: store,
            session: CloudSession(accountId: "account-b", deviceId: "device-b", token: "token-b"),
            cloudEnabled: false
        )
        _ = try await coordinator.mutate(
            dialogId: "dialog-a",
            text: "new account",
            replyToMsgId: nil,
            replyPreview: nil,
            mentions: [],
            reason: .navigation
        )
        let oldFlushSucceeded = await oldFlush.value
        XCTAssertNotEqual(oldFlushSucceeded, .synced)

        let oldPending = try await store.pendingDraftMutation(
            accountId: "account-a",
            dialogId: "dialog-a"
        )
        XCTAssertEqual(oldPending?.text, "old account")
        let newVisible = try await coordinator.currentDraft(dialogId: "dialog-a")
        XCTAssertEqual(newVisible?.accountId, "account-b")
        XCTAssertEqual(newVisible?.text, "new account")
        await coordinator.cancelAndWait()
    }

    func testOfflineAlbumKeepsExactDependencyAndOnePendingGroupAcrossReopen() async throws {
        let fixture = try makeStoreFixture()
        let operationId: String
        let clientGroupId: String
        do {
            let store = try CloudLocalStore(path: fixture.path, key: fixture.key)
            _ = try await store.saveLocalDraft(
                accountId: "account-a",
                dialogId: "dialog-a",
                text: "offline album",
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
            let loaded = try await store.loadDraft(accountId: "account-a", dialogId: "dialog-a")
            let draft = try XCTUnwrap(loaded)
            operationId = draft.operationId
            let group = try await store.consumeDraftAsMediaGroup(
                accountId: "account-a",
                dialogId: "dialog-a",
                operationId: operationId
            )
            clientGroupId = group.clientGroupId
        }
        let reopened = try CloudLocalStore(path: fixture.path, key: fixture.key)
        let groups = try await reopened.pendingMediaGroupSendsReady()
        XCTAssertEqual(groups.map(\.clientGroupId), [clientGroupId])
        XCTAssertEqual(groups.first?.draftConsumeOperationId, operationId)
        let dependency = try await reopened.pendingDraftDependency(operationId: operationId)
        XCTAssertEqual(dependency?.text, "offline album")
        let snapshot = try await reopened.conversationSnapshot(dialogId: "dialog-a", window: .initial)
        XCTAssertEqual(snapshot.timeline.messages.count, 2)
        XCTAssertEqual(Set(snapshot.timeline.messages.compactMap(\.mediaGroupId)), [clientGroupId])
    }

    func testAlbumAcknowledgementCleanupSurvivesCrashAndReconcilesOnce() async throws {
        let fixture = try makeStoreFixture()
        let group: PendingMediaGroupSend
        do {
            let store = try CloudLocalStore(path: fixture.path, key: fixture.key)
            _ = try await store.saveLocalDraft(
                accountId: "account-a",
                dialogId: "dialog-a",
                text: "cleanup",
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
            let loaded = try await store.loadDraft(accountId: "account-a", dialogId: "dialog-a")
            let draft = try XCTUnwrap(loaded)
            group = try await store.consumeDraftAsMediaGroup(
                accountId: "account-a",
                dialogId: "dialog-a",
                operationId: draft.operationId
            )
            let messages = group.payload.items.enumerated().map { index, item in
                CloudMessage(
                    dialogId: "dialog-a",
                    msgId: Int64(200 + index),
                    senderAccountId: "account-a",
                    clientMsgId: item.clientMsgId,
                    kind: item.media.kind,
                    text: index == 0 ? "cleanup" : "",
                    media: item.media,
                    mediaGroupId: group.clientGroupId,
                    mediaGroupIndex: index,
                    mediaGroupCount: 2,
                    editVersion: 0,
                    state: "visible",
                    serverTs: "2026-07-25T12:00:00.000Z"
                )
            }
            try await store.completeMediaGroupSend(
                MediaGroupSendResponse(
                    dialogId: "dialog-a",
                    clientGroupId: group.clientGroupId,
                    messages: messages,
                    senderPts: 12,
                    clearedDraftRevision: 12,
                    duplicate: false
                ),
                senderAccountId: "account-a",
                attemptedOperationId: group.draftConsumeOperationId
            )
        }
        let reopened = try CloudLocalStore(path: fixture.path, key: fixture.key)
        let cleanupRows = try await reopened.pendingMediaGroupCleanups()
        let cleanup = try XCTUnwrap(cleanupRows.first)
        XCTAssertEqual(cleanup.clientGroupId, group.clientGroupId)
        XCTAssertEqual(cleanup.transferIds.count, 2)
        let sendsAfterAck = try await reopened.pendingMediaGroupSendsReady()
        XCTAssertTrue(sendsAfterAck.isEmpty)
        try await reopened.finalizeMediaGroupCleanup(cleanup)
        let cleanupsAfterFinalize = try await reopened.pendingMediaGroupCleanups()
        let transfersAfterFinalize = try await reopened.mediaTransfers(ids: cleanup.transferIds)
        XCTAssertTrue(cleanupsAfterFinalize.isEmpty)
        XCTAssertTrue(transfersAfterFinalize.isEmpty)
    }

    func testConcurrentStagingAllocatesUniqueContiguousPositions() async throws {
        let fixture = try makeStoreFixture()
        let store = try CloudLocalStore(path: fixture.path, key: fixture.key)
        let uploads = (0..<10).map(preparedUpload)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for position in 0..<10 {
                let prepared = uploads[position]
                group.addTask {
                    _ = try await store.stageDraftAttachment(
                        prepared: prepared,
                        accountId: "account-a",
                        dialogId: "dialog-a",
                        attachmentId: "attachment-\(position)",
                        position: 0
                    )
                }
            }
            try await group.waitForAll()
        }
        let draft = try await store.loadDraft(accountId: "account-a", dialogId: "dialog-a")
        XCTAssertEqual(draft?.attachments.map(\.position).sorted(), Array(0..<10))
        XCTAssertEqual(Set(draft?.attachments.map(\.position) ?? []).count, 10)
    }

    func testDoubleTapConsumesOneAlbumOperationOnlyOnce() async throws {
        let fixture = try makeStoreFixture()
        let store = try CloudLocalStore(path: fixture.path, key: fixture.key)
        _ = try await store.saveLocalDraft(
            accountId: "account-a",
            dialogId: "dialog-a",
            text: "one tap",
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
        let loaded = try await store.loadDraft(accountId: "account-a", dialogId: "dialog-a")
        let operationId = try XCTUnwrap(loaded?.operationId)
        let successes = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    do {
                        _ = try await store.consumeDraftAsMediaGroup(
                            accountId: "account-a",
                            dialogId: "dialog-a",
                            operationId: operationId
                        )
                        return true
                    } catch {
                        return false
                    }
                }
            }
            var count = 0
            for await success in group where success { count += 1 }
            return count
        }
        XCTAssertEqual(successes, 1)
        let pendingGroupCount = try await store.pendingMediaGroupSendsReady().count
        XCTAssertEqual(pendingGroupCount, 1)
    }

    func test401SuspendsCoordinatorWithoutTerminalizingDurableMutation() async throws {
        let fixture = try makeStoreFixture()
        let store = try CloudLocalStore(path: fixture.path, key: fixture.key)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DraftMockURLProtocol.self]
        DraftMockURLProtocol.handler = { request in
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 401,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["content-type": "application/json"]
                )!,
                Data(#"{"error":"expired","code":"session_expired"}"#.utf8)
            )
        }
        defer { DraftMockURLProtocol.handler = nil }
        let coordinator = DraftSyncCoordinator(
            api: CloudAPI(
                config: CloudConfig(baseURL: URL(string: "https://drafts.example.test")!),
                session: URLSession(configuration: configuration)
            )
        )
        await coordinator.configure(
            store: store,
            session: CloudSession(accountId: "account-a", deviceId: "device-a", token: "expired"),
            cloudEnabled: true
        )
        _ = try await coordinator.mutate(
            dialogId: "dialog-a",
            text: "must survive auth",
            replyToMsgId: nil,
            replyPreview: nil,
            mentions: [],
            reason: .navigation
        )
        let flushed = await coordinator.flush(dialogId: "dialog-a", force: true)
        XCTAssertEqual(flushed, .suspended)
        let pending = try await store.pendingDraftMutation(accountId: "account-a", dialogId: "dialog-a")
        XCTAssertEqual(pending?.text, "must survive auth")
        XCTAssertFalse(pending?.terminal ?? true)
        await coordinator.cancelAndWait()
    }

    func testHundredQueuedDraftsStopAfterFirstNetworkFailure() async throws {
        let fixture = try makeStoreFixture()
        let store = try CloudLocalStore(path: fixture.path, key: fixture.key)
        for index in 0..<100 {
            _ = try await store.saveLocalDraft(
                accountId: "account-a",
                dialogId: "dialog-\(index)",
                text: "queued \(index)",
                replyToMsgId: nil,
                replyPreview: nil,
                mentions: []
            )
        }
        let requests = LockedDraftRequests()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DraftMockURLProtocol.self]
        DraftMockURLProtocol.handler = { request in
            requests.append(operationId: "failed", text: request.url?.path ?? "")
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 503,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["content-type": "application/json"]
                )!,
                Data(#"{"error":"unavailable","code":"temporarily_unavailable"}"#.utf8)
            )
        }
        defer { DraftMockURLProtocol.handler = nil }
        let coordinator = DraftSyncCoordinator(
            api: CloudAPI(
                config: CloudConfig(baseURL: URL(string: "https://drafts.example.test")!),
                session: URLSession(configuration: configuration)
            )
        )
        await coordinator.configure(
            store: store,
            session: CloudSession(accountId: "account-a", deviceId: "device-a", token: "token"),
            cloudEnabled: true
        )
        await coordinator.flushAll(reason: .navigation)
        XCTAssertEqual(requests.snapshot().count, 1)
        let stillQueued = try await store.pendingDraftDialogIds(accountId: "account-a")
        XCTAssertEqual(stillQueued.count, 100)
        await coordinator.cancelAndWait()
    }

    func testCapabilityWithdrawalPreservesDraftDependentSendAndExcludesRetryDelay() async throws {
        XCTAssertEqual(
            cloudFailureDisposition(
                CloudAPIError(
                    status: 404,
                    message: "feature killed",
                    retryAfter: nil,
                    code: "capability_unavailable"
                )
            ),
            .unsupportedServer
        )
        XCTAssertEqual(
            cloudFailureDisposition(
                CloudAPIError(
                    status: 404,
                    message: "resource missing",
                    retryAfter: nil,
                    code: "media_not_found"
                )
            ),
            .permanent
        )

        let fixture = try makeStoreFixture()
        let store = try CloudLocalStore(path: fixture.path, key: fixture.key)
        _ = try await store.saveLocalDraft(
            accountId: "account-a",
            dialogId: "dialog-a",
            text: "preserve me",
            replyToMsgId: nil,
            replyPreview: nil,
            mentions: []
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
        let loaded = try await store.loadDraft(accountId: "account-a", dialogId: "dialog-a")
        let draft = try XCTUnwrap(loaded)
        let transfer = try await store.consumeDraftAsSingleMedia(
            accountId: "account-a",
            dialogId: "dialog-a",
            operationId: draft.operationId
        )
        XCTAssertEqual(transfer.draftOperationId, draft.operationId)
        _ = try await store.insertSending(
            dialogId: "dialog-a",
            clientMsgId: "capability-withdrawn-text",
            text: "queued text",
            senderAccountId: "account-a",
            draftConsumeOperationId: draft.operationId
        )
        let disabledOutbox = try await store.pendingOutboxReady(
            includeCloudDraftDependencies: false
        )
        XCTAssertTrue(disabledOutbox.isEmpty)
        let disabledOutboxDelay = try await store.nextPendingOutboxDelay(
            includeCloudDraftDependencies: false
        )
        XCTAssertNil(disabledOutboxDelay)
        let enabledOutbox = try await store.pendingOutboxReady(
            includeCloudDraftDependencies: true
        )
        XCTAssertEqual(enabledOutbox.count, 1)
        let disabledDelay = try await store.nextMediaTransferDelay(
            includeCloudDraftDependencies: false
        )
        XCTAssertNil(disabledDelay)
        let enabledDelay = try await store.nextMediaTransferDelay(
            includeCloudDraftDependencies: true
        )
        XCTAssertEqual(enabledDelay, 0)
        let dependency = try await store.pendingDraftDependency(operationId: draft.operationId)
        XCTAssertNotNil(dependency)
        try await store.markDraftDependencyFailed(
            operationId: draft.operationId,
            error: "resource missing",
            retryAfter: nil,
            terminal: true
        )
        let terminalDependency = try await store.pendingDraftDependency(operationId: draft.operationId)
        XCTAssertTrue(terminalDependency?.terminal ?? false)
        let terminalOutbox = try await store.pendingOutboxReady(
            includeCloudDraftDependencies: true
        )
        let terminalMediaDelay = try await store.nextMediaTransferDelay(
            includeCloudDraftDependencies: true
        )
        XCTAssertTrue(terminalOutbox.isEmpty)
        XCTAssertNil(terminalMediaDelay)
        let failedSnapshot = try await store.conversationSnapshot(
            dialogId: "dialog-a",
            window: .initial
        )
        XCTAssertTrue(failedSnapshot.timeline.messages.allSatisfy { $0.localState == "failed" })
    }

    func testServerRestoredAttachmentsSendOnAnotherDeviceAndPreserveOriginalTransferId() async throws {
        let fixture = try makeStoreFixture()
        let store = try CloudLocalStore(path: fixture.path, key: fixture.key)
        _ = try await store.saveLocalDraft(
            accountId: "account-a",
            dialogId: "dialog-local",
            text: "single",
            replyToMsgId: nil,
            replyPreview: nil,
            mentions: []
        )
        let prepared = preparedUpload(0)
        _ = try await store.stageDraftAttachment(
            prepared: prepared,
            accountId: "account-a",
            dialogId: "dialog-local",
            attachmentId: "attachment-local",
            position: 0
        )
        try await store.updateDraftAttachment(
            transferId: prepared.transferId,
            mediaId: "media-local",
            state: "ready",
            progress: 1,
            error: nil
        )
        let loadedLocal = try await store.loadDraft(
            accountId: "account-a",
            dialogId: "dialog-local"
        )
        let local = try XCTUnwrap(loadedLocal)
        let canonical = cloudDraft(
            dialogId: "dialog-local",
            operationId: local.operationId,
            revision: 5,
            mediaIds: ["media-local"]
        )
        try await store.acknowledgeDraftMutation(
            DraftMutationResponse(draft: canonical, duplicate: false),
            accountId: "account-a",
            attemptedOperationId: local.operationId
        )
        let loadedReconciled = try await store.loadDraft(
            accountId: "account-a",
            dialogId: "dialog-local"
        )
        let reconciled = try XCTUnwrap(loadedReconciled)
        XCTAssertEqual(reconciled.attachments.first?.transferId, prepared.transferId)
        let single = try await store.consumeDraftAsSingleMedia(
            accountId: "account-a",
            dialogId: "dialog-local",
            operationId: reconciled.operationId
        )
        XCTAssertEqual(single.mediaId, "media-local")

        let otherFixture = try makeStoreFixture()
        let other = try CloudLocalStore(path: otherFixture.path, key: otherFixture.key)
        let remoteAlbum = cloudDraft(
            dialogId: "dialog-remote",
            operationId: "operation-remote",
            revision: 7,
            mediaIds: ["media-1", "media-2", "media-3"]
        )
        try await other.applyCloudDraft(remoteAlbum, accountId: "account-a")
        let loadedRestored = try await other.loadDraft(
            accountId: "account-a",
            dialogId: "dialog-remote"
        )
        let restored = try XCTUnwrap(loadedRestored)
        XCTAssertTrue(restored.attachments.allSatisfy { $0.transferId?.hasPrefix("server:") == true })
        let group = try await other.consumeDraftAsMediaGroup(
            accountId: "account-a",
            dialogId: "dialog-remote",
            operationId: restored.operationId
        )
        XCTAssertEqual(group.payload.items.map(\.mediaId), ["media-1", "media-2", "media-3"])
    }

    func testIdleAcknowledgedDraftAttachmentNeverEntersGenericTransferRetryLane() async throws {
        let fixture = try makeStoreFixture()
        let store = try CloudLocalStore(path: fixture.path, key: fixture.key)
        let draft = cloudDraft(
            dialogId: "dialog-idle",
            operationId: "operation-idle",
            revision: 11,
            mediaIds: ["media-idle"]
        )
        try await store.applyCloudDraft(draft, accountId: "account-a")
        let beforeChanges = try await store.debugSQLiteTotalChanges()
        for _ in 0..<100 {
            let ready = try await store.mediaTransfersReady()
            let delay = try await store.nextMediaTransferDelay()
            XCTAssertTrue(ready.isEmpty)
            XCTAssertNil(delay)
        }
        let afterChanges = try await store.debugSQLiteTotalChanges()
        XCTAssertEqual(afterChanges, beforeChanges)
        let pending = try await store.pendingDraftMutation(
            accountId: "account-a",
            dialogId: "dialog-idle"
        )
        XCTAssertNil(pending)
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

    private func cloudDraft(
        dialogId: String,
        operationId: String,
        revision: Int64,
        mediaIds: [String]
    ) -> CloudDraft {
        CloudDraft(
            dialogId: dialogId,
            revision: revision,
            state: "active",
            text: "restored caption",
            replyToMsgId: nil,
            replyPreview: nil,
            mentions: [],
            attachments: mediaIds.enumerated().map { index, mediaId in
                CloudDraftAttachment(
                    attachmentId: "attachment-\(dialogId)-\(index)",
                    mediaId: mediaId,
                    position: index,
                    media: CloudMedia(
                        id: mediaId,
                        kind: index.isMultiple(of: 2) ? "photo" : "video",
                        contentType: index.isMultiple(of: 2) ? "image/jpeg" : "video/mp4",
                        fileName: "restored-\(index)",
                        byteSize: 128,
                        durationMs: index.isMultiple(of: 2) ? nil : 1_000,
                        width: 100,
                        height: 100,
                        hasThumbnail: false
                    )
                )
            },
            operationId: operationId,
            updatedAt: "2026-07-26T12:00:00.000Z"
        )
    }

    private func albumLine(
        id: String,
        msgId: Int64,
        index: Int,
        count: Int
    ) -> CloudAppModel.Line {
        CloudAppModel.Line(
            id: id,
            dialogId: "dialog-a",
            msgId: msgId,
            clientMsgId: "client-\(id)",
            text: "album item \(index + 1)",
            mine: false,
            delivery: .sent,
            mediaGroupId: "album-a",
            mediaGroupIndex: index,
            mediaGroupCount: count
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

private enum DraftModelRetainer {
    @MainActor static var models: [CloudAppModel] = []
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
