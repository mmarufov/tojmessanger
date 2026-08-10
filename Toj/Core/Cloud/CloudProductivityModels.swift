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
    let draftOperationId: String?
    let retryCount: Int
    let nextRetryAt: String?
    let lastError: String?
}

nonisolated struct CloudScheduledMutationRequest: Encodable, Sendable {
    let clientMutationId: String
    let expectedRevision: Int64
    var deliverAt: String? = nil
    var silent: Bool? = nil
    var reminder: Bool? = nil
    var items: [CloudScheduledItem]? = nil
}

nonisolated struct CloudFolderMutationRequest: Encodable, Sendable {
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
