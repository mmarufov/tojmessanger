import XCTest
@testable import Toj

final class GroupsV1Tests: XCTestCase {
    func testPendingGroupAndItsOutboxSurviveRelaunchUntilCreationIsConfirmed() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "groups.sqlite").path
        let key = Data("groups-v1-relaunch-key".utf8)
        let groupId = "8af9c6da-77b2-4cad-9f09-c8fc584d59a8"

        do {
            let store = try CloudLocalStore(path: path, key: key)
            let created = try await store.createPendingGroup(
                groupId: groupId,
                title: "Launch crew",
                memberIds: ["member-b"],
                creatorAccountId: "owner-a"
            )
            XCTAssertTrue(created)
            _ = try await store.insertSending(
                dialogId: groupId,
                clientMsgId: "f7b8f302-1fa7-43c1-a7eb-95a826c02247",
                text: "Queued before the network",
                senderAccountId: "owner-a"
            )
            let preparedPhoto = PreparedMediaUpload(
                transferId: "173d1d2f-a407-48ff-814e-726fa8a1c1c7",
                kind: "photo",
                contentType: "image/jpeg",
                fileName: "group-photo.jpg",
                byteSize: 128,
                sha256: String(repeating: "a", count: 64),
                durationMs: nil,
                width: 100,
                height: 100,
                encryptedSourcePath: "/tmp/group-photo.tojmedia",
                encryptedThumbnailPath: nil
            )
            try await store.insertMediaTransfer(
                prepared: preparedPhoto,
                dialogId: groupId,
                clientMsgId: "group-photo:\(preparedPhoto.transferId)",
                caption: "",
                replyToMsgId: nil,
                purpose: "group_photo"
            )
            try await store.enqueueGroupMutation(
                dialogId: groupId,
                operation: "update_title",
                payloadJSON: #"{"title":"Launch crew 2"}"#,
                clientMutationId: "d9804b8c-64cb-47f1-b8ff-d6c0fd34949c"
            )
            let readyBeforeCreation = try await store.pendingOutboxReady()
            let photoBeforeCreation = try await store.mediaTransfersReady()
            let mutationBeforeCreation = try await store.pendingGroupMutationsReady()
            XCTAssertTrue(readyBeforeCreation.isEmpty)
            XCTAssertTrue(photoBeforeCreation.isEmpty)
            XCTAssertTrue(mutationBeforeCreation.isEmpty)
        }

        let reopened = try CloudLocalStore(path: path, key: key)
        let pending = try await reopened.pendingGroupCreationsReady()
        XCTAssertEqual(pending.map(\.groupId), [groupId])
        let pendingDialogs = try await reopened.dialogs(accountId: "owner-a")
        let heldOutbox = try await reopened.pendingOutboxReady()
        XCTAssertEqual(pendingDialogs.first?.type, "group")
        XCTAssertEqual(pendingDialogs.first?.accessState, "pending")
        XCTAssertTrue(heldOutbox.isEmpty)

        try await reopened.applyGroupEnvelope(
            CloudGroupEnvelope(
                group: CloudGroup(
                    id: groupId,
                    title: "Launch crew",
                    photo: nil,
                    revision: 1,
                    memberCount: 2,
                    selfRole: "owner",
                    notificationMode: "all",
                    createdBy: "owner-a",
                    createdAt: "2026-07-25T00:00:00.000Z",
                    closedAt: nil
                ),
                members: [
                    CloudGroupMember(
                        accountId: "owner-a",
                        role: "owner",
                        joinedAt: "2026-07-25T00:00:00.000Z",
                        isActive: true
                    ),
                    CloudGroupMember(
                        accountId: "member-b",
                        role: "member",
                        joinedAt: "2026-07-25T00:00:00.000Z",
                        isActive: true
                    ),
                ],
                profiles: [],
                duplicate: false
            )
        )

        let completedCreations = try await reopened.pendingGroupCreationsReady()
        let releasedOutbox = try await reopened.pendingOutboxReady()
        let activeDialogs = try await reopened.dialogs(accountId: "owner-a")
        let releasedPhoto = try await reopened.mediaTransfersReady()
        let releasedMutation = try await reopened.pendingGroupMutationsReady()
        XCTAssertTrue(completedCreations.isEmpty)
        XCTAssertEqual(releasedOutbox.map(\.dialogId), [groupId])
        XCTAssertEqual(activeDialogs.first?.accessState, "active")
        XCTAssertEqual(releasedPhoto.first?.purpose, "group_photo")
        XCTAssertEqual(releasedMutation.first?.operation, "update_title")
    }

    func testAccessRevocationHidesDialogAndDrainsItsDurablePurge() async throws {
        let store = try makeStore()
        let groupId = "0da3e894-20eb-4a78-a254-66ce577a762f"
        try await store.upsertDialog(
            dialogId: groupId,
            type: "group",
            title: "Removed group"
        )
        _ = try await store.insertSending(
            dialogId: groupId,
            clientMsgId: "50802d40-31a2-471e-90d4-d4f5d1ea1688",
            text: "Must not leave after removal",
            senderAccountId: "account-me"
        )

        try await store.applyDifference(
            DifferenceResponse(
                kind: "difference",
                state: .init(pts: 1),
                updates: [
                    CloudUpdate(
                        pts: 1,
                        ptsCount: 1,
                        type: "dialog.access_revoked",
                        dialogId: groupId,
                        dialogTitle: nil,
                        dialogType: "group",
                        message: nil,
                        readerAccountId: nil,
                        maxReadMsgId: nil
                    ),
                ],
                profiles: [],
                hasMore: false
            ),
            accountId: "account-me"
        )

        let visibleDialogs = try await store.dialogs(accountId: "account-me")
        let readyOutbox = try await store.pendingOutboxReady()
        let purgeJobs = try await store.pendingAccessPurgeJobs()
        for job in purgeJobs {
            try await store.markAccessPurgeFilesDeleted(id: job.id)
            try await store.finalizeAccessPurge(id: job.id)
        }
        let timeline = try await store.timeline(dialogId: groupId)
        XCTAssertTrue(visibleDialogs.isEmpty)
        XCTAssertTrue(readyOutbox.isEmpty)
        XCTAssertFalse(purgeJobs.isEmpty)
        XCTAssertTrue(timeline.messages.isEmpty)
    }

    func testGroupServiceMessagesRetainTypedLifecycleMetadata() async throws {
        let store = try makeStore()
        let groupId = "560773f9-a452-4abe-9b78-0d7472a93c9f"
        let service = CloudMessage(
            dialogId: groupId,
            msgId: 1,
            senderAccountId: "owner-a",
            clientMsgId: "1d7cf881-4bb0-49b7-8913-6bd31fb3f9d2",
            kind: "service",
            text: "",
            media: nil,
            serviceType: "dialog.title_changed",
            serviceData: CloudServiceData(
                actorAccountId: "owner-a",
                subjectAccountId: nil,
                memberAccountIds: nil,
                successorAccountId: nil,
                role: nil,
                title: "New name"
            ),
            editVersion: 0,
            state: "visible",
            serverTs: "2026-07-25T00:00:00.000Z"
        )
        try await store.applyDifference(
            DifferenceResponse(
                kind: "difference",
                state: .init(pts: 1),
                updates: [
                    CloudUpdate(
                        pts: 1,
                        ptsCount: 1,
                        type: "message.new",
                        dialogId: groupId,
                        dialogTitle: "New name",
                        dialogType: "group",
                        message: service,
                        group: CloudUpdateGroup(
                            id: groupId,
                            title: "New name",
                            revision: 2,
                            memberCount: 2
                        ),
                        readerAccountId: nil,
                        maxReadMsgId: nil
                    ),
                ],
                profiles: [],
                hasMore: false
            ),
            accountId: "member-b"
        )

        let restored = try await store.timeline(dialogId: groupId).messages
        let dialogs = try await store.dialogs(accountId: "member-b")
        XCTAssertEqual(restored.first?.serviceType, "dialog.title_changed")
        XCTAssertEqual(restored.first?.serviceData?.title, "New name")
        XCTAssertEqual(dialogs.first?.type, "group")
    }

    func testStructuredMentionsPersistAndDriveUnreadMentionCount() async throws {
        let store = try makeStore()
        let groupId = "9e7378ca-56c0-4d44-99fc-0abeb936a312"
        let accountId = "member-b"
        try await store.applyGroupEnvelope(
            CloudGroupEnvelope(
                group: CloudGroup(
                    id: groupId,
                    title: "Mention test",
                    photo: nil,
                    revision: 1,
                    memberCount: 2,
                    selfRole: "member",
                    notificationMode: "all",
                    createdBy: "owner-a",
                    createdAt: "2026-07-25T00:00:00.000Z",
                    closedAt: nil
                ),
                members: [
                    CloudGroupMember(
                        accountId: "owner-a",
                        role: "owner",
                        joinedAt: "2026-07-25T00:00:00.000Z",
                        isActive: true
                    ),
                    CloudGroupMember(
                        accountId: accountId,
                        role: "member",
                        joinedAt: "2026-07-25T00:00:00.000Z",
                        isActive: true
                    ),
                ],
                profiles: [],
                duplicate: false
            )
        )
        let message = CloudMessage(
            dialogId: groupId,
            msgId: 2,
            senderAccountId: "owner-a",
            clientMsgId: "801534a9-333e-4e1b-8186-3af6d90b7e1b",
            kind: "text",
            text: "Hi @Member",
            mentions: [
                CloudMention(accountId: accountId, offset: 3, length: 7),
            ],
            editVersion: 0,
            state: "visible",
            serverTs: "2026-07-25T00:00:01.000Z"
        )
        try await store.applyDifference(
            DifferenceResponse(
                kind: "difference",
                state: .init(pts: 2),
                updates: [
                    CloudUpdate(
                        pts: 2,
                        ptsCount: 1,
                        type: "message.new",
                        dialogId: groupId,
                        dialogTitle: "Mention test",
                        dialogType: "group",
                        message: message,
                        readerAccountId: nil,
                        maxReadMsgId: nil
                    ),
                ],
                profiles: [],
                hasMore: false
            ),
            accountId: accountId
        )

        let mentionedTimeline = try await store.timeline(dialogId: groupId)
        let mentionedDialogs = try await store.dialogs(accountId: accountId)
        XCTAssertEqual(mentionedTimeline.messages.first?.mentions, message.mentions)
        XCTAssertEqual(mentionedDialogs.first?.mentionCount, 1)
        try await store.markRead(dialogId: groupId, accountId: accountId, maxReadMsgId: 2)
        let readDialogs = try await store.dialogs(accountId: accountId)
        XCTAssertEqual(readDialogs.first?.mentionCount, 0)
    }

    private func makeStore() throws -> CloudLocalStore {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try CloudLocalStore(
            path: directory.appending(path: "groups.sqlite").path,
            key: Data(UUID().uuidString.utf8)
        )
    }
}
