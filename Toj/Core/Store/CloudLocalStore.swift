import Foundation
import GRDB
import os
import Security

nonisolated struct LocalMessage: Identifiable, Equatable, Sendable {
    let localId: String
    var id: String { localId }
    let dialogId: String
    let msgId: Int64?
    let clientMsgId: String
    let senderAccountId: String
    let senderDisplayName: String?
    let kind: String
    let text: String
    let replyToMsgId: Int64?
    let forwardedFromAccountId: String?
    let forwardedFromDialogId: String?
    let forwardedFromMsgId: Int64?
    let isForwarded: Bool
    let reactions: [CloudReaction]
    let mentions: [CloudMention]
    let media: CloudMedia?
    let serviceType: String?
    let serviceData: CloudServiceData?
    let editVersion: Int
    let state: String
    let serverTs: String?
    let localState: String
}

nonisolated struct LocalDialog: Identifiable, Equatable, Sendable {
    let dialogId: String
    var id: String { dialogId }
    let type: String
    let title: String?
    let photo: CloudMedia?
    let lastMsgId: Int64
    let updatedAt: String
    let lastText: String?
    let lastKind: String?
    let lastState: String?
    let lastSenderAccountId: String?
    let lastLocalState: String?
    let lastServerTs: String?
    let unreadCount: Int
    let mentionCount: Int
    let peerAccountId: String?
    let peerBio: String?
    let peerBirthday: String?
    let peerColorIndex: Int?
    let revision: Int64
    let memberCount: Int
    let selfRole: String?
    let notificationMode: String
    let accessState: String
    let isPinned: Bool
    let pinnedAt: String?
    let isMuted: Bool
    let isArchived: Bool
}

nonisolated struct PendingGroupCreation: Identifiable, Equatable, Sendable {
    let groupId: String
    var id: String { groupId }
    let title: String
    let memberIds: [String]
    let localPhotoReference: String?
    let state: String
    let retryCount: Int
    let nextRetryAt: String?
    let lastError: String?
    let terminal: Bool
}

nonisolated struct PendingGroupMutation: Identifiable, Equatable, Sendable {
    let clientMutationId: String
    var id: String { clientMutationId }
    let dialogId: String
    let operation: String
    let payloadJSON: String
    let retryCount: Int
    let nextRetryAt: String?
    let lastError: String?
    let terminal: Bool
}

nonisolated enum DialogPreferenceField: String, CaseIterable, Sendable {
    case pinned
    case muted
    case archived
}

nonisolated struct PendingDialogPreferenceMutation: Identifiable, Equatable, Sendable {
    var id: String { clientMutationId }
    let accountId: String
    let dialogId: String
    let field: DialogPreferenceField
    let desiredValue: Bool
    let clientMutationId: String
    let retryCount: Int
    let nextRetryAt: String?
    let acknowledgedPts: Int64?
    let lastError: String?
}

nonisolated struct LocalLaunchSnapshot: Equatable, Sendable {
    let pts: Int64
    let dialogs: [LocalDialog]
}

nonisolated struct PendingOutboxItem: Identifiable, Equatable, Sendable {
    let clientMsgId: String
    var id: String { clientMsgId }
    let dialogId: String
    let body: String
    let replyToMsgId: Int64?
    let forwardedFromDialogId: String?
    let forwardedFromMsgId: Int64?
    var mentions: [CloudMention] = []
    let retryCount: Int
    let nextRetryAt: String?
}

nonisolated struct PendingReadReceipt: Identifiable, Equatable, Sendable {
    var id: String { "\(accountId)|\(dialogId)" }
    let dialogId: String
    let accountId: String
    let maxReadMsgId: Int64
    let retryCount: Int
    let nextRetryAt: String?
}

nonisolated struct PendingMessageMutation: Identifiable, Equatable, Sendable {
    let clientMutationId: String
    var id: String { clientMutationId }
    let operation: String
    let dialogId: String
    let msgId: Int64
    let body: String?
    let expectedEditVersion: Int?
    let emoji: String?
    let retryCount: Int
    let nextRetryAt: String?
    let lastError: String?
}

nonisolated struct MediaTransferRecord: Identifiable, Equatable, Sendable {
    let transferId: String
    var id: String { transferId }
    let dialogId: String
    let clientMsgId: String
    let caption: String
    let replyToMsgId: Int64?
    var purpose: String = "message"
    let kind: String
    let contentType: String
    let fileName: String?
    let byteSize: Int64
    let sha256: String
    let durationMs: Int64?
    let width: Int?
    let height: Int?
    let encryptedSourcePath: String
    let encryptedThumbnailPath: String?
    let mediaId: String?
    let uploadOffset: Int64
    let state: String
    let retryCount: Int
    let nextRetryAt: String?
    let lastError: String?
    let terminal: Bool

    var media: CloudMedia {
        return CloudMedia(
            id: mediaId ?? "pending:\(transferId)", kind: kind, contentType: contentType, fileName: fileName,
            byteSize: byteSize, durationMs: durationMs, width: width, height: height,
            hasThumbnail: encryptedThumbnailPath != nil
        )
    }
}

nonisolated struct TimelineWindow: Equatable, Sendable {
    static let initialLimit = 120
    static let pageLimit = 80
    static let maximumRetainedMessages = 400

    let beforeMsgId: Int64?
    let afterMsgId: Int64?
    let limit: Int

    static let initial = TimelineWindow(beforeMsgId: nil, afterMsgId: nil, limit: initialLimit)

    static func earlier(beforeMsgId: Int64) -> TimelineWindow {
        TimelineWindow(beforeMsgId: beforeMsgId, afterMsgId: nil, limit: pageLimit)
    }

    init(beforeMsgId: Int64? = nil, afterMsgId: Int64? = nil, limit: Int = initialLimit) {
        self.beforeMsgId = beforeMsgId
        self.afterMsgId = afterMsgId
        self.limit = max(1, min(limit, Self.maximumRetainedMessages))
    }
}

nonisolated struct TimelineSnapshot: Equatable, Sendable {
    let messages: [LocalMessage]
    let oldestServerMsgId: Int64?
    let newestServerMsgId: Int64?
    let hasEarlierLocalMessages: Bool
    let hasLaterLocalMessages: Bool
}

/// The complete local input required to present one conversation. GRDB produces this value from a
/// single read transaction, so the first frame cannot mix messages from one database revision with
/// mutations, transfers, or read cursors from another.
nonisolated struct ConversationLocalSnapshot: Equatable, Sendable {
    let timeline: TimelineSnapshot
    let mutations: [PendingMessageMutation]
    let transfers: [MediaTransferRecord]
    let peerReadMsgId: Int64
    let historyState: DialogHistoryState?
}

nonisolated enum TimelineAnchor: Equatable, Sendable {
    /// The semantic unread watermark is known, but the actual first incoming row has not yet been
    /// proven from a contiguous local history range. The UI may render cached content immediately
    /// while targeted forward hydration resolves this into `firstUnread`.
    case provisionalFirstUnread(msgId: Int64)
    case firstUnread(msgId: Int64)
    case saved(msgId: Int64)
    case bottom
}

nonisolated struct ChatViewportState: Equatable, Sendable {
    let dialogId: String
    let accountId: String
    let topVisibleMsgId: Int64?
    let wasAtBottom: Bool
    let updatedAt: String

    init(
        dialogId: String,
        accountId: String,
        topVisibleMsgId: Int64?,
        wasAtBottom: Bool,
        updatedAt: String = CloudLocalStore.sqliteTimestamp(Date())
    ) {
        self.dialogId = dialogId
        self.accountId = accountId
        self.topVisibleMsgId = topVisibleMsgId
        self.wasAtBottom = wasAtBottom
        self.updatedAt = updatedAt
    }
}

nonisolated struct DialogHistoryState: Equatable, Sendable {
    let dialogId: String
    let ceilingMsgId: Int64
    let nextBeforeMsgId: Int64?
    let historyComplete: Bool
    let retryCount: Int
    let nextRetryAt: String?
    let updatedAt: String

    init(
        dialogId: String,
        ceilingMsgId: Int64,
        nextBeforeMsgId: Int64?,
        historyComplete: Bool,
        retryCount: Int = 0,
        nextRetryAt: String? = nil,
        updatedAt: String = CloudLocalStore.sqliteTimestamp(Date())
    ) {
        self.dialogId = dialogId
        self.ceilingMsgId = ceilingMsgId
        self.nextBeforeMsgId = nextBeforeMsgId
        self.historyComplete = historyComplete
        self.retryCount = retryCount
        self.nextRetryAt = nextRetryAt
        self.updatedAt = updatedAt
    }
}

nonisolated struct ReplicaBootstrapState: Equatable, Sendable {
    let accountId: String
    let token: String?
    let nextCursor: String?
    let snapshotPts: Int64
    let status: String
    let mode: ReplicaBootstrapMode
    let updatedAt: String
}

nonisolated enum ReplicaBootstrapMode: String, Equatable, Sendable {
    /// Used for a device with no published replica. Pages are committed to the live tables as they
    /// arrive so the first page can render without waiting for the entire account snapshot.
    case initial

    /// Used when replacing an existing replica. Pages remain in staging tables until the complete
    /// snapshot can be merged atomically, keeping the old replica readable throughout the fetch.
    case replacement
}

nonisolated enum CloudLocalStoreBootstrapError: LocalizedError, Equatable, Sendable {
    case notInProgress
    case invalidStagedMessage
    case invalidGroupState

    var errorDescription: String? {
        switch self {
        case .notInProgress:
            return "No local replica bootstrap is in progress"
        case .invalidStagedMessage:
            return "The staged local replica contains an invalid message"
        case .invalidGroupState:
            return "The local group state is invalid"
        }
    }
}

nonisolated private struct StagedBootstrapSnapshot: Sendable {
    let dialogs: [BootstrapDialog]
    let profiles: [CloudProfile]
}

nonisolated struct MessageMediaRecord: Equatable, Sendable {
    let localId: String
    let dialogId: String
    let msgId: Int64?
    let media: CloudMedia
}

nonisolated struct MediaCacheEntry: Equatable, Sendable {
    let mediaId: String
    let variant: String
    let encryptedPath: String
    let byteSize: Int64
    let cachedBytes: Int64
    let contiguousOffset: Int64
    let state: String
    let lastAccessedAt: String
    let protectedUntil: String?
}

nonisolated enum MediaDownloadJobState: String, Equatable, Sendable {
    case queued
    case downloading
    case paused
    case completed
    case failed
}

nonisolated enum LocalStoreOpenError: LocalizedError, Sendable {
    case integrityCheckFailed

    var errorDescription: String? {
        switch self {
        case .integrityCheckFailed:
            "The encrypted local replica failed its integrity check"
        }
    }
}

nonisolated struct MediaDownloadJobRecord: Equatable, Sendable {
    let mediaId: String
    let variant: String
    let dialogId: String?
    let priority: Int
    let state: MediaDownloadJobState
    let userInitiated: Bool
    let retryCount: Int
    let nextRetryAt: String?
    let lastError: String?
    let updatedAt: String
}

nonisolated private final class AsyncObservationBox<Element>: @unchecked Sendable {
    let values: AsyncValueObservation<Element>

    init(_ values: AsyncValueObservation<Element>) {
        self.values = values
    }
}

actor CloudLocalStore {
    private let dbQueue: DatabasePool
    nonisolated private static let signposter = OSSignposter(
        subsystem: "com.toj.Toj",
        category: "LocalStore"
    )

    nonisolated static func `default`() throws -> CloudLocalStore {
        let key = try LocalDatabaseKeyStore.currentEnvironment().loadOrCreateKey()
        let appDirectory = try defaultApplicationDirectory()
        let path = appDirectory.appending(path: "cloud.sqlite").path

        try applyFileSecurity(to: appDirectory)
        return try CloudLocalStore(path: path, key: key)
    }

    /// Permanently destroys the default encrypted replica, its recovery copies, and its key.
    /// Callers must release every open `CloudLocalStore` before invoking this method.
    nonisolated static func destroyDefaultStore() throws {
        let fileManager = FileManager.default
        let appDirectory = try defaultApplicationDirectory()
        let databasePath = appDirectory.appending(path: "cloud.sqlite").path
        var firstError: Error?

        for suffix in ["", "-wal", "-shm"] {
            let url = URL(fileURLWithPath: databasePath + suffix)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            do {
                try fileManager.removeItem(at: url)
            } catch {
                if firstError == nil { firstError = error }
            }
        }

        let quarantine = appDirectory.appending(path: "Quarantine", directoryHint: .isDirectory)
        if fileManager.fileExists(atPath: quarantine.path) {
            do {
                try fileManager.removeItem(at: quarantine)
            } catch {
                if firstError == nil { firstError = error }
            }
        }

        // Delete the key even if a filesystem cleanup failed: any leftover encrypted bytes must
        // become permanently unreadable after an explicit logout.
        do {
            try LocalDatabaseKeyStore.currentEnvironment().deleteKey()
        } catch {
            if firstError == nil { firstError = error }
        }
        if let firstError { throw firstError }
    }

    /// Preserves an unreadable default replica for diagnostics/recovery. The caller must first
    /// authenticate the cloud session and must not hold an open store. Opening never invokes this
    /// API automatically.
    @discardableResult
    nonisolated static func quarantineDefaultStore(now: Date = Date()) throws -> URL? {
        let path = try defaultApplicationDirectory().appending(path: "cloud.sqlite").path
        return try quarantineStore(at: path, now: now)
    }

    /// Path-injectable variant used by recovery tooling and tests.
    @discardableResult
    nonisolated static func quarantineStore(at path: String, now: Date = Date()) throws -> URL? {
        let fileManager = FileManager.default
        let existingSuffixes = ["", "-wal", "-shm"].filter {
            fileManager.fileExists(atPath: path + $0)
        }
        guard !existingSuffixes.isEmpty else { return nil }

        let databaseURL = URL(fileURLWithPath: path)
        let quarantineRoot = databaseURL.deletingLastPathComponent()
            .appending(path: "Quarantine", directoryHint: .isDirectory)
        try fileManager.createDirectory(
            at: quarantineRoot,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        try applyFileSecurity(to: quarantineRoot)

        let identifier = "\(quarantineTimestamp(now))-\(UUID().uuidString.lowercased())"
        let staging = quarantineRoot.appending(path: ".staging-\(identifier)", directoryHint: .isDirectory)
        let destination = quarantineRoot.appending(path: "cloud-\(identifier)", directoryHint: .isDirectory)
        try fileManager.createDirectory(
            at: staging,
            withIntermediateDirectories: false,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )

        var movedSuffixes: [String] = []
        do {
            for suffix in existingSuffixes {
                let source = URL(fileURLWithPath: path + suffix)
                let target = staging.appending(path: source.lastPathComponent)
                try fileManager.moveItem(at: source, to: target)
                movedSuffixes.append(suffix)
                try applyFileSecurity(to: target)
            }
            try applyFileSecurity(to: staging)
            try fileManager.moveItem(at: staging, to: destination)
            try applyFileSecurity(to: destination)
            return destination
        } catch {
            for suffix in movedSuffixes.reversed() {
                let fileName = URL(fileURLWithPath: path + suffix).lastPathComponent
                let quarantined = staging.appending(path: fileName)
                if fileManager.fileExists(atPath: quarantined.path) {
                    try? fileManager.moveItem(at: quarantined, to: URL(fileURLWithPath: path + suffix))
                }
            }
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    init(path: String, key: Data) throws {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.usePassphrase(key)
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        configuration.journalMode = .wal
        // A background runtime and a foreground scene can briefly overlap during process
        // restoration. Wait for the current WAL writer instead of surfacing SQLITE_BUSY and
        // abandoning an otherwise valid atomic job claim.
        configuration.busyMode = .timeout(5)
        let openInterval = Self.signposter.beginInterval("DatabaseOpen")
        let pool: DatabasePool
        do {
            pool = try DatabasePool(path: path, configuration: configuration)
            Self.signposter.endInterval("DatabaseOpen", openInterval)
        } catch {
            Self.signposter.endInterval("DatabaseOpen", openInterval)
            throw error
        }
        dbQueue = pool
        let migrationInterval = Self.signposter.beginInterval("DatabaseMigration")
        do {
            try Self.migrate(dbQueue)
            Self.signposter.endInterval("DatabaseMigration", migrationInterval)
        } catch {
            Self.signposter.endInterval("DatabaseMigration", migrationInterval)
            throw error
        }
        try Self.applyFileSecurity(toSQLiteFilesAt: path)
    }

    /// Runs the potentially expensive whole-store integrity scan after the cached launch snapshot
    /// has already been published. Opening SQLCipher and running migrations still validate the key
    /// and schema synchronously; this scan is deliberately not on the launch critical path.
    func verifyIntegrity() throws {
        let interval = Self.signposter.beginInterval("DatabaseIntegrity")
        defer { Self.signposter.endInterval("DatabaseIntegrity", interval) }
        let result = try dbQueue.read { db in
            try String.fetchAll(db, sql: "PRAGMA quick_check(1)")
        }
        guard result == ["ok"] else { throw LocalStoreOpenError.integrityCheckFailed }
    }

    func databaseJournalMode() throws -> String {
        try dbQueue.read { db in
            try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? ""
        }
    }

    func loadPts(accountId: String) throws -> Int64 {
        try dbQueue.read { db in
            try Int64.fetchOne(db, sql: "SELECT pts FROM sync_state WHERE account_id = ?", arguments: [accountId]) ?? 0
        }
    }

    /// Reads the complete UI launch state from one WAL snapshot so the main actor can publish it
    /// atomically before any online reconciler starts writing.
    func loadLaunchSnapshot(accountId: String) throws -> LocalLaunchSnapshot {
        try dbQueue.read { db in
            LocalLaunchSnapshot(
                pts: try Int64.fetchOne(
                    db,
                    sql: "SELECT pts FROM sync_state WHERE account_id = ?",
                    arguments: [accountId]
                ) ?? 0,
                dialogs: try Self.fetchDialogs(db, accountId: accountId)
            )
        }
    }

    func savePts(_ pts: Int64, accountId: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO sync_state (account_id, pts, updated_at)
                VALUES (?, ?, datetime('now'))
                ON CONFLICT(account_id) DO UPDATE SET pts = excluded.pts, updated_at = excluded.updated_at
                """,
                arguments: [accountId, pts]
            )
        }
    }

    func isReplicaInitialized(accountId: String) throws -> Bool {
        try dbQueue.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT initialized FROM replica_state WHERE account_id = ?",
                arguments: [accountId]
            ) ?? false
        }
    }

    func clearAccount(accountId: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM sync_state WHERE account_id = ?", arguments: [accountId])
            try db.execute(sql: "DELETE FROM replica_state WHERE account_id = ?", arguments: [accountId])
            try deleteReplicaData(db, includeMediaTransfers: true)
        }
    }

    func beginBootstrap(accountId: String) throws {
        try beginBootstrap(accountId: accountId, token: nil, snapshotPts: nil)
    }

    func beginBootstrap(accountId: String, token: String?, snapshotPts: Int64?) throws {
        try beginBootstrap(accountId: accountId, token: token, snapshotPts: snapshotPts, mode: nil)
    }

    func beginBootstrap(
        accountId: String,
        token: String?,
        snapshotPts: Int64?,
        mode: ReplicaBootstrapMode
    ) throws {
        try beginBootstrap(accountId: accountId, token: token, snapshotPts: snapshotPts, mode: mode as ReplicaBootstrapMode?)
    }

    private func beginBootstrap(
        accountId: String,
        token: String?,
        snapshotPts: Int64?,
        mode requestedMode: ReplicaBootstrapMode?
    ) throws {
        try dbQueue.write { db in
            let savedMode = try String.fetchOne(
                db,
                sql: "SELECT mode FROM bootstrap_state WHERE account_id = ?",
                arguments: [accountId]
            ).flatMap(ReplicaBootstrapMode.init(rawValue:))
            let hasPublishedDialogs = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM dialogs LIMIT 1)"
            ) ?? false
            let mode = requestedMode ?? savedMode ?? (hasPublishedDialogs ? .replacement : .initial)

            try clearBootstrapStaging(db, accountId: accountId)
            try db.execute(
                sql: """
                INSERT INTO bootstrap_baseline_dialogs (account_id, dialog_id)
                SELECT ?, dialog_id FROM dialogs
                """,
                arguments: [accountId]
            )
            try db.execute(
                sql: """
                INSERT INTO bootstrap_state (
                  account_id, token, next_cursor, snapshot_pts, status, mode, updated_at
                ) VALUES (?, ?, NULL, COALESCE(?, 0), 'in_progress', ?, datetime('now'))
                ON CONFLICT(account_id) DO UPDATE SET
                  token = COALESCE(excluded.token, bootstrap_state.token),
                  next_cursor = NULL,
                  snapshot_pts = CASE
                    WHEN ? IS NULL THEN bootstrap_state.snapshot_pts
                    ELSE excluded.snapshot_pts
                  END,
                  status = 'in_progress',
                  mode = excluded.mode,
                  updated_at = excluded.updated_at
                """,
                arguments: [accountId, token, snapshotPts, mode.rawValue, snapshotPts]
            )
        }
    }

    func applyBootstrapPage(_ page: BootstrapDialogsPage) throws {
        try dbQueue.write { db in
            guard let state = try Row.fetchOne(
                db,
                sql: "SELECT account_id, mode FROM bootstrap_state WHERE status = 'in_progress'"
            ) else {
                throw CloudLocalStoreBootstrapError.notInProgress
            }
            let accountId: String = state["account_id"]
            let mode = ReplicaBootstrapMode(rawValue: state["mode"]) ?? .initial

            try stageBootstrapPage(db, accountId: accountId, page: page)
            if mode == .initial {
                // A genuinely new device has no prior UI to protect. Publishing each committed page
                // lets it render after page one while the durable staging set still tracks which
                // rows belong to the eventual complete snapshot.
                for profile in page.dialogs.flatMap({ $0.profiles ?? [] }) {
                    try upsertProfile(db, profile: profile)
                }
                for dialog in page.dialogs {
                    try mergeBootstrapDialog(
                        db,
                        accountId: accountId,
                        dialog: dialog,
                        pruneSnapshotWindow: false
                    )
                }
            }
            try db.execute(
                sql: """
                UPDATE bootstrap_state
                SET token = ?, next_cursor = ?, snapshot_pts = ?, updated_at = datetime('now')
                WHERE account_id = ? AND status = 'in_progress'
                """,
                arguments: [page.token, page.nextCursor, page.state.pts, accountId]
            )
        }
    }

    func applyHistoryPage(_ page: HistoryPageResponse) throws {
        try dbQueue.write { db in
            for profile in page.profiles ?? [] {
                try upsertProfile(db, profile: profile)
            }
            let durableType = try String.fetchOne(
                db,
                sql: "SELECT type FROM dialogs WHERE dialog_id = ?",
                arguments: [page.dialogId]
            ) ?? "direct"
            for message in page.messages {
                try upsertDialog(
                    db,
                    dialogId: message.dialogId,
                    type: durableType,
                    title: nil,
                    lastMsgId: message.msgId,
                    updatedAt: message.serverTs
                )
                try upsertMessage(db, message: message, localState: "sent", refreshSummaries: false)
            }
            try refreshDialogSummary(db, dialogId: page.dialogId)
            let existingCeiling = try Int64.fetchOne(
                db,
                sql: "SELECT ceiling_msg_id FROM dialog_history_state WHERE dialog_id = ?",
                arguments: [page.dialogId]
            ) ?? 0
            let pageCeiling = page.messages.map(\.msgId).max() ?? 0
            try upsertHistoryState(
                db,
                state: DialogHistoryState(
                    dialogId: page.dialogId,
                    ceilingMsgId: max(existingCeiling, pageCeiling),
                    nextBeforeMsgId: page.nextBeforeMsgId,
                    historyComplete: !page.hasMore,
                    retryCount: 0,
                    nextRetryAt: nil
                )
            )
        }
    }

    /// Stores a window fetched around a semantic anchor without moving the sequential backfill
    /// cursor. This lets a sparse bootstrap locate first-unread immediately while normal hydration
    /// continues from its previously persisted position.
    func applyTargetedHistoryPage(_ page: HistoryPageResponse) throws {
        try dbQueue.write { db in
            for profile in page.profiles ?? [] {
                try upsertProfile(db, profile: profile)
            }
            let durableType = try String.fetchOne(
                db,
                sql: "SELECT type FROM dialogs WHERE dialog_id = ?",
                arguments: [page.dialogId]
            ) ?? "direct"
            for message in page.messages {
                try upsertDialog(
                    db,
                    dialogId: message.dialogId,
                    type: durableType,
                    title: nil,
                    lastMsgId: message.msgId,
                    updatedAt: message.serverTs
                )
                try upsertMessage(db, message: message, localState: "sent", refreshSummaries: false)
            }
            try refreshDialogSummary(db, dialogId: page.dialogId)
        }
    }

    func finishBootstrap(accountId: String, pts: Int64) throws {
        try dbQueue.write { db in
            guard try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM bootstrap_state WHERE account_id = ? AND status = 'in_progress')",
                arguments: [accountId]
            ) == true else {
                throw CloudLocalStoreBootstrapError.notInProgress
            }

            let snapshot = try loadStagedBootstrapSnapshot(db, accountId: accountId)
            for profile in snapshot.profiles {
                try upsertProfile(db, profile: profile)
            }
            for dialog in snapshot.dialogs {
                try mergeBootstrapDialog(
                    db,
                    accountId: accountId,
                    dialog: dialog,
                    pruneSnapshotWindow: true
                )
            }
            try pruneDialogsMissingFromBootstrap(
                db,
                accountId: accountId,
                stagedDialogIds: Set(snapshot.dialogs.map(\.dialogId))
            )

            try db.execute(
                sql: """
                INSERT INTO sync_state (account_id, pts, updated_at)
                VALUES (?, ?, datetime('now'))
                ON CONFLICT(account_id) DO UPDATE SET pts = excluded.pts, updated_at = excluded.updated_at
                """,
                arguments: [accountId, pts]
            )
            try db.execute(
                sql: """
                INSERT INTO replica_state (account_id, initialized, updated_at)
                VALUES (?, 1, datetime('now'))
                ON CONFLICT(account_id) DO UPDATE SET
                  initialized = 1,
                  updated_at = excluded.updated_at
                """,
                arguments: [accountId]
            )
            // A response only proves that the server accepted the mutation. Keep its optimistic
            // overlay until the exact snapshot cursor is known to contain the canonical value.
            try db.execute(
                sql: """
                DELETE FROM pending_dialog_preference_mutations
                WHERE account_id = ?
                  AND acknowledged_pts IS NOT NULL
                  AND acknowledged_pts <= ?
                """,
                arguments: [accountId, pts]
            )
            try clearBootstrapStaging(db, accountId: accountId)
            try db.execute(sql: "DELETE FROM bootstrap_state WHERE account_id = ?", arguments: [accountId])
        }
    }

    func saveMembers(dialogId: String, members: [BootstrapDialogMember]) throws {
        try dbQueue.write { db in
            for member in members {
                try upsertMember(db, dialogId: dialogId, member: member)
            }
        }
    }

    func saveProfile(_ profile: CloudProfile) throws {
        try dbQueue.write { db in
            try upsertProfile(db, profile: profile)
        }
    }

    @discardableResult
    func queueDialogPreference(
        accountId: String,
        dialogId: String,
        field: DialogPreferenceField,
        desiredValue explicitValue: Bool? = nil
    ) throws -> PendingDialogPreferenceMutation? {
        try dbQueue.write { db in
            guard try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM dialogs WHERE dialog_id = ?)",
                arguments: [dialogId]
            ) == true else { return nil }
            try ensureDialogPreferences(db, accountId: accountId, dialogId: dialogId)

            let existing = try Row.fetchOne(
                db,
                sql: """
                SELECT *
                FROM pending_dialog_preference_mutations
                WHERE account_id = ? AND dialog_id = ? AND field = ? AND terminal = 0
                """,
                arguments: [accountId, dialogId, field.rawValue]
            )
            let canonicalColumn: String = switch field {
            case .pinned: "is_pinned"
            case .muted: "is_muted"
            case .archived: "is_archived"
            }
            let canonical = try Bool.fetchOne(
                db,
                sql: """
                SELECT \(canonicalColumn)
                FROM dialog_preferences
                WHERE account_id = ? AND dialog_id = ?
                """,
                arguments: [accountId, dialogId]
            ) ?? false
            let current = existing.map { ($0["desired_value"] as Int) != 0 } ?? canonical
            let desiredValue = explicitValue ?? !current
            if explicitValue != nil, desiredValue == current {
                return existing.map(Self.pendingDialogPreference(from:))
            }

            let mutationId = UUID().uuidString.lowercased()
            // Preserve sub-second toggle order and use the same lexical shape as server-authored
            // pinned_at values so rapid offline pins sort deterministically.
            let desiredAt = Self.preferenceTimestamp(Date())
            try db.execute(
                sql: """
                INSERT INTO pending_dialog_preference_mutations (
                  account_id, dialog_id, field, desired_value, desired_at,
                  client_mutation_id, acknowledged_pts, retry_count,
                  next_retry_at, last_error, terminal
                ) VALUES (?, ?, ?, ?, ?, ?, NULL, 0, NULL, NULL, 0)
                ON CONFLICT(account_id, dialog_id, field) DO UPDATE SET
                  desired_value = excluded.desired_value,
                  desired_at = excluded.desired_at,
                  client_mutation_id = excluded.client_mutation_id,
                  acknowledged_pts = NULL,
                  retry_count = 0,
                  next_retry_at = NULL,
                  last_error = NULL,
                  terminal = 0
                """,
                arguments: [
                    accountId, dialogId, field.rawValue, desiredValue,
                    desiredAt, mutationId,
                ]
            )
            return try Row.fetchOne(
                db,
                sql: """
                SELECT *
                FROM pending_dialog_preference_mutations
                WHERE account_id = ? AND dialog_id = ? AND field = ?
                """,
                arguments: [accountId, dialogId, field.rawValue]
            ).map(Self.pendingDialogPreference(from:))
        }
    }

    func pendingDialogPreferencesReady(
        accountId: String,
        limit: Int = 50
    ) throws -> [PendingDialogPreferenceMutation] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT *
                FROM pending_dialog_preference_mutations
                WHERE account_id = ?
                  AND terminal = 0
                  AND acknowledged_pts IS NULL
                  AND (next_retry_at IS NULL OR next_retry_at <= datetime('now'))
                ORDER BY desired_at, dialog_id, field
                LIMIT ?
                """,
                arguments: [accountId, max(1, min(limit, 200))]
            ).map(Self.pendingDialogPreference(from:))
        }
    }

    func acknowledgeDialogPreference(
        clientMutationId: String,
        pts: Int64,
        preferences _: CloudDialogPreferences,
        accountId: String
    ) throws {
        try dbQueue.write { db in
            // A delayed HTTP response may predate a difference event already applied locally.
            // The response therefore records only its acknowledgement cursor; canonical values
            // remain exclusively authored by the ordered event/bootstrap stream.
            try db.execute(
                sql: """
                UPDATE pending_dialog_preference_mutations
                SET acknowledged_pts = ?, next_retry_at = NULL, last_error = NULL
                WHERE account_id = ? AND client_mutation_id = ? AND terminal = 0
                """,
                arguments: [pts, accountId, clientMutationId]
            )
        }
    }

    func nextDialogPreferenceRetryDelay(
        accountId: String,
        now: Date = Date()
    ) throws -> TimeInterval? {
        let nowText = Self.sqliteTimestamp(now)
        return try dbQueue.read { db in
            let due = try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM pending_dialog_preference_mutations
                WHERE account_id = ?
                  AND terminal = 0
                  AND acknowledged_pts IS NULL
                  AND (next_retry_at IS NULL OR next_retry_at <= ?)
                """,
                arguments: [accountId, nowText]
            ) ?? 0
            if due > 0 { return 0 }
            guard let next = try String.fetchOne(
                db,
                sql: """
                SELECT MIN(next_retry_at)
                FROM pending_dialog_preference_mutations
                WHERE account_id = ?
                  AND terminal = 0
                  AND acknowledged_pts IS NULL
                  AND next_retry_at > ?
                """,
                arguments: [accountId, nowText]
            ), let date = Self.makeSQLiteDateFormatter().date(from: next) else { return nil }
            return max(0, date.timeIntervalSince(now))
        }
    }

    func failDialogPreference(
        accountId: String,
        clientMutationId: String,
        retryAfter: TimeInterval?,
        error: String,
        terminal: Bool
    ) throws {
        let nextRetryAt = retryAfter.map {
            Self.sqliteTimestamp(Date().addingTimeInterval(max(1, $0)))
        }
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE pending_dialog_preference_mutations
                SET retry_count = retry_count + 1,
                    next_retry_at = ?,
                    last_error = ?,
                    terminal = ?
                WHERE account_id = ? AND client_mutation_id = ?
                """,
                arguments: [
                    nextRetryAt, error, terminal, accountId, clientMutationId,
                ]
            )
        }
    }

    func applyDialogPreferences(
        _ preferences: CloudDialogPreferences,
        accountId: String,
        clientMutationId: String? = nil
    ) throws {
        try dbQueue.write { db in
            try upsertDialogPreferences(
                db,
                preferences: preferences,
                accountId: accountId,
                clientMutationId: clientMutationId
            )
        }
    }

    func markRead(
        dialogId: String,
        accountId: String,
        maxReadMsgId: Int64,
        exactUnreadCount: Int? = nil
    ) throws {
        try dbQueue.write { db in
            try markRead(
                db,
                dialogId: dialogId,
                accountId: accountId,
                maxReadMsgId: maxReadMsgId,
                exactUnreadCount: exactUnreadCount
            )
        }
    }

    /// Advances the UI watermark and durably queues its server acknowledgement in one transaction.
    func queueReadReceipt(dialogId: String, accountId: String, maxReadMsgId: Int64) throws {
        try dbQueue.write { db in
            try markRead(db, dialogId: dialogId, accountId: accountId, maxReadMsgId: maxReadMsgId)
            try db.execute(
                sql: """
                INSERT INTO pending_read_receipts (
                  dialog_id, account_id, max_read_msg_id, retry_count,
                  next_retry_at, last_error, updated_at
                ) VALUES (?, ?, ?, 0, NULL, NULL, datetime('now'))
                ON CONFLICT(dialog_id, account_id) DO UPDATE SET
                  max_read_msg_id = MAX(
                    pending_read_receipts.max_read_msg_id,
                    excluded.max_read_msg_id
                  ),
                  retry_count = CASE
                    WHEN excluded.max_read_msg_id > pending_read_receipts.max_read_msg_id THEN 0
                    ELSE pending_read_receipts.retry_count
                  END,
                  next_retry_at = NULL,
                  last_error = NULL,
                  updated_at = excluded.updated_at
                """,
                arguments: [dialogId, accountId, maxReadMsgId]
            )
        }
    }

    func pendingReadReceiptsReady(limit: Int = 50) throws -> [PendingReadReceipt] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT dialog_id, account_id, max_read_msg_id, retry_count, next_retry_at
                FROM pending_read_receipts
                WHERE next_retry_at IS NULL OR next_retry_at <= datetime('now')
                ORDER BY updated_at, dialog_id
                LIMIT ?
                """,
                arguments: [max(1, min(limit, 200))]
            )
            return rows.map { row in
                PendingReadReceipt(
                    dialogId: row["dialog_id"],
                    accountId: row["account_id"],
                    maxReadMsgId: row["max_read_msg_id"],
                    retryCount: row["retry_count"],
                    nextRetryAt: row["next_retry_at"]
                )
            }
        }
    }

    func completeReadReceipt(
        dialogId: String,
        accountId: String,
        acknowledgedMsgId: Int64
    ) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                DELETE FROM pending_read_receipts
                WHERE dialog_id = ? AND account_id = ? AND max_read_msg_id <= ?
                """,
                arguments: [dialogId, accountId, acknowledgedMsgId]
            )
        }
    }

    func failReadReceipt(
        dialogId: String,
        accountId: String,
        retryAfter: TimeInterval,
        error: String? = nil,
        attemptedMsgId: Int64? = nil
    ) throws {
        let nextRetryAt = Self.sqliteTimestamp(Date().addingTimeInterval(max(1, retryAfter)))
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE pending_read_receipts
                SET retry_count = retry_count + 1,
                    next_retry_at = ?, last_error = ?, updated_at = datetime('now')
                WHERE dialog_id = ? AND account_id = ?
                  AND (? IS NULL OR max_read_msg_id <= ?)
                """,
                arguments: [
                    nextRetryAt, error, dialogId, accountId,
                    attemptedMsgId, attemptedMsgId,
                ]
            )
        }
    }

    func upsertDialog(dialogId: String, type: String = "direct", title: String? = nil, lastMsgId: Int64 = 0, updatedAt: String? = nil) throws {
        try dbQueue.write { db in
            try upsertDialog(db, dialogId: dialogId, type: type, title: title, lastMsgId: lastMsgId, updatedAt: updatedAt)
        }
    }

    @discardableResult
    func createPendingGroup(
        groupId: String,
        title: String,
        memberIds: [String],
        creatorAccountId: String,
        localPhotoReference: String? = nil
    ) throws -> Bool {
        let normalizedMembers = Array(Set(memberIds.filter { $0 != creatorAccountId })).sorted()
        let memberData = try JSONEncoder().encode(normalizedMembers)
        guard let memberJSON = String(data: memberData, encoding: .utf8) else {
            throw CloudLocalStoreBootstrapError.invalidGroupState
        }
        return try dbQueue.write { db in
            let exists = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM pending_group_creations WHERE group_id = ?)",
                arguments: [groupId]
            ) ?? false
            if exists { return false }
            try db.execute(
                sql: """
                INSERT INTO dialogs (
                  dialog_id, type, title, last_msg_id, updated_at, revision, member_count,
                  self_role, notification_mode, access_state
                ) VALUES (?, 'group', ?, 0, datetime('now'), 0, ?, 'owner', 'all', 'pending')
                ON CONFLICT(dialog_id) DO NOTHING
                """,
                arguments: [groupId, title, normalizedMembers.count + 1]
            )
            try ensureDialogSummary(db, dialogId: groupId)
            try db.execute(
                sql: """
                INSERT INTO dialog_members (
                  dialog_id, account_id, role, last_read_msg_id, joined_at, is_active, revision
                ) VALUES (?, ?, 'owner', 0, datetime('now'), 1, 0)
                ON CONFLICT(dialog_id, account_id) DO UPDATE SET
                  role = 'owner', is_active = 1, left_at = NULL
                """,
                arguments: [groupId, creatorAccountId]
            )
            for memberId in normalizedMembers {
                try db.execute(
                    sql: """
                    INSERT INTO dialog_members (
                      dialog_id, account_id, role, last_read_msg_id, joined_at, is_active, revision
                    ) VALUES (?, ?, 'member', 0, datetime('now'), 1, 0)
                    ON CONFLICT(dialog_id, account_id) DO UPDATE SET
                      role = 'member', is_active = 1, left_at = NULL
                    """,
                    arguments: [groupId, memberId]
                )
            }
            try db.execute(
                sql: """
                INSERT INTO pending_group_creations (
                  group_id, title, member_ids_json, local_photo_reference, state,
                  created_at, updated_at
                ) VALUES (?, ?, ?, ?, 'queued', datetime('now'), datetime('now'))
                """,
                arguments: [groupId, title, memberJSON, localPhotoReference]
            )
            return true
        }
    }

    func pendingGroupCreationsReady(limit: Int = 10) throws -> [PendingGroupCreation] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM pending_group_creations
                WHERE terminal = 0 AND state IN ('queued','creating')
                  AND (next_retry_at IS NULL OR next_retry_at <= datetime('now'))
                ORDER BY created_at
                LIMIT ?
                """,
                arguments: [max(1, min(50, limit))]
            ).compactMap(Self.pendingGroupCreation(from:))
        }
    }

    func nextPendingGroupCreationDelay(now: Date = Date()) throws -> TimeInterval? {
        let nowText = Self.sqliteTimestamp(now)
        return try dbQueue.read { db in
            let due = try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*) FROM pending_group_creations
                WHERE terminal = 0 AND state IN ('queued','creating')
                  AND (next_retry_at IS NULL OR next_retry_at <= ?)
                """,
                arguments: [nowText]
            ) ?? 0
            if due > 0 { return 0 }
            guard let next = try String.fetchOne(
                db,
                sql: """
                SELECT MIN(next_retry_at) FROM pending_group_creations
                WHERE terminal = 0 AND state IN ('queued','creating') AND next_retry_at > ?
                """,
                arguments: [nowText]
            ), let date = Self.makeSQLiteDateFormatter().date(from: next) else { return nil }
            return max(0, date.timeIntervalSince(now))
        }
    }

    func markGroupCreating(groupId: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE pending_group_creations
                SET state = 'creating', last_error = NULL, updated_at = datetime('now')
                WHERE group_id = ? AND terminal = 0
                """,
                arguments: [groupId]
            )
        }
    }

    func retryGroupCreation(
        groupId: String,
        after delay: TimeInterval,
        error: String
    ) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE pending_group_creations
                SET state = 'queued', retry_count = retry_count + 1,
                    next_retry_at = ?, last_error = ?, updated_at = datetime('now')
                WHERE group_id = ? AND terminal = 0
                """,
                arguments: [
                    Self.sqliteTimestamp(Date().addingTimeInterval(max(1, delay))),
                    error,
                    groupId,
                ]
            )
        }
    }

    func failGroupCreation(groupId: String, error: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE pending_group_creations
                SET state = 'failed', terminal = 1, last_error = ?, updated_at = datetime('now')
                WHERE group_id = ?
                """,
                arguments: [error, groupId]
            )
        }
    }

    func retryFailedGroupCreation(groupId: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE pending_group_creations
                SET state = 'queued', terminal = 0, next_retry_at = NULL,
                    last_error = NULL, updated_at = datetime('now')
                WHERE group_id = ?
                """,
                arguments: [groupId]
            )
        }
    }

    func enqueueGroupMutation(
        dialogId: String,
        operation: String,
        payloadJSON: String,
        clientMutationId: String
    ) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO pending_group_mutations (
                  client_mutation_id, dialog_id, operation, payload_json, created_at
                ) VALUES (?, ?, ?, ?, datetime('now'))
                ON CONFLICT(client_mutation_id) DO NOTHING
                """,
                arguments: [clientMutationId, dialogId, operation, payloadJSON]
            )
        }
    }

    func pendingGroupMutationsReady(
        now: Date = Date(),
        limit: Int = 20
    ) throws -> [PendingGroupMutation] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT pending_group_mutations.* FROM pending_group_mutations
                LEFT JOIN dialogs
                  ON dialogs.dialog_id = pending_group_mutations.dialog_id
                WHERE pending_group_mutations.terminal = 0
                  AND COALESCE(dialogs.access_state, 'active') <> 'pending'
                  AND (
                    pending_group_mutations.next_retry_at IS NULL
                    OR pending_group_mutations.next_retry_at <= ?
                  )
                ORDER BY pending_group_mutations.created_at,
                         pending_group_mutations.client_mutation_id
                LIMIT ?
                """,
                arguments: [Self.sqliteTimestamp(now), max(1, min(100, limit))]
            ).map(Self.pendingGroupMutation(from:))
        }
    }

    func completeGroupMutation(clientMutationId: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM pending_group_mutations WHERE client_mutation_id = ?",
                arguments: [clientMutationId]
            )
        }
    }

    func failGroupMutation(
        clientMutationId: String,
        retryAfter: TimeInterval?,
        error: String,
        terminal: Bool
    ) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE pending_group_mutations
                SET retry_count = retry_count + 1,
                    next_retry_at = ?,
                    last_error = ?,
                    terminal = ?
                WHERE client_mutation_id = ?
                """,
                arguments: [
                    retryAfter.map {
                        Self.sqliteTimestamp(Date().addingTimeInterval(max(1, $0)))
                    },
                    error,
                    terminal,
                    clientMutationId,
                ]
            )
        }
    }

    func nextPendingGroupMutationDelay(now: Date = Date()) throws -> TimeInterval? {
        let nowText = Self.sqliteTimestamp(now)
        return try dbQueue.read { db in
            let due = try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*) FROM pending_group_mutations
                LEFT JOIN dialogs
                  ON dialogs.dialog_id = pending_group_mutations.dialog_id
                WHERE pending_group_mutations.terminal = 0
                  AND COALESCE(dialogs.access_state, 'active') <> 'pending'
                  AND (
                    pending_group_mutations.next_retry_at IS NULL
                    OR pending_group_mutations.next_retry_at <= ?
                  )
                """,
                arguments: [nowText]
            ) ?? 0
            if due > 0 { return 0 }
            guard let next = try String.fetchOne(
                db,
                sql: """
                SELECT MIN(pending_group_mutations.next_retry_at)
                FROM pending_group_mutations
                LEFT JOIN dialogs
                  ON dialogs.dialog_id = pending_group_mutations.dialog_id
                WHERE pending_group_mutations.terminal = 0
                  AND COALESCE(dialogs.access_state, 'active') <> 'pending'
                  AND pending_group_mutations.next_retry_at > ?
                """,
                arguments: [nowText]
            ), let date = Self.makeSQLiteDateFormatter().date(from: next) else { return nil }
            return max(0, date.timeIntervalSince(now))
        }
    }

    func applyGroupEnvelope(_ envelope: CloudGroupEnvelope) throws {
        try dbQueue.write { db in
            for profile in envelope.profiles {
                try upsertProfile(db, profile: profile)
            }
            try applyGroup(db, group: envelope.group)
            for member in envelope.members ?? [] {
                try upsertGroupMember(
                    db,
                    dialogId: envelope.group.id,
                    member: member,
                    revision: envelope.group.revision
                )
            }
            try db.execute(
                sql: "DELETE FROM pending_group_creations WHERE group_id = ?",
                arguments: [envelope.group.id]
            )
        }
    }

    func applyGroupMembersPage(_ page: CloudGroupMembersPage, generation: String) throws {
        try dbQueue.write { db in
            for profile in page.profiles {
                try upsertProfile(db, profile: profile)
            }
            try applyGroup(db, group: page.group)
            for member in page.members {
                try upsertGroupMember(
                    db,
                    dialogId: page.group.id,
                    member: member,
                    revision: page.group.revision,
                    generation: generation
                )
            }
            if !page.hasMore {
                try db.execute(
                    sql: """
                    DELETE FROM dialog_members
                    WHERE dialog_id = ? AND COALESCE(seen_generation, '') <> ?
                    """,
                    arguments: [page.group.id, generation]
                )
                try db.execute(
                    sql: "DELETE FROM group_member_hydration WHERE dialog_id = ?",
                    arguments: [page.group.id]
                )
            }
        }
    }

    func revokeGroupAccess(
        dialogId: String,
        accessState: String = "removed",
        reason: String
    ) throws {
        try dbQueue.write { db in
            try revokeGroupAccess(
                db,
                dialogId: dialogId,
                accessState: accessState,
                reason: reason
            )
        }
    }

    func drainPendingPurges(limit: Int = 20) throws -> Int {
        try dbQueue.write { db in
            let purges = try Row.fetchAll(
                db,
                sql: "SELECT * FROM pending_purges ORDER BY created_at LIMIT ?",
                arguments: [max(1, min(100, limit))]
            )
            for purge in purges {
                let id: String = purge["id"]
                let dialogId: String = purge["dialog_id"]
                let kind: String = purge["kind"]
                if kind == "messages" {
                    try db.execute(sql: "DELETE FROM messages WHERE dialog_id = ?", arguments: [dialogId])
                    try db.execute(sql: "DELETE FROM message_media WHERE dialog_id = ?", arguments: [dialogId])
                } else {
                    let payload: String? = purge["payload"]
                    let mediaIds = payload?
                        .data(using: .utf8)
                        .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
                    for mediaId in mediaIds {
                        try db.execute(
                            sql: "DELETE FROM media_cache_entries WHERE media_id = ?",
                            arguments: [mediaId]
                        )
                        try db.execute(
                            sql: "DELETE FROM media_download_jobs WHERE media_id = ?",
                            arguments: [mediaId]
                        )
                    }
                }
                try db.execute(sql: "DELETE FROM pending_purges WHERE id = ?", arguments: [id])
            }
            return purges.count
        }
    }

    func insertSending(
        dialogId: String,
        clientMsgId: String,
        text: String,
        senderAccountId: String,
        replyToMsgId: Int64? = nil,
        mentions: [CloudMention] = [],
        forwardedFromAccountId: String? = nil,
        forwardedFromDialogId: String? = nil,
        forwardedFromMsgId: Int64? = nil
    ) throws -> LocalMessage {
        let localId = "pending:\(clientMsgId)"
        let mentionsJSON = try String(
            data: JSONEncoder().encode(mentions),
            encoding: .utf8
        ) ?? "[]"
        try dbQueue.write { db in
            try upsertDialog(db, dialogId: dialogId, type: "direct", title: nil, lastMsgId: 0, updatedAt: nil)
            try db.execute(
                sql: """
                INSERT INTO messages (
                  local_id, dialog_id, msg_id, client_msg_id, sender_account_id, kind, text,
                  reply_to_msg_id, forwarded_from_account_id, forwarded_from_dialog_id,
                  forwarded_from_msg_id, is_forwarded, mentions_json,
                  edit_version, state, server_ts, local_state
                )
                VALUES (?, ?, NULL, ?, ?, 'text', ?, ?, ?, ?, ?, ?, ?, 0, 'visible', NULL, 'sending')
                ON CONFLICT(client_msg_id) DO UPDATE SET
                  text = excluded.text,
                  reply_to_msg_id = excluded.reply_to_msg_id,
                  forwarded_from_account_id = excluded.forwarded_from_account_id,
                  forwarded_from_dialog_id = excluded.forwarded_from_dialog_id,
                  forwarded_from_msg_id = excluded.forwarded_from_msg_id,
                  is_forwarded = excluded.is_forwarded,
                  mentions_json = excluded.mentions_json,
                  local_state = 'sending'
                """,
                arguments: [
                    localId, dialogId, clientMsgId, senderAccountId, text, replyToMsgId,
                    forwardedFromAccountId, forwardedFromDialogId, forwardedFromMsgId,
                    forwardedFromMsgId != nil, mentionsJSON
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO pending_outbox (
                  client_msg_id, dialog_id, body, reply_to_msg_id,
                  forwarded_from_dialog_id, forwarded_from_msg_id, mentions_json, created_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, datetime('now'))
                ON CONFLICT(client_msg_id) DO UPDATE SET
                  body = excluded.body,
                  reply_to_msg_id = excluded.reply_to_msg_id,
                  forwarded_from_dialog_id = excluded.forwarded_from_dialog_id,
                  forwarded_from_msg_id = excluded.forwarded_from_msg_id,
                  mentions_json = excluded.mentions_json,
                  next_retry_at = NULL
                """,
                arguments: [
                    clientMsgId, dialogId, text, replyToMsgId,
                    forwardedFromDialogId, forwardedFromMsgId, mentionsJSON
                ]
            )
            try refreshDialogSummary(db, dialogId: dialogId)
            try refreshAllUnreadSummaries(db, dialogId: dialogId)
        }
        return LocalMessage(
            localId: localId,
            dialogId: dialogId,
            msgId: nil,
            clientMsgId: clientMsgId,
            senderAccountId: senderAccountId,
            senderDisplayName: nil,
            kind: "text",
            text: text,
            replyToMsgId: replyToMsgId,
            forwardedFromAccountId: forwardedFromAccountId,
            forwardedFromDialogId: forwardedFromDialogId,
            forwardedFromMsgId: forwardedFromMsgId,
            isForwarded: forwardedFromMsgId != nil,
            reactions: [],
            mentions: mentions,
            media: nil,
            serviceType: nil,
            serviceData: nil,
            editVersion: 0,
            state: "visible",
            serverTs: nil,
            localState: "sending"
        )
    }

    func markRetrying(clientMsgId: String) throws {
        try dbQueue.write { db in
            let dialogId = try String.fetchOne(
                db, sql: "SELECT dialog_id FROM messages WHERE client_msg_id = ?", arguments: [clientMsgId]
            )
            try db.execute(
                sql: """
                UPDATE messages
                SET local_state = 'sending'
                WHERE client_msg_id = ?
                """,
                arguments: [clientMsgId]
            )
            try db.execute(
                sql: """
                UPDATE pending_outbox
                SET next_retry_at = NULL, terminal = 0
                WHERE client_msg_id = ?
                """,
                arguments: [clientMsgId]
            )
            if let dialogId { try refreshDialogSummary(db, dialogId: dialogId) }
        }
    }

    func markFailed(
        clientMsgId: String,
        retryAfter: TimeInterval? = nil,
        terminal: Bool = false
    ) throws {
        let nextRetryAt = retryAfter.map { Self.sqliteTimestamp(Date().addingTimeInterval($0)) }
        try dbQueue.write { db in
            let dialogId = try String.fetchOne(
                db, sql: "SELECT dialog_id FROM messages WHERE client_msg_id = ?", arguments: [clientMsgId]
            )
            try db.execute(sql: "UPDATE messages SET local_state = 'failed' WHERE client_msg_id = ?", arguments: [clientMsgId])
            try db.execute(
                sql: """
                UPDATE pending_outbox
                SET retry_count = retry_count + 1, next_retry_at = ?, terminal = ?
                WHERE client_msg_id = ?
                """,
                arguments: [nextRetryAt, terminal, clientMsgId]
            )
            if let dialogId { try refreshDialogSummary(db, dialogId: dialogId) }
        }
    }

    func markSent(_ response: SendMessageResponse, senderAccountId: String) throws {
        try dbQueue.write { db in
            let previousLocalId = try String.fetchOne(
                db,
                sql: "SELECT local_id FROM messages WHERE client_msg_id = ?",
                arguments: [response.clientMsgId]
            )
            try db.execute(
                sql: """
                UPDATE messages
                SET local_id = ?, dialog_id = ?, msg_id = ?, sender_account_id = ?, text = COALESCE(?, text),
                    server_ts = ?, local_state = 'sent'
                WHERE client_msg_id = ?
                """,
                arguments: [
                    "\(response.dialogId):\(response.msgId)",
                    response.dialogId,
                    response.msgId,
                    senderAccountId,
                    response.text,
                    response.serverTs,
                    response.clientMsgId
                ]
            )
            if let previousLocalId {
                try db.execute(
                    sql: """
                    UPDATE message_media
                    SET local_id = ?, dialog_id = ?, msg_id = ?
                    WHERE local_id = ?
                    """,
                    arguments: [
                        "\(response.dialogId):\(response.msgId)", response.dialogId,
                        response.msgId, previousLocalId
                    ]
                )
            }
            try db.execute(sql: "DELETE FROM pending_outbox WHERE client_msg_id = ?", arguments: [response.clientMsgId])
            try refreshDialogSummary(db, dialogId: response.dialogId)
            try refreshAllUnreadSummaries(db, dialogId: response.dialogId)
        }
    }

    func insertMediaTransfer(
        prepared: PreparedMediaUpload, dialogId: String, clientMsgId: String,
        caption: String, replyToMsgId: Int64?, purpose: String = "message"
    ) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO media_transfers (
                  transfer_id, dialog_id, client_msg_id, caption, reply_to_msg_id,
                  purpose, kind, content_type, file_name, byte_size, sha256, duration_ms, width, height,
                  encrypted_source_path, encrypted_thumbnail_path, state, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', datetime('now'))
                ON CONFLICT(transfer_id) DO NOTHING
                """,
                arguments: [
                    prepared.transferId, dialogId, clientMsgId, caption, replyToMsgId, purpose,
                    prepared.kind, prepared.contentType, prepared.fileName, prepared.byteSize,
                    prepared.sha256, prepared.durationMs, prepared.width, prepared.height,
                    prepared.encryptedSourcePath, prepared.encryptedThumbnailPath
                ]
            )
        }
    }

    func updateMediaTransfer(
        transferId: String, mediaId: String?, uploadOffset: Int64,
        state: String, error: String?, retryAfter: TimeInterval? = nil
    ) throws {
        let next = retryAfter.map { Self.sqliteTimestamp(Date().addingTimeInterval($0)) }
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE media_transfers
                SET media_id = COALESCE(?, media_id), upload_offset = ?, state = ?,
                    last_error = ?, next_retry_at = ?,
                    retry_count = retry_count + CASE WHEN ? IS NULL THEN 0 ELSE 1 END
                WHERE transfer_id = ?
                """,
                arguments: [mediaId, uploadOffset, state, error, next, retryAfter, transferId]
            )
        }
    }

    func markMediaRetrying(clientMsgId: String) throws {
        try dbQueue.write { db in
            let dialogId = try String.fetchOne(
                db, sql: "SELECT dialog_id FROM messages WHERE client_msg_id = ?", arguments: [clientMsgId]
            )
            try db.execute(
                sql: "UPDATE media_transfers SET next_retry_at = NULL, last_error = NULL, terminal = 0 WHERE client_msg_id = ?",
                arguments: [clientMsgId]
            )
            if let dialogId { try refreshDialogSummary(db, dialogId: dialogId) }
            try db.execute(
                sql: "UPDATE messages SET local_state = 'sending' WHERE client_msg_id = ?",
                arguments: [clientMsgId]
            )
        }
    }

    func resetMediaUpload(transferId: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE media_transfers
                SET media_id = NULL, upload_offset = 0, state = 'pending',
                    next_retry_at = NULL, last_error = NULL
                WHERE transfer_id = ?
                """,
                arguments: [transferId]
            )
        }
    }

    func mediaTransfersReady(now: Date = Date(), limit: Int = 10) throws -> [MediaTransferRecord] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT media_transfers.* FROM media_transfers
                LEFT JOIN dialogs ON dialogs.dialog_id = media_transfers.dialog_id
                WHERE media_transfers.terminal = 0
                  AND COALESCE(dialogs.access_state, 'active') <> 'pending'
                  AND (media_transfers.next_retry_at IS NULL OR media_transfers.next_retry_at <= ?)
                ORDER BY media_transfers.created_at, media_transfers.transfer_id LIMIT ?
                """,
                arguments: [Self.sqliteTimestamp(now), limit]
            )
            return rows.map(Self.mediaTransfer(from:))
        }
    }

    func nextMediaTransferDelay(now: Date = Date()) throws -> TimeInterval? {
        let nowText = Self.sqliteTimestamp(now)
        return try dbQueue.read { db in
            let due = try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*) FROM media_transfers
                LEFT JOIN dialogs ON dialogs.dialog_id = media_transfers.dialog_id
                WHERE media_transfers.terminal = 0
                  AND COALESCE(dialogs.access_state, 'active') <> 'pending'
                  AND (media_transfers.next_retry_at IS NULL OR media_transfers.next_retry_at <= ?)
                """,
                arguments: [nowText]
            ) ?? 0
            if due > 0 { return 0 }
            guard let next = try String.fetchOne(
                db,
                sql: """
                SELECT MIN(media_transfers.next_retry_at) FROM media_transfers
                LEFT JOIN dialogs ON dialogs.dialog_id = media_transfers.dialog_id
                WHERE media_transfers.terminal = 0
                  AND COALESCE(dialogs.access_state, 'active') <> 'pending'
                  AND media_transfers.next_retry_at > ?
                """,
                arguments: [nowText]
            ), let date = Self.makeSQLiteDateFormatter().date(from: next) else { return nil }
            return max(0, date.timeIntervalSince(now))
        }
    }

    func mediaTransfer(id: String) throws -> MediaTransferRecord? {
        try dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM media_transfers WHERE transfer_id = ?", arguments: [id])
                .map(Self.mediaTransfer(from:))
        }
    }

    func mediaTransfer(clientMsgId: String) throws -> MediaTransferRecord? {
        try dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM media_transfers WHERE client_msg_id = ? LIMIT 1",
                arguments: [clientMsgId]
            ).map(Self.mediaTransfer(from:))
        }
    }

    func mediaTransfers(dialogId: String) throws -> [MediaTransferRecord] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM media_transfers WHERE dialog_id = ? ORDER BY created_at, transfer_id",
                arguments: [dialogId]
            ).map(Self.mediaTransfer(from:))
        }
    }

    func completeMediaTransfer(transferId: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM media_transfers WHERE transfer_id = ?", arguments: [transferId])
        }
    }

    func cancelMediaTransfer(transferId: String, clientMsgId: String) throws {
        try dbQueue.write { db in
            // Remove the durable outbox row and its optimistic bubble atomically. A later retry can
            // therefore never resurrect a transfer the user explicitly cancelled.
            try db.execute(sql: "DELETE FROM media_transfers WHERE transfer_id = ?", arguments: [transferId])
            let pendingRow = try Row.fetchOne(
                db,
                sql: "SELECT local_id, dialog_id FROM messages WHERE client_msg_id = ? AND msg_id IS NULL",
                arguments: [clientMsgId]
            )
            if let localId: String = pendingRow?["local_id"] {
                try db.execute(sql: "DELETE FROM message_media WHERE local_id = ?", arguments: [localId])
            }
            try db.execute(
                sql: "DELETE FROM messages WHERE client_msg_id = ? AND msg_id IS NULL",
                arguments: [clientMsgId]
            )
            if let dialogId: String = pendingRow?["dialog_id"] {
                try refreshDialogSummary(db, dialogId: dialogId)
                try refreshAllUnreadSummaries(db, dialogId: dialogId)
            }
        }
    }

    func insertSendingMedia(_ transfer: MediaTransferRecord, senderAccountId: String) throws {
        let mediaJSON = String(data: try JSONEncoder().encode(transfer.media), encoding: .utf8)
        try dbQueue.write { db in
            try upsertDialog(db, dialogId: transfer.dialogId, type: "direct", title: nil, lastMsgId: 0, updatedAt: nil)
            try db.execute(
                sql: """
                INSERT INTO messages (
                  local_id, dialog_id, msg_id, client_msg_id, sender_account_id, kind, text,
                  reply_to_msg_id, is_forwarded, media_json, edit_version, state, server_ts, local_state
                ) VALUES (?, ?, NULL, ?, ?, ?, ?, ?, 0, ?, 0, 'visible', NULL, 'sending')
                ON CONFLICT(client_msg_id) DO UPDATE SET
                  kind = excluded.kind, text = excluded.text, media_json = excluded.media_json,
                  local_state = 'sending'
                """,
                arguments: [
                    "pending:\(transfer.clientMsgId)", transfer.dialogId, transfer.clientMsgId,
                    senderAccountId, transfer.kind, transfer.caption, transfer.replyToMsgId, mediaJSON
                ]
            )
            try Self.upsertMessageMedia(
                db,
                localId: "pending:\(transfer.clientMsgId)",
                dialogId: transfer.dialogId,
                msgId: nil,
                media: transfer.media
            )
            try refreshDialogSummary(db, dialogId: transfer.dialogId)
            try refreshAllUnreadSummaries(db, dialogId: transfer.dialogId)
        }
    }

    func applyMessageMutation(_ response: MessageMutationResponse) throws {
        try dbQueue.write { db in
            try upsertMessage(db, message: response.message, localState: "sent")
        }
    }

    func enqueueMessageMutation(
        clientMutationId: String,
        operation: String,
        dialogId: String,
        msgId: Int64,
        body: String? = nil,
        expectedEditVersion: Int? = nil,
        emoji: String? = nil
    ) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO pending_message_mutations (
                  client_mutation_id, operation, dialog_id, msg_id, body,
                  expected_edit_version, emoji, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, datetime('now'))
                ON CONFLICT(client_mutation_id) DO NOTHING
                """,
                arguments: [
                    clientMutationId, operation, dialogId, msgId, body,
                    expectedEditVersion, emoji
                ]
            )
            try refreshDialogSummary(db, dialogId: dialogId)
        }
    }

    func messageMutations(dialogId: String) throws -> [PendingMessageMutation] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM pending_message_mutations
                WHERE dialog_id = ?
                ORDER BY created_at, client_mutation_id
                """,
                arguments: [dialogId]
            ).map(Self.messageMutation(from:))
        }
    }

    func pendingMessageMutationsReady(now: Date = Date(), limit: Int = 20) throws -> [PendingMessageMutation] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM pending_message_mutations
                WHERE terminal = 0 AND (next_retry_at IS NULL OR next_retry_at <= ?)
                ORDER BY created_at, client_mutation_id
                LIMIT ?
                """,
                arguments: [Self.sqliteTimestamp(now), limit]
            ).map(Self.messageMutation(from:))
        }
    }

    func markMessageMutationFailed(
        clientMutationId: String,
        error: String,
        retryAfter: TimeInterval?,
        terminal: Bool
    ) throws {
        let next = retryAfter.map { Self.sqliteTimestamp(Date().addingTimeInterval($0)) }
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE pending_message_mutations
                SET retry_count = retry_count + 1, next_retry_at = ?, last_error = ?, terminal = ?
                WHERE client_mutation_id = ?
                """,
                arguments: [next, error, terminal, clientMutationId]
            )
        }
    }

    func retryMessageMutation(clientMutationId: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE pending_message_mutations
                SET next_retry_at = NULL, last_error = NULL, terminal = 0
                WHERE client_mutation_id = ?
                """,
                arguments: [clientMutationId]
            )
        }
    }

    func completeMessageMutation(clientMutationId: String) throws {
        try dbQueue.write { db in
            let dialogId = try String.fetchOne(
                db,
                sql: "SELECT dialog_id FROM pending_message_mutations WHERE client_mutation_id = ?",
                arguments: [clientMutationId]
            )
            try db.execute(
                sql: "DELETE FROM pending_message_mutations WHERE client_mutation_id = ?",
                arguments: [clientMutationId]
            )
            if let dialogId { try refreshDialogSummary(db, dialogId: dialogId) }
        }
    }

    func nextMessageMutationDelay(now: Date = Date()) throws -> TimeInterval? {
        let nowText = Self.sqliteTimestamp(now)
        return try dbQueue.read { db in
            let due = try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*) FROM pending_message_mutations
                WHERE terminal = 0 AND (next_retry_at IS NULL OR next_retry_at <= ?)
                """,
                arguments: [nowText]
            ) ?? 0
            if due > 0 { return 0 }
            guard let next = try String.fetchOne(
                db,
                sql: """
                SELECT MIN(next_retry_at) FROM pending_message_mutations
                WHERE terminal = 0 AND next_retry_at > ?
                """,
                arguments: [nowText]
            ), let date = Self.makeSQLiteDateFormatter().date(from: next) else { return nil }
            return max(0, date.timeIntervalSince(now))
        }
    }

    func markMediaTerminal(clientMsgId: String, error: String) throws {
        try dbQueue.write { db in
            let dialogId = try String.fetchOne(
                db, sql: "SELECT dialog_id FROM messages WHERE client_msg_id = ?", arguments: [clientMsgId]
            )
            try db.execute(
                sql: """
                UPDATE media_transfers
                SET terminal = 1, next_retry_at = NULL, last_error = ?
                WHERE client_msg_id = ?
                """,
                arguments: [error, clientMsgId]
            )
            try db.execute(
                sql: "UPDATE messages SET local_state = 'failed' WHERE client_msg_id = ?",
                arguments: [clientMsgId]
            )
            if let dialogId { try refreshDialogSummary(db, dialogId: dialogId) }
        }
    }

    func applyDifference(_ difference: DifferenceResponse, accountId: String) throws {
        try dbQueue.write { db in
            if difference.kind == "difference_too_long" {
                // Keep the last readable replica and every durable outbox row in place while a
                // replacement snapshot is fetched. The bootstrap merge is idempotent, so an app
                // termination never leaves the user with an empty chat list.
                try db.execute(
                    sql: """
                    INSERT INTO bootstrap_state (
                      account_id, token, next_cursor, snapshot_pts, status, mode, updated_at
                    ) VALUES (
                      ?, NULL, NULL, ?, 'needs_rebuild',
                      CASE WHEN EXISTS(SELECT 1 FROM dialogs LIMIT 1)
                        THEN 'replacement' ELSE 'initial' END,
                      datetime('now')
                    )
                    ON CONFLICT(account_id) DO UPDATE SET
                      status = 'needs_rebuild',
                      snapshot_pts = excluded.snapshot_pts,
                      mode = excluded.mode,
                      updated_at = excluded.updated_at
                    """,
                    arguments: [accountId, difference.state.pts]
                )
                return
            } else {
                var messageDialogsToRefresh: Set<String> = []
                for profile in difference.profiles ?? [] {
                    try upsertProfile(db, profile: profile)
                }
                for update in difference.updates ?? [] {
                    if update.type == "dialog.preferences_updated",
                       let preferences = update.preferences {
                        try upsertDialogPreferences(
                            db,
                            preferences: preferences,
                            accountId: accountId,
                            clientMutationId: update.clientMutationId
                        )
                    }
                    switch update.type {
                    case "message.new", "message.edited", "message.deleted", "reaction.updated":
                        guard let message = update.message else { continue }
                        let previousMessage = try Row.fetchOne(
                            db,
                            sql: """
                            SELECT msg_id, sender_account_id, state
                            FROM messages WHERE dialog_id = ? AND msg_id = ?
                            """,
                            arguments: [message.dialogId, message.msgId]
                        )
                        let currentRead = try Int64.fetchOne(
                            db,
                            sql: """
                            SELECT last_read_msg_id FROM dialog_members
                            WHERE dialog_id = ? AND account_id = ?
                            """,
                            arguments: [message.dialogId, accountId]
                        ) ?? 0
                        let wasUnread: Bool = {
                            guard let previousMessage else { return false }
                            let msgId: Int64? = previousMessage["msg_id"]
                            let sender: String = previousMessage["sender_account_id"]
                            let state: String = previousMessage["state"]
                            return state == "visible" && sender != accountId && (msgId ?? 0) > currentRead
                        }()
                        let storedType = try String.fetchOne(
                            db,
                            sql: "SELECT type FROM dialogs WHERE dialog_id = ?",
                            arguments: [message.dialogId]
                        )
                        let durableType = update.dialogType ?? storedType ?? "direct"
                        try upsertDialog(
                            db,
                            dialogId: message.dialogId,
                            type: durableType,
                            title: update.dialogTitle,
                            lastMsgId: message.msgId,
                            updatedAt: message.serverTs
                        )
                        // Incoming message events may carry the recipient's atomic auto-unarchive
                        // snapshot. Apply it in the same transaction as the message and pts cursor.
                        if let preferences = update.preferences {
                            try upsertDialogPreferences(
                                db,
                                preferences: preferences,
                                accountId: accountId,
                                clientMutationId: update.clientMutationId
                            )
                        }
                        try upsertMessage(
                            db,
                            message: message,
                            localState: "sent",
                            refreshSummaries: false
                        )
                        let isUnread = message.state == "visible"
                            && message.senderAccountId != accountId
                            && message.msgId > currentRead
                        if wasUnread != isUnread {
                            try adjustUnreadSummary(
                                db,
                                dialogId: message.dialogId,
                                accountId: accountId,
                                delta: isUnread ? 1 : -1
                            )
                        }
                        messageDialogsToRefresh.insert(message.dialogId)
                        if let peerAccountId = update.peerAccountId {
                            try upsertMember(
                                db, dialogId: message.dialogId,
                                member: BootstrapDialogMember(accountId: accountId, role: "member", lastReadMsgId: 0)
                            )
                            try upsertMember(
                                db, dialogId: message.dialogId,
                                member: BootstrapDialogMember(accountId: peerAccountId, role: "member", lastReadMsgId: 0)
                            )
                        }
                    case "dialog.created":
                        guard let dialogId = update.dialogId else { continue }
                        let durableType = update.dialogType
                            ?? (update.group == nil ? "direct" : "group")
                        try upsertDialog(
                            db,
                            dialogId: dialogId,
                            type: durableType,
                            title: update.group?.title ?? update.dialogTitle,
                            lastMsgId: 0,
                            updatedAt: nil
                        )
                        if let group = update.group {
                            try applyGroupMetadata(db, group: group)
                        }
                        if let peerAccountId = update.peerAccountId {
                            try upsertMember(
                                db, dialogId: dialogId,
                                member: BootstrapDialogMember(accountId: accountId, role: "member", lastReadMsgId: 0)
                            )
                            try upsertMember(
                                db, dialogId: dialogId,
                                member: BootstrapDialogMember(accountId: peerAccountId, role: "member", lastReadMsgId: 0)
                            )
                        }
                    case "member.added", "member.removed", "member.role_changed", "member.left",
                         "dialog.profile_updated", "dialog.closed":
                        if let group = update.group {
                            try applyGroupMetadata(db, group: group)
                        }
                        if let member = update.member, let dialogId = update.dialogId {
                            try upsertGroupMember(
                                db,
                                dialogId: dialogId,
                                member: member,
                                revision: update.group?.revision ?? 0
                            )
                        }
                    case "dialog.access_revoked":
                        guard let dialogId = update.dialogId else { continue }
                        try revokeGroupAccess(
                            db,
                            dialogId: dialogId,
                            accessState: "removed",
                            reason: "You no longer have access to this group."
                        )
                    case "read.updated":
                        guard
                            let dialogId = update.dialogId,
                            let accountId = update.readerAccountId,
                            let maxReadMsgId = update.maxReadMsgId
                        else { continue }
                        try markRead(
                            db,
                            dialogId: dialogId,
                            accountId: accountId,
                            maxReadMsgId: maxReadMsgId,
                            exactUnreadCount: update.unreadCount
                        )
                    case "profile.updated":
                        guard
                            let subjectAccountId = update.subjectAccountId,
                            let firstName = update.firstName,
                            let lastName = update.lastName,
                            let displayName = update.displayName,
                            let bio = update.bio,
                            let colorIndex = update.colorIndex,
                            let updatedAt = update.profileUpdatedAt
                        else { continue }
                        try upsertProfile(
                            db,
                            profile: CloudProfile(
                                accountId: subjectAccountId,
                                firstName: firstName,
                                lastName: lastName,
                                displayName: displayName,
                                bio: bio,
                                birthday: update.birthday,
                                colorIndex: colorIndex,
                                updatedAt: updatedAt
                            )
                        )
                        if subjectAccountId != accountId, let sharedDialogIds = update.sharedDialogIds {
                            for dialogId in sharedDialogIds {
                                try db.execute(
                                    sql: """
                                    INSERT INTO dialogs (dialog_id, type, title, last_msg_id, updated_at)
                                    VALUES (?, 'direct', ?, 0, ?)
                                    ON CONFLICT(dialog_id) DO UPDATE SET title = excluded.title
                                    """,
                                    arguments: [dialogId, displayName, updatedAt]
                                )
                                try ensureDialogSummary(db, dialogId: dialogId)
                                try upsertMember(
                                    db, dialogId: dialogId,
                                    member: BootstrapDialogMember(accountId: accountId, role: "member", lastReadMsgId: 0)
                                )
                                try upsertMember(
                                    db, dialogId: dialogId,
                                    member: BootstrapDialogMember(accountId: subjectAccountId, role: "member", lastReadMsgId: 0)
                                )
                            }
                        } else if subjectAccountId != accountId {
                            try db.execute(
                                sql: """
                                UPDATE dialogs SET title = ?
                                WHERE type = 'direct' AND dialog_id IN (
                                  SELECT dialog_id FROM dialog_members WHERE account_id = ?
                                )
                                """,
                                arguments: [displayName, subjectAccountId]
                            )
                        }
                    default:
                        continue
                    }
                }
                for dialogId in messageDialogsToRefresh {
                    try refreshDialogSummary(db, dialogId: dialogId)
                    try refreshAllUnreadSummaries(db, dialogId: dialogId)
                }
            }
            try db.execute(
                sql: """
                INSERT INTO sync_state (account_id, pts, updated_at)
                VALUES (?, ?, datetime('now'))
                ON CONFLICT(account_id) DO UPDATE SET pts = excluded.pts, updated_at = excluded.updated_at
                """,
                arguments: [accountId, difference.state.pts]
            )
        }
    }

    func maxReadMsgId(dialogId: String, accountId: String) throws -> Int64 {
        try dbQueue.read { db in
            try Int64.fetchOne(
                db,
                sql: """
                SELECT last_read_msg_id
                FROM dialog_members
                WHERE dialog_id = ? AND account_id = ?
                """,
                arguments: [dialogId, accountId]
            ) ?? 0
        }
    }

    func maxPeerReadMsgId(dialogId: String, excluding accountId: String) throws -> Int64 {
        try dbQueue.read { db in
            try Int64.fetchOne(
                db,
                sql: """
                SELECT MAX(last_read_msg_id)
                FROM dialog_members
                WHERE dialog_id = ? AND account_id != ?
                """,
                arguments: [dialogId, accountId]
            ) ?? 0
        }
    }

    func peerAccountId(dialogId: String, excluding accountId: String) throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(
                db,
                sql: """
                SELECT account_id
                FROM dialog_members
                WHERE dialog_id = ? AND account_id != ?
                ORDER BY account_id
                LIMIT 1
                """,
                arguments: [dialogId, accountId]
            )
        }
    }

    func messages(dialogId: String) throws -> [LocalMessage] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT local_id, dialog_id, msg_id, client_msg_id, sender_account_id, kind, text,
                       reply_to_msg_id, forwarded_from_account_id, forwarded_from_dialog_id,
                       forwarded_from_msg_id, is_forwarded, media_json, edit_version, state, server_ts, local_state
                FROM messages
                WHERE dialog_id = ?
                ORDER BY COALESCE(msg_id, 9223372036854775807), rowid
                """,
                arguments: [dialogId]
            )
            return try Self.messages(from: rows, in: db, dialogId: dialogId)
        }
    }

    /// A bounded keyset read. With no cursor it returns the newest messages in ascending display
    /// order, including optimistic rows. `beforeMsgId` pages older server messages and
    /// `afterMsgId` pages newer server messages without an OFFSET scan.
    func messages(
        dialogId: String,
        limit: Int,
        beforeMsgId: Int64? = nil,
        afterMsgId: Int64? = nil
    ) throws -> [LocalMessage] {
        try dbQueue.read { db in
            try Self.fetchMessages(
                db,
                dialogId: dialogId,
                limit: limit,
                beforeMsgId: beforeMsgId,
                afterMsgId: afterMsgId
            )
        }
    }

    func messageWindow(
        dialogId: String,
        anchorMsgId: Int64,
        beforeCount: Int = 60,
        afterCount: Int = 59
    ) throws -> [LocalMessage] {
        try dbQueue.read { db in
            let before = try Self.fetchMessages(
                db,
                dialogId: dialogId,
                limit: beforeCount,
                beforeMsgId: anchorMsgId,
                afterMsgId: nil
            )
            let anchorRows = try Row.fetchAll(
                db,
                sql: Self.messageSelectionSQL + " WHERE dialog_id = ? AND msg_id = ? LIMIT 1",
                arguments: [dialogId, anchorMsgId]
            )
            let anchor = try Self.messages(from: anchorRows, in: db, dialogId: dialogId)
            let after = try Self.fetchMessages(
                db,
                dialogId: dialogId,
                limit: afterCount,
                beforeMsgId: nil,
                afterMsgId: anchorMsgId
            )
            return Array((before + anchor + after).prefix(TimelineWindow.maximumRetainedMessages))
        }
    }

    func timelineWindow(
        dialogId: String,
        anchorMsgId: Int64,
        beforeCount: Int = 60,
        afterCount: Int = 59
    ) throws -> TimelineSnapshot {
        try dbQueue.read { db in
            let before = try Self.fetchMessages(
                db,
                dialogId: dialogId,
                limit: beforeCount,
                beforeMsgId: anchorMsgId,
                afterMsgId: nil
            )
            let anchorRows = try Row.fetchAll(
                db,
                sql: Self.messageSelectionSQL + " WHERE dialog_id = ? AND msg_id = ? LIMIT 1",
                arguments: [dialogId, anchorMsgId]
            )
            let anchor = try Self.messages(from: anchorRows, in: db, dialogId: dialogId)
            let after = try Self.fetchMessages(
                db,
                dialogId: dialogId,
                limit: afterCount,
                beforeMsgId: nil,
                afterMsgId: anchorMsgId
            )
            let messages = Array(
                (before + anchor + after).prefix(TimelineWindow.maximumRetainedMessages)
            )
            return try Self.timelineSnapshot(db, dialogId: dialogId, messages: messages)
        }
    }

    func timeline(dialogId: String, window: TimelineWindow = .initial) throws -> TimelineSnapshot {
        try dbQueue.read { db in
            try Self.fetchTimeline(db, dialogId: dialogId, window: window)
        }
    }

    func conversationSnapshot(
        dialogId: String,
        window: TimelineWindow = .initial
    ) throws -> ConversationLocalSnapshot {
        try dbQueue.read { db in
            try Self.fetchConversationSnapshot(db, dialogId: dialogId, window: window)
        }
    }

    func firstUnreadMessageId(dialogId: String, accountId: String) throws -> Int64? {
        try dbQueue.read { db in
            try Self.fetchFirstUnreadMessageId(db, dialogId: dialogId, accountId: accountId)
        }
    }

    func resolveOpeningAnchor(dialogId: String, accountId: String) throws -> TimelineAnchor {
        try dbQueue.read { db in
            let lastReadMsgId = try Int64.fetchOne(
                db,
                sql: """
                SELECT last_read_msg_id FROM dialog_members
                WHERE dialog_id = ? AND account_id = ?
                """,
                arguments: [dialogId, accountId]
            ) ?? 0
            let dialogCeiling = try Int64.fetchOne(
                db,
                sql: "SELECT last_msg_id FROM dialogs WHERE dialog_id = ?",
                arguments: [dialogId]
            ) ?? 0
            let historyComplete = try Bool.fetchOne(
                db,
                sql: "SELECT history_complete FROM dialog_history_state WHERE dialog_id = ?",
                arguments: [dialogId]
            ) ?? false
            let unreadSummary = try Row.fetchOne(
                db,
                sql: """
                SELECT unread_count, is_exact FROM dialog_unread_summaries
                WHERE dialog_id = ? AND account_id = ?
                """,
                arguments: [dialogId, accountId]
            )
            let unreadIsExact: Bool = unreadSummary?["is_exact"] ?? false
            let exactUnreadCount: Int? = unreadIsExact ? unreadSummary?["unread_count"] : nil
            let localFirstUnread = try Self.fetchFirstUnreadMessageId(
                db,
                dialogId: dialogId,
                accountId: accountId
            )

            if exactUnreadCount != 0, let localFirstUnread {
                if historyComplete {
                    return .firstUnread(msgId: localFirstUnread)
                }
                if try Self.hasContiguousMessageRange(
                    db,
                    dialogId: dialogId,
                    lowerBound: lastReadMsgId + 1,
                    upperBound: localFirstUnread
                ) {
                    return .firstUnread(msgId: localFirstUnread)
                }
            }
            if exactUnreadCount.map({ $0 > 0 }) == true
                || (exactUnreadCount == nil && !historyComplete && lastReadMsgId < dialogCeiling) {
                // A sparse bootstrap can contain the candidate row itself (including an outgoing
                // row from another device) without containing every row through the first incoming
                // message. Keep it provisional until targeted forward hydration proves continuity.
                return .provisionalFirstUnread(msgId: lastReadMsgId + 1)
            }
            if let viewport = try Self.fetchViewportState(db, dialogId: dialogId, accountId: accountId) {
                if viewport.wasAtBottom { return .bottom }
                if let msgId = viewport.topVisibleMsgId,
                   let resolved = try Self.resolveVisibleSavedMessage(
                       db,
                       dialogId: dialogId,
                       targetMsgId: msgId
                   ) {
                    return .saved(msgId: resolved)
                }
            }
            return .bottom
        }
    }

    func loadViewportState(dialogId: String, accountId: String) throws -> ChatViewportState? {
        try dbQueue.read { db in
            try Self.fetchViewportState(db, dialogId: dialogId, accountId: accountId)
        }
    }

    func saveViewportState(_ state: ChatViewportState) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO chat_viewport_state (
                  dialog_id, account_id, top_visible_msg_id, was_at_bottom, updated_at
                ) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(dialog_id, account_id) DO UPDATE SET
                  top_visible_msg_id = excluded.top_visible_msg_id,
                  was_at_bottom = excluded.was_at_bottom,
                  updated_at = excluded.updated_at
                """,
                arguments: [
                    state.dialogId, state.accountId, state.topVisibleMsgId,
                    state.wasAtBottom, state.updatedAt
                ]
            )
        }
    }

    func loadHistoryState(dialogId: String) throws -> DialogHistoryState? {
        try dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM dialog_history_state WHERE dialog_id = ?",
                arguments: [dialogId]
            ).map(Self.historyState(from:))
        }
    }

    func saveHistoryState(_ state: DialogHistoryState) throws {
        try dbQueue.write { db in
            try upsertHistoryState(db, state: state)
        }
    }

    func historyStatesReady(now: Date = Date(), limit: Int = 20) throws -> [DialogHistoryState] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM dialog_history_state
                WHERE history_complete = 0 AND (next_retry_at IS NULL OR next_retry_at <= ?)
                ORDER BY updated_at, dialog_id
                LIMIT ?
                """,
                arguments: [Self.sqliteTimestamp(now), max(1, limit)]
            ).map(Self.historyState(from:))
        }
    }

    func historyStatesReady(
        dialogIds: [String],
        now: Date = Date()
    ) throws -> [DialogHistoryState] {
        let uniqueIds = Array(Set(dialogIds)).sorted().prefix(200)
        guard !uniqueIds.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: uniqueIds.count).joined(separator: ",")
        let arguments = StatementArguments(Array(uniqueIds) + [Self.sqliteTimestamp(now)])
        return try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM dialog_history_state
                WHERE dialog_id IN (\(placeholders))
                  AND history_complete = 0
                  AND (next_retry_at IS NULL OR next_retry_at <= ?)
                ORDER BY updated_at, dialog_id
                """,
                arguments: arguments
            ).map(Self.historyState(from:))
        }
    }

    func markHistoryHydrationFailed(
        dialogId: String,
        retryAfter: TimeInterval,
        now: Date = Date()
    ) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE dialog_history_state
                SET retry_count = retry_count + 1, next_retry_at = ?, updated_at = ?
                WHERE dialog_id = ?
                """,
                arguments: [
                    Self.sqliteTimestamp(now.addingTimeInterval(max(0, retryAfter))),
                    Self.sqliteTimestamp(now), dialogId
                ]
            )
        }
    }

    func loadBootstrapState(accountId: String) throws -> ReplicaBootstrapState? {
        try dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM bootstrap_state WHERE account_id = ?",
                arguments: [accountId]
            ).map(Self.bootstrapState(from:))
        }
    }

    func messageMedia(localId: String) throws -> MessageMediaRecord? {
        try dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM message_media WHERE local_id = ?",
                arguments: [localId]
            ).map(Self.messageMedia(from:))
        }
    }

    func messageMedia(mediaId: String) throws -> [MessageMediaRecord] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM message_media WHERE media_id = ? ORDER BY dialog_id, msg_id",
                arguments: [mediaId]
            ).map(Self.messageMedia(from:))
        }
    }

    func mediaChatClass(dialogId: String) throws -> MediaChatClass {
        try dbQueue.read { db in
            let type = try String.fetchOne(
                db,
                sql: "SELECT type FROM dialogs WHERE dialog_id = ?",
                arguments: [dialogId]
            )
            return type == "group" ? .group : .privateChat
        }
    }

    func mediaIds(dialogId: String) throws -> Set<String> {
        try dbQueue.read { db in
            Set(try String.fetchAll(
                db,
                sql: "SELECT DISTINCT media_id FROM message_media WHERE dialog_id = ?",
                arguments: [dialogId]
            ))
        }
    }

    func mediaIds(kind: String) throws -> Set<String> {
        try dbQueue.read { db in
            Set(try String.fetchAll(
                db,
                sql: "SELECT DISTINCT media_id FROM message_media WHERE kind = ?",
                arguments: [kind]
            ))
        }
    }

    func upsertMediaCacheEntry(_ entry: MediaCacheEntry) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO media_cache_entries (
                  media_id, variant, encrypted_path, byte_size, cached_bytes,
                  contiguous_offset, state, last_accessed_at, protected_until
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(media_id, variant) DO UPDATE SET
                  encrypted_path = excluded.encrypted_path,
                  byte_size = excluded.byte_size,
                  cached_bytes = excluded.cached_bytes,
                  contiguous_offset = excluded.contiguous_offset,
                  state = excluded.state,
                  last_accessed_at = excluded.last_accessed_at,
                  protected_until = excluded.protected_until
                """,
                arguments: [
                    entry.mediaId, entry.variant, entry.encryptedPath, entry.byteSize,
                    entry.cachedBytes, entry.contiguousOffset, entry.state,
                    entry.lastAccessedAt, entry.protectedUntil
                ]
            )
        }
    }

    func mediaCacheEntry(mediaId: String, variant: String) throws -> MediaCacheEntry? {
        try dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM media_cache_entries WHERE media_id = ? AND variant = ?",
                arguments: [mediaId, variant]
            ).map(Self.mediaCacheEntry(from:))
        }
    }

    /// Returns the durable cache ledger in least-recently-used order. Passing an eviction date
    /// filters out entries whose active-use protection has not expired.
    func mediaCacheEntries(evictableAt date: Date? = nil) throws -> [MediaCacheEntry] {
        try dbQueue.read { db in
            let rows: [Row]
            if let date {
                rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT * FROM media_cache_entries
                    WHERE protected_until IS NULL OR protected_until <= ?
                    ORDER BY last_accessed_at, media_id, variant
                    """,
                    arguments: [Self.sqliteTimestamp(date)]
                )
            } else {
                rows = try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM media_cache_entries ORDER BY last_accessed_at, media_id, variant"
                )
            }
            return rows.map(Self.mediaCacheEntry(from:))
        }
    }

    func touchMediaCacheEntry(mediaId: String, variant: String, at date: Date = Date()) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE media_cache_entries SET last_accessed_at = ?
                WHERE media_id = ? AND variant = ?
                """,
                arguments: [Self.sqliteTimestamp(date), mediaId, variant]
            )
        }
    }

    func removeMediaCacheEntry(mediaId: String, variant: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM media_cache_entries WHERE media_id = ? AND variant = ?",
                arguments: [mediaId, variant]
            )
        }
    }

    func removeMediaCacheEntries(keys: Set<MediaCacheLedgerKey>) throws {
        guard !keys.isEmpty else { return }
        try dbQueue.write { db in
            for key in keys {
                try db.execute(
                    sql: "DELETE FROM media_cache_entries WHERE media_id = ? AND variant = ?",
                    arguments: [key.mediaId, key.variant]
                )
            }
        }
    }

    func removeMediaCacheEntries(mediaIds: [String]) throws {
        guard !mediaIds.isEmpty else { return }
        try dbQueue.write { db in
            for mediaId in Set(mediaIds) {
                try db.execute(sql: "DELETE FROM media_cache_entries WHERE media_id = ?", arguments: [mediaId])
            }
        }
    }

    func downloadedMediaUsageBytes() throws -> Int64 {
        try dbQueue.read { db in
            try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(cached_bytes), 0) FROM media_cache_entries") ?? 0
        }
    }

    func upsertMediaDownloadJob(_ job: MediaDownloadJobRecord) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO media_download_jobs (
                  media_id, variant, dialog_id, priority, state, user_initiated,
                  retry_count, next_retry_at, last_error, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(media_id, variant) DO UPDATE SET
                  dialog_id = COALESCE(excluded.dialog_id, media_download_jobs.dialog_id),
                  priority = MAX(media_download_jobs.priority, excluded.priority),
                  state = excluded.state,
                  user_initiated = MAX(media_download_jobs.user_initiated, excluded.user_initiated),
                  retry_count = excluded.retry_count,
                  next_retry_at = excluded.next_retry_at,
                  last_error = excluded.last_error,
                  updated_at = excluded.updated_at
                """,
                arguments: [
                    job.mediaId, job.variant, job.dialogId, job.priority, job.state.rawValue,
                    job.userInitiated, job.retryCount, job.nextRetryAt, job.lastError, job.updatedAt
                ]
            )
        }
    }

    /// Adds or reprioritizes an automatic download without making an in-flight claim visible to a
    /// second worker. State transitions after a claim use `upsertMediaDownloadJob(_:)` instead.
    func enqueueMediaDownloadJob(_ job: MediaDownloadJobRecord) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO media_download_jobs (
                  media_id, variant, dialog_id, priority, state, user_initiated,
                  retry_count, next_retry_at, last_error, updated_at
                ) VALUES (?, ?, ?, ?, 'queued', ?, ?, ?, ?, ?)
                ON CONFLICT(media_id, variant) DO UPDATE SET
                  dialog_id = COALESCE(excluded.dialog_id, media_download_jobs.dialog_id),
                  priority = MAX(media_download_jobs.priority, excluded.priority),
                  state = CASE
                    WHEN media_download_jobs.state = 'downloading' THEN 'downloading'
                    ELSE 'queued'
                  END,
                  user_initiated = MAX(media_download_jobs.user_initiated, excluded.user_initiated),
                  retry_count = CASE
                    WHEN media_download_jobs.state = 'downloading' THEN media_download_jobs.retry_count
                    ELSE excluded.retry_count
                  END,
                  next_retry_at = CASE
                    WHEN media_download_jobs.state = 'downloading' THEN media_download_jobs.next_retry_at
                    ELSE excluded.next_retry_at
                  END,
                  last_error = CASE
                    WHEN media_download_jobs.state = 'downloading' THEN media_download_jobs.last_error
                    ELSE excluded.last_error
                  END,
                  updated_at = CASE
                    WHEN media_download_jobs.state = 'downloading' THEN media_download_jobs.updated_at
                    ELSE excluded.updated_at
                  END
                """,
                arguments: [
                    job.mediaId, job.variant, job.dialogId, job.priority,
                    job.userInitiated, job.retryCount, job.nextRetryAt, job.lastError, job.updatedAt
                ]
            )
        }
    }

    /// Claims exactly one ready job inside the writer transaction. Competing foreground and
    /// background drains therefore cannot both receive the same `(media_id, variant)` row.
    func claimNextMediaDownloadJob(
        variant: String? = nil,
        now: Date = Date()
    ) throws -> MediaDownloadJobRecord? {
        let nowText = Self.sqliteTimestamp(now)
        return try dbQueue.write { db in
            try Row.fetchOne(
                db,
                sql: """
                UPDATE media_download_jobs
                SET state = 'downloading', next_retry_at = NULL, last_error = NULL, updated_at = ?
                WHERE rowid = (
                  SELECT rowid
                  FROM media_download_jobs
                  WHERE state IN ('queued','failed')
                    AND (next_retry_at IS NULL OR next_retry_at <= ?)
                    AND (? IS NULL OR variant = ?)
                  ORDER BY user_initiated DESC, priority DESC, updated_at, media_id, variant
                  LIMIT 1
                )
                RETURNING *
                """,
                arguments: [nowText, nowText, variant, variant]
            ).map(Self.mediaDownloadJob(from:))
        }
    }

    /// A fresh process has no transfer capable of owning a persisted `.downloading` claim. Return
    /// every interrupted claim to the ready queue before workers start draining it.
    @discardableResult
    func recoverInterruptedMediaDownloadJobs(now: Date = Date()) throws -> Int {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE media_download_jobs
                SET state = 'queued', next_retry_at = NULL, last_error = 'interrupted', updated_at = ?
                WHERE state = 'downloading'
                """,
                arguments: [Self.sqliteTimestamp(now)]
            )
            return db.changesCount
        }
    }

    /// Cancels future automatic work selected by a cache-clear action. A currently claimed
    /// transfer remains protected, as do media IDs with an active playback/share/export lease.
    @discardableResult
    func cancelMediaDownloadJobs(
        mediaIds: Set<String>? = nil,
        excluding protectedMediaIds: Set<String> = []
    ) throws -> Int {
        try dbQueue.write { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT media_id, variant, state FROM media_download_jobs"
            )
            var removed = 0
            for row in rows {
                let mediaId: String = row["media_id"]
                let state: String = row["state"]
                if let mediaIds, !mediaIds.contains(mediaId) { continue }
                guard state != MediaDownloadJobState.downloading.rawValue else { continue }
                guard !protectedMediaIds.contains(mediaId) else { continue }
                let variant: String = row["variant"]
                try db.execute(
                    sql: "DELETE FROM media_download_jobs WHERE media_id = ? AND variant = ?",
                    arguments: [mediaId, variant]
                )
                removed += db.changesCount
            }
            return removed
        }
    }

    func mediaDownloadJob(mediaId: String, variant: String) throws -> MediaDownloadJobRecord? {
        try dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM media_download_jobs WHERE media_id = ? AND variant = ?",
                arguments: [mediaId, variant]
            ).map(Self.mediaDownloadJob(from:))
        }
    }

    func mediaDownloadJobsReady(now: Date = Date(), limit: Int = 20) throws -> [MediaDownloadJobRecord] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM media_download_jobs
                WHERE state IN ('queued','failed')
                  AND (next_retry_at IS NULL OR next_retry_at <= ?)
                ORDER BY user_initiated DESC, priority DESC, updated_at, media_id
                LIMIT ?
                """,
                arguments: [Self.sqliteTimestamp(now), max(1, limit)]
            ).map(Self.mediaDownloadJob(from:))
        }
    }

    func nextMediaDownloadRetryDate(now: Date = Date()) throws -> Date? {
        try dbQueue.read { db in
            guard let value = try String.fetchOne(
                db,
                sql: """
                SELECT MIN(next_retry_at)
                FROM media_download_jobs
                WHERE state IN ('queued','failed') AND next_retry_at > ?
                """,
                arguments: [Self.sqliteTimestamp(now)]
            ) else { return nil }
            return Self.makeSQLiteDateFormatter().date(from: value)
        }
    }

    func removeMediaDownloadJob(mediaId: String, variant: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM media_download_jobs WHERE media_id = ? AND variant = ?",
                arguments: [mediaId, variant]
            )
        }
    }

    func oldestServerMsgId(dialogId: String) throws -> Int64? {
        try dbQueue.read { db in
            try Int64.fetchOne(
                db,
                sql: """
                SELECT MIN(msg_id)
                FROM messages
                WHERE dialog_id = ? AND msg_id IS NOT NULL
                """,
                arguments: [dialogId]
            )
        }
    }

    func pendingOutboxReady(now: Date = Date(), limit: Int = 20) throws -> [PendingOutboxItem] {
        let nowText = Self.sqliteTimestamp(now)
        return try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT pending_outbox.client_msg_id, pending_outbox.dialog_id, pending_outbox.body,
                       pending_outbox.reply_to_msg_id, pending_outbox.forwarded_from_dialog_id,
                       pending_outbox.forwarded_from_msg_id, pending_outbox.mentions_json,
                       pending_outbox.retry_count,
                       pending_outbox.next_retry_at
                FROM pending_outbox
                LEFT JOIN dialogs ON dialogs.dialog_id = pending_outbox.dialog_id
                WHERE pending_outbox.terminal = 0
                  AND COALESCE(dialogs.access_state, 'active') <> 'pending'
                  AND (pending_outbox.next_retry_at IS NULL OR pending_outbox.next_retry_at <= ?)
                ORDER BY pending_outbox.created_at ASC, pending_outbox.client_msg_id ASC
                LIMIT ?
                """,
                arguments: [nowText, limit]
            )
            return rows.map(Self.pendingOutboxItem(from:))
        }
    }

    func pendingDestructiveLogoutItemCount() throws -> Int {
        try dbQueue.read { db in
            let pendingText = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM pending_outbox"
            ) ?? 0
            let pendingMutations = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM pending_message_mutations"
            ) ?? 0
            let pendingMedia = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM media_transfers"
            ) ?? 0
            let pendingGroups = try Int.fetchOne(
                db,
                sql: """
                SELECT
                  (SELECT COUNT(*) FROM pending_group_creations)
                  + (SELECT COUNT(*) FROM pending_group_mutations)
                """
            ) ?? 0
            return pendingText + pendingMutations + pendingMedia + pendingGroups
        }
    }

    func nextPendingOutboxDelay(now: Date = Date()) throws -> TimeInterval? {
        let nowText = Self.sqliteTimestamp(now)
        return try dbQueue.read { db in
            let dueCount = try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM pending_outbox
                LEFT JOIN dialogs ON dialogs.dialog_id = pending_outbox.dialog_id
                WHERE pending_outbox.terminal = 0
                  AND COALESCE(dialogs.access_state, 'active') <> 'pending'
                  AND (pending_outbox.next_retry_at IS NULL OR pending_outbox.next_retry_at <= ?)
                """,
                arguments: [nowText]
            ) ?? 0
            if dueCount > 0 {
                return 0
            }

            guard let next = try String.fetchOne(
                db,
                sql: """
                SELECT MIN(pending_outbox.next_retry_at)
                FROM pending_outbox
                LEFT JOIN dialogs ON dialogs.dialog_id = pending_outbox.dialog_id
                WHERE pending_outbox.terminal = 0
                  AND COALESCE(dialogs.access_state, 'active') <> 'pending'
                  AND pending_outbox.next_retry_at > ?
                """,
                arguments: [nowText]
            ), let nextDate = Self.makeSQLiteDateFormatter().date(from: next) else {
                return nil
            }
            return max(0, nextDate.timeIntervalSince(now))
        }
    }

    func dialogs(accountId: String) throws -> [LocalDialog] {
        try dbQueue.read { db in
            try Self.fetchDialogs(db, accountId: accountId)
        }
    }

    func observeDialogs(accountId: String) -> AsyncThrowingStream<[LocalDialog], Error> {
        let values = ValueObservation
            .tracking { db in try Self.fetchDialogs(db, accountId: accountId) }
            .removeDuplicates()
            .values(
                in: dbQueue,
                scheduling: .async(onQueue: .global(qos: .userInitiated)),
                bufferingPolicy: .bufferingNewest(1)
            )
        return Self.stream(values)
    }

    func observeTimeline(
        dialogId: String,
        window: TimelineWindow = .initial
    ) -> AsyncThrowingStream<TimelineSnapshot, Error> {
        let values = ValueObservation
            .tracking { db in try Self.fetchTimeline(db, dialogId: dialogId, window: window) }
            .removeDuplicates()
            .values(
                in: dbQueue,
                scheduling: .async(onQueue: .global(qos: .userInitiated)),
                bufferingPolicy: .bufferingNewest(1)
            )
        return Self.stream(values)
    }

    /// Its first element is the authoritative initial load; the same observation owns all later
    /// database-driven updates. Consumers must not issue a second initial query beside this stream.
    func observeConversation(
        dialogId: String,
        window: TimelineWindow = .initial
    ) -> AsyncThrowingStream<ConversationLocalSnapshot, Error> {
        let values = ValueObservation
            .tracking {
                try Self.fetchConversationSnapshot($0, dialogId: dialogId, window: window)
            }
            .removeDuplicates()
            .values(
                in: dbQueue,
                scheduling: .async(onQueue: .global(qos: .userInitiated)),
                bufferingPolicy: .bufferingNewest(1)
            )
        return Self.stream(values)
    }

    func latestDialogId() throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(
                db,
                sql: """
                SELECT dialog_id
                FROM dialogs
                ORDER BY updated_at DESC, dialog_id DESC
                LIMIT 1
                """
            )
        }
    }

    private static func migrate(_ dbPool: DatabasePool) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-cloud-replica") { db in
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS sync_state (
              account_id TEXT PRIMARY KEY,
              pts INTEGER NOT NULL DEFAULT 0,
              updated_at TEXT NOT NULL DEFAULT (datetime('now'))
            );

            CREATE TABLE IF NOT EXISTS dialogs (
              dialog_id TEXT PRIMARY KEY,
              type TEXT NOT NULL,
              title TEXT,
              last_msg_id INTEGER NOT NULL DEFAULT 0,
              updated_at TEXT NOT NULL DEFAULT (datetime('now'))
            );

            CREATE TABLE IF NOT EXISTS dialog_members (
              dialog_id TEXT NOT NULL,
              account_id TEXT NOT NULL,
              role TEXT NOT NULL,
              last_read_msg_id INTEGER NOT NULL DEFAULT 0,
              PRIMARY KEY (dialog_id, account_id)
            );

            CREATE TABLE IF NOT EXISTS profiles (
              account_id TEXT PRIMARY KEY,
              first_name TEXT NOT NULL,
              last_name TEXT NOT NULL,
              display_name TEXT NOT NULL,
              bio TEXT NOT NULL,
              birthday TEXT,
              color_index INTEGER NOT NULL DEFAULT 0,
              updated_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS messages (
              local_id TEXT PRIMARY KEY,
              dialog_id TEXT NOT NULL,
              msg_id INTEGER,
              client_msg_id TEXT NOT NULL UNIQUE,
              sender_account_id TEXT NOT NULL,
              kind TEXT NOT NULL,
              text TEXT NOT NULL,
              reply_to_msg_id INTEGER,
              forwarded_from_account_id TEXT,
              forwarded_from_dialog_id TEXT,
              forwarded_from_msg_id INTEGER,
              is_forwarded INTEGER NOT NULL DEFAULT 0,
              media_json TEXT,
              edit_version INTEGER NOT NULL DEFAULT 0,
              state TEXT NOT NULL,
              server_ts TEXT,
              local_state TEXT NOT NULL
            );

            CREATE UNIQUE INDEX IF NOT EXISTS messages_dialog_msg_idx
              ON messages(dialog_id, msg_id)
              WHERE msg_id IS NOT NULL;

            CREATE INDEX IF NOT EXISTS messages_dialog_order_idx
              ON messages(dialog_id, msg_id);

            CREATE TABLE IF NOT EXISTS pending_outbox (
              client_msg_id TEXT PRIMARY KEY,
              dialog_id TEXT NOT NULL,
              body TEXT NOT NULL,
              reply_to_msg_id INTEGER,
              forwarded_from_dialog_id TEXT,
              forwarded_from_msg_id INTEGER,
              retry_count INTEGER NOT NULL DEFAULT 0,
              next_retry_at TEXT,
              terminal INTEGER NOT NULL DEFAULT 0,
              created_at TEXT NOT NULL DEFAULT (datetime('now'))
            );

            CREATE TABLE IF NOT EXISTS message_reactions (
              dialog_id TEXT NOT NULL,
              msg_id INTEGER NOT NULL,
              account_id TEXT NOT NULL,
              emoji TEXT NOT NULL,
              PRIMARY KEY (dialog_id, msg_id, account_id)
            );

            CREATE TABLE IF NOT EXISTS media_transfers (
              transfer_id TEXT PRIMARY KEY,
              dialog_id TEXT NOT NULL,
              client_msg_id TEXT NOT NULL UNIQUE,
              caption TEXT NOT NULL DEFAULT '',
              reply_to_msg_id INTEGER,
              kind TEXT NOT NULL,
              content_type TEXT NOT NULL,
              file_name TEXT,
              byte_size INTEGER NOT NULL,
              sha256 TEXT NOT NULL,
              duration_ms INTEGER,
              width INTEGER,
              height INTEGER,
              encrypted_source_path TEXT NOT NULL,
              encrypted_thumbnail_path TEXT,
              media_id TEXT,
              upload_offset INTEGER NOT NULL DEFAULT 0,
              state TEXT NOT NULL CHECK (state IN ('pending','uploading','ready_to_send')),
              retry_count INTEGER NOT NULL DEFAULT 0,
              next_retry_at TEXT,
              last_error TEXT,
              terminal INTEGER NOT NULL DEFAULT 0,
              created_at TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS media_transfers_retry_idx
              ON media_transfers(state, next_retry_at, created_at);

            CREATE TABLE IF NOT EXISTS pending_message_mutations (
              client_mutation_id TEXT PRIMARY KEY,
              operation TEXT NOT NULL CHECK (operation IN ('edit','delete','reaction')),
              dialog_id TEXT NOT NULL,
              msg_id INTEGER NOT NULL,
              body TEXT,
              expected_edit_version INTEGER,
              emoji TEXT,
              retry_count INTEGER NOT NULL DEFAULT 0,
              next_retry_at TEXT,
              last_error TEXT,
              terminal INTEGER NOT NULL DEFAULT 0,
              created_at TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS pending_message_mutations_retry_idx
              ON pending_message_mutations(terminal, next_retry_at, created_at);
            """)

            let messageColumns = try db.columns(in: "messages").map(\.name)
            if !messageColumns.contains("reply_to_msg_id") {
                try db.execute(sql: "ALTER TABLE messages ADD COLUMN reply_to_msg_id INTEGER")
            }
            if !messageColumns.contains("edit_version") {
                try db.execute(sql: "ALTER TABLE messages ADD COLUMN edit_version INTEGER NOT NULL DEFAULT 0")
            }
            if !messageColumns.contains("forwarded_from_account_id") {
                try db.execute(sql: "ALTER TABLE messages ADD COLUMN forwarded_from_account_id TEXT")
            }
            if !messageColumns.contains("forwarded_from_dialog_id") {
                try db.execute(sql: "ALTER TABLE messages ADD COLUMN forwarded_from_dialog_id TEXT")
            }
            if !messageColumns.contains("forwarded_from_msg_id") {
                try db.execute(sql: "ALTER TABLE messages ADD COLUMN forwarded_from_msg_id INTEGER")
            }
            if !messageColumns.contains("is_forwarded") {
                try db.execute(sql: "ALTER TABLE messages ADD COLUMN is_forwarded INTEGER NOT NULL DEFAULT 0")
            }
            if !messageColumns.contains("media_json") {
                try db.execute(sql: "ALTER TABLE messages ADD COLUMN media_json TEXT")
            }
            let outboxColumns = try db.columns(in: "pending_outbox").map(\.name)
            if !outboxColumns.contains("reply_to_msg_id") {
                try db.execute(sql: "ALTER TABLE pending_outbox ADD COLUMN reply_to_msg_id INTEGER")
            }
            if !outboxColumns.contains("forwarded_from_dialog_id") {
                try db.execute(sql: "ALTER TABLE pending_outbox ADD COLUMN forwarded_from_dialog_id TEXT")
            }
            if !outboxColumns.contains("forwarded_from_msg_id") {
                try db.execute(sql: "ALTER TABLE pending_outbox ADD COLUMN forwarded_from_msg_id INTEGER")
            }
            if !outboxColumns.contains("terminal") {
                try db.execute(sql: "ALTER TABLE pending_outbox ADD COLUMN terminal INTEGER NOT NULL DEFAULT 0")
            }
            let mediaColumns = try db.columns(in: "media_transfers").map(\.name)
            if !mediaColumns.contains("terminal") {
                try db.execute(sql: "ALTER TABLE media_transfers ADD COLUMN terminal INTEGER NOT NULL DEFAULT 0")
            }
        }

        migrator.registerMigration("v2-local-first-windows-and-ledgers") { db in
            try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS dialogs_updated_idx
              ON dialogs(updated_at DESC, dialog_id DESC);
            CREATE INDEX IF NOT EXISTS dialog_members_account_idx
              ON dialog_members(account_id, dialog_id, last_read_msg_id);
            CREATE INDEX IF NOT EXISTS messages_dialog_visible_order_idx
              ON messages(dialog_id, state, msg_id DESC)
              WHERE msg_id IS NOT NULL;
            CREATE INDEX IF NOT EXISTS messages_dialog_sender_state_msg_idx
              ON messages(dialog_id, sender_account_id, state, msg_id)
              WHERE msg_id IS NOT NULL;
            CREATE INDEX IF NOT EXISTS message_reactions_dialog_msg_idx
              ON message_reactions(dialog_id, msg_id, account_id);
            CREATE INDEX IF NOT EXISTS pending_message_mutations_dialog_msg_idx
              ON pending_message_mutations(dialog_id, msg_id, operation);

            CREATE TABLE IF NOT EXISTS chat_viewport_state (
              dialog_id TEXT NOT NULL,
              account_id TEXT NOT NULL,
              top_visible_msg_id INTEGER,
              was_at_bottom INTEGER NOT NULL DEFAULT 1,
              updated_at TEXT NOT NULL,
              PRIMARY KEY (dialog_id, account_id)
            );

            CREATE TABLE IF NOT EXISTS dialog_history_state (
              dialog_id TEXT PRIMARY KEY,
              ceiling_msg_id INTEGER NOT NULL DEFAULT 0,
              next_before_msg_id INTEGER,
              history_complete INTEGER NOT NULL DEFAULT 0,
              retry_count INTEGER NOT NULL DEFAULT 0,
              next_retry_at TEXT,
              updated_at TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS dialog_history_ready_idx
              ON dialog_history_state(history_complete, next_retry_at, updated_at);

            CREATE TABLE IF NOT EXISTS bootstrap_state (
              account_id TEXT PRIMARY KEY,
              token TEXT,
              next_cursor TEXT,
              snapshot_pts INTEGER NOT NULL DEFAULT 0,
              status TEXT NOT NULL CHECK (status IN ('in_progress','needs_rebuild')),
              updated_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS message_media (
              local_id TEXT PRIMARY KEY,
              dialog_id TEXT NOT NULL,
              msg_id INTEGER,
              media_id TEXT NOT NULL,
              kind TEXT NOT NULL,
              content_type TEXT NOT NULL,
              file_name TEXT,
              byte_size INTEGER NOT NULL,
              duration_ms INTEGER,
              width INTEGER,
              height INTEGER,
              has_thumbnail INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS message_media_dialog_msg_idx
              ON message_media(dialog_id, msg_id);
            CREATE INDEX IF NOT EXISTS message_media_media_idx
              ON message_media(media_id);

            CREATE TABLE IF NOT EXISTS media_cache_entries (
              media_id TEXT NOT NULL,
              variant TEXT NOT NULL CHECK (variant IN ('thumbnail','full')),
              encrypted_path TEXT NOT NULL,
              byte_size INTEGER NOT NULL DEFAULT 0,
              cached_bytes INTEGER NOT NULL DEFAULT 0,
              contiguous_offset INTEGER NOT NULL DEFAULT 0,
              state TEXT NOT NULL,
              last_accessed_at TEXT NOT NULL,
              protected_until TEXT,
              PRIMARY KEY (media_id, variant)
            );
            CREATE INDEX IF NOT EXISTS media_cache_lru_idx
              ON media_cache_entries(protected_until, last_accessed_at);

            CREATE TABLE IF NOT EXISTS media_download_jobs (
              media_id TEXT NOT NULL,
              variant TEXT NOT NULL CHECK (variant IN ('thumbnail','full')),
              dialog_id TEXT,
              priority INTEGER NOT NULL DEFAULT 0,
              state TEXT NOT NULL CHECK (state IN ('queued','downloading','paused','completed','failed')),
              user_initiated INTEGER NOT NULL DEFAULT 0,
              retry_count INTEGER NOT NULL DEFAULT 0,
              next_retry_at TEXT,
              last_error TEXT,
              updated_at TEXT NOT NULL,
              PRIMARY KEY (media_id, variant)
            );
            CREATE INDEX IF NOT EXISTS media_download_ready_idx
              ON media_download_jobs(state, next_retry_at, priority DESC, updated_at);
            """)

            let mediaRows = try Row.fetchAll(
                db,
                sql: """
                SELECT local_id, dialog_id, msg_id, media_json
                FROM messages
                WHERE media_json IS NOT NULL
                """
            )
            for row in mediaRows {
                guard
                    let json: String = row["media_json"],
                    let data = json.data(using: .utf8),
                    let media = try? JSONDecoder().decode(CloudMedia.self, from: data)
                else { continue }
                try Self.upsertMessageMedia(
                    db,
                    localId: row["local_id"],
                    dialogId: row["dialog_id"],
                    msgId: row["msg_id"],
                    media: media
                )
            }

            try db.execute(
                sql: """
                INSERT INTO dialog_history_state (
                  dialog_id, ceiling_msg_id, next_before_msg_id, history_complete, updated_at
                )
                SELECT
                  d.dialog_id,
                  d.last_msg_id,
                  MIN(m.msg_id),
                  CASE WHEN MIN(m.msg_id) = 1 OR d.last_msg_id = 0 THEN 1 ELSE 0 END,
                  datetime('now')
                FROM dialogs d
                LEFT JOIN messages m ON m.dialog_id = d.dialog_id AND m.msg_id IS NOT NULL
                GROUP BY d.dialog_id
                ON CONFLICT(dialog_id) DO NOTHING
                """
            )
        }

        migrator.registerMigration("v3-denormalized-dialog-summaries") { db in
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS dialog_summaries (
              dialog_id TEXT PRIMARY KEY,
              last_local_id TEXT,
              last_msg_id INTEGER,
              last_text TEXT,
              last_kind TEXT,
              last_state TEXT,
              last_sender_account_id TEXT,
              last_local_state TEXT,
              last_server_ts TEXT
            );

            CREATE TABLE IF NOT EXISTS dialog_unread_summaries (
              dialog_id TEXT NOT NULL,
              account_id TEXT NOT NULL,
              unread_count INTEGER NOT NULL DEFAULT 0,
              PRIMARY KEY (dialog_id, account_id)
            );
            CREATE INDEX IF NOT EXISTS dialog_unread_account_idx
              ON dialog_unread_summaries(account_id, dialog_id, unread_count);

            INSERT INTO dialog_summaries (
              dialog_id, last_local_id, last_msg_id, last_text, last_kind, last_state,
              last_sender_account_id, last_local_state, last_server_ts
            )
            SELECT
              d.dialog_id, m.local_id, m.msg_id, m.text, m.kind, m.state,
              m.sender_account_id, m.local_state, m.server_ts
            FROM dialogs d
            LEFT JOIN messages m ON m.rowid = (
              SELECT candidate.rowid
              FROM messages candidate
              WHERE candidate.dialog_id = d.dialog_id
                AND candidate.state = 'visible'
                AND NOT EXISTS (
                  SELECT 1 FROM pending_message_mutations pending_delete
                  WHERE pending_delete.dialog_id = candidate.dialog_id
                    AND pending_delete.msg_id = candidate.msg_id
                    AND pending_delete.operation = 'delete'
                )
              ORDER BY COALESCE(candidate.msg_id, 9223372036854775807) DESC, candidate.rowid DESC
              LIMIT 1
            );

            INSERT INTO dialog_unread_summaries (dialog_id, account_id, unread_count)
            SELECT
              member.dialog_id,
              member.account_id,
              COUNT(message.msg_id)
            FROM dialog_members member
            LEFT JOIN messages message
              ON message.dialog_id = member.dialog_id
             AND message.msg_id IS NOT NULL
             AND message.sender_account_id != member.account_id
             AND message.state = 'visible'
             AND message.msg_id > member.last_read_msg_id
            GROUP BY member.dialog_id, member.account_id;
            """)
        }

        migrator.registerMigration("v4-atomic-bootstrap-staging") { db in
            let bootstrapColumns = try db.columns(in: "bootstrap_state").map(\.name)
            if !bootstrapColumns.contains("mode") {
                try db.execute(
                    sql: """
                    ALTER TABLE bootstrap_state
                    ADD COLUMN mode TEXT NOT NULL DEFAULT 'initial'
                      CHECK (mode IN ('initial','replacement'))
                    """
                )
                try db.execute(
                    sql: """
                    UPDATE bootstrap_state
                    SET mode = CASE WHEN EXISTS(SELECT 1 FROM dialogs LIMIT 1)
                      THEN 'replacement' ELSE 'initial' END
                    """
                )
            }

            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS bootstrap_staged_dialogs (
              account_id TEXT NOT NULL,
              dialog_id TEXT NOT NULL,
              type TEXT NOT NULL,
              title TEXT,
              last_msg_id INTEGER NOT NULL,
              updated_at TEXT NOT NULL,
              PRIMARY KEY (account_id, dialog_id)
            );

            CREATE TABLE IF NOT EXISTS bootstrap_staged_members (
              account_id TEXT NOT NULL,
              dialog_id TEXT NOT NULL,
              member_account_id TEXT NOT NULL,
              role TEXT NOT NULL,
              last_read_msg_id INTEGER NOT NULL,
              PRIMARY KEY (account_id, dialog_id, member_account_id)
            );
            CREATE INDEX IF NOT EXISTS bootstrap_staged_members_dialog_idx
              ON bootstrap_staged_members(account_id, dialog_id);

            CREATE TABLE IF NOT EXISTS bootstrap_staged_profiles (
              account_id TEXT NOT NULL,
              profile_account_id TEXT NOT NULL,
              profile_json TEXT NOT NULL,
              PRIMARY KEY (account_id, profile_account_id)
            );

            CREATE TABLE IF NOT EXISTS bootstrap_staged_messages (
              account_id TEXT NOT NULL,
              dialog_id TEXT NOT NULL,
              msg_id INTEGER NOT NULL,
              client_msg_id TEXT NOT NULL,
              message_json TEXT NOT NULL,
              PRIMARY KEY (account_id, dialog_id, msg_id),
              UNIQUE (account_id, client_msg_id)
            );
            CREATE INDEX IF NOT EXISTS bootstrap_staged_messages_dialog_idx
              ON bootstrap_staged_messages(account_id, dialog_id, msg_id);
            """)
        }

        migrator.registerMigration("v5-durable-read-receipts") { db in
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS pending_read_receipts (
              dialog_id TEXT NOT NULL,
              account_id TEXT NOT NULL,
              max_read_msg_id INTEGER NOT NULL,
              retry_count INTEGER NOT NULL DEFAULT 0,
              next_retry_at TEXT,
              last_error TEXT,
              updated_at TEXT NOT NULL,
              PRIMARY KEY (dialog_id, account_id)
            );
            CREATE INDEX IF NOT EXISTS pending_read_receipts_ready_idx
              ON pending_read_receipts(next_retry_at, updated_at);
            """)
        }

        migrator.registerMigration("v6-bootstrap-baseline-dialogs") { db in
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS bootstrap_baseline_dialogs (
              account_id TEXT NOT NULL,
              dialog_id TEXT NOT NULL,
              PRIMARY KEY (account_id, dialog_id)
            );
            """)
        }

        migrator.registerMigration("v7-replica-initialization-and-exact-unreads") { db in
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS replica_state (
              account_id TEXT PRIMARY KEY,
              initialized INTEGER NOT NULL DEFAULT 0,
              updated_at TEXT NOT NULL DEFAULT (datetime('now'))
            );

            INSERT OR IGNORE INTO replica_state (account_id, initialized, updated_at)
            SELECT account_id, 1, updated_at FROM sync_state;
            """)

            let stagedColumns = try db.columns(in: "bootstrap_staged_dialogs").map(\.name)
            if !stagedColumns.contains("unread_count") {
                try db.execute(sql: "ALTER TABLE bootstrap_staged_dialogs ADD COLUMN unread_count INTEGER")
            }

            let unreadColumns = try db.columns(in: "dialog_unread_summaries").map(\.name)
            if !unreadColumns.contains("is_exact") {
                try db.execute(
                    sql: "ALTER TABLE dialog_unread_summaries ADD COLUMN is_exact INTEGER NOT NULL DEFAULT 0"
                )
            }

            let stagedDialogColumns = try db.columns(in: "bootstrap_staged_dialogs").map(\.name)
            if !stagedDialogColumns.contains("revision") {
                try db.execute(sql: "ALTER TABLE bootstrap_staged_dialogs ADD COLUMN revision INTEGER")
            }
            if !stagedDialogColumns.contains("member_count") {
                try db.execute(sql: "ALTER TABLE bootstrap_staged_dialogs ADD COLUMN member_count INTEGER")
            }
            if !stagedDialogColumns.contains("self_role") {
                try db.execute(sql: "ALTER TABLE bootstrap_staged_dialogs ADD COLUMN self_role TEXT")
            }
            if !stagedDialogColumns.contains("notification_mode") {
                try db.execute(sql: "ALTER TABLE bootstrap_staged_dialogs ADD COLUMN notification_mode TEXT")
            }
            if !stagedDialogColumns.contains("photo_media_json") {
                try db.execute(sql: "ALTER TABLE bootstrap_staged_dialogs ADD COLUMN photo_media_json TEXT")
            }

            let stagedMemberColumns = try db.columns(in: "bootstrap_staged_members").map(\.name)
            if !stagedMemberColumns.contains("joined_at") {
                try db.execute(sql: "ALTER TABLE bootstrap_staged_members ADD COLUMN joined_at TEXT")
            }
            if !stagedMemberColumns.contains("is_active") {
                try db.execute(sql: "ALTER TABLE bootstrap_staged_members ADD COLUMN is_active INTEGER")
            }
        }

        migrator.registerMigration("v8-media-presentation-representations") { db in
            // SQLite cannot widen a CHECK constraint in place. Preserve the encrypted-cache ledger
            // while admitting the durable presentation variants introduced above the raw cache.
            try db.execute(sql: "DROP INDEX IF EXISTS media_cache_lru_idx")
            try db.execute(sql: "ALTER TABLE media_cache_entries RENAME TO media_cache_entries_v7")
            try db.execute(sql: """
            CREATE TABLE media_cache_entries (
              media_id TEXT NOT NULL,
              variant TEXT NOT NULL CHECK (
                variant IN ('thumbnail','full','bubble-720','screen-2048','video-poster')
              ),
              encrypted_path TEXT NOT NULL,
              byte_size INTEGER NOT NULL DEFAULT 0,
              cached_bytes INTEGER NOT NULL DEFAULT 0,
              contiguous_offset INTEGER NOT NULL DEFAULT 0,
              state TEXT NOT NULL,
              last_accessed_at TEXT NOT NULL,
              protected_until TEXT,
              PRIMARY KEY (media_id, variant)
            );
            INSERT INTO media_cache_entries (
              media_id, variant, encrypted_path, byte_size, cached_bytes,
              contiguous_offset, state, last_accessed_at, protected_until
            )
            SELECT media_id, variant, encrypted_path, byte_size, cached_bytes,
                   contiguous_offset, state, last_accessed_at, protected_until
            FROM media_cache_entries_v7;
            DROP TABLE media_cache_entries_v7;
            CREATE INDEX media_cache_lru_idx
              ON media_cache_entries(protected_until, last_accessed_at);
            """)
        }

        migrator.registerMigration("v9-groups") { db in
            let dialogColumns = try db.columns(in: "dialogs").map(\.name)
            if !dialogColumns.contains("revision") {
                try db.execute(sql: "ALTER TABLE dialogs ADD COLUMN revision INTEGER NOT NULL DEFAULT 0")
            }
            if !dialogColumns.contains("photo_media_json") {
                try db.execute(sql: "ALTER TABLE dialogs ADD COLUMN photo_media_json TEXT")
            }
            if !dialogColumns.contains("member_count") {
                try db.execute(sql: "ALTER TABLE dialogs ADD COLUMN member_count INTEGER NOT NULL DEFAULT 0")
            }
            if !dialogColumns.contains("self_role") {
                try db.execute(sql: "ALTER TABLE dialogs ADD COLUMN self_role TEXT")
            }
            if !dialogColumns.contains("notification_mode") {
                try db.execute(sql: "ALTER TABLE dialogs ADD COLUMN notification_mode TEXT NOT NULL DEFAULT 'all'")
            }
            if !dialogColumns.contains("access_state") {
                try db.execute(
                    sql: """
                    ALTER TABLE dialogs ADD COLUMN access_state TEXT NOT NULL DEFAULT 'active'
                      CHECK (access_state IN ('pending','active','removed','left','closed'))
                    """
                )
            }

            let memberColumns = try db.columns(in: "dialog_members").map(\.name)
            if !memberColumns.contains("joined_at") {
                try db.execute(sql: "ALTER TABLE dialog_members ADD COLUMN joined_at TEXT")
            }
            if !memberColumns.contains("left_at") {
                try db.execute(sql: "ALTER TABLE dialog_members ADD COLUMN left_at TEXT")
            }
            if !memberColumns.contains("is_active") {
                try db.execute(sql: "ALTER TABLE dialog_members ADD COLUMN is_active INTEGER NOT NULL DEFAULT 1")
            }
            if !memberColumns.contains("revision") {
                try db.execute(sql: "ALTER TABLE dialog_members ADD COLUMN revision INTEGER NOT NULL DEFAULT 0")
            }
            if !memberColumns.contains("seen_generation") {
                try db.execute(sql: "ALTER TABLE dialog_members ADD COLUMN seen_generation TEXT")
            }

            let messageColumns = try db.columns(in: "messages").map(\.name)
            if !messageColumns.contains("service_type") {
                try db.execute(sql: "ALTER TABLE messages ADD COLUMN service_type TEXT")
            }
            if !messageColumns.contains("service_data_json") {
                try db.execute(sql: "ALTER TABLE messages ADD COLUMN service_data_json TEXT")
            }
            if !messageColumns.contains("mentions_json") {
                try db.execute(sql: "ALTER TABLE messages ADD COLUMN mentions_json TEXT NOT NULL DEFAULT '[]'")
            }

            let groupOutboxColumns = try db.columns(in: "pending_outbox").map(\.name)
            if !groupOutboxColumns.contains("mentions_json") {
                try db.execute(
                    sql: "ALTER TABLE pending_outbox ADD COLUMN mentions_json TEXT NOT NULL DEFAULT '[]'"
                )
            }

            let mediaTransferColumns = try db.columns(in: "media_transfers").map(\.name)
            if !mediaTransferColumns.contains("purpose") {
                try db.execute(
                    sql: "ALTER TABLE media_transfers ADD COLUMN purpose TEXT NOT NULL DEFAULT 'message'"
                )
            }

            let unreadColumns = try db.columns(in: "dialog_unread_summaries").map(\.name)
            if !unreadColumns.contains("mention_count") {
                try db.execute(
                    sql: "ALTER TABLE dialog_unread_summaries ADD COLUMN mention_count INTEGER NOT NULL DEFAULT 0"
                )
            }

            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS pending_group_creations (
              group_id TEXT PRIMARY KEY,
              title TEXT NOT NULL,
              member_ids_json TEXT NOT NULL,
              local_photo_reference TEXT,
              state TEXT NOT NULL CHECK (state IN ('queued','creating','failed','active')),
              retry_count INTEGER NOT NULL DEFAULT 0,
              next_retry_at TEXT,
              last_error TEXT,
              terminal INTEGER NOT NULL DEFAULT 0,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS pending_group_creations_ready_idx
              ON pending_group_creations(terminal, next_retry_at, created_at);

            CREATE TABLE IF NOT EXISTS pending_group_mutations (
              client_mutation_id TEXT PRIMARY KEY,
              dialog_id TEXT NOT NULL,
              operation TEXT NOT NULL,
              payload_json TEXT NOT NULL,
              retry_count INTEGER NOT NULL DEFAULT 0,
              next_retry_at TEXT,
              last_error TEXT,
              terminal INTEGER NOT NULL DEFAULT 0,
              created_at TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS pending_group_mutations_ready_idx
              ON pending_group_mutations(terminal, next_retry_at, created_at);

            CREATE TABLE IF NOT EXISTS message_mentions (
              dialog_id TEXT NOT NULL,
              msg_id INTEGER NOT NULL,
              account_id TEXT NOT NULL,
              entity_offset INTEGER NOT NULL,
              length INTEGER NOT NULL,
              PRIMARY KEY (dialog_id, msg_id, account_id)
            );
            CREATE INDEX IF NOT EXISTS message_mentions_account_idx
              ON message_mentions(account_id, dialog_id, msg_id);

            CREATE TABLE IF NOT EXISTS group_member_hydration (
              dialog_id TEXT PRIMARY KEY,
              scan_generation TEXT NOT NULL,
              scan_revision INTEGER NOT NULL,
              cursor TEXT,
              completed INTEGER NOT NULL DEFAULT 0,
              attempts INTEGER NOT NULL DEFAULT 0,
              updated_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS pending_purges (
              id TEXT PRIMARY KEY,
              dialog_id TEXT NOT NULL,
              kind TEXT NOT NULL CHECK (kind IN ('messages','media')),
              payload TEXT,
              created_at TEXT NOT NULL,
              attempts INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS pending_purges_dialog_idx
              ON pending_purges(dialog_id, created_at);
            """)
        }

        migrator.registerMigration("v10-dialog-preferences") { db in
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS dialog_preferences (
              account_id TEXT NOT NULL,
              dialog_id TEXT NOT NULL REFERENCES dialogs(dialog_id) ON DELETE CASCADE,
              is_pinned INTEGER NOT NULL DEFAULT 0 CHECK (is_pinned IN (0, 1)),
              pinned_at TEXT,
              is_muted INTEGER NOT NULL DEFAULT 0 CHECK (is_muted IN (0, 1)),
              is_archived INTEGER NOT NULL DEFAULT 0 CHECK (is_archived IN (0, 1)),
              server_updated_at TEXT NOT NULL,
              PRIMARY KEY (account_id, dialog_id)
            );
            CREATE INDEX IF NOT EXISTS dialog_preferences_account_idx
              ON dialog_preferences(account_id, dialog_id);

            CREATE TABLE IF NOT EXISTS pending_dialog_preference_mutations (
              account_id TEXT NOT NULL,
              dialog_id TEXT NOT NULL REFERENCES dialogs(dialog_id) ON DELETE CASCADE,
              field TEXT NOT NULL CHECK (field IN ('pinned','muted','archived')),
              desired_value INTEGER NOT NULL CHECK (desired_value IN (0, 1)),
              desired_at TEXT NOT NULL,
              client_mutation_id TEXT NOT NULL,
              acknowledged_pts INTEGER,
              retry_count INTEGER NOT NULL DEFAULT 0,
              next_retry_at TEXT,
              last_error TEXT,
              terminal INTEGER NOT NULL DEFAULT 0,
              PRIMARY KEY (account_id, dialog_id, field),
              UNIQUE (account_id, client_mutation_id)
            );
            CREATE INDEX IF NOT EXISTS pending_dialog_preferences_ready_idx
              ON pending_dialog_preference_mutations(
                terminal, acknowledged_pts, next_retry_at, desired_at
              );

            INSERT INTO dialog_preferences (
              account_id, dialog_id, is_pinned, pinned_at,
              is_muted, is_archived, server_updated_at
            )
            SELECT
              sync.account_id, dialog.dialog_id, 0, NULL,
              dialog.notification_mode = 'muted', 0, dialog.updated_at
            FROM dialogs dialog
            CROSS JOIN sync_state sync
            WHERE 1
            ON CONFLICT(account_id, dialog_id) DO NOTHING;

            INSERT INTO pending_dialog_preference_mutations (
              account_id, dialog_id, field, desired_value, desired_at,
              client_mutation_id, retry_count, next_retry_at, last_error, terminal
            )
            SELECT
              sync.account_id,
              pending.dialog_id,
              'muted',
              CASE json_extract(pending.payload_json, '$.mode')
                WHEN 'muted' THEN 1 ELSE 0
              END,
              pending.created_at,
              pending.client_mutation_id,
              pending.retry_count,
              pending.next_retry_at,
              pending.last_error,
              pending.terminal
            FROM pending_group_mutations pending
            CROSS JOIN sync_state sync
            WHERE pending.operation = 'notifications'
            ON CONFLICT(account_id, dialog_id, field) DO UPDATE SET
              desired_value = excluded.desired_value,
              desired_at = excluded.desired_at,
              client_mutation_id = excluded.client_mutation_id,
              acknowledged_pts = NULL,
              retry_count = excluded.retry_count,
              next_retry_at = excluded.next_retry_at,
              last_error = excluded.last_error,
              terminal = excluded.terminal;

            DELETE FROM pending_group_mutations
            WHERE operation = 'notifications'
              AND EXISTS(SELECT 1 FROM sync_state);
            """)

            let stagedColumns = try db.columns(in: "bootstrap_staged_dialogs").map(\.name)
            if !stagedColumns.contains("preference_is_pinned") {
                try db.execute(
                    sql: "ALTER TABLE bootstrap_staged_dialogs ADD COLUMN preference_is_pinned INTEGER"
                )
            }
            if !stagedColumns.contains("preference_pinned_at") {
                try db.execute(
                    sql: "ALTER TABLE bootstrap_staged_dialogs ADD COLUMN preference_pinned_at TEXT"
                )
            }
            if !stagedColumns.contains("preference_is_muted") {
                try db.execute(
                    sql: "ALTER TABLE bootstrap_staged_dialogs ADD COLUMN preference_is_muted INTEGER"
                )
            }
            if !stagedColumns.contains("preference_is_archived") {
                try db.execute(
                    sql: "ALTER TABLE bootstrap_staged_dialogs ADD COLUMN preference_is_archived INTEGER"
                )
            }
            if !stagedColumns.contains("preference_updated_at") {
                try db.execute(
                    sql: "ALTER TABLE bootstrap_staged_dialogs ADD COLUMN preference_updated_at TEXT"
                )
            }
        }

        try migrator.migrate(dbPool)
    }

    nonisolated private static let messageSelectionSQL = """
    SELECT local_id, dialog_id, msg_id, client_msg_id, sender_account_id, kind, text,
           reply_to_msg_id, forwarded_from_account_id, forwarded_from_dialog_id,
           forwarded_from_msg_id, is_forwarded, mentions_json,
           media_json, service_type, service_data_json,
           edit_version, state,
           server_ts, local_state,
           (SELECT display_name FROM profiles WHERE account_id = messages.sender_account_id)
             AS sender_display_name,
           rowid AS storage_rowid
    FROM messages
    """

    nonisolated private static func fetchMessages(
        _ db: Database,
        dialogId: String,
        limit: Int,
        beforeMsgId: Int64?,
        afterMsgId: Int64?
    ) throws -> [LocalMessage] {
        guard limit > 0 else { return [] }
        let boundedLimit = min(limit, TimelineWindow.maximumRetainedMessages)
        let rows: [Row]
        switch (beforeMsgId, afterMsgId) {
        case let (before?, after?):
            rows = try Row.fetchAll(
                db,
                sql: messageSelectionSQL + """
                 WHERE dialog_id = ? AND msg_id < ? AND msg_id > ?
                 ORDER BY msg_id ASC, storage_rowid ASC
                 LIMIT ?
                """,
                arguments: [dialogId, before, after, boundedLimit]
            )
        case let (before?, nil):
            rows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM (
                  \(messageSelectionSQL)
                  WHERE dialog_id = ? AND msg_id < ?
                  ORDER BY msg_id DESC, storage_rowid DESC
                  LIMIT ?
                ) ORDER BY msg_id ASC, storage_rowid ASC
                """,
                arguments: [dialogId, before, boundedLimit]
            )
        case let (nil, after?):
            rows = try Row.fetchAll(
                db,
                sql: messageSelectionSQL + """
                 WHERE dialog_id = ? AND msg_id > ?
                 ORDER BY msg_id ASC, storage_rowid ASC
                 LIMIT ?
                """,
                arguments: [dialogId, after, boundedLimit]
            )
        case (nil, nil):
            // Keep optimistic rows at the end without wrapping the indexed server ordering in
            // COALESCE. COALESCE forced SQLite to sort the whole conversation before LIMIT,
            // turning every online observation into a visible hitch on large chats.
            let pendingRows = try Row.fetchAll(
                db,
                sql: messageSelectionSQL + """
                 WHERE dialog_id = ? AND msg_id IS NULL
                 ORDER BY storage_rowid ASC
                 LIMIT ?
                """,
                arguments: [dialogId, boundedLimit]
            )
            let serverLimit = max(0, boundedLimit - pendingRows.count)
            let serverRows: [Row]
            if serverLimit > 0 {
                serverRows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT * FROM (
                      \(messageSelectionSQL)
                      WHERE dialog_id = ? AND msg_id IS NOT NULL
                      ORDER BY msg_id DESC
                      LIMIT ?
                    ) ORDER BY msg_id ASC
                    """,
                    arguments: [dialogId, serverLimit]
                )
            } else {
                serverRows = []
            }
            rows = serverRows + pendingRows
        }
        return try messages(from: rows, in: db, dialogId: dialogId)
    }

    nonisolated private static func messages(
        from rows: [Row],
        in db: Database,
        dialogId: String
    ) throws -> [LocalMessage] {
        let serverIds: [Int64] = rows.compactMap { $0["msg_id"] }
        var reactionsByMessage: [Int64: [CloudReaction]] = [:]
        if let minimum = serverIds.min(), let maximum = serverIds.max() {
            let reactionRows = try Row.fetchAll(
                db,
                sql: """
                SELECT msg_id, account_id, emoji
                FROM message_reactions
                WHERE dialog_id = ? AND msg_id BETWEEN ? AND ?
                ORDER BY msg_id, account_id
                """,
                arguments: [dialogId, minimum, maximum]
            )
            for row in reactionRows {
                let msgId: Int64 = row["msg_id"]
                reactionsByMessage[msgId, default: []].append(
                    CloudReaction(accountId: row["account_id"], emoji: row["emoji"])
                )
            }
        }
        return rows.map { row in
            let msgId: Int64? = row["msg_id"]
            return message(from: row, reactions: msgId.flatMap { reactionsByMessage[$0] } ?? [])
        }
    }

    nonisolated private static func fetchTimeline(
        _ db: Database,
        dialogId: String,
        window: TimelineWindow
    ) throws -> TimelineSnapshot {
        let messages = try fetchMessages(
            db,
            dialogId: dialogId,
            limit: window.limit,
            beforeMsgId: window.beforeMsgId,
            afterMsgId: window.afterMsgId
        )
        return try timelineSnapshot(db, dialogId: dialogId, messages: messages)
    }

    nonisolated private static func fetchConversationSnapshot(
        _ db: Database,
        dialogId: String,
        window: TimelineWindow
    ) throws -> ConversationLocalSnapshot {
        let timeline = try fetchTimeline(db, dialogId: dialogId, window: window)
        let mutations = try Row.fetchAll(
            db,
            sql: """
            SELECT * FROM pending_message_mutations
            WHERE dialog_id = ?
            ORDER BY created_at, client_mutation_id
            """,
            arguments: [dialogId]
        ).map(Self.messageMutation(from:))
        let transfers = try Row.fetchAll(
            db,
            sql: """
            SELECT * FROM media_transfers
            WHERE dialog_id = ?
            ORDER BY created_at, transfer_id
            """,
            arguments: [dialogId]
        ).map(Self.mediaTransfer(from:))
        let accountId = try String.fetchOne(
            db,
            sql: "SELECT account_id FROM sync_state ORDER BY updated_at DESC LIMIT 1"
        )
        let peerReadMsgId: Int64
        if let accountId {
            peerReadMsgId = try Int64.fetchOne(
                db,
                sql: """
                SELECT MAX(last_read_msg_id)
                FROM dialog_members
                WHERE dialog_id = ? AND account_id != ?
                """,
                arguments: [dialogId, accountId]
            ) ?? 0
        } else {
            peerReadMsgId = 0
        }
        let historyState = try Row.fetchOne(
            db,
            sql: "SELECT * FROM dialog_history_state WHERE dialog_id = ?",
            arguments: [dialogId]
        ).map(Self.historyState(from:))
        return ConversationLocalSnapshot(
            timeline: timeline,
            mutations: mutations,
            transfers: transfers,
            peerReadMsgId: peerReadMsgId,
            historyState: historyState
        )
    }

    nonisolated private static func timelineSnapshot(
        _ db: Database,
        dialogId: String,
        messages: [LocalMessage]
    ) throws -> TimelineSnapshot {
        let ids = messages.compactMap(\.msgId)
        let oldest = ids.min()
        let newest = ids.max()
        let hasEarlier: Bool
        if let oldest {
            hasEarlier = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM messages WHERE dialog_id = ? AND msg_id < ?)",
                arguments: [dialogId, oldest]
            ) ?? false
        } else {
            hasEarlier = false
        }
        let hasLaterServerMessage: Bool
        if let newest {
            hasLaterServerMessage = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM messages WHERE dialog_id = ? AND msg_id > ?)",
                arguments: [dialogId, newest]
            ) ?? false
        } else {
            hasLaterServerMessage = false
        }
        let includesOptimisticRows = messages.contains { $0.msgId == nil }
        let hasLaterOptimisticMessage: Bool
        if includesOptimisticRows {
            hasLaterOptimisticMessage = false
        } else {
            hasLaterOptimisticMessage = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM messages WHERE dialog_id = ? AND msg_id IS NULL)",
                arguments: [dialogId]
            ) ?? false
        }
        return TimelineSnapshot(
            messages: messages,
            oldestServerMsgId: oldest,
            newestServerMsgId: newest,
            hasEarlierLocalMessages: hasEarlier,
            hasLaterLocalMessages: hasLaterServerMessage || hasLaterOptimisticMessage
        )
    }

    nonisolated private static func hasContiguousMessageRange(
        _ db: Database,
        dialogId: String,
        lowerBound: Int64,
        upperBound: Int64
    ) throws -> Bool {
        guard lowerBound <= upperBound else { return false }
        let expectedCount = upperBound - lowerBound + 1
        let cachedCount = try Int64.fetchOne(
            db,
            sql: """
            SELECT COUNT(DISTINCT msg_id)
            FROM messages
            WHERE dialog_id = ? AND msg_id BETWEEN ? AND ?
            """,
            arguments: [dialogId, lowerBound, upperBound]
        ) ?? 0
        return cachedCount == expectedCount
    }

    /// Resolve a deleted/expired semantic anchor predictably: first the next visible server row,
    /// then the previous visible row. This remains stable as media/local-only rows are rewritten.
    nonisolated private static func resolveVisibleSavedMessage(
        _ db: Database,
        dialogId: String,
        targetMsgId: Int64
    ) throws -> Int64? {
        if let next = try Int64.fetchOne(
            db,
            sql: """
            SELECT msg_id FROM messages
            WHERE dialog_id = ? AND msg_id >= ? AND state = 'visible'
            ORDER BY msg_id ASC LIMIT 1
            """,
            arguments: [dialogId, targetMsgId]
        ) {
            return next
        }
        return try Int64.fetchOne(
            db,
            sql: """
            SELECT msg_id FROM messages
            WHERE dialog_id = ? AND msg_id < ? AND state = 'visible'
            ORDER BY msg_id DESC LIMIT 1
            """,
            arguments: [dialogId, targetMsgId]
        )
    }

    nonisolated private static func fetchFirstUnreadMessageId(
        _ db: Database,
        dialogId: String,
        accountId: String
    ) throws -> Int64? {
        try Int64.fetchOne(
            db,
            sql: """
            SELECT MIN(message.msg_id)
            FROM messages message
            WHERE message.dialog_id = ?
              AND message.msg_id IS NOT NULL
              AND message.sender_account_id != ?
              AND message.state = 'visible'
              AND message.msg_id > COALESCE((
                SELECT member.last_read_msg_id
                FROM dialog_members member
                WHERE member.dialog_id = ? AND member.account_id = ?
              ), 0)
            """,
            arguments: [dialogId, accountId, dialogId, accountId]
        )
    }

    nonisolated private static func fetchViewportState(
        _ db: Database,
        dialogId: String,
        accountId: String
    ) throws -> ChatViewportState? {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT * FROM chat_viewport_state WHERE dialog_id = ? AND account_id = ?",
            arguments: [dialogId, accountId]
        ) else { return nil }
        return ChatViewportState(
            dialogId: row["dialog_id"],
            accountId: row["account_id"],
            topVisibleMsgId: row["top_visible_msg_id"],
            wasAtBottom: row["was_at_bottom"],
            updatedAt: row["updated_at"]
        )
    }

    nonisolated private static func fetchDialogs(_ db: Database, accountId: String) throws -> [LocalDialog] {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT
              d.dialog_id,
              d.type,
              d.title,
              d.photo_media_json,
              d.last_msg_id,
              d.updated_at,
              d.revision,
              d.member_count,
              d.self_role,
              d.notification_mode,
              d.access_state,
              COALESCE(pending_pin.desired_value, preference.is_pinned, 0) AS is_pinned,
              CASE
                WHEN pending_pin.client_mutation_id IS NOT NULL
                  THEN CASE WHEN pending_pin.desired_value = 1 THEN pending_pin.desired_at ELSE NULL END
                ELSE preference.pinned_at
              END AS pinned_at,
              COALESCE(pending_mute.desired_value, preference.is_muted, 0) AS is_muted,
              COALESCE(pending_archive.desired_value, preference.is_archived, 0) AS is_archived,
              peer.account_id AS peer_account_id,
              profile.bio AS peer_bio,
              profile.birthday AS peer_birthday,
              profile.color_index AS peer_color_index,
              summary.last_text,
              summary.last_kind,
              summary.last_state,
              summary.last_sender_account_id,
              summary.last_local_state,
              summary.last_server_ts,
              COALESCE(unread.unread_count, 0) AS unread_count,
              COALESCE(unread.mention_count, 0) AS mention_count
            FROM dialogs d
            LEFT JOIN dialog_members peer ON peer.dialog_id = d.dialog_id
              AND peer.account_id != ? AND d.type = 'direct'
            LEFT JOIN profiles profile ON profile.account_id = peer.account_id
            LEFT JOIN dialog_summaries summary ON summary.dialog_id = d.dialog_id
            LEFT JOIN dialog_unread_summaries unread
              ON unread.dialog_id = d.dialog_id AND unread.account_id = ?
            LEFT JOIN dialog_preferences preference
              ON preference.dialog_id = d.dialog_id AND preference.account_id = ?
            LEFT JOIN pending_dialog_preference_mutations pending_pin
              ON pending_pin.dialog_id = d.dialog_id
             AND pending_pin.account_id = ?
             AND pending_pin.field = 'pinned'
             AND pending_pin.terminal = 0
            LEFT JOIN pending_dialog_preference_mutations pending_mute
              ON pending_mute.dialog_id = d.dialog_id
             AND pending_mute.account_id = ?
             AND pending_mute.field = 'muted'
             AND pending_mute.terminal = 0
            LEFT JOIN pending_dialog_preference_mutations pending_archive
              ON pending_archive.dialog_id = d.dialog_id
             AND pending_archive.account_id = ?
             AND pending_archive.field = 'archived'
             AND pending_archive.terminal = 0
            WHERE d.access_state IN ('pending','active')
            ORDER BY
              is_pinned DESC,
              pinned_at DESC,
              d.updated_at DESC,
              d.dialog_id DESC
            """,
            arguments: [
                accountId, accountId,
                accountId, accountId, accountId, accountId,
            ]
        )
        return rows.map(dialog(from:))
    }

    nonisolated private static func stream<Element: Sendable>(
        _ values: AsyncValueObservation<Element>
    ) -> AsyncThrowingStream<Element, Error> {
        let box = AsyncObservationBox(values)
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                do {
                    for try await value in box.values {
                        if case .terminated = continuation.yield(value) { break }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    private func clearBootstrapStaging(_ db: Database, accountId: String) throws {
        try db.execute(
            sql: "DELETE FROM bootstrap_baseline_dialogs WHERE account_id = ?",
            arguments: [accountId]
        )
        try db.execute(
            sql: "DELETE FROM bootstrap_staged_messages WHERE account_id = ?",
            arguments: [accountId]
        )
        try db.execute(
            sql: "DELETE FROM bootstrap_staged_members WHERE account_id = ?",
            arguments: [accountId]
        )
        try db.execute(
            sql: "DELETE FROM bootstrap_staged_profiles WHERE account_id = ?",
            arguments: [accountId]
        )
        try db.execute(
            sql: "DELETE FROM bootstrap_staged_dialogs WHERE account_id = ?",
            arguments: [accountId]
        )
    }

    private func stageBootstrapPage(
        _ db: Database,
        accountId: String,
        page: BootstrapDialogsPage
    ) throws {
        let encoder = JSONEncoder()
        for dialog in page.dialogs {
            let photoJSON = dialog.photo
                .flatMap { try? encoder.encode($0) }
                .flatMap { String(data: $0, encoding: .utf8) }
            try db.execute(
                sql: """
                INSERT INTO bootstrap_staged_dialogs (
                  account_id, dialog_id, type, title, last_msg_id, updated_at, unread_count,
                  revision, member_count, self_role, notification_mode, photo_media_json,
                  preference_is_pinned, preference_pinned_at, preference_is_muted,
                  preference_is_archived, preference_updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(account_id, dialog_id) DO UPDATE SET
                  type = excluded.type,
                  title = excluded.title,
                  last_msg_id = excluded.last_msg_id,
                  updated_at = excluded.updated_at,
                  unread_count = excluded.unread_count,
                  revision = excluded.revision,
                  member_count = excluded.member_count,
                  self_role = excluded.self_role,
                  notification_mode = excluded.notification_mode,
                  photo_media_json = excluded.photo_media_json,
                  preference_is_pinned = excluded.preference_is_pinned,
                  preference_pinned_at = excluded.preference_pinned_at,
                  preference_is_muted = excluded.preference_is_muted,
                  preference_is_archived = excluded.preference_is_archived,
                  preference_updated_at = excluded.preference_updated_at
                """,
                arguments: [
                    accountId, dialog.dialogId, dialog.type, dialog.title,
                    dialog.lastMsgId, dialog.updatedAt, dialog.unreadCount,
                    dialog.revision, dialog.memberCount, dialog.selfRole,
                    dialog.notificationMode, photoJSON,
                    dialog.preferences?.pinned ?? false,
                    dialog.preferences?.pinnedAt,
                    dialog.preferences?.muted ?? (dialog.notificationMode == "muted"),
                    dialog.preferences?.archived ?? false,
                    dialog.preferences?.updatedAt ?? dialog.updatedAt,
                ]
            )
            try db.execute(
                sql: "DELETE FROM bootstrap_staged_members WHERE account_id = ? AND dialog_id = ?",
                arguments: [accountId, dialog.dialogId]
            )
            try db.execute(
                sql: "DELETE FROM bootstrap_staged_messages WHERE account_id = ? AND dialog_id = ?",
                arguments: [accountId, dialog.dialogId]
            )
            for member in dialog.members {
                try db.execute(
                    sql: """
                    INSERT INTO bootstrap_staged_members (
                      account_id, dialog_id, member_account_id, role, last_read_msg_id,
                      joined_at, is_active
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        accountId, dialog.dialogId, member.accountId,
                        member.role, member.lastReadMsgId, member.joinedAt, member.isActive
                    ]
                )
            }
            for profile in dialog.profiles ?? [] {
                let data = try encoder.encode(profile)
                guard let json = String(data: data, encoding: .utf8) else {
                    throw CloudLocalStoreBootstrapError.invalidStagedMessage
                }
                try db.execute(
                    sql: """
                    INSERT INTO bootstrap_staged_profiles (
                      account_id, profile_account_id, profile_json
                    ) VALUES (?, ?, ?)
                    ON CONFLICT(account_id, profile_account_id) DO UPDATE SET
                      profile_json = excluded.profile_json
                    """,
                    arguments: [accountId, profile.accountId, json]
                )
            }
            for message in dialog.messages {
                guard message.dialogId == dialog.dialogId else {
                    throw CloudLocalStoreBootstrapError.invalidStagedMessage
                }
                let data = try encoder.encode(message)
                guard let json = String(data: data, encoding: .utf8) else {
                    throw CloudLocalStoreBootstrapError.invalidStagedMessage
                }
                try db.execute(
                    sql: """
                    DELETE FROM bootstrap_staged_messages
                    WHERE account_id = ? AND client_msg_id = ?
                      AND (dialog_id != ? OR msg_id != ?)
                    """,
                    arguments: [accountId, message.clientMsgId, message.dialogId, message.msgId]
                )
                try db.execute(
                    sql: """
                    INSERT INTO bootstrap_staged_messages (
                      account_id, dialog_id, msg_id, client_msg_id, message_json
                    ) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(account_id, dialog_id, msg_id) DO UPDATE SET
                      client_msg_id = excluded.client_msg_id,
                      message_json = excluded.message_json
                    """,
                    arguments: [accountId, message.dialogId, message.msgId, message.clientMsgId, json]
                )
            }
        }
    }

    private func loadStagedBootstrapSnapshot(
        _ db: Database,
        accountId: String
    ) throws -> StagedBootstrapSnapshot {
        let decoder = JSONDecoder()
        let memberRows = try Row.fetchAll(
            db,
            sql: """
            SELECT dialog_id, member_account_id, role, last_read_msg_id, joined_at, is_active
            FROM bootstrap_staged_members
            WHERE account_id = ?
            ORDER BY dialog_id, member_account_id
            """,
            arguments: [accountId]
        )
        var membersByDialog: [String: [BootstrapDialogMember]] = [:]
        for row in memberRows {
            let dialogId: String = row["dialog_id"]
            membersByDialog[dialogId, default: []].append(
                BootstrapDialogMember(
                    accountId: row["member_account_id"],
                    role: row["role"],
                    lastReadMsgId: row["last_read_msg_id"],
                    joinedAt: row["joined_at"],
                    isActive: row["is_active"]
                )
            )
        }

        let messageRows = try Row.fetchAll(
            db,
            sql: """
            SELECT dialog_id, message_json
            FROM bootstrap_staged_messages
            WHERE account_id = ?
            ORDER BY dialog_id, msg_id
            """,
            arguments: [accountId]
        )
        var messagesByDialog: [String: [CloudMessage]] = [:]
        for row in messageRows {
            let dialogId: String = row["dialog_id"]
            let json: String = row["message_json"]
            guard
                let data = json.data(using: .utf8),
                let message = try? decoder.decode(CloudMessage.self, from: data)
            else {
                throw CloudLocalStoreBootstrapError.invalidStagedMessage
            }
            messagesByDialog[dialogId, default: []].append(message)
        }

        let profileRows = try Row.fetchAll(
            db,
            sql: "SELECT profile_json FROM bootstrap_staged_profiles WHERE account_id = ?",
            arguments: [accountId]
        )
        let profiles = try profileRows.map { row -> CloudProfile in
            let json: String = row["profile_json"]
            guard
                let data = json.data(using: .utf8),
                let profile = try? decoder.decode(CloudProfile.self, from: data)
            else {
                throw CloudLocalStoreBootstrapError.invalidStagedMessage
            }
            return profile
        }

        let dialogRows = try Row.fetchAll(
            db,
            sql: """
            SELECT dialog_id, type, title, last_msg_id, updated_at, unread_count,
                   revision, member_count, self_role, notification_mode, photo_media_json,
                   preference_is_pinned, preference_pinned_at, preference_is_muted,
                   preference_is_archived, preference_updated_at
            FROM bootstrap_staged_dialogs
            WHERE account_id = ?
            ORDER BY updated_at DESC, dialog_id DESC
            """,
            arguments: [accountId]
        )
        let dialogs = dialogRows.map { row in
            let dialogId: String = row["dialog_id"]
            let photo = (row["photo_media_json"] as String?)
                .flatMap { $0.data(using: .utf8) }
                .flatMap { try? decoder.decode(CloudMedia.self, from: $0) }
            return BootstrapDialog(
                dialogId: dialogId,
                type: row["type"],
                title: row["title"],
                lastMsgId: row["last_msg_id"],
                updatedAt: row["updated_at"],
                unreadCount: row["unread_count"],
                revision: row["revision"],
                memberCount: row["member_count"],
                selfRole: row["self_role"],
                notificationMode: row["notification_mode"],
                preferences: CloudDialogPreferences(
                    dialogId: dialogId,
                    pinned: (row["preference_is_pinned"] as Int? ?? 0) != 0,
                    pinnedAt: row["preference_pinned_at"],
                    muted: (row["preference_is_muted"] as Int? ?? 0) != 0,
                    archived: (row["preference_is_archived"] as Int? ?? 0) != 0,
                    updatedAt: row["preference_updated_at"] ?? row["updated_at"]
                ),
                photo: photo,
                members: membersByDialog[dialogId] ?? [],
                messages: messagesByDialog[dialogId] ?? []
            )
        }
        return StagedBootstrapSnapshot(dialogs: dialogs, profiles: profiles)
    }

    private func mergeBootstrapDialog(
        _ db: Database,
        accountId: String,
        dialog: BootstrapDialog,
        pruneSnapshotWindow: Bool
    ) throws {
        let existingReadRows = try Row.fetchAll(
            db,
            sql: "SELECT account_id, last_read_msg_id FROM dialog_members WHERE dialog_id = ?",
            arguments: [dialog.dialogId]
        )
        let existingReads = Dictionary(uniqueKeysWithValues: existingReadRows.map { row in
            (row["account_id"] as String, row["last_read_msg_id"] as Int64)
        })

        try db.execute(
            sql: """
            INSERT INTO dialogs (
              dialog_id, type, title, last_msg_id, updated_at, revision, photo_media_json,
              member_count, self_role, notification_mode, access_state
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, COALESCE(?, 'all'), 'active')
            ON CONFLICT(dialog_id) DO UPDATE SET
              type = excluded.type,
              title = excluded.title,
              revision = CASE
                WHEN excluded.revision >= dialogs.revision THEN excluded.revision
                ELSE dialogs.revision
              END,
              photo_media_json = CASE
                WHEN excluded.revision >= dialogs.revision THEN excluded.photo_media_json
                ELSE dialogs.photo_media_json
              END,
              member_count = CASE
                WHEN excluded.revision >= dialogs.revision THEN excluded.member_count
                ELSE dialogs.member_count
              END,
              self_role = COALESCE(excluded.self_role, dialogs.self_role),
              notification_mode = COALESCE(excluded.notification_mode, dialogs.notification_mode),
              access_state = 'active',
              last_msg_id = MAX(
                excluded.last_msg_id,
                COALESCE((SELECT MAX(msg_id) FROM messages WHERE dialog_id = ?), 0)
              ),
              updated_at = MAX(dialogs.updated_at, excluded.updated_at)
            """,
            arguments: [
                dialog.dialogId, dialog.type, dialog.title,
                dialog.lastMsgId, dialog.updatedAt, dialog.revision ?? 0,
                dialog.photo.flatMap { try? JSONEncoder().encode($0) }
                    .flatMap { String(data: $0, encoding: .utf8) },
                dialog.memberCount ?? dialog.members.count,
                dialog.selfRole,
                dialog.notificationMode,
                dialog.dialogId,
            ]
        )
        try ensureDialogSummary(db, dialogId: dialog.dialogId)
        try upsertDialogPreferences(
            db,
            preferences: dialog.preferences ?? CloudDialogPreferences(
                dialogId: dialog.dialogId,
                pinned: false,
                pinnedAt: nil,
                muted: dialog.notificationMode == "muted",
                archived: false,
                updatedAt: dialog.updatedAt
            ),
            accountId: accountId,
            clientMutationId: nil
        )

        if pruneSnapshotWindow {
            try pruneSnapshotMessageWindow(db, dialog: dialog)
        }

        try db.execute(
            sql: "DELETE FROM dialog_unread_summaries WHERE dialog_id = ?",
            arguments: [dialog.dialogId]
        )
        try db.execute(
            sql: "DELETE FROM dialog_members WHERE dialog_id = ?",
            arguments: [dialog.dialogId]
        )
        for member in dialog.members {
            try db.execute(
                sql: """
                INSERT INTO dialog_members (
                  dialog_id, account_id, role, last_read_msg_id, joined_at, is_active, revision
                )
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    dialog.dialogId, member.accountId, member.role,
                    max(member.lastReadMsgId, existingReads[member.accountId] ?? 0),
                    member.joinedAt,
                    member.isActive ?? true,
                    dialog.revision ?? 0,
                ]
            )
        }

        for message in dialog.messages {
            let existingVersion = try Int.fetchOne(
                db,
                sql: "SELECT edit_version FROM messages WHERE dialog_id = ? AND msg_id = ?",
                arguments: [dialog.dialogId, message.msgId]
            )
            if let existingVersion, message.editVersion < existingVersion { continue }
            if let existingClientId = try String.fetchOne(
                db,
                sql: "SELECT client_msg_id FROM messages WHERE dialog_id = ? AND msg_id = ?",
                arguments: [dialog.dialogId, message.msgId]
            ), existingClientId != message.clientMsgId {
                try deleteCloudMessage(
                    db,
                    dialogId: dialog.dialogId,
                    msgId: message.msgId,
                    localId: nil
                )
            }
            try upsertMessage(db, message: message, localState: "sent", refreshSummaries: false)
        }

        try mergeBootstrapHistoryState(db, dialog: dialog)
        try refreshDialogSummary(db, dialogId: dialog.dialogId)
        try refreshAllUnreadSummaries(db, dialogId: dialog.dialogId)
        if let unreadCount = dialog.unreadCount {
            try setUnreadSummary(
                db,
                dialogId: dialog.dialogId,
                accountId: accountId,
                unreadCount: unreadCount,
                isExact: true
            )
        }
    }

    private func pruneSnapshotMessageWindow(_ db: Database, dialog: BootstrapDialog) throws {
        let stagedMessageIds = Set(dialog.messages.map(\.msgId))
        let lowerBound: Int64
        if let oldest = stagedMessageIds.min() {
            lowerBound = oldest
        } else if dialog.lastMsgId == 0 {
            lowerBound = 0
        } else {
            // A non-empty dialog can legitimately have no preview messages when a server applies a
            // stricter page-size cap. Without a lower bound, retaining history is safer than guessing.
            return
        }

        let pendingTextClientIds = try String.fetchAll(
            db,
            sql: "SELECT client_msg_id FROM pending_outbox WHERE dialog_id = ?",
            arguments: [dialog.dialogId]
        )
        let pendingMediaClientIds = try String.fetchAll(
            db,
            sql: "SELECT client_msg_id FROM media_transfers WHERE dialog_id = ?",
            arguments: [dialog.dialogId]
        )
        let pendingClientIds = Set(pendingTextClientIds + pendingMediaClientIds)
        let pendingMutationIds = Set(try Int64.fetchAll(
            db,
            sql: "SELECT msg_id FROM pending_message_mutations WHERE dialog_id = ?",
            arguments: [dialog.dialogId]
        ))
        let candidates = try Row.fetchAll(
            db,
            sql: """
            SELECT local_id, msg_id, client_msg_id, local_state
            FROM messages
            WHERE dialog_id = ? AND msg_id BETWEEN ? AND ?
            """,
            arguments: [dialog.dialogId, lowerBound, dialog.lastMsgId]
        )
        for row in candidates {
            let msgId: Int64 = row["msg_id"]
            let clientMsgId: String = row["client_msg_id"]
            let localState: String = row["local_state"]
            guard
                !stagedMessageIds.contains(msgId),
                localState == "sent",
                !pendingClientIds.contains(clientMsgId),
                !pendingMutationIds.contains(msgId)
            else { continue }
            try deleteCloudMessage(
                db,
                dialogId: dialog.dialogId,
                msgId: msgId,
                localId: row["local_id"]
            )
        }
    }

    private func deleteCloudMessage(
        _ db: Database,
        dialogId: String,
        msgId: Int64,
        localId: String?
    ) throws {
        if let localId {
            try db.execute(
                sql: "DELETE FROM message_media WHERE local_id = ?",
                arguments: [localId]
            )
        } else {
            try db.execute(
                sql: "DELETE FROM message_media WHERE dialog_id = ? AND msg_id = ?",
                arguments: [dialogId, msgId]
            )
        }
        try db.execute(
            sql: "DELETE FROM message_reactions WHERE dialog_id = ? AND msg_id = ?",
            arguments: [dialogId, msgId]
        )
        try db.execute(
            sql: "DELETE FROM messages WHERE dialog_id = ? AND msg_id = ?",
            arguments: [dialogId, msgId]
        )
    }

    private func mergeBootstrapHistoryState(_ db: Database, dialog: BootstrapDialog) throws {
        let existing = try Row.fetchOne(
            db,
            sql: "SELECT * FROM dialog_history_state WHERE dialog_id = ?",
            arguments: [dialog.dialogId]
        ).map(Self.historyState(from:))
        let snapshotOldest = dialog.messages.map(\.msgId).min()
        let snapshotComplete = dialog.lastMsgId == 0 || snapshotOldest == 1
        let historyComplete = (existing?.historyComplete ?? false) || snapshotComplete
        let nextBeforeMsgId: Int64?
        if historyComplete {
            nextBeforeMsgId = nil
        } else {
            // `/v1/history` uses an exclusive before cursor. Beginning at the snapshot ceiling + 1
            // gives a resumable, server-defined boundary; preview duplicates are harmless upserts.
            let snapshotCursor = dialog.lastMsgId < Int64.max ? dialog.lastMsgId + 1 : dialog.lastMsgId
            nextBeforeMsgId = [existing?.nextBeforeMsgId, snapshotCursor].compactMap { $0 }.min()
        }
        try upsertHistoryState(
            db,
            state: DialogHistoryState(
                dialogId: dialog.dialogId,
                ceilingMsgId: max(existing?.ceilingMsgId ?? 0, dialog.lastMsgId),
                nextBeforeMsgId: nextBeforeMsgId,
                historyComplete: historyComplete,
                retryCount: existing?.retryCount ?? 0,
                nextRetryAt: existing?.nextRetryAt
            )
        )
    }

    private func pruneDialogsMissingFromBootstrap(
        _ db: Database,
        accountId: String,
        stagedDialogIds: Set<String>
    ) throws {
        let publishedDialogIds = try String.fetchAll(
            db,
            sql: "SELECT dialog_id FROM bootstrap_baseline_dialogs WHERE account_id = ?",
            arguments: [accountId]
        )
        for dialogId in publishedDialogIds where !stagedDialogIds.contains(dialogId) {
            let hasPendingWork = try Bool.fetchOne(
                db,
                sql: """
                SELECT
                  EXISTS(SELECT 1 FROM pending_outbox WHERE dialog_id = ?) OR
                  EXISTS(SELECT 1 FROM pending_message_mutations WHERE dialog_id = ?) OR
                  EXISTS(SELECT 1 FROM media_transfers WHERE dialog_id = ?) OR
                  EXISTS(
                    SELECT 1 FROM messages
                    WHERE dialog_id = ? AND (msg_id IS NULL OR local_state != 'sent')
                  )
                """,
                arguments: [dialogId, dialogId, dialogId, dialogId]
            ) ?? false
            guard !hasPendingWork else { continue }

            // Hydrated messages, history cursors, and semantic viewport anchors intentionally stay
            // on disk. Only snapshot-owned list metadata is pruned, so an active timeline remains
            // readable and a later server reappearance can reuse its already hydrated history.
            try db.execute(
                sql: "DELETE FROM dialog_members WHERE dialog_id = ?",
                arguments: [dialogId]
            )
            try db.execute(
                sql: "DELETE FROM dialog_unread_summaries WHERE dialog_id = ?",
                arguments: [dialogId]
            )
            try db.execute(
                sql: "DELETE FROM dialog_summaries WHERE dialog_id = ?",
                arguments: [dialogId]
            )
            try db.execute(
                sql: "DELETE FROM dialogs WHERE dialog_id = ?",
                arguments: [dialogId]
            )
        }
    }

    private func upsertHistoryState(_ db: Database, state: DialogHistoryState) throws {
        try db.execute(
            sql: """
            INSERT INTO dialog_history_state (
              dialog_id, ceiling_msg_id, next_before_msg_id, history_complete,
              retry_count, next_retry_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(dialog_id) DO UPDATE SET
              ceiling_msg_id = MAX(dialog_history_state.ceiling_msg_id, excluded.ceiling_msg_id),
              next_before_msg_id = excluded.next_before_msg_id,
              history_complete = excluded.history_complete,
              retry_count = excluded.retry_count,
              next_retry_at = excluded.next_retry_at,
              updated_at = excluded.updated_at
            """,
            arguments: [
                state.dialogId, state.ceilingMsgId, state.nextBeforeMsgId, state.historyComplete,
                state.retryCount, state.nextRetryAt, state.updatedAt
            ]
        )
    }

    private func ensureDialogSummary(_ db: Database, dialogId: String) throws {
        try db.execute(
            sql: "INSERT INTO dialog_summaries (dialog_id) VALUES (?) ON CONFLICT(dialog_id) DO NOTHING",
            arguments: [dialogId]
        )
    }

    private func refreshDialogSummary(_ db: Database, dialogId: String) throws {
        let row = try Row.fetchOne(
            db,
            sql: """
            SELECT local_id, msg_id, text, kind, state, sender_account_id, local_state, server_ts
            FROM messages candidate
            WHERE candidate.dialog_id = ?
              AND candidate.state = 'visible'
              AND NOT EXISTS (
                SELECT 1 FROM pending_message_mutations pending_delete
                WHERE pending_delete.dialog_id = candidate.dialog_id
                  AND pending_delete.msg_id = candidate.msg_id
                  AND pending_delete.operation = 'delete'
              )
            ORDER BY COALESCE(candidate.msg_id, 9223372036854775807) DESC, candidate.rowid DESC
            LIMIT 1
            """,
            arguments: [dialogId]
        )
        try db.execute(
            sql: """
            INSERT INTO dialog_summaries (
              dialog_id, last_local_id, last_msg_id, last_text, last_kind, last_state,
              last_sender_account_id, last_local_state, last_server_ts
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(dialog_id) DO UPDATE SET
              last_local_id = excluded.last_local_id,
              last_msg_id = excluded.last_msg_id,
              last_text = excluded.last_text,
              last_kind = excluded.last_kind,
              last_state = excluded.last_state,
              last_sender_account_id = excluded.last_sender_account_id,
              last_local_state = excluded.last_local_state,
              last_server_ts = excluded.last_server_ts
            """,
            arguments: [
                dialogId,
                row?["local_id"], row?["msg_id"], row?["text"], row?["kind"],
                row?["state"], row?["sender_account_id"], row?["local_state"], row?["server_ts"]
            ]
        )
    }

    private func refreshUnreadSummary(_ db: Database, dialogId: String, accountId: String) throws {
        // Once bootstrap or a read acknowledgement supplied an authoritative server count, sparse
        // local history must never replace it with a count of only the cached rows.
        if try Bool.fetchOne(
            db,
            sql: """
            SELECT is_exact FROM dialog_unread_summaries
            WHERE dialog_id = ? AND account_id = ?
            """,
            arguments: [dialogId, accountId]
        ) == true {
            return
        }
        let count = try Int.fetchOne(
            db,
            sql: """
            SELECT COUNT(*)
            FROM messages message
            WHERE message.dialog_id = ?
              AND message.msg_id IS NOT NULL
              AND message.sender_account_id != ?
              AND message.state = 'visible'
              AND message.msg_id > COALESCE((
                SELECT last_read_msg_id FROM dialog_members
                WHERE dialog_id = ? AND account_id = ?
              ), 0)
            """,
            arguments: [dialogId, accountId, dialogId, accountId]
        ) ?? 0
        try setUnreadSummary(
            db,
            dialogId: dialogId,
            accountId: accountId,
            unreadCount: count,
            isExact: false
        )
    }

    private func setUnreadSummary(
        _ db: Database,
        dialogId: String,
        accountId: String,
        unreadCount: Int,
        isExact: Bool
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO dialog_unread_summaries (
              dialog_id, account_id, unread_count, is_exact, mention_count
            )
            VALUES (
              ?, ?, MAX(0, ?), ?,
              COALESCE((
                SELECT COUNT(*)
                FROM message_mentions mention
                JOIN messages message
                  ON message.dialog_id = mention.dialog_id AND message.msg_id = mention.msg_id
                WHERE mention.dialog_id = ? AND mention.account_id = ?
                  AND message.state = 'visible'
                  AND mention.msg_id > COALESCE((
                    SELECT last_read_msg_id FROM dialog_members
                    WHERE dialog_id = ? AND account_id = ?
                  ), 0)
              ), 0)
            )
            ON CONFLICT(dialog_id, account_id) DO UPDATE SET
              unread_count = excluded.unread_count,
              is_exact = excluded.is_exact,
              mention_count = excluded.mention_count
            """,
            arguments: [
                dialogId, accountId, unreadCount, isExact,
                dialogId, accountId, dialogId, accountId
            ]
        )
    }

    private func adjustUnreadSummary(
        _ db: Database,
        dialogId: String,
        accountId: String,
        delta: Int
    ) throws {
        guard delta != 0 else { return }
        try db.execute(
            sql: """
            INSERT INTO dialog_unread_summaries (
              dialog_id, account_id, unread_count, is_exact, mention_count
            )
            VALUES (
              ?, ?, MAX(0, ?), 0,
              COALESCE((
                SELECT COUNT(*)
                FROM message_mentions mention
                JOIN messages message
                  ON message.dialog_id = mention.dialog_id AND message.msg_id = mention.msg_id
                WHERE mention.dialog_id = ? AND mention.account_id = ?
                  AND message.state = 'visible'
                  AND mention.msg_id > COALESCE((
                    SELECT last_read_msg_id FROM dialog_members
                    WHERE dialog_id = ? AND account_id = ?
                  ), 0)
              ), 0)
            )
            ON CONFLICT(dialog_id, account_id) DO UPDATE SET
              unread_count = MAX(0, dialog_unread_summaries.unread_count + ?),
              is_exact = dialog_unread_summaries.is_exact,
              mention_count = excluded.mention_count
            """,
            arguments: [
                dialogId, accountId, delta,
                dialogId, accountId, dialogId, accountId,
                delta
            ]
        )
    }

    private func refreshAllUnreadSummaries(_ db: Database, dialogId: String) throws {
        let accountIds = try String.fetchAll(
            db,
            sql: "SELECT account_id FROM dialog_members WHERE dialog_id = ?",
            arguments: [dialogId]
        )
        for accountId in accountIds {
            try refreshUnreadSummary(db, dialogId: dialogId, accountId: accountId)
        }
    }

    nonisolated private static func upsertMessageMedia(
        _ db: Database,
        localId: String,
        dialogId: String,
        msgId: Int64?,
        media: CloudMedia
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO message_media (
              local_id, dialog_id, msg_id, media_id, kind, content_type, file_name,
              byte_size, duration_ms, width, height, has_thumbnail
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(local_id) DO UPDATE SET
              dialog_id = excluded.dialog_id,
              msg_id = excluded.msg_id,
              media_id = excluded.media_id,
              kind = excluded.kind,
              content_type = excluded.content_type,
              file_name = excluded.file_name,
              byte_size = excluded.byte_size,
              duration_ms = excluded.duration_ms,
              width = excluded.width,
              height = excluded.height,
              has_thumbnail = excluded.has_thumbnail
            """,
            arguments: [
                localId, dialogId, msgId, media.id, media.kind, media.contentType,
                media.fileName, media.byteSize, media.durationMs, media.width, media.height,
                media.hasThumbnail
            ]
        )
    }

    nonisolated private static func historyState(from row: Row) -> DialogHistoryState {
        DialogHistoryState(
            dialogId: row["dialog_id"],
            ceilingMsgId: row["ceiling_msg_id"],
            nextBeforeMsgId: row["next_before_msg_id"],
            historyComplete: row["history_complete"],
            retryCount: row["retry_count"],
            nextRetryAt: row["next_retry_at"],
            updatedAt: row["updated_at"]
        )
    }

    nonisolated private static func bootstrapState(from row: Row) -> ReplicaBootstrapState {
        ReplicaBootstrapState(
            accountId: row["account_id"],
            token: row["token"],
            nextCursor: row["next_cursor"],
            snapshotPts: row["snapshot_pts"],
            status: row["status"],
            mode: ReplicaBootstrapMode(rawValue: row["mode"]) ?? .initial,
            updatedAt: row["updated_at"]
        )
    }

    nonisolated private static func messageMedia(from row: Row) -> MessageMediaRecord {
        MessageMediaRecord(
            localId: row["local_id"],
            dialogId: row["dialog_id"],
            msgId: row["msg_id"],
            media: CloudMedia(
                id: row["media_id"],
                kind: row["kind"],
                contentType: row["content_type"],
                fileName: row["file_name"],
                byteSize: row["byte_size"],
                durationMs: row["duration_ms"],
                width: row["width"],
                height: row["height"],
                hasThumbnail: row["has_thumbnail"]
            )
        )
    }

    nonisolated private static func mediaCacheEntry(from row: Row) -> MediaCacheEntry {
        MediaCacheEntry(
            mediaId: row["media_id"], variant: row["variant"],
            encryptedPath: row["encrypted_path"], byteSize: row["byte_size"],
            cachedBytes: row["cached_bytes"], contiguousOffset: row["contiguous_offset"],
            state: row["state"], lastAccessedAt: row["last_accessed_at"],
            protectedUntil: row["protected_until"]
        )
    }

    nonisolated private static func mediaDownloadJob(from row: Row) -> MediaDownloadJobRecord {
        MediaDownloadJobRecord(
            mediaId: row["media_id"], variant: row["variant"], dialogId: row["dialog_id"],
            priority: row["priority"],
            state: MediaDownloadJobState(rawValue: row["state"]) ?? .failed,
            userInitiated: row["user_initiated"], retryCount: row["retry_count"],
            nextRetryAt: row["next_retry_at"], lastError: row["last_error"],
            updatedAt: row["updated_at"]
        )
    }

    private func applyGroup(_ db: Database, group: CloudGroup) throws {
        let photoJSON = group.photo
            .flatMap { try? JSONEncoder().encode($0) }
            .flatMap { String(data: $0, encoding: .utf8) }
        try db.execute(
            sql: """
            INSERT INTO dialogs (
              dialog_id, type, title, last_msg_id, updated_at, revision, photo_media_json,
              member_count, self_role, notification_mode, access_state
            ) VALUES (?, 'group', ?, 0, datetime('now'), ?, ?, ?, ?, ?, 'active')
            ON CONFLICT(dialog_id) DO UPDATE SET
              type = 'group',
              title = CASE WHEN excluded.revision >= dialogs.revision
                THEN excluded.title ELSE dialogs.title END,
              photo_media_json = CASE WHEN excluded.revision >= dialogs.revision
                THEN excluded.photo_media_json ELSE dialogs.photo_media_json END,
              member_count = CASE WHEN excluded.revision >= dialogs.revision
                THEN excluded.member_count ELSE dialogs.member_count END,
              self_role = excluded.self_role,
              notification_mode = excluded.notification_mode,
              access_state = 'active',
              revision = MAX(dialogs.revision, excluded.revision),
              updated_at = MAX(dialogs.updated_at, excluded.updated_at)
            """,
            arguments: [
                group.id, group.title, group.revision, photoJSON, group.memberCount,
                group.selfRole, group.notificationMode,
            ]
        )
        try ensureDialogSummary(db, dialogId: group.id)
    }

    private func applyGroupMetadata(_ db: Database, group: CloudUpdateGroup) throws {
        let existingRevision = try Int64.fetchOne(
            db,
            sql: "SELECT revision FROM dialogs WHERE dialog_id = ?",
            arguments: [group.id]
        ) ?? -1
        guard group.revision > existingRevision else { return }
        try db.execute(
            sql: """
            INSERT INTO dialogs (
              dialog_id, type, title, last_msg_id, updated_at, revision, member_count,
              notification_mode, access_state
            ) VALUES (?, 'group', ?, 0, datetime('now'), ?, ?, 'all', 'active')
            ON CONFLICT(dialog_id) DO UPDATE SET
              type = 'group',
              title = COALESCE(excluded.title, dialogs.title),
              revision = excluded.revision,
              member_count = excluded.member_count,
              updated_at = excluded.updated_at
            """,
            arguments: [group.id, group.title, group.revision, group.memberCount]
        )
        try ensureDialogSummary(db, dialogId: group.id)
    }

    private func upsertGroupMember(
        _ db: Database,
        dialogId: String,
        member: CloudGroupMember,
        revision: Int64,
        generation: String? = nil
    ) throws {
        let localRevision = try Int64.fetchOne(
            db,
            sql: """
            SELECT revision FROM dialog_members
            WHERE dialog_id = ? AND account_id = ?
            """,
            arguments: [dialogId, member.accountId]
        ) ?? -1
        guard revision >= localRevision else { return }
        try db.execute(
            sql: """
            INSERT INTO dialog_members (
              dialog_id, account_id, role, last_read_msg_id, joined_at, left_at,
              is_active, revision, seen_generation
            ) VALUES (?, ?, ?, 0, ?, NULL, ?, ?, ?)
            ON CONFLICT(dialog_id, account_id) DO UPDATE SET
              role = excluded.role,
              joined_at = excluded.joined_at,
              left_at = excluded.left_at,
              is_active = excluded.is_active,
              revision = excluded.revision,
              seen_generation = COALESCE(excluded.seen_generation, dialog_members.seen_generation)
            """,
            arguments: [
                dialogId, member.accountId, member.role, member.joinedAt,
                member.isActive, revision, generation,
            ]
        )
    }

    private func revokeGroupAccess(
        _ db: Database,
        dialogId: String,
        accessState: String,
        reason: String
    ) throws {
        let mediaIds = try String.fetchAll(
            db,
            sql: "SELECT DISTINCT media_id FROM message_media WHERE dialog_id = ?",
            arguments: [dialogId]
        )
        let mediaPayload = try JSONEncoder().encode(mediaIds)
        let mediaJSON = String(data: mediaPayload, encoding: .utf8) ?? "[]"
        // Access state is the first write in this transaction so every observation hides the
        // conversation even if the process exits before the durable purge is drained.
        try db.execute(
            sql: "UPDATE dialogs SET access_state = ?, updated_at = datetime('now') WHERE dialog_id = ?",
            arguments: [accessState, dialogId]
        )
        try db.execute(
            sql: "UPDATE pending_outbox SET terminal = 1 WHERE dialog_id = ?",
            arguments: [dialogId]
        )
        try db.execute(
            sql: "UPDATE media_transfers SET terminal = 1, last_error = ? WHERE dialog_id = ?",
            arguments: [reason, dialogId]
        )
        try db.execute(
            sql: """
            UPDATE pending_message_mutations
            SET terminal = 1, last_error = ?
            WHERE dialog_id = ?
            """,
            arguments: [reason, dialogId]
        )
        try db.execute(
            sql: """
            UPDATE pending_group_mutations
            SET terminal = 1, last_error = ?
            WHERE dialog_id = ?
            """,
            arguments: [reason, dialogId]
        )
        try db.execute(sql: "DELETE FROM media_download_jobs WHERE dialog_id = ?", arguments: [dialogId])
        try db.execute(sql: "DELETE FROM dialog_unread_summaries WHERE dialog_id = ?", arguments: [dialogId])
        try db.execute(sql: "DELETE FROM group_member_hydration WHERE dialog_id = ?", arguments: [dialogId])
        try db.execute(
            sql: """
            INSERT INTO pending_purges (id, dialog_id, kind, payload, created_at)
            VALUES (?, ?, 'media', ?, datetime('now')),
                   (?, ?, 'messages', NULL, datetime('now'))
            """,
            arguments: [
                UUID().uuidString.lowercased(), dialogId, mediaJSON,
                UUID().uuidString.lowercased(), dialogId,
            ]
        )
    }

    private func upsertDialog(
        _ db: Database,
        dialogId: String,
        type: String,
        title: String?,
        lastMsgId: Int64,
        updatedAt: String?
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO dialogs (dialog_id, type, title, last_msg_id, updated_at)
            VALUES (?, ?, ?, ?, COALESCE(?, datetime('now')))
            ON CONFLICT(dialog_id) DO UPDATE SET
              type = CASE
                WHEN excluded.type = 'direct' AND dialogs.type <> 'direct' THEN dialogs.type
                ELSE excluded.type
              END,
              title = COALESCE(excluded.title, dialogs.title),
              last_msg_id = MAX(dialogs.last_msg_id, excluded.last_msg_id),
              updated_at = MAX(dialogs.updated_at, excluded.updated_at)
            """,
            arguments: [dialogId, type, title, lastMsgId, updatedAt]
        )
        try ensureDialogSummary(db, dialogId: dialogId)
    }

    private func ensureDialogPreferences(
        _ db: Database,
        accountId: String,
        dialogId: String
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO dialog_preferences (
              account_id, dialog_id, is_pinned, pinned_at,
              is_muted, is_archived, server_updated_at
            )
            SELECT
              ?, dialog_id, 0, NULL,
              notification_mode = 'muted', 0, updated_at
            FROM dialogs
            WHERE dialog_id = ?
            ON CONFLICT(account_id, dialog_id) DO NOTHING
            """,
            arguments: [accountId, dialogId]
        )
    }

    private func upsertDialogPreferences(
        _ db: Database,
        preferences: CloudDialogPreferences,
        accountId: String,
        clientMutationId: String?
    ) throws {
        guard try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM dialogs WHERE dialog_id = ?)",
            arguments: [preferences.dialogId]
        ) == true else { return }
        try db.execute(
            sql: """
            INSERT INTO dialog_preferences (
              account_id, dialog_id, is_pinned, pinned_at,
              is_muted, is_archived, server_updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(account_id, dialog_id) DO UPDATE SET
              is_pinned = excluded.is_pinned,
              pinned_at = excluded.pinned_at,
              is_muted = excluded.is_muted,
              is_archived = excluded.is_archived,
              server_updated_at = excluded.server_updated_at
            """,
            arguments: [
                accountId, preferences.dialogId, preferences.pinned, preferences.pinnedAt,
                preferences.muted, preferences.archived, preferences.updatedAt,
            ]
        )
        try db.execute(
            sql: """
            UPDATE dialogs
            SET notification_mode = ?
            WHERE dialog_id = ?
            """,
            arguments: [preferences.muted ? "muted" : "all", preferences.dialogId]
        )
        if let clientMutationId {
            try db.execute(
                sql: """
                DELETE FROM pending_dialog_preference_mutations
                WHERE account_id = ? AND client_mutation_id = ?
                """,
                arguments: [accountId, clientMutationId]
            )
        }
    }

    private func upsertMember(_ db: Database, dialogId: String, member: BootstrapDialogMember) throws {
        try db.execute(
            sql: """
            INSERT INTO dialog_members (dialog_id, account_id, role, last_read_msg_id)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(dialog_id, account_id) DO UPDATE SET
              role = excluded.role,
              last_read_msg_id = MAX(dialog_members.last_read_msg_id, excluded.last_read_msg_id)
            """,
            arguments: [dialogId, member.accountId, member.role, member.lastReadMsgId]
        )
        try refreshUnreadSummary(db, dialogId: dialogId, accountId: member.accountId)
    }

    private func upsertProfile(_ db: Database, profile: CloudProfile) throws {
        try db.execute(
            sql: """
            INSERT INTO profiles (
              account_id, first_name, last_name, display_name, bio, birthday, color_index, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(account_id) DO UPDATE SET
              first_name = excluded.first_name,
              last_name = excluded.last_name,
              display_name = excluded.display_name,
              bio = excluded.bio,
              birthday = excluded.birthday,
              color_index = excluded.color_index,
              updated_at = excluded.updated_at
            WHERE excluded.updated_at >= profiles.updated_at
            """,
            arguments: [
                profile.accountId, profile.firstName, profile.lastName, profile.displayName,
                profile.bio, profile.birthday, profile.colorIndex, profile.updatedAt
            ]
        )
    }

    private func markRead(
        _ db: Database,
        dialogId: String,
        accountId: String,
        maxReadMsgId: Int64,
        exactUnreadCount: Int? = nil
    ) throws {
        let previousMaxRead = try Int64.fetchOne(
            db,
            sql: """
            SELECT last_read_msg_id FROM dialog_members
            WHERE dialog_id = ? AND account_id = ?
            """,
            arguments: [dialogId, accountId]
        ) ?? 0
        try db.execute(
            sql: """
            INSERT INTO dialog_members (dialog_id, account_id, role, last_read_msg_id)
            VALUES (?, ?, 'member', ?)
            ON CONFLICT(dialog_id, account_id) DO UPDATE SET
              last_read_msg_id = MAX(dialog_members.last_read_msg_id, excluded.last_read_msg_id)
            """,
            arguments: [dialogId, accountId, maxReadMsgId]
        )
        if let exactUnreadCount {
            try setUnreadSummary(
                db,
                dialogId: dialogId,
                accountId: accountId,
                unreadCount: exactUnreadCount,
                isExact: true
            )
        } else if try Bool.fetchOne(
            db,
            sql: """
            SELECT is_exact FROM dialog_unread_summaries
            WHERE dialog_id = ? AND account_id = ?
            """,
            arguments: [dialogId, accountId]
        ) == true {
            let locallyCovered = try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*) FROM messages
                WHERE dialog_id = ?
                  AND msg_id > ? AND msg_id <= ?
                  AND sender_account_id != ?
                  AND state = 'visible'
                """,
                arguments: [dialogId, previousMaxRead, maxReadMsgId, accountId]
            ) ?? 0
            try adjustUnreadSummary(
                db,
                dialogId: dialogId,
                accountId: accountId,
                delta: -locallyCovered
            )
        } else {
            try refreshUnreadSummary(db, dialogId: dialogId, accountId: accountId)
        }
    }

    private func upsertMessage(
        _ db: Database,
        message: CloudMessage,
        localState: String,
        refreshSummaries: Bool = true
    ) throws {
        let previousLocalId = try String.fetchOne(
            db,
            sql: "SELECT local_id FROM messages WHERE client_msg_id = ?",
            arguments: [message.clientMsgId]
        )
        try db.execute(
            sql: """
            INSERT INTO messages (
              local_id, dialog_id, msg_id, client_msg_id, sender_account_id, kind, text,
              reply_to_msg_id, forwarded_from_account_id, forwarded_from_dialog_id,
              forwarded_from_msg_id, is_forwarded, edit_version, state, server_ts, local_state,
              mentions_json, media_json, service_type, service_data_json
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(client_msg_id) DO UPDATE SET
              local_id = excluded.local_id,
              dialog_id = excluded.dialog_id,
              msg_id = excluded.msg_id,
              sender_account_id = excluded.sender_account_id,
              kind = excluded.kind,
              text = excluded.text,
              reply_to_msg_id = excluded.reply_to_msg_id,
              forwarded_from_account_id = excluded.forwarded_from_account_id,
              forwarded_from_dialog_id = excluded.forwarded_from_dialog_id,
              forwarded_from_msg_id = excluded.forwarded_from_msg_id,
              is_forwarded = excluded.is_forwarded,
              mentions_json = excluded.mentions_json,
              media_json = excluded.media_json,
              service_type = excluded.service_type,
              service_data_json = excluded.service_data_json,
              edit_version = excluded.edit_version,
              state = excluded.state,
              server_ts = excluded.server_ts,
              local_state = excluded.local_state
            """,
            arguments: [
                message.id,
                message.dialogId,
                message.msgId,
                message.clientMsgId,
                message.senderAccountId,
                message.kind,
                message.text,
                message.replyToMsgId,
                message.forwardedFromAccountId,
                message.forwardedFromDialogId,
                message.forwardedFromMsgId,
                message.isForwarded,
                message.editVersion,
                message.state,
                message.serverTs,
                localState,
                message.mentions.isEmpty
                    ? "[]"
                    : String(data: try JSONEncoder().encode(message.mentions), encoding: .utf8) ?? "[]",
                message.media.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) },
                message.serviceType,
                message.serviceData.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
            ]
        )
        if let previousLocalId, previousLocalId != message.id {
            try db.execute(sql: "DELETE FROM message_media WHERE local_id = ?", arguments: [previousLocalId])
        }
        if let media = message.media {
            try Self.upsertMessageMedia(
                db,
                localId: message.id,
                dialogId: message.dialogId,
                msgId: message.msgId,
                media: media
            )
        } else {
            try db.execute(sql: "DELETE FROM message_media WHERE local_id = ?", arguments: [message.id])
        }
        try db.execute(
            sql: "DELETE FROM message_reactions WHERE dialog_id = ? AND msg_id = ?",
            arguments: [message.dialogId, message.msgId]
        )
        for reaction in message.reactions {
            try db.execute(
                sql: """
                INSERT INTO message_reactions (dialog_id, msg_id, account_id, emoji)
                VALUES (?, ?, ?, ?)
                """,
                arguments: [message.dialogId, message.msgId, reaction.accountId, reaction.emoji]
            )
        }
        try db.execute(
            sql: "DELETE FROM message_mentions WHERE dialog_id = ? AND msg_id = ?",
            arguments: [message.dialogId, message.msgId]
        )
        for mention in message.mentions {
            try db.execute(
                sql: """
                INSERT INTO message_mentions (dialog_id, msg_id, account_id, entity_offset, length)
                VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [
                    message.dialogId, message.msgId, mention.accountId, mention.offset, mention.length
                ]
            )
        }
        if refreshSummaries {
            try refreshDialogSummary(db, dialogId: message.dialogId)
            try refreshAllUnreadSummaries(db, dialogId: message.dialogId)
        }
    }

    private static func message(from row: Row, reactions: [CloudReaction]) -> LocalMessage {
        LocalMessage(
            localId: row["local_id"],
            dialogId: row["dialog_id"],
            msgId: row["msg_id"],
            clientMsgId: row["client_msg_id"],
            senderAccountId: row["sender_account_id"],
            senderDisplayName: row["sender_display_name"],
            kind: row["kind"],
            text: row["text"],
            replyToMsgId: row["reply_to_msg_id"],
            forwardedFromAccountId: row["forwarded_from_account_id"],
            forwardedFromDialogId: row["forwarded_from_dialog_id"],
            forwardedFromMsgId: row["forwarded_from_msg_id"],
            isForwarded: row["is_forwarded"],
            reactions: reactions,
            mentions: (row["mentions_json"] as String?)
                .flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONDecoder().decode([CloudMention].self, from: $0) } ?? [],
            media: (row["media_json"] as String?).flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(CloudMedia.self, from: $0) },
            serviceType: row["service_type"],
            serviceData: (row["service_data_json"] as String?)
                .flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONDecoder().decode(CloudServiceData.self, from: $0) },
            editVersion: row["edit_version"],
            state: row["state"],
            serverTs: row["server_ts"],
            localState: row["local_state"]
        )
    }

    private static func mediaTransfer(from row: Row) -> MediaTransferRecord {
        MediaTransferRecord(
            transferId: row["transfer_id"], dialogId: row["dialog_id"],
            clientMsgId: row["client_msg_id"], caption: row["caption"],
            replyToMsgId: row["reply_to_msg_id"], purpose: row["purpose"],
            kind: row["kind"],
            contentType: row["content_type"], fileName: row["file_name"],
            byteSize: row["byte_size"], sha256: row["sha256"], durationMs: row["duration_ms"],
            width: row["width"], height: row["height"],
            encryptedSourcePath: row["encrypted_source_path"],
            encryptedThumbnailPath: row["encrypted_thumbnail_path"], mediaId: row["media_id"],
            uploadOffset: row["upload_offset"], state: row["state"],
            retryCount: row["retry_count"], nextRetryAt: row["next_retry_at"],
            lastError: row["last_error"], terminal: (row["terminal"] as Int) != 0
        )
    }

    private static func messageMutation(from row: Row) -> PendingMessageMutation {
        PendingMessageMutation(
            clientMutationId: row["client_mutation_id"], operation: row["operation"],
            dialogId: row["dialog_id"], msgId: row["msg_id"], body: row["body"],
            expectedEditVersion: row["expected_edit_version"], emoji: row["emoji"],
            retryCount: row["retry_count"], nextRetryAt: row["next_retry_at"],
            lastError: row["last_error"]
        )
    }

    private static func pendingGroupCreation(from row: Row) -> PendingGroupCreation? {
        guard
            let json: String = row["member_ids_json"],
            let data = json.data(using: .utf8),
            let memberIds = try? JSONDecoder().decode([String].self, from: data)
        else { return nil }
        return PendingGroupCreation(
            groupId: row["group_id"],
            title: row["title"],
            memberIds: memberIds,
            localPhotoReference: row["local_photo_reference"],
            state: row["state"],
            retryCount: row["retry_count"],
            nextRetryAt: row["next_retry_at"],
            lastError: row["last_error"],
            terminal: (row["terminal"] as Int) != 0
        )
    }

    private static func pendingGroupMutation(from row: Row) -> PendingGroupMutation {
        PendingGroupMutation(
            clientMutationId: row["client_mutation_id"],
            dialogId: row["dialog_id"],
            operation: row["operation"],
            payloadJSON: row["payload_json"],
            retryCount: row["retry_count"],
            nextRetryAt: row["next_retry_at"],
            lastError: row["last_error"],
            terminal: (row["terminal"] as Int) != 0
        )
    }

    private static func pendingDialogPreference(
        from row: Row
    ) -> PendingDialogPreferenceMutation {
        PendingDialogPreferenceMutation(
            accountId: row["account_id"],
            dialogId: row["dialog_id"],
            field: DialogPreferenceField(rawValue: row["field"]) ?? .muted,
            desiredValue: (row["desired_value"] as Int) != 0,
            clientMutationId: row["client_mutation_id"],
            retryCount: row["retry_count"],
            nextRetryAt: row["next_retry_at"],
            acknowledgedPts: row["acknowledged_pts"],
            lastError: row["last_error"]
        )
    }

    private static func dialog(from row: Row) -> LocalDialog {
        LocalDialog(
            dialogId: row["dialog_id"],
            type: row["type"],
            title: row["title"],
            photo: (row["photo_media_json"] as String?)
                .flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONDecoder().decode(CloudMedia.self, from: $0) },
            lastMsgId: row["last_msg_id"],
            updatedAt: row["updated_at"],
            lastText: row["last_text"],
            lastKind: row["last_kind"],
            lastState: row["last_state"],
            lastSenderAccountId: row["last_sender_account_id"],
            lastLocalState: row["last_local_state"],
            lastServerTs: row["last_server_ts"],
            unreadCount: row["unread_count"],
            mentionCount: row["mention_count"],
            peerAccountId: row["peer_account_id"],
            peerBio: row["peer_bio"],
            peerBirthday: row["peer_birthday"],
            peerColorIndex: row["peer_color_index"],
            revision: row["revision"],
            memberCount: row["member_count"],
            selfRole: row["self_role"],
            notificationMode: row["notification_mode"],
            accessState: row["access_state"],
            isPinned: (row["is_pinned"] as Int) != 0,
            pinnedAt: row["pinned_at"],
            isMuted: (row["is_muted"] as Int) != 0,
            isArchived: (row["is_archived"] as Int) != 0
        )
    }

    private static func pendingOutboxItem(from row: Row) -> PendingOutboxItem {
        PendingOutboxItem(
            clientMsgId: row["client_msg_id"],
            dialogId: row["dialog_id"],
            body: row["body"],
            replyToMsgId: row["reply_to_msg_id"],
            forwardedFromDialogId: row["forwarded_from_dialog_id"],
            forwardedFromMsgId: row["forwarded_from_msg_id"],
            mentions: (row["mentions_json"] as String?)
                .flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONDecoder().decode([CloudMention].self, from: $0) } ?? [],
            retryCount: row["retry_count"],
            nextRetryAt: row["next_retry_at"]
        )
    }

    nonisolated static func sqliteTimestamp(_ date: Date) -> String {
        makeSQLiteDateFormatter().string(from: date)
    }

    nonisolated private static func preferenceTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    nonisolated private static func makeSQLiteDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }

    nonisolated private static func defaultApplicationDirectory() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = support.appending(
            path: LocalDatabaseKeyStore.usesTelegramFastUITestFixture ? "TojUITest" : "Toj",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        return directory
    }

    nonisolated private static func quarantineTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    nonisolated private static func applyFileSecurity(to url: URL) throws {
        let fileManager = FileManager.default
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        var protectedURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try protectedURL.setResourceValues(values)
    }

    nonisolated private static func applyFileSecurity(toSQLiteFilesAt path: String) throws {
        let fileManager = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let candidate = path + suffix
            if fileManager.fileExists(atPath: candidate) {
                try applyFileSecurity(to: URL(fileURLWithPath: candidate))
            }
        }
    }

    private func deleteReplicaData(_ db: Database, includeMediaTransfers: Bool) throws {
        try db.execute(sql: "DELETE FROM message_reactions")
        try db.execute(sql: "DELETE FROM message_media")
        try db.execute(sql: "DELETE FROM messages")
        try db.execute(sql: "DELETE FROM pending_dialog_preference_mutations")
        try db.execute(sql: "DELETE FROM dialog_preferences")
        try db.execute(sql: "DELETE FROM dialog_members")
        try db.execute(sql: "DELETE FROM dialog_unread_summaries")
        try db.execute(sql: "DELETE FROM dialog_summaries")
        try db.execute(sql: "DELETE FROM profiles")
        try db.execute(sql: "DELETE FROM dialogs")
        try db.execute(sql: "DELETE FROM pending_outbox")
        try db.execute(sql: "DELETE FROM pending_read_receipts")
        try db.execute(sql: "DELETE FROM chat_viewport_state")
        try db.execute(sql: "DELETE FROM dialog_history_state")
        try db.execute(sql: "DELETE FROM message_mentions")
        try db.execute(sql: "DELETE FROM group_member_hydration")
        try db.execute(sql: "DELETE FROM pending_group_creations")
        try db.execute(sql: "DELETE FROM pending_purges")
        try db.execute(sql: "DELETE FROM bootstrap_baseline_dialogs")
        try db.execute(sql: "DELETE FROM bootstrap_staged_messages")
        try db.execute(sql: "DELETE FROM bootstrap_staged_members")
        try db.execute(sql: "DELETE FROM bootstrap_staged_profiles")
        try db.execute(sql: "DELETE FROM bootstrap_staged_dialogs")
        try db.execute(sql: "DELETE FROM bootstrap_state")
        if includeMediaTransfers {
            try db.execute(sql: "DELETE FROM pending_message_mutations")
            try db.execute(sql: "DELETE FROM media_transfers")
            try db.execute(sql: "DELETE FROM media_download_jobs")
            try db.execute(sql: "DELETE FROM media_cache_entries")
        }
    }
}

nonisolated struct LocalDatabaseKeyStore {
    private let service: String
    private let account: String

    init(service: String = "com.toj.cloud-db", account: String = "sqlcipher-key") {
        self.service = service
        self.account = account
    }

    static var usesTelegramFastUITestFixture: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["TOJ_UI_FIXTURE"] == "telegram-fast"
        #else
        false
        #endif
    }

    static func currentEnvironment() -> LocalDatabaseKeyStore {
        usesTelegramFastUITestFixture
            ? LocalDatabaseKeyStore(
                service: "com.toj.cloud-db.ui-fixture",
                account: "sqlcipher-key"
            )
            : LocalDatabaseKeyStore()
    }

    func loadOrCreateKey() throws -> Data {
        if let existing = try loadKey() { return existing }

        var bytes = [UInt8](repeating: 0, count: 32)
        let randomStatus = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard randomStatus == errSecSuccess else {
            throw KeychainError(status: randomStatus)
        }

        let data = Data(bytes)
        var addQuery = baseQuery()
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecSuccess { return data }
        if addStatus == errSecDuplicateItem, let existing = try loadKey() {
            return existing
        }
        throw KeychainError(status: addStatus)
    }

    func deleteKey() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    private func loadKey() throws -> Data? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw KeychainError(status: status)
        }
        return data
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
