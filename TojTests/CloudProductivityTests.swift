import Foundation
import GRDB
import XCTest
@testable import Toj

final class CloudProductivityTests: XCTestCase {
    func testMediaLimitRemainsDarkGatedAtTwentyFiveMegabytes() {
        let exactLimit = Int64(25 * 1024 * 1024)
        XCTAssertEqual(TojMediaLimits.maximumMessageBytes, exactLimit)
        XCTAssertEqual(TojMediaLimits.maximumMessageBytesInt, Int(exactLimit))
        XCTAssertEqual(TojMediaLimits.displayMaximum, "25 MB")
        XCTAssertLessThan(TojMediaLimits.maximumMessageBytes, Int64(25 * 1024 * 1024 + 1))
        XCTAssertLessThan(TojMediaLimits.maximumMessageBytes, Int64(100 * 1024 * 1024))
    }

    func testLinkCandidateUsesUTF16RangeAndPreservesExactMessageSubstring() throws {
        let text = "👨‍👩‍👧‍👦 see https://example.com/path"
        let candidate = try XCTUnwrap(CloudLinkPreviewCandidate.first(in: text))
        XCTAssertEqual(candidate.url, "https://example.com/path")
        XCTAssertEqual(
            (text as NSString).substring(
                with: NSRange(location: candidate.utf16Offset, length: candidate.utf16Length)
            ),
            candidate.url
        )
    }

    func testFoldersAndServerSchedulesSurviveEncryptedStoreRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("toj-productivity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("cloud.sqlite").path
        let key = Data(repeating: 0x5A, count: 32)
        let accountId = "11111111-1111-4111-8111-111111111111"
        let dialogId = "22222222-2222-4222-8222-222222222222"
        let folder = CloudChatFolder(
            folderId: "33333333-3333-4333-8333-333333333333",
            title: "Family",
            icon: "family",
            position: 0,
            includeDirect: true,
            includeGroups: false,
            includeSaved: false,
            excludeRead: false,
            excludeMuted: false,
            excludeArchived: true,
            revision: 4,
            rules: [CloudChatFolderRule(dialogId: dialogId, rule: "include")],
            createdAt: "2026-08-04T00:00:00.000Z",
            updatedAt: "2026-08-04T00:00:00.000Z"
        )
        let delivery = CloudScheduledDelivery(
            scheduleId: "44444444-4444-4444-8444-444444444444",
            dialogId: dialogId,
            deliverAt: "2026-08-05T12:00:00.000Z",
            state: "scheduled",
            silent: false,
            reminder: false,
            revision: 8,
            attempts: 0,
            lastErrorCode: nil,
            deliveredFirstMsgId: nil,
            deliveredLastMsgId: nil,
            items: [CloudScheduledItem(
                clientMsgId: "55555555-5555-4555-8555-555555555555",
                kind: "text",
                body: "Later",
                replyToMsgId: nil,
                mediaId: nil,
                mentions: [],
                linkPreviewCandidate: nil
            )],
            createdAt: "2026-08-04T00:00:00.000Z",
            updatedAt: "2026-08-04T00:00:00.000Z",
            completedAt: nil
        )

        do {
            let store = try CloudLocalStore(path: path, key: key)
            try await store.saveChatFolderSnapshot(
                CloudChatFolderSnapshot(
                    collectionRevision: 4,
                    folders: [folder],
                    clientMutationId: nil,
                    pts: nil,
                    duplicate: nil
                ),
                accountId: accountId
            )
            try await store.upsertScheduledDelivery(delivery, accountId: accountId)
        }

        let relaunched = try CloudLocalStore(path: path, key: key)
        let restoredFolders = try await relaunched.chatFolderSnapshot(accountId: accountId)
        let restoredSchedules = try await relaunched.scheduledDeliveries(accountId: accountId)
        XCTAssertEqual(restoredFolders?.folders, [folder])
        XCTAssertEqual(restoredSchedules, [delivery])
    }

    func testOlderFolderAndScheduleSnapshotsCannotOverwriteNewerLocalState() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("toj-productivity-order-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CloudLocalStore(
            path: directory.appendingPathComponent("cloud.sqlite").path,
            key: Data(repeating: 0x31, count: 32)
        )
        let accountId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let newer = CloudChatFolderSnapshot(
            collectionRevision: 9, folders: [], clientMutationId: nil, pts: nil, duplicate: nil
        )
        let older = CloudChatFolderSnapshot(
            collectionRevision: 8, folders: [], clientMutationId: nil, pts: nil, duplicate: nil
        )
        try await store.saveChatFolderSnapshot(newer, accountId: accountId)
        try await store.saveChatFolderSnapshot(older, accountId: accountId)
        let restoredRevision = try await store.chatFolderSnapshot(
            accountId: accountId
        )?.collectionRevision
        XCTAssertEqual(restoredRevision, 9)
    }

    func testUnacknowledgedScheduleKeepsStableIdsAcrossRelaunchAndReconcilesOnAck() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("toj-schedule-outbox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("cloud.sqlite").path
        let key = Data(repeating: 0x73, count: 32)
        let accountId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let dialogId = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        let request = CloudScheduledCreateRequest(
            scheduleId: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
            clientMutationId: "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
            dialogId: dialogId,
            deliverAt: "2026-08-05T12:00:00.000Z",
            silent: false,
            reminder: false,
            items: [CloudScheduledItem(
                clientMsgId: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
                kind: "text",
                body: "Send once",
                replyToMsgId: nil,
                mediaId: nil,
                mentions: [],
                linkPreviewCandidate: nil
            )]
        )
        do {
            let store = try CloudLocalStore(path: path, key: key)
            let local = try await store.stageScheduledCreate(
                request,
                accountId: accountId,
                draftOperationId: "draft-operation"
            )
            XCTAssertEqual(local.state, "local_pending")
        }

        let relaunched = try CloudLocalStore(path: path, key: key)
        let pending = try await relaunched.pendingScheduledCreatesReady(accountId: accountId)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.request.scheduleId, request.scheduleId)
        XCTAssertEqual(pending.first?.request.clientMutationId, request.clientMutationId)
        XCTAssertEqual(pending.first?.request.items.first?.clientMsgId, request.items.first?.clientMsgId)

        let acknowledged = CloudScheduledDelivery(
            scheduleId: request.scheduleId,
            dialogId: dialogId,
            deliverAt: request.deliverAt,
            state: "scheduled",
            silent: false,
            reminder: false,
            revision: 1,
            attempts: 0,
            lastErrorCode: nil,
            deliveredFirstMsgId: nil,
            deliveredLastMsgId: nil,
            items: request.items,
            createdAt: "2026-08-04T00:00:00.000Z",
            updatedAt: "2026-08-04T00:00:00.000Z",
            completedAt: nil
        )
        try await relaunched.acknowledgeScheduledCreate(
            CloudScheduledMutationResponse(
                scheduledDelivery: acknowledged,
                collectionRevision: 1,
                pts: 1,
                clientMutationId: request.clientMutationId,
                duplicate: false,
                serverNow: "2026-08-04T00:00:00.000Z"
            ),
            accountId: accountId
        )
        let pendingAfterAck = try await relaunched.pendingScheduledCreatesReady(accountId: accountId)
        let deliveriesAfterAck = try await relaunched.scheduledDeliveries(accountId: accountId)
        XCTAssertTrue(pendingAfterAck.isEmpty)
        XCTAssertEqual(deliveriesAfterAck, [acknowledged])
    }

    func testScheduledRefreshTraversesEveryPageBeyondLegacy150RowBoundary() async throws {
        let fixture = try makeStoreFixture("paging")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let deliveries = (0..<205).map { makeDelivery(index: $0, revision: 42) }
        let session = makeMockSession { request in
            XCTAssertEqual(self.queryValue("limit", in: request), "100")
            let page: CloudScheduledListResponse
            switch self.queryValue("cursor", in: request) {
            case nil:
                page = CloudScheduledListResponse(
                    collectionRevision: 42,
                    deliveries: Array(deliveries[0..<100]),
                    nextCursor: "page-2"
                )
            case "page-2":
                page = CloudScheduledListResponse(
                    collectionRevision: 42,
                    deliveries: Array(deliveries[100..<200]),
                    nextCursor: "page-3"
                )
            case "page-3":
                page = CloudScheduledListResponse(
                    collectionRevision: 42,
                    deliveries: Array(deliveries[200..<205]),
                    nextCursor: nil
                )
            default:
                XCTFail("Unexpected cursor")
                page = CloudScheduledListResponse(
                    collectionRevision: 42, deliveries: [], nextCursor: nil
                )
            }
            return try self.jsonResponse(page, for: request)
        }
        defer { CloudProductivityMockURLProtocol.handler = nil }
        let coordinator = CloudProductivitySyncCoordinator()
        await coordinator.bind(operationContext(store: fixture.store))
        let api = CloudAPI(config: testCloudConfig(), session: session)

        let accepted = try await coordinator.refreshScheduledDeliveries(api: api)
        XCTAssertTrue(accepted)
        let restored = try await fixture.store.scheduledDeliveries(accountId: Self.accountId)
        XCTAssertEqual(restored.count, 205)
        let revision = try await fixture.store.scheduledCollectionRevision(accountId: Self.accountId)
        XCTAssertEqual(revision, 42)
    }

    func testFailedSecondPageRetainsPreviouslyAcceptedScheduleCache() async throws {
        let fixture = try makeStoreFixture("page-failure")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let cached = makeDelivery(index: 900, revision: 20)
        let seeded = try await fixture.store.replaceScheduledDeliveries(
            [cached], collectionRevision: 20, accountId: Self.accountId
        )
        XCTAssertTrue(seeded)
        let session = makeMockSession { request in
            if self.queryValue("cursor", in: request) == nil {
                return try self.jsonResponse(
                    CloudScheduledListResponse(
                        collectionRevision: 21,
                        deliveries: [self.makeDelivery(index: 901, revision: 21)],
                        nextCursor: "page-2"
                    ),
                    for: request
                )
            }
            return (
                try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 503, httpVersion: nil,
                    headerFields: ["content-type": "application/json"]
                )),
                Data("{\"error\":\"try later\"}".utf8)
            )
        }
        defer { CloudProductivityMockURLProtocol.handler = nil }
        let coordinator = CloudProductivitySyncCoordinator()
        await coordinator.bind(operationContext(store: fixture.store))

        do {
            _ = try await coordinator.refreshScheduledDeliveries(
                api: CloudAPI(config: testCloudConfig(), session: session)
            )
            XCTFail("Expected the incomplete traversal to fail")
        } catch {
            XCTAssertEqual((error as? CloudAPIError)?.status, 503)
        }
        let retained = try await fixture.store.scheduledDeliveries(accountId: Self.accountId)
        XCTAssertEqual(retained, [cached])
        let revision = try await fixture.store.scheduledCollectionRevision(accountId: Self.accountId)
        XCTAssertEqual(revision, 20)
    }

    func testRevisionDriftRestartsThreeTimesThenRetainsCache() async throws {
        let fixture = try makeStoreFixture("revision-drift")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let cached = makeDelivery(index: 910, revision: 30)
        let seeded = try await fixture.store.replaceScheduledDeliveries(
            [cached], collectionRevision: 30, accountId: Self.accountId
        )
        XCTAssertTrue(seeded)
        let counter = ProductivityLockedCounter()
        let session = makeMockSession { request in
            counter.increment()
            let isFirstPage = self.queryValue("cursor", in: request) == nil
            return try self.jsonResponse(
                CloudScheduledListResponse(
                    collectionRevision: isFirstPage ? 31 : 32,
                    deliveries: [self.makeDelivery(
                        index: isFirstPage ? 911 : 912,
                        revision: isFirstPage ? 31 : 32
                    )],
                    nextCursor: isFirstPage ? "page-2" : nil
                ),
                for: request
            )
        }
        defer { CloudProductivityMockURLProtocol.handler = nil }
        let coordinator = CloudProductivitySyncCoordinator()
        await coordinator.bind(operationContext(store: fixture.store))

        do {
            _ = try await coordinator.refreshScheduledDeliveries(
                api: CloudAPI(config: testCloudConfig(), session: session)
            )
            XCTFail("Expected repeated revision drift to fail")
        } catch CloudProductivityRefreshError.collectionChanged {
            // One initial traversal plus the three permitted revision-drift restarts.
            XCTAssertEqual(counter.value, 8)
        }
        let retained = try await fixture.store.scheduledDeliveries(accountId: Self.accountId)
        XCTAssertEqual(retained, [cached])
    }

    func testCursorLoopsAndDuplicateIdsNeverReplaceTheCache() async throws {
        for defect in ["cursor", "duplicate"] {
            let fixture = try makeStoreFixture(defect)
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let cached = makeDelivery(index: defect == "cursor" ? 920 : 930, revision: 40)
            let seeded = try await fixture.store.replaceScheduledDeliveries(
                [cached], collectionRevision: 40, accountId: Self.accountId
            )
            XCTAssertTrue(seeded)
            let repeated = makeDelivery(index: 931, revision: 41)
            let session = makeMockSession { request in
                let first = self.queryValue("cursor", in: request) == nil
                return try self.jsonResponse(
                    CloudScheduledListResponse(
                        collectionRevision: 41,
                        deliveries: defect == "duplicate" ? [repeated] : [
                            self.makeDelivery(index: first ? 921 : 922, revision: 41),
                        ],
                        nextCursor: first ? "same-cursor" : (defect == "cursor" ? "same-cursor" : nil)
                    ),
                    for: request
                )
            }
            defer { CloudProductivityMockURLProtocol.handler = nil }
            let coordinator = CloudProductivitySyncCoordinator()
            await coordinator.bind(operationContext(store: fixture.store))
            do {
                _ = try await coordinator.refreshScheduledDeliveries(
                    api: CloudAPI(config: testCloudConfig(), session: session)
                )
                XCTFail("Expected \(defect) traversal failure")
            } catch CloudProductivityRefreshError.cursorLoop where defect == "cursor" {
            } catch CloudProductivityRefreshError.duplicateDelivery where defect == "duplicate" {
            }
            let retained = try await fixture.store.scheduledDeliveries(accountId: Self.accountId)
            XCTAssertEqual(retained, [cached])
        }
    }

    func testStaleSnapshotIsRejectedAndCompleteSnapshotPreservesPendingOverlay() async throws {
        let fixture = try makeStoreFixture("revision-overlay")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let deliveries = (0..<151).map { makeDelivery(index: $0, revision: 50) }
        let seeded = try await fixture.store.replaceScheduledDeliveries(
            deliveries, collectionRevision: 50, accountId: Self.accountId
        )
        XCTAssertTrue(seeded)
        _ = try await fixture.store.stageScheduledDeliveryMutation(
            CloudScheduledMutationIntent(
                operation: .cancel,
                scheduleId: deliveries[0].scheduleId,
                deliverAt: nil
            ),
            accountId: Self.accountId
        )

        let staleAccepted = try await fixture.store.replaceScheduledDeliveries(
            [], collectionRevision: 49, accountId: Self.accountId
        )
        XCTAssertFalse(staleAccepted)
        let retainedCount = try await fixture.store.scheduledDeliveries(
            accountId: Self.accountId
        ).count
        XCTAssertEqual(retainedCount, 151)
        let completeAccepted = try await fixture.store.replaceScheduledDeliveries(
            [deliveries[1]], collectionRevision: 51, accountId: Self.accountId
        )
        XCTAssertTrue(completeAccepted)
        let effective = try await fixture.store.scheduledDeliveries(accountId: Self.accountId)
        XCTAssertEqual(effective.count, 2)
        XCTAssertEqual(
            effective.first(where: { $0.scheduleId == deliveries[0].scheduleId })?.state,
            "cancel_pending"
        )
        let revision = try await fixture.store.scheduledCollectionRevision(accountId: Self.accountId)
        XCTAssertEqual(revision, 51)
    }

    func testDurableFolderAndScheduleJournalsSurviveRelaunchWithExactRequest() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("toj-productivity-journal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("cloud.sqlite").path
        let key = Data(repeating: 0x77, count: 32)
        let originalFolder = makeFolder(title: "Work", revision: 5)
        let renamedFolder = makeFolder(title: "Work now", revision: 5)
        let schedule = makeDelivery(index: 940, revision: 7)
        var preparedFolder: PendingChatFolderMutation?
        var preparedSchedule: PendingScheduledDeliveryMutation?
        do {
            let store = try CloudLocalStore(path: path, key: key)
            try await store.saveChatFolderSnapshot(
                CloudChatFolderSnapshot(
                    collectionRevision: 5,
                    folders: [originalFolder],
                    clientMutationId: nil,
                    pts: nil,
                    duplicate: nil
                ),
                accountId: Self.accountId
            )
            _ = try await store.stageChatFolderMutation(
                CloudFolderMutationIntent(
                    operation: .update,
                    folderId: originalFolder.folderId,
                    folder: renamedFolder,
                    beforeFolderId: nil,
                    afterFolderId: nil
                ),
                accountId: Self.accountId
            )
            let pending = try await store.pendingChatFolderMutationsReady(accountId: Self.accountId)
            preparedFolder = try await store.prepareChatFolderMutation(
                localOperationId: try XCTUnwrap(pending.first?.localOperationId),
                accountId: Self.accountId
            )
            try await store.upsertScheduledDelivery(
                schedule, collectionRevision: 7, accountId: Self.accountId
            )
            _ = try await store.stageScheduledDeliveryMutation(
                CloudScheduledMutationIntent(
                    operation: .reschedule,
                    scheduleId: schedule.scheduleId,
                    deliverAt: "2026-09-01T12:00:00.000Z"
                ),
                accountId: Self.accountId
            )
            let pendingSchedules = try await store.pendingScheduledDeliveryMutationsReady(
                accountId: Self.accountId
            )
            preparedSchedule = try await store.prepareScheduledDeliveryMutation(
                localOperationId: try XCTUnwrap(pendingSchedules.first?.localOperationId),
                accountId: Self.accountId
            )
        }

        let relaunched = try CloudLocalStore(path: path, key: key)
        let folders = try await relaunched.effectiveChatFolderSnapshot(accountId: Self.accountId)
        XCTAssertEqual(folders.folders.first?.title, "Work now")
        let restoredFolderMutations = try await relaunched.pendingChatFolderMutationsReady(
            accountId: Self.accountId
        )
        let restoredFolder = try XCTUnwrap(restoredFolderMutations.first)
        XCTAssertEqual(restoredFolder.clientMutationId, preparedFolder?.clientMutationId)
        XCTAssertEqual(restoredFolder.request?.clientMutationId, preparedFolder?.request?.clientMutationId)
        XCTAssertEqual(restoredFolder.requestData, preparedFolder?.requestData)
        XCTAssertEqual(restoredFolder.request?.title, "Work now")
        let restoredScheduleMutations = try await relaunched
            .pendingScheduledDeliveryMutationsReady(accountId: Self.accountId)
        let restoredSchedule = try XCTUnwrap(restoredScheduleMutations.first)
        XCTAssertEqual(restoredSchedule.clientMutationId, preparedSchedule?.clientMutationId)
        XCTAssertEqual(restoredSchedule.requestData, preparedSchedule?.requestData)
        let restoredSchedules = try await relaunched.scheduledDeliveries(accountId: Self.accountId)
        XCTAssertEqual(restoredSchedules.first?.state, "reschedule_pending")
        XCTAssertEqual(restoredSchedules.first?.deliverAt, "2026-09-01T12:00:00.000Z")

        try await relaunched.clearAccount(accountId: Self.accountId)
        let clearedFolders = try await relaunched.pendingChatFolderMutationsReady(
            accountId: Self.accountId
        )
        let clearedSchedules = try await relaunched.pendingScheduledDeliveryMutationsReady(
            accountId: Self.accountId
        )
        let clearedCreates = try await relaunched.pendingScheduledCreatesReady(
            accountId: Self.accountId
        )
        XCTAssertTrue(clearedFolders.isEmpty)
        XCTAssertTrue(clearedSchedules.isEmpty)
        XCTAssertTrue(clearedCreates.isEmpty)
        let clearedSnapshot = try await relaunched.chatFolderSnapshot(accountId: Self.accountId)
        XCTAssertNil(clearedSnapshot)
    }

    func testCancellationDistinguishesNeverAttemptedAndUncertainCreates() async throws {
        let fixture = try makeStoreFixture("create-cancel")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let first = makeCreateRequest(index: 950)
        _ = try await fixture.store.stageScheduledCreate(
            first, accountId: Self.accountId, draftOperationId: nil
        )
        let discarded = try await fixture.store.discardUnattemptedScheduledCreate(
            scheduleId: first.scheduleId, accountId: Self.accountId
        )
        XCTAssertTrue(discarded)

        let uncertain = makeCreateRequest(index: 951)
        _ = try await fixture.store.stageScheduledCreate(
            uncertain, accountId: Self.accountId, draftOperationId: nil
        )
        try await fixture.store.markScheduledCreateAttempted(
            scheduleId: uncertain.scheduleId, accountId: Self.accountId
        )
        let uncertainDiscarded = try await fixture.store.discardUnattemptedScheduledCreate(
            scheduleId: uncertain.scheduleId, accountId: Self.accountId
        )
        XCTAssertFalse(uncertainDiscarded)
        let effective = try await fixture.store.stageScheduledDeliveryMutation(
            CloudScheduledMutationIntent(
                operation: .cancel,
                scheduleId: uncertain.scheduleId,
                deliverAt: nil
            ),
            accountId: Self.accountId
        )
        XCTAssertEqual(effective.first?.state, "cancel_pending")
        let blockedMutations = try await fixture.store.pendingScheduledDeliveryMutationsReady(
            accountId: Self.accountId
        )
        XCTAssertTrue(blockedMutations.isEmpty, "Cancellation must wait for uncertain create replay")
        let acknowledged = makeDelivery(index: 951, revision: 1)
        try await fixture.store.acknowledgeScheduledCreate(
            CloudScheduledMutationResponse(
                scheduledDelivery: acknowledged,
                collectionRevision: 1,
                pts: 1,
                clientMutationId: uncertain.clientMutationId,
                duplicate: true,
                serverNow: "2026-08-11T00:00:00.000Z"
            ),
            accountId: Self.accountId
        )
        let readyMutations = try await fixture.store.pendingScheduledDeliveryMutationsReady(
            accountId: Self.accountId
        )
        let cancel = try XCTUnwrap(readyMutations.first)
        let preparedCancel = try await fixture.store.prepareScheduledDeliveryMutation(
            localOperationId: cancel.localOperationId,
            accountId: Self.accountId
        )
        XCTAssertNotNil(preparedCancel)
        let pendingCreates = try await fixture.store.pendingScheduledCreatesReady(
            accountId: Self.accountId
        )
        XCTAssertTrue(pendingCreates.isEmpty)
    }

    func testDeferredMutationHeadsCannotBeOvertakenAndCancellationStillWins() async throws {
        let fixture = try makeStoreFixture("mutation-heads")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let original = makeFolder(title: "Original", revision: 2)
        try await fixture.store.saveChatFolderSnapshot(
            CloudChatFolderSnapshot(
                collectionRevision: 2,
                folders: [original],
                clientMutationId: nil,
                pts: nil,
                duplicate: nil
            ),
            accountId: Self.accountId
        )
        for title in ["First", "Second"] {
            _ = try await fixture.store.stageChatFolderMutation(
                CloudFolderMutationIntent(
                    operation: .update,
                    folderId: original.folderId,
                    folder: makeFolder(title: title, revision: 2),
                    beforeFolderId: nil,
                    afterFolderId: nil
                ),
                accountId: Self.accountId
            )
        }
        var readyFolders = try await fixture.store.pendingChatFolderMutationsReady(
            accountId: Self.accountId
        )
        XCTAssertEqual(readyFolders.count, 1)
        let firstFolderOperation = try XCTUnwrap(readyFolders.first?.localOperationId)
        _ = try await fixture.store.prepareChatFolderMutation(
            localOperationId: firstFolderOperation,
            accountId: Self.accountId
        )
        try await fixture.store.deferChatFolderMutation(
            localOperationId: firstFolderOperation,
            accountId: Self.accountId,
            after: 120,
            error: "offline"
        )
        readyFolders = try await fixture.store.pendingChatFolderMutationsReady(
            accountId: Self.accountId
        )
        XCTAssertTrue(readyFolders.isEmpty, "A newer folder edit must not overtake the deferred head")
        let storedFolderDelay = try await fixture.store.nextProductivityMutationRetryDelay(
            accountId: Self.accountId
        )
        let folderDelay = try XCTUnwrap(storedFolderDelay)
        XCTAssertGreaterThan(folderDelay, 100)

        let schedule = makeDelivery(index: 952, revision: 5)
        try await fixture.store.upsertScheduledDelivery(
            schedule,
            collectionRevision: 5,
            accountId: Self.accountId
        )
        for deliverAt in ["2026-09-02T12:00:00.000Z", "2026-09-03T12:00:00.000Z"] {
            _ = try await fixture.store.stageScheduledDeliveryMutation(
                CloudScheduledMutationIntent(
                    operation: .reschedule,
                    scheduleId: schedule.scheduleId,
                    deliverAt: deliverAt
                ),
                accountId: Self.accountId
            )
        }
        var readySchedules = try await fixture.store.pendingScheduledDeliveryMutationsReady(
            accountId: Self.accountId
        )
        XCTAssertEqual(readySchedules.count, 1)
        let firstScheduleOperation = try XCTUnwrap(readySchedules.first?.localOperationId)
        _ = try await fixture.store.prepareScheduledDeliveryMutation(
            localOperationId: firstScheduleOperation,
            accountId: Self.accountId
        )
        try await fixture.store.deferScheduledDeliveryMutation(
            localOperationId: firstScheduleOperation,
            accountId: Self.accountId,
            after: 120,
            error: "offline"
        )
        readySchedules = try await fixture.store.pendingScheduledDeliveryMutationsReady(
            accountId: Self.accountId
        )
        XCTAssertTrue(readySchedules.isEmpty, "A newer reschedule must not overtake the deferred head")

        _ = try await fixture.store.stageScheduledDeliveryMutation(
            CloudScheduledMutationIntent(
                operation: .cancel,
                scheduleId: schedule.scheduleId,
                deliverAt: nil
            ),
            accountId: Self.accountId
        )
        readySchedules = try await fixture.store.pendingScheduledDeliveryMutationsReady(
            accountId: Self.accountId
        )
        XCTAssertEqual(readySchedules.count, 1)
        XCTAssertEqual(readySchedules.first?.intent.operation, .cancel)
        let cancellationDelay = try await fixture.store.nextProductivityMutationRetryDelay(
            accountId: Self.accountId
        )
        XCTAssertEqual(cancellationDelay, 0)
    }

    func testAttemptedCreateSurvivesRouteSkewCancellationAndRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("toj-schedule-route-skew-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("cloud.sqlite").path
        let key = Data(repeating: 0x58, count: 32)
        let request = makeCreateRequest(index: 953)
        do {
            let store = try CloudLocalStore(path: path, key: key)
            _ = try await store.stageScheduledCreate(
                request,
                accountId: Self.accountId,
                draftOperationId: nil
            )
            try await store.markScheduledCreateAttempted(
                scheduleId: request.scheduleId,
                accountId: Self.accountId
            )
            let routeSkew = CloudAPIError(
                status: 404,
                message: "Not Found",
                retryAfter: nil,
                code: nil
            )
            XCTAssertEqual(
                cloudOperationFailureDisposition(routeSkew, serverAdvertisesFeature: true),
                .unsupportedServer
            )
            try await store.deferScheduledCreate(
                scheduleId: request.scheduleId,
                accountId: Self.accountId,
                after: 300,
                error: routeSkew.localizedDescription
            )
            _ = try await store.stageScheduledDeliveryMutation(
                CloudScheduledMutationIntent(
                    operation: .cancel,
                    scheduleId: request.scheduleId,
                    deliverAt: nil
                ),
                accountId: Self.accountId
            )
        }

        let relaunched = try CloudLocalStore(path: path, key: key)
        let pendingCreate = try await relaunched.pendingScheduledCreate(
            scheduleId: request.scheduleId,
            accountId: Self.accountId
        )
        XCTAssertNotNil(pendingCreate?.attemptedAt)
        let readyMutations = try await relaunched.pendingScheduledDeliveryMutationsReady(
            accountId: Self.accountId
        )
        XCTAssertTrue(readyMutations.isEmpty, "Cancellation must wait for exact create replay")
        let effective = try await relaunched.scheduledDeliveries(accountId: Self.accountId)
        XCTAssertEqual(effective.first?.state, "cancel_pending")
        let terminalErrors = try await relaunched.unacknowledgedProductivityTerminalErrors(
            accountId: Self.accountId
        )
        XCTAssertTrue(terminalErrors.isEmpty)
    }

    func testPreviouslyAttemptedCreatePermanentReplayFailureRemainsDurableAfterRelaunch()
        async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "toj-schedule-permanent-replay-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("cloud.sqlite").path
        let key = Data(repeating: 0x59, count: 32)
        let request = makeCreateRequest(index: 955)
        do {
            let store = try CloudLocalStore(path: path, key: key)
            _ = try await store.stageScheduledCreate(
                request,
                accountId: Self.accountId,
                draftOperationId: nil
            )
            try await store.markScheduledCreateAttempted(
                scheduleId: request.scheduleId,
                accountId: Self.accountId
            )
        }

        let relaunched = try CloudLocalStore(path: path, key: key)
        let restoredPending = try await relaunched.pendingScheduledCreate(
            scheduleId: request.scheduleId,
            accountId: Self.accountId
        )
        let pending = try XCTUnwrap(restoredPending)
        XCTAssertNotNil(pending.attemptedAt)
        let conflict = CloudAPIError(
            status: 409,
            message: "request conflicts with an older deployment",
            retryAfter: nil,
            code: "idempotency_conflict"
        )
        XCTAssertEqual(
            cloudOperationFailureDisposition(conflict, serverAdvertisesFeature: true),
            .permanent
        )
        let mayTerminalize = cloudScheduledCreateCanTerminalizePermanentFailure(
            wasPreviouslyAttempted: pending.attemptedAt != nil
        )
        XCTAssertFalse(mayTerminalize)
        XCTAssertTrue(
            cloudScheduledCreateCanTerminalizePermanentFailure(wasPreviouslyAttempted: false)
        )
        try await relaunched.deferScheduledCreate(
            scheduleId: request.scheduleId,
            accountId: Self.accountId,
            after: 300,
            error: conflict.localizedDescription,
            terminal: mayTerminalize
        )

        let reopened = try CloudLocalStore(path: path, key: key)
        let retained = try await reopened.pendingScheduledCreate(
            scheduleId: request.scheduleId,
            accountId: Self.accountId
        )
        XCTAssertNotNil(retained)
        XCTAssertNotNil(retained?.attemptedAt)
        XCTAssertNotNil(retained?.nextRetryAt)
        let terminalErrors = try await reopened.unacknowledgedProductivityTerminalErrors(
            accountId: Self.accountId
        )
        XCTAssertTrue(terminalErrors.isEmpty)
    }

    func testCancellationSyncAcknowledgementSupersedesUncertainReschedules() async throws {
        let fixture = try makeStoreFixture("cancel-sync-supersedes")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let schedule = makeDelivery(index: 954, revision: 7)
        try await fixture.store.upsertScheduledDelivery(
            schedule,
            collectionRevision: 7,
            accountId: Self.accountId
        )
        _ = try await fixture.store.stageScheduledDeliveryMutation(
            CloudScheduledMutationIntent(
                operation: .reschedule,
                scheduleId: schedule.scheduleId,
                deliverAt: "2026-09-04T12:00:00.000Z"
            ),
            accountId: Self.accountId
        )
        let readyReschedules = try await fixture.store.pendingScheduledDeliveryMutationsReady(
            accountId: Self.accountId
        )
        let reschedule = try XCTUnwrap(readyReschedules.first)
        _ = try await fixture.store.prepareScheduledDeliveryMutation(
            localOperationId: reschedule.localOperationId,
            accountId: Self.accountId
        )
        _ = try await fixture.store.stageScheduledDeliveryMutation(
            CloudScheduledMutationIntent(
                operation: .cancel,
                scheduleId: schedule.scheduleId,
                deliverAt: nil
            ),
            accountId: Self.accountId
        )
        let readyCancellations = try await fixture.store.pendingScheduledDeliveryMutationsReady(
            accountId: Self.accountId
        )
        let cancel = try XCTUnwrap(readyCancellations.first)
        let maybePreparedCancel = try await fixture.store.prepareScheduledDeliveryMutation(
            localOperationId: cancel.localOperationId,
            accountId: Self.accountId
        )
        let preparedCancel = try XCTUnwrap(maybePreparedCancel)
        let canceled = copyDelivery(schedule, state: "canceled", revision: 8)
        try await fixture.store.applyDifference(
            DifferenceResponse(
                kind: "difference",
                state: DifferenceResponse.State(pts: 1),
                updates: [CloudUpdate(
                    pts: 1,
                    ptsCount: 1,
                    type: "scheduled.canceled",
                    dialogId: schedule.dialogId,
                    dialogTitle: nil,
                    message: nil,
                    readerAccountId: nil,
                    maxReadMsgId: nil,
                    clientMutationId: preparedCancel.clientMutationId,
                    scheduledDelivery: canceled,
                    scheduledDeliveryId: schedule.scheduleId,
                    collectionRevision: 8
                )],
                hasMore: false
            ),
            accountId: Self.accountId
        )
        let remaining = try await fixture.store.pendingScheduledDeliveryMutationsReady(
            accountId: Self.accountId
        )
        XCTAssertTrue(remaining.isEmpty)
        let effective = try await fixture.store.scheduledDeliveries(accountId: Self.accountId)
        XCTAssertEqual(effective.first?.state, "canceled")
    }

    func testOldSessionRefreshCannotCommitIntoReplacementAccountOrStore() async throws {
        let first = try makeStoreFixture("session-a")
        let second = try makeStoreFixture("session-b")
        defer {
            try? FileManager.default.removeItem(at: first.directory)
            try? FileManager.default.removeItem(at: second.directory)
        }
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let session = makeMockSession { request in
            started.signal()
            guard release.wait(timeout: .now() + 5) == .success else {
                throw URLError(.timedOut)
            }
            return try self.jsonResponse(
                CloudScheduledListResponse(
                    collectionRevision: 12,
                    deliveries: [self.makeDelivery(index: 960, revision: 12)],
                    nextCursor: nil
                ),
                for: request
            )
        }
        defer {
            release.signal()
            CloudProductivityMockURLProtocol.handler = nil
        }
        let coordinator = CloudProductivitySyncCoordinator()
        let firstContext = operationContext(store: first.store)
        let secondContext = AccountOperationContext(
            accountId: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
            deviceId: "ffffffff-ffff-4fff-8fff-ffffffffffff",
            token: "token-b",
            generation: 2,
            store: second.store
        )
        await coordinator.bind(firstContext)
        let api = CloudAPI(config: testCloudConfig(), session: session)
        let refresh = Task {
            try await coordinator.refreshScheduledDeliveries(api: api)
        }
        XCTAssertEqual(started.wait(timeout: .now() + 5), .success)
        let cancellation = Task { await coordinator.cancelAndWait() }
        while await coordinator.isBound(to: firstContext) { await Task.yield() }
        release.signal()
        await cancellation.value
        await coordinator.bind(secondContext)

        do {
            _ = try await refresh.value
            XCTFail("Expected the old-session result to be discarded")
        } catch CloudProductivityRefreshError.sessionChanged {
        }
        let firstRows = try await first.store.scheduledDeliveries(accountId: Self.accountId)
        let secondRows = try await second.store.scheduledDeliveries(
            accountId: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"
        )
        XCTAssertTrue(firstRows.isEmpty)
        XCTAssertTrue(secondRows.isEmpty)
    }

    func testNewestReentrantBindWinsWhileOldOperationQuiesces() async throws {
        let first = try makeStoreFixture("bind-a")
        let second = try makeStoreFixture("bind-b")
        let third = try makeStoreFixture("bind-c")
        defer {
            try? FileManager.default.removeItem(at: first.directory)
            try? FileManager.default.removeItem(at: second.directory)
            try? FileManager.default.removeItem(at: third.directory)
        }
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let session = makeMockSession { request in
            started.signal()
            guard release.wait(timeout: .now() + 5) == .success else {
                throw URLError(.timedOut)
            }
            return try self.jsonResponse(
                CloudScheduledListResponse(
                    collectionRevision: 1,
                    deliveries: [],
                    nextCursor: nil
                ),
                for: request
            )
        }
        defer {
            release.signal()
            CloudProductivityMockURLProtocol.handler = nil
        }
        let coordinator = CloudProductivitySyncCoordinator()
        let firstContext = operationContext(store: first.store)
        let secondContext = AccountOperationContext(
            accountId: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
            deviceId: "11111111-eeee-4eee-8eee-eeeeeeeeeeee",
            token: "token-b",
            generation: 2,
            store: second.store
        )
        let thirdContext = AccountOperationContext(
            accountId: "ffffffff-ffff-4fff-8fff-ffffffffffff",
            deviceId: "22222222-ffff-4fff-8fff-ffffffffffff",
            token: "token-c",
            generation: 3,
            store: third.store
        )
        await coordinator.bind(firstContext)
        let api = CloudAPI(config: testCloudConfig(), session: session)
        let refresh = Task {
            try await coordinator.refreshScheduledDeliveries(api: api)
        }
        XCTAssertEqual(started.wait(timeout: .now() + 5), .success)
        let bindSecond = Task { await coordinator.bind(secondContext) }
        while await coordinator.isBound(to: firstContext) { await Task.yield() }
        let bindThird = Task { await coordinator.bind(thirdContext) }
        release.signal()
        await bindSecond.value
        await bindThird.value

        do {
            _ = try await refresh.value
            XCTFail("Expected the old operation to be fenced")
        } catch CloudProductivityRefreshError.sessionChanged {
        }
        let secondIsBound = await coordinator.isBound(to: secondContext)
        let thirdIsBound = await coordinator.isBound(to: thirdContext)
        XCTAssertFalse(secondIsBound)
        XCTAssertTrue(thirdIsBound)
    }

    func testTerminalProductivityErrorsSurviveRelaunchUntilUserAcknowledges() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("toj-productivity-terminal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("cloud.sqlite").path
        let key = Data(repeating: 0x29, count: 32)
        let delivery = makeDelivery(index: 970, revision: 4)

        do {
            let store = try CloudLocalStore(path: path, key: key)
            try await store.upsertScheduledDelivery(
                delivery, collectionRevision: 4, accountId: Self.accountId
            )
            _ = try await store.stageScheduledDeliveryMutation(
                CloudScheduledMutationIntent(
                    operation: .reschedule,
                    scheduleId: delivery.scheduleId,
                    deliverAt: "2026-12-02T12:00:00.000Z"
                ),
                accountId: Self.accountId
            )
            let pending = try await store.pendingScheduledDeliveryMutationsReady(
                accountId: Self.accountId
            )
            let mutation = try XCTUnwrap(pending.first)
            _ = try await store.prepareScheduledDeliveryMutation(
                localOperationId: mutation.localOperationId,
                accountId: Self.accountId
            )
            try await store.deferScheduledDeliveryMutation(
                localOperationId: mutation.localOperationId,
                accountId: Self.accountId,
                after: 0,
                error: "Delivery already started",
                terminal: true
            )
        }

        let relaunched = try CloudLocalStore(path: path, key: key)
        let failures = try await relaunched.unacknowledgedProductivityTerminalErrors(
            accountId: Self.accountId
        )
        let failure = try XCTUnwrap(failures.first)
        XCTAssertEqual(failure.source, .scheduledMutation)
        XCTAssertEqual(failure.message, "Delivery already started")
        try await relaunched.acknowledgeProductivityTerminalError(
            failure,
            accountId: Self.accountId
        )
        let remainingFailures = try await relaunched.unacknowledgedProductivityTerminalErrors(
            accountId: Self.accountId
        )
        XCTAssertTrue(remainingFailures.isEmpty)

        let failedCreate = makeCreateRequest(index: 971)
        _ = try await relaunched.stageScheduledCreate(
            failedCreate, accountId: Self.accountId, draftOperationId: nil
        )
        try await relaunched.markScheduledCreateAttempted(
            scheduleId: failedCreate.scheduleId,
            accountId: Self.accountId
        )
        try await relaunched.deferScheduledCreate(
            scheduleId: failedCreate.scheduleId,
            accountId: Self.accountId,
            after: 0,
            error: "Schedule rejected",
            terminal: true
        )
        let failedRows = try await relaunched.scheduledDeliveries(accountId: Self.accountId)
        XCTAssertEqual(
            failedRows.first(where: { $0.scheduleId == failedCreate.scheduleId })?.state,
            "local_error"
        )
        let createFailures = try await relaunched.unacknowledgedProductivityTerminalErrors(
            accountId: Self.accountId
        )
        let createFailure = try XCTUnwrap(
            createFailures.first(where: { $0.source == .scheduledCreate })
        )
        try await relaunched.acknowledgeProductivityTerminalError(
            createFailure,
            accountId: Self.accountId
        )
        _ = try await relaunched.stageScheduledDeliveryMutation(
            CloudScheduledMutationIntent(
                operation: .cancel,
                scheduleId: failedCreate.scheduleId,
                deliverAt: nil
            ),
            accountId: Self.accountId
        )
        let cancellations = try await relaunched.pendingScheduledDeliveryMutationsReady(
            accountId: Self.accountId
        )
        let cancellation = try XCTUnwrap(cancellations.first(where: {
            $0.intent.scheduleId == failedCreate.scheduleId
        }))
        let preparedCancellation = try await relaunched.prepareScheduledDeliveryMutation(
            localOperationId: cancellation.localOperationId,
            accountId: Self.accountId
        )
        XCTAssertNil(preparedCancellation)
        let deliveriesAfterRemoval = try await relaunched.scheduledDeliveries(
            accountId: Self.accountId
        )
        XCTAssertNil(deliveriesAfterRemoval.first(where: {
            $0.scheduleId == failedCreate.scheduleId
        }))
    }

    func testV14MigrationTreatsLegacyPendingCreatesAsPossiblyAttempted() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("toj-productivity-v13-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("cloud.sqlite").path
        let key = Data(repeating: 0x41, count: 32)
        let request = makeCreateRequest(index: 972)
        do {
            let latest = try CloudLocalStore(path: path, key: key)
            _ = try await latest.stageScheduledCreate(
                request, accountId: Self.accountId, draftOperationId: nil
            )
        }

        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.usePassphrase(key)
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        do {
            let legacy = try DatabaseQueue(path: path, configuration: configuration)
            try await legacy.write { db in
                try db.execute(sql: """
                DROP TABLE cloud_scheduled_delivery_state;
                DROP TABLE pending_chat_folder_mutations;
                DROP TABLE pending_scheduled_delivery_mutations;
                ALTER TABLE pending_scheduled_delivery_creates DROP COLUMN attempted_at;
                ALTER TABLE pending_scheduled_delivery_creates DROP COLUMN error_acknowledged;
                ALTER TABLE media_transfers DROP COLUMN silent;
                DELETE FROM grdb_migrations
                WHERE identifier = 'v14-cloud-productivity-durable-mutations';
                """)
            }
        }

        do {
            let upgraded = try CloudLocalStore(path: path, key: key)
            let pending = try await upgraded.pendingScheduledCreatesReady(accountId: Self.accountId)
            XCTAssertNotNil(try XCTUnwrap(pending.first).attemptedAt)
            let discarded = try await upgraded.discardUnattemptedScheduledCreate(
                scheduleId: request.scheduleId,
                accountId: Self.accountId
            )
            XCTAssertFalse(discarded)
        }
        // Opening the migrated replica again proves the migration is idempotent on relaunch.
        let reopened = try CloudLocalStore(path: path, key: key)
        let reopenedPending = try await reopened.pendingScheduledCreate(
            scheduleId: request.scheduleId,
            accountId: Self.accountId
        )
        XCTAssertNotNil(reopenedPending?.attemptedAt)
    }

    func testCancellationsRunBeforeFoldersAndOneFailureDoesNotBlockAnotherSchedule() async throws {
        let fixture = try makeStoreFixture("cancel-priority")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let folder = makeFolder(title: "Work", revision: 2)
        let renamed = makeFolder(title: "Work updated", revision: 2)
        try await fixture.store.saveChatFolderSnapshot(
            CloudChatFolderSnapshot(
                collectionRevision: 2,
                folders: [folder],
                clientMutationId: nil,
                pts: nil,
                duplicate: nil
            ),
            accountId: Self.accountId
        )
        _ = try await fixture.store.stageChatFolderMutation(
            CloudFolderMutationIntent(
                operation: .update,
                folderId: folder.folderId,
                folder: renamed,
                beforeFolderId: nil,
                afterFolderId: nil
            ),
            accountId: Self.accountId
        )
        let first = makeDelivery(index: 973, revision: 5)
        let second = makeDelivery(index: 974, revision: 5)
        try await fixture.store.upsertScheduledDelivery(
            first, collectionRevision: 5, accountId: Self.accountId
        )
        try await fixture.store.upsertScheduledDelivery(
            second, collectionRevision: 5, accountId: Self.accountId
        )
        for delivery in [first, second] {
            _ = try await fixture.store.stageScheduledDeliveryMutation(
                CloudScheduledMutationIntent(
                    operation: .cancel,
                    scheduleId: delivery.scheduleId,
                    deliverAt: nil
                ),
                accountId: Self.accountId
            )
        }
        let ready = try await fixture.store.pendingScheduledDeliveryMutationsReady(
            accountId: Self.accountId
        )
        var exactBodies: [String: Data] = [:]
        for pending in ready {
            let maybePrepared = try await fixture.store.prepareScheduledDeliveryMutation(
                localOperationId: pending.localOperationId,
                accountId: Self.accountId
            )
            let prepared = try XCTUnwrap(maybePrepared)
            exactBodies[pending.intent.scheduleId] = try XCTUnwrap(prepared.requestData)
        }
        let secondRequest = try JSONDecoder().decode(
            CloudScheduledMutationRequest.self,
            from: try XCTUnwrap(exactBodies[second.scheduleId])
        )

        let recorder = ProductivityRequestRecorder()
        let session = makeMockSession { request in
            let path = request.url?.path ?? ""
            recorder.record(
                method: request.httpMethod ?? "",
                path: path,
                body: CloudProductivityMockURLProtocol.bodyData(from: request)
            )
            if path.hasSuffix(first.scheduleId) {
                return (
                    try XCTUnwrap(HTTPURLResponse(
                        url: request.url!, statusCode: 503, httpVersion: nil,
                        headerFields: [
                            "content-type": "application/json",
                            "Retry-After": "30",
                        ]
                    )),
                    Data("{\"error\":\"temporarily unavailable\",\"code\":\"scheduled_worker_unavailable\"}".utf8)
                )
            }
            if path.hasSuffix(second.scheduleId) {
                let canceled = self.copyDelivery(second, state: "canceled", revision: 6)
                return try self.jsonResponse(
                    CloudScheduledMutationResponse(
                        scheduledDelivery: canceled,
                        collectionRevision: 6,
                        pts: 6,
                        clientMutationId: secondRequest.clientMutationId,
                        duplicate: false,
                        serverNow: "2026-08-11T00:00:00.000Z"
                    ),
                    for: request
                )
            }
            return (
                try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 503, httpVersion: nil,
                    headerFields: ["content-type": "application/json", "Retry-After": "30"]
                )),
                Data("{\"error\":\"temporarily unavailable\"}".utf8)
            )
        }
        defer { CloudProductivityMockURLProtocol.handler = nil }
        let coordinator = CloudProductivitySyncCoordinator()
        await coordinator.bind(operationContext(store: fixture.store))
        let report = await coordinator.drain(
            api: CloudAPI(config: testCloudConfig(), session: session)
        )

        let requests = recorder.entries
        XCTAssertEqual(requests.map(\.method), ["DELETE", "DELETE", "PATCH"])
        XCTAssertEqual(requests[0].path, "/v1/scheduled-messages/\(first.scheduleId)")
        XCTAssertEqual(requests[1].path, "/v1/scheduled-messages/\(second.scheduleId)")
        XCTAssertEqual(requests[0].body, exactBodies[first.scheduleId])
        XCTAssertEqual(requests[1].body, exactBodies[second.scheduleId])
        XCTAssertTrue(report.schedulesChanged)
        let effective = try await fixture.store.scheduledDeliveries(accountId: Self.accountId)
        XCTAssertEqual(
            effective.first(where: { $0.scheduleId == first.scheduleId })?.state,
            "cancel_pending"
        )
        XCTAssertEqual(
            effective.first(where: { $0.scheduleId == second.scheduleId })?.state,
            "canceled"
        )
    }

    func testCancellationStagedDuringDrainOvertakesCapturedUncertainReschedule() async throws {
        let fixture = try makeStoreFixture("cancel-during-drain")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let first = makeDelivery(index: 975, revision: 5)
        let second = makeDelivery(index: 976, revision: 5)
        for delivery in [first, second] {
            try await fixture.store.upsertScheduledDelivery(
                delivery,
                collectionRevision: 5,
                accountId: Self.accountId
            )
        }
        _ = try await fixture.store.stageScheduledDeliveryMutation(
            CloudScheduledMutationIntent(
                operation: .cancel,
                scheduleId: first.scheduleId,
                deliverAt: nil
            ),
            accountId: Self.accountId
        )
        _ = try await fixture.store.stageScheduledDeliveryMutation(
            CloudScheduledMutationIntent(
                operation: .reschedule,
                scheduleId: second.scheduleId,
                deliverAt: "2026-09-02T12:00:00.000Z"
            ),
            accountId: Self.accountId
        )
        let ready = try await fixture.store.pendingScheduledDeliveryMutationsReady(
            accountId: Self.accountId
        )
        let secondReschedule = try XCTUnwrap(
            ready.first(where: { $0.intent.scheduleId == second.scheduleId })
        )
        XCTAssertNil(secondReschedule.request)

        let firstRequestEntered = expectation(description: "first cancellation reached transport")
        let releaseFirstRequest = DispatchSemaphore(value: 0)
        let recorder = ProductivityRequestRecorder()
        let session = makeMockSession { request in
            let body = try XCTUnwrap(CloudProductivityMockURLProtocol.bodyData(from: request))
            let mutation = try JSONDecoder().decode(CloudScheduledMutationRequest.self, from: body)
            let path = request.url?.path ?? ""
            recorder.record(method: request.httpMethod ?? "", path: path, body: body)
            let source: CloudScheduledDelivery
            let revision: Int64
            if path.hasSuffix(first.scheduleId) {
                firstRequestEntered.fulfill()
                _ = releaseFirstRequest.wait(timeout: .now() + 5)
                source = first
                revision = 6
            } else {
                source = second
                revision = 7
            }
            let canceled = self.copyDelivery(source, state: "canceled", revision: revision)
            return try self.jsonResponse(
                CloudScheduledMutationResponse(
                    scheduledDelivery: canceled,
                    collectionRevision: revision,
                    pts: revision,
                    clientMutationId: mutation.clientMutationId,
                    duplicate: false,
                    serverNow: "2026-08-11T00:00:00.000Z"
                ),
                for: request
            )
        }
        defer {
            releaseFirstRequest.signal()
            CloudProductivityMockURLProtocol.handler = nil
        }
        let coordinator = CloudProductivitySyncCoordinator()
        await coordinator.bind(operationContext(store: fixture.store))
        let api = CloudAPI(config: testCloudConfig(), session: session)
        let drainTask = Task { await coordinator.drain(api: api) }
        await fulfillment(of: [firstRequestEntered], timeout: 5)

        _ = try await fixture.store.stageScheduledDeliveryMutation(
            CloudScheduledMutationIntent(
                operation: .cancel,
                scheduleId: second.scheduleId,
                deliverAt: nil
            ),
            accountId: Self.accountId
        )
        let capturedRescheduleAfterCancellation = try await fixture.store
            .prepareScheduledDeliveryMutation(
                localOperationId: secondReschedule.localOperationId,
                accountId: Self.accountId
            )
        XCTAssertNil(
            capturedRescheduleAfterCancellation,
            "A cancellation must invalidate a stale unprepared reschedule selection atomically"
        )
        releaseFirstRequest.signal()
        let report = await drainTask.value

        XCTAssertTrue(report.schedulesChanged)
        let requests = recorder.entries
        XCTAssertEqual(requests.map(\.method), ["DELETE", "DELETE"])
        XCTAssertEqual(requests.map(\.path), [
            "/v1/scheduled-messages/\(first.scheduleId)",
            "/v1/scheduled-messages/\(second.scheduleId)",
        ])
        let effective = try await fixture.store.scheduledDeliveries(accountId: Self.accountId)
        XCTAssertEqual(
            effective.first(where: { $0.scheduleId == second.scheduleId })?.state,
            "canceled"
        )
    }

    func testFolderConflictRebaseRestartsQueueWithoutLettingLaterIntentOvertake() async throws {
        let fixture = try makeStoreFixture("folder-rebase-order")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let original = makeFolder(title: "Original", revision: 2)
        let firstEdit = makeFolder(title: "First", revision: 2)
        let secondEdit = makeFolder(title: "Second", revision: 2)
        try await fixture.store.saveChatFolderSnapshot(
            CloudChatFolderSnapshot(
                collectionRevision: 2,
                folders: [original],
                clientMutationId: nil,
                pts: nil,
                duplicate: nil
            ),
            accountId: Self.accountId
        )
        for folder in [firstEdit, secondEdit] {
            _ = try await fixture.store.stageChatFolderMutation(
                CloudFolderMutationIntent(
                    operation: .update,
                    folderId: folder.folderId,
                    folder: folder,
                    beforeFolderId: nil,
                    afterFolderId: nil
                ),
                accountId: Self.accountId
            )
        }

        let recorder = ProductivityRequestRecorder()
        let session = makeMockSession { request in
            let body = CloudProductivityMockURLProtocol.bodyData(from: request)
            recorder.record(
                method: request.httpMethod ?? "",
                path: request.url?.path ?? "",
                body: body
            )
            switch recorder.entries.count {
            case 1:
                return (
                    try XCTUnwrap(HTTPURLResponse(
                        url: request.url!, statusCode: 409, httpVersion: nil,
                        headerFields: ["content-type": "application/json"]
                    )),
                    Data("{\"error\":\"folder changed\",\"code\":\"folder_revision_conflict\"}".utf8)
                )
            case 2:
                XCTAssertEqual(request.httpMethod, "GET")
                return try self.jsonResponse(
                    CloudChatFolderSnapshot(
                        collectionRevision: 3,
                        folders: [self.makeFolder(title: "Server", revision: 3)],
                        clientMutationId: nil,
                        pts: nil,
                        duplicate: nil
                    ),
                    for: request
                )
            case 3, 4:
                let mutation = try JSONDecoder().decode(
                    CloudFolderMutationRequest.self,
                    from: try XCTUnwrap(body)
                )
                let expectedTitle = recorder.entries.count == 3 ? "First" : "Second"
                let expectedRevision: Int64 = recorder.entries.count == 3 ? 3 : 4
                XCTAssertEqual(mutation.title, expectedTitle)
                XCTAssertEqual(mutation.expectedRevision, expectedRevision)
                return try self.jsonResponse(
                    CloudChatFolderSnapshot(
                        collectionRevision: expectedRevision + 1,
                        folders: [self.makeFolder(
                            title: expectedTitle,
                            revision: expectedRevision + 1
                        )],
                        clientMutationId: mutation.clientMutationId,
                        pts: expectedRevision + 1,
                        duplicate: false
                    ),
                    for: request
                )
            default:
                XCTFail("Unexpected folder request")
                throw URLError(.badServerResponse)
            }
        }
        defer { CloudProductivityMockURLProtocol.handler = nil }
        let coordinator = CloudProductivitySyncCoordinator()
        await coordinator.bind(operationContext(store: fixture.store))
        let api = CloudAPI(config: testCloudConfig(), session: session)
        _ = await coordinator.drain(api: api)
        XCTAssertEqual(recorder.entries.map(\.method), ["PATCH", "GET"])
        _ = await coordinator.drain(api: api)
        XCTAssertEqual(recorder.entries.map(\.method), ["PATCH", "GET", "PATCH", "PATCH"])
        let effective = try await fixture.store.effectiveChatFolderSnapshot(
            accountId: Self.accountId
        )
        XCTAssertEqual(effective.collectionRevision, 5)
        XCTAssertEqual(effective.folders.first?.title, "Second")
        let remaining = try await fixture.store.pendingChatFolderMutationsReady(
            accountId: Self.accountId
        )
        XCTAssertTrue(remaining.isEmpty)
    }

    func testLegacyMediaGroupPayloadDefaultsToAudible() throws {
        let legacy = Data("{\"items\":[],\"caption\":\"\",\"replyToMsgId\":null,\"mentions\":[]}".utf8)
        let decoded = try JSONDecoder().decode(PendingMediaGroupPayload.self, from: legacy)
        XCTAssertFalse(decoded.silent)
        let silent = PendingMediaGroupPayload(
            items: [], caption: "", replyToMsgId: nil, mentions: [], silent: true
        )
        XCTAssertTrue(try JSONDecoder().decode(
            PendingMediaGroupPayload.self,
            from: JSONEncoder().encode(silent)
        ).silent)
    }

    func testCloudAPICarriesSilentFlagAcrossSingleAndAlbumHTTPBoundaries() async throws {
        let recorder = ProductivityRequestRecorder()
        let session = makeMockSession { request in
            recorder.record(
                method: request.httpMethod ?? "",
                path: request.url?.path ?? "",
                body: CloudProductivityMockURLProtocol.bodyData(from: request)
            )
            return (
                try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 503, httpVersion: nil,
                    headerFields: ["content-type": "application/json", "Retry-After": "15"]
                )),
                Data("{\"error\":\"retry later\"}".utf8)
            )
        }
        defer { CloudProductivityMockURLProtocol.handler = nil }
        let api = CloudAPI(config: testCloudConfig(), session: session)
        do {
            _ = try await api.sendMediaMessage(
                dialogId: Self.dialogId,
                clientMsgId: "30000000-0000-4000-8000-000000000001",
                body: "quiet photo",
                mediaId: "40000000-0000-4000-8000-000000000001",
                silent: true,
                token: "token-a"
            )
            XCTFail("Expected retryable mock response")
        } catch let error as CloudAPIError {
            XCTAssertEqual(error.status, 503)
        }
        do {
            _ = try await api.sendMediaGroup(
                dialogId: Self.dialogId,
                clientGroupId: "50000000-0000-4000-8000-000000000001",
                items: [MediaGroupItemRequest(
                    clientMsgId: "60000000-0000-4000-8000-000000000001",
                    mediaId: "70000000-0000-4000-8000-000000000001"
                )],
                caption: "quiet album",
                replyToMsgId: nil,
                mentions: [],
                draftConsumeOperationId: nil,
                silent: true,
                token: "token-a"
            )
            XCTFail("Expected retryable mock response")
        } catch let error as CloudAPIError {
            XCTAssertEqual(error.status, 503)
        }
        XCTAssertEqual(recorder.entries.map(\.path), [
            "/v1/messages/send",
            "/v1/messages/send-group",
        ])
        for entry in recorder.entries {
            let body = try XCTUnwrap(entry.body)
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            XCTAssertEqual(json["silent"] as? Bool, true)
        }
    }

    private static let accountId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private static let dialogId = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

    private func makeStoreFixture(_ label: String) throws -> (
        directory: URL,
        store: CloudLocalStore
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("toj-productivity-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (
            directory,
            try CloudLocalStore(
                path: directory.appendingPathComponent("cloud.sqlite").path,
                key: Data(repeating: 0x63, count: 32)
            )
        )
    }

    private func makeDelivery(index: Int, revision: Int64) -> CloudScheduledDelivery {
        CloudScheduledDelivery(
            scheduleId: String(format: "00000000-0000-4000-8000-%012d", index),
            dialogId: Self.dialogId,
            deliverAt: "2026-12-01T12:00:00.000Z",
            state: "scheduled",
            silent: false,
            reminder: false,
            revision: revision,
            attempts: 0,
            lastErrorCode: nil,
            deliveredFirstMsgId: nil,
            deliveredLastMsgId: nil,
            items: [CloudScheduledItem(
                clientMsgId: String(format: "10000000-0000-4000-8000-%012d", index),
                kind: "text",
                body: "Message \(index)",
                replyToMsgId: nil,
                mediaId: nil,
                mentions: [],
                linkPreviewCandidate: nil
            )],
            createdAt: "2026-08-11T00:00:00.000Z",
            updatedAt: "2026-08-11T00:00:00.000Z",
            completedAt: nil
        )
    }

    private func copyDelivery(
        _ delivery: CloudScheduledDelivery,
        state: String,
        revision: Int64
    ) -> CloudScheduledDelivery {
        CloudScheduledDelivery(
            scheduleId: delivery.scheduleId,
            dialogId: delivery.dialogId,
            deliverAt: delivery.deliverAt,
            state: state,
            silent: delivery.silent,
            reminder: delivery.reminder,
            revision: revision,
            attempts: delivery.attempts,
            lastErrorCode: delivery.lastErrorCode,
            deliveredFirstMsgId: delivery.deliveredFirstMsgId,
            deliveredLastMsgId: delivery.deliveredLastMsgId,
            items: delivery.items,
            createdAt: delivery.createdAt,
            updatedAt: "2026-08-11T00:00:00.000Z",
            completedAt: state == "scheduled" ? nil : "2026-08-11T00:00:00.000Z"
        )
    }

    private func makeCreateRequest(index: Int) -> CloudScheduledCreateRequest {
        let delivery = makeDelivery(index: index, revision: 0)
        return CloudScheduledCreateRequest(
            scheduleId: delivery.scheduleId,
            clientMutationId: String(format: "20000000-0000-4000-8000-%012d", index),
            dialogId: delivery.dialogId,
            deliverAt: delivery.deliverAt,
            silent: delivery.silent,
            reminder: delivery.reminder,
            items: delivery.items
        )
    }

    private func makeFolder(title: String, revision: Int64) -> CloudChatFolder {
        CloudChatFolder(
            folderId: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
            title: title,
            icon: "work",
            position: 0,
            includeDirect: true,
            includeGroups: false,
            includeSaved: false,
            excludeRead: false,
            excludeMuted: false,
            excludeArchived: false,
            revision: revision,
            rules: [],
            createdAt: "2026-08-11T00:00:00.000Z",
            updatedAt: "2026-08-11T00:00:00.000Z"
        )
    }

    private func operationContext(store: CloudLocalStore) -> AccountOperationContext {
        AccountOperationContext(
            accountId: Self.accountId,
            deviceId: "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
            token: "token-a",
            generation: 1,
            store: store
        )
    }

    private func testCloudConfig() -> CloudConfig {
        CloudConfig(baseURL: URL(string: "https://productivity.example.test")!)
    }

    private func makeMockSession(
        _ handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudProductivityMockURLProtocol.self]
        CloudProductivityMockURLProtocol.handler = handler
        return URLSession(configuration: configuration)
    }

    private func queryValue(_ name: String, in request: URLRequest) -> String? {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == name })?.value
    }

    private func jsonResponse<Response: Encodable>(
        _ value: Response,
        for request: URLRequest
    ) throws -> (HTTPURLResponse, Data) {
        (
            try XCTUnwrap(HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["content-type": "application/json"]
            )),
            try JSONEncoder().encode(value)
        )
    }
}

private final class CloudProductivityMockURLProtocol: URLProtocol {
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

private final class ProductivityLockedCounter: @unchecked Sendable {
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

private final class ProductivityRequestRecorder: @unchecked Sendable {
    struct Entry: Equatable {
        let method: String
        let path: String
        let body: Data?
    }

    private let lock = NSLock()
    private var storage: [Entry] = []

    func record(method: String, path: String, body: Data?) {
        lock.lock()
        storage.append(Entry(method: method, path: path, body: body))
        lock.unlock()
    }

    var entries: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
