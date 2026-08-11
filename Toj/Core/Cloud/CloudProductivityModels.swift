import Foundation

nonisolated struct CloudLinkPreviewCandidate: Codable, Equatable, Sendable {
    let url: String
    let utf16Offset: Int
    let utf16Length: Int
    let disabled: Bool

    static func first(in text: String) -> Self? {
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue
        ) else { return nil }
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = detector.matches(in: text, range: fullRange).first else { return nil }
        let rawURL = (text as NSString).substring(with: match.range)
        guard let url = URL(string: rawURL),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return Self(
            url: rawURL,
            utf16Offset: match.range.location,
            utf16Length: match.range.length,
            disabled: false
        )
    }
}

nonisolated struct CloudLinkPreview: Codable, Equatable, Sendable {
    let state: String
    let originalUrl: String?
    let finalUrl: String?
    let destinationHost: String?
    let title: String?
    let description: String?
    let siteName: String?
    let assetId: String?
    let fetchedAt: String?
}

nonisolated struct CloudChatFolderRule: Codable, Equatable, Sendable {
    let dialogId: String
    let rule: String
}

nonisolated struct CloudChatFolder: Codable, Identifiable, Equatable, Sendable {
    var id: String { folderId }
    let folderId: String
    let title: String
    let icon: String
    let position: Int
    let includeDirect: Bool
    let includeGroups: Bool
    let includeSaved: Bool
    let excludeRead: Bool
    let excludeMuted: Bool
    let excludeArchived: Bool
    let revision: Int64
    let rules: [CloudChatFolderRule]
    let createdAt: String
    let updatedAt: String

    var systemImageName: String {
        switch icon {
        case "personal": "person.2"
        case "unread": "message.badge"
        case "work": "briefcase"
        case "favorite": "star"
        case "groups", "family": "person.3"
        case "muted": "bell.slash"
        default: "folder"
        }
    }
}

nonisolated struct CloudChatFolderSnapshot: Codable, Equatable, Sendable {
    let collectionRevision: Int64
    let folders: [CloudChatFolder]
    let clientMutationId: String?
    let pts: Int64?
    let duplicate: Bool?
}

nonisolated struct CloudScheduledItem: Codable, Equatable, Sendable {
    let clientMsgId: String
    let kind: String
    let body: String
    let replyToMsgId: Int64?
    let mediaId: String?
    let mentions: [CloudMention]
    let linkPreviewCandidate: CloudLinkPreviewCandidate?
}

nonisolated struct CloudScheduledDelivery: Codable, Identifiable, Equatable, Sendable {
    var id: String { scheduleId }
    let scheduleId: String
    let dialogId: String
    let deliverAt: String
    let state: String
    let silent: Bool
    let reminder: Bool
    let revision: Int64
    let attempts: Int
    let lastErrorCode: String?
    let deliveredFirstMsgId: Int64?
    let deliveredLastMsgId: Int64?
    let items: [CloudScheduledItem]
    let createdAt: String
    let updatedAt: String
    let completedAt: String?

    enum CodingKeys: String, CodingKey {
        case scheduleId = "id"
        case dialogId, deliverAt, state, silent, reminder, revision, attempts, lastErrorCode
        case deliveredFirstMsgId, deliveredLastMsgId, items, createdAt, updatedAt, completedAt
    }
}

nonisolated struct CloudScheduledMutationResponse: Codable, Sendable {
    let scheduledDelivery: CloudScheduledDelivery
    let collectionRevision: Int64
    let pts: Int64
    let clientMutationId: String
    let duplicate: Bool
    let serverNow: String
}

nonisolated struct CloudScheduledListResponse: Codable, Sendable {
    let collectionRevision: Int64
    let deliveries: [CloudScheduledDelivery]
    let nextCursor: String?
}

nonisolated struct CloudScheduledCreateRequest: Codable, Sendable {
    let scheduleId: String
    let clientMutationId: String
    let dialogId: String
    let deliverAt: String
    let silent: Bool
    let reminder: Bool
    let items: [CloudScheduledItem]
}

nonisolated struct PendingScheduledCreate: Identifiable, Sendable {
    var id: String { request.scheduleId }
    let accountId: String
    let request: CloudScheduledCreateRequest
    /// Exact UTF-8 body persisted before the first HTTP attempt.
    let requestData: Data
    let draftOperationId: String?
    let retryCount: Int
    let nextRetryAt: String?
    let lastError: String?
    let attemptedAt: String?
}

nonisolated struct CloudScheduledMutationRequest: Codable, Sendable {
    let clientMutationId: String
    let expectedRevision: Int64
    var deliverAt: String? = nil
    var silent: Bool? = nil
    var reminder: Bool? = nil
    var items: [CloudScheduledItem]? = nil
}

nonisolated struct CloudFolderMutationRequest: Codable, Sendable {
    let clientMutationId: String
    var folderId: String? = nil
    var title: String? = nil
    var icon: String? = nil
    var includeDirect: Bool? = nil
    var includeGroups: Bool? = nil
    var includeSaved: Bool? = nil
    var excludeRead: Bool? = nil
    var excludeMuted: Bool? = nil
    var excludeArchived: Bool? = nil
    var rules: [CloudChatFolderRule]? = nil
    var expectedRevision: Int64? = nil
    var beforeFolderId: String? = nil
    var afterFolderId: String? = nil
}

nonisolated enum CloudFolderMutationOperation: String, Codable, Sendable {
    case create
    case update
    case delete
    case move
}

nonisolated struct CloudFolderMutationIntent: Codable, Equatable, Sendable {
    let operation: CloudFolderMutationOperation
    let folderId: String
    let folder: CloudChatFolder?
    let beforeFolderId: String?
    let afterFolderId: String?
    var desiredOrder: [String]? = nil
}

nonisolated struct PendingChatFolderMutation: Identifiable, Sendable {
    var id: String { localOperationId }
    let localOperationId: String
    let accountId: String
    let intent: CloudFolderMutationIntent
    let clientMutationId: String?
    let request: CloudFolderMutationRequest?
    let requestData: Data?
    let retryCount: Int
    let attemptedAt: String?
    let lastError: String?
    let terminal: Bool
    let localOrder: Int64
}

nonisolated enum CloudScheduledMutationOperation: String, Codable, Sendable {
    case cancel
    case reschedule
}

nonisolated struct CloudScheduledMutationIntent: Codable, Equatable, Sendable {
    let operation: CloudScheduledMutationOperation
    let scheduleId: String
    let deliverAt: String?
}

nonisolated struct PendingScheduledDeliveryMutation: Identifiable, Sendable {
    var id: String { localOperationId }
    let localOperationId: String
    let accountId: String
    let intent: CloudScheduledMutationIntent
    let clientMutationId: String?
    let request: CloudScheduledMutationRequest?
    let requestData: Data?
    let retryCount: Int
    let attemptedAt: String?
    let lastError: String?
    let terminal: Bool
    let localOrder: Int64
}

nonisolated enum CloudProductivityTerminalErrorSource: String, Sendable {
    case chatFolder
    case scheduledCreate
    case scheduledMutation
}

/// A durable failure remains queryable until the user dismisses its notice. This closes the
/// process-death gap between marking a journal row terminal and publishing the error in the UI.
nonisolated struct CloudProductivityTerminalError: Identifiable, Equatable, Sendable {
    let source: CloudProductivityTerminalErrorSource
    let localOperationId: String
    let message: String

    var id: String { "\(source.rawValue):\(localOperationId)" }
}

extension CloudScheduledDelivery {
    nonisolated func applyingPendingMutation(_ intent: CloudScheduledMutationIntent) -> Self {
        Self(
            scheduleId: scheduleId,
            dialogId: dialogId,
            deliverAt: intent.deliverAt ?? deliverAt,
            state: intent.operation == .cancel ? "cancel_pending" : "reschedule_pending",
            silent: silent,
            reminder: reminder,
            revision: revision,
            attempts: attempts,
            lastErrorCode: lastErrorCode,
            deliveredFirstMsgId: deliveredFirstMsgId,
            deliveredLastMsgId: deliveredLastMsgId,
            items: items,
            createdAt: createdAt,
            updatedAt: ISO8601DateFormatter().string(from: Date()),
            completedAt: completedAt
        )
    }
}
