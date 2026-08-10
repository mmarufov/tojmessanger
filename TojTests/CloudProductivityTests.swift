import Foundation
import XCTest
@testable import Toj

final class CloudProductivityTests: XCTestCase {
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
}
