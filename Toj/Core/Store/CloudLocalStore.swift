import Foundation
import GRDB
import Security

nonisolated struct LocalMessage: Identifiable, Equatable, Sendable {
    let localId: String
    var id: String { localId }
    let dialogId: String
    let msgId: Int64?
    let clientMsgId: String
    let senderAccountId: String
    let kind: String
    let text: String
    let replyToMsgId: Int64?
    let forwardedFromAccountId: String?
    let forwardedFromDialogId: String?
    let forwardedFromMsgId: Int64?
    let isForwarded: Bool
    let reactions: [CloudReaction]
    let media: CloudMedia?
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
    let lastMsgId: Int64
    let updatedAt: String
    let lastText: String?
    let lastState: String?
    let lastSenderAccountId: String?
    let lastLocalState: String?
    let lastServerTs: String?
    let unreadCount: Int
}

nonisolated struct PendingOutboxItem: Identifiable, Equatable, Sendable {
    let clientMsgId: String
    var id: String { clientMsgId }
    let dialogId: String
    let body: String
    let replyToMsgId: Int64?
    let forwardedFromDialogId: String?
    let forwardedFromMsgId: Int64?
    let retryCount: Int
    let nextRetryAt: String?
}

nonisolated struct MediaTransferRecord: Identifiable, Equatable, Sendable {
    let transferId: String
    var id: String { transferId }
    let dialogId: String
    let clientMsgId: String
    let caption: String
    let replyToMsgId: Int64?
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

    var media: CloudMedia {
        return CloudMedia(
            id: mediaId ?? "pending:\(transferId)", kind: kind, contentType: contentType, fileName: fileName,
            byteSize: byteSize, durationMs: durationMs, width: width, height: height,
            hasThumbnail: encryptedThumbnailPath != nil
        )
    }
}

actor CloudLocalStore {
    private let dbQueue: DatabaseQueue

    nonisolated static func `default`() throws -> CloudLocalStore {
        let key = try LocalDatabaseKeyStore().loadOrCreateKey()
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let appDirectory = directory.appending(path: "Toj", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        let path = appDirectory.appending(path: "cloud.sqlite").path

        do {
            return try CloudLocalStore(path: path, key: key)
        } catch let error as DatabaseError where error.resultCode == .SQLITE_NOTADB {
            try removeSQLiteFiles(at: path)
            return try CloudLocalStore(path: path, key: key)
        }
    }

    init(path: String, key: Data) throws {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.usePassphrase(key)
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        dbQueue = try DatabaseQueue(path: path, configuration: configuration)
        try Self.migrate(dbQueue)
    }

    func loadPts(accountId: String) throws -> Int64 {
        try dbQueue.read { db in
            try Int64.fetchOne(db, sql: "SELECT pts FROM sync_state WHERE account_id = ?", arguments: [accountId]) ?? 0
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

    func clearAccount(accountId: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM sync_state WHERE account_id = ?", arguments: [accountId])
            try deleteReplicaData(db, includeMediaTransfers: true)
        }
    }

    func beginBootstrap(accountId: String) throws {
        try dbQueue.write { db in
            // Upload rows point to encrypted source files and are the durable media outbox.
            // A server snapshot rebuild must not discard them.
            try deleteReplicaData(db, includeMediaTransfers: false)
            try db.execute(
                sql: """
                INSERT INTO sync_state (account_id, pts, updated_at)
                VALUES (?, 0, datetime('now'))
                ON CONFLICT(account_id) DO UPDATE SET pts = 0, updated_at = excluded.updated_at
                """,
                arguments: [accountId]
            )
        }
    }

    func applyBootstrapPage(_ page: BootstrapDialogsPage) throws {
        try dbQueue.write { db in
            for dialog in page.dialogs {
                try upsertDialog(
                    db,
                    dialogId: dialog.dialogId,
                    type: dialog.type,
                    title: dialog.title,
                    lastMsgId: dialog.lastMsgId,
                    updatedAt: dialog.updatedAt
                )
                try db.execute(sql: "DELETE FROM dialog_members WHERE dialog_id = ?", arguments: [dialog.dialogId])
                for member in dialog.members {
                    try upsertMember(db, dialogId: dialog.dialogId, member: member)
                }
                for message in dialog.messages {
                    try upsertMessage(db, message: message, localState: "sent")
                }
            }
        }
    }

    func applyHistoryPage(_ page: HistoryPageResponse) throws {
        try dbQueue.write { db in
            for message in page.messages {
                try upsertDialog(
                    db,
                    dialogId: message.dialogId,
                    type: "direct",
                    title: nil,
                    lastMsgId: message.msgId,
                    updatedAt: message.serverTs
                )
                try upsertMessage(db, message: message, localState: "sent")
            }
        }
    }

    func finishBootstrap(accountId: String, pts: Int64) throws {
        try savePts(pts, accountId: accountId)
    }

    func saveMembers(dialogId: String, members: [BootstrapDialogMember]) throws {
        try dbQueue.write { db in
            for member in members {
                try upsertMember(db, dialogId: dialogId, member: member)
            }
        }
    }

    func markRead(dialogId: String, accountId: String, maxReadMsgId: Int64) throws {
        try dbQueue.write { db in
            try markRead(db, dialogId: dialogId, accountId: accountId, maxReadMsgId: maxReadMsgId)
        }
    }

    func upsertDialog(dialogId: String, type: String = "direct", title: String? = nil, lastMsgId: Int64 = 0, updatedAt: String? = nil) throws {
        try dbQueue.write { db in
            try upsertDialog(db, dialogId: dialogId, type: type, title: title, lastMsgId: lastMsgId, updatedAt: updatedAt)
        }
    }

    func insertSending(
        dialogId: String,
        clientMsgId: String,
        text: String,
        senderAccountId: String,
        replyToMsgId: Int64? = nil,
        forwardedFromAccountId: String? = nil,
        forwardedFromDialogId: String? = nil,
        forwardedFromMsgId: Int64? = nil
    ) throws -> LocalMessage {
        let localId = "pending:\(clientMsgId)"
        try dbQueue.write { db in
            try upsertDialog(db, dialogId: dialogId, type: "direct", title: nil, lastMsgId: 0, updatedAt: nil)
            try db.execute(
                sql: """
                INSERT INTO messages (
                  local_id, dialog_id, msg_id, client_msg_id, sender_account_id, kind, text,
                  reply_to_msg_id, forwarded_from_account_id, forwarded_from_dialog_id,
                  forwarded_from_msg_id, is_forwarded, edit_version, state, server_ts, local_state
                )
                VALUES (?, ?, NULL, ?, ?, 'text', ?, ?, ?, ?, ?, ?, 0, 'visible', NULL, 'sending')
                ON CONFLICT(client_msg_id) DO UPDATE SET
                  text = excluded.text,
                  reply_to_msg_id = excluded.reply_to_msg_id,
                  forwarded_from_account_id = excluded.forwarded_from_account_id,
                  forwarded_from_dialog_id = excluded.forwarded_from_dialog_id,
                  forwarded_from_msg_id = excluded.forwarded_from_msg_id,
                  is_forwarded = excluded.is_forwarded,
                  local_state = 'sending'
                """,
                arguments: [
                    localId, dialogId, clientMsgId, senderAccountId, text, replyToMsgId,
                    forwardedFromAccountId, forwardedFromDialogId, forwardedFromMsgId,
                    forwardedFromMsgId != nil
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO pending_outbox (
                  client_msg_id, dialog_id, body, reply_to_msg_id,
                  forwarded_from_dialog_id, forwarded_from_msg_id, created_at
                )
                VALUES (?, ?, ?, ?, ?, ?, datetime('now'))
                ON CONFLICT(client_msg_id) DO UPDATE SET
                  body = excluded.body,
                  reply_to_msg_id = excluded.reply_to_msg_id,
                  forwarded_from_dialog_id = excluded.forwarded_from_dialog_id,
                  forwarded_from_msg_id = excluded.forwarded_from_msg_id,
                  next_retry_at = NULL
                """,
                arguments: [
                    clientMsgId, dialogId, text, replyToMsgId,
                    forwardedFromDialogId, forwardedFromMsgId
                ]
            )
        }
        return LocalMessage(
            localId: localId,
            dialogId: dialogId,
            msgId: nil,
            clientMsgId: clientMsgId,
            senderAccountId: senderAccountId,
            kind: "text",
            text: text,
            replyToMsgId: replyToMsgId,
            forwardedFromAccountId: forwardedFromAccountId,
            forwardedFromDialogId: forwardedFromDialogId,
            forwardedFromMsgId: forwardedFromMsgId,
            isForwarded: forwardedFromMsgId != nil,
            reactions: [],
            media: nil,
            editVersion: 0,
            state: "visible",
            serverTs: nil,
            localState: "sending"
        )
    }

    func markRetrying(clientMsgId: String) throws {
        try dbQueue.write { db in
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
                SET next_retry_at = NULL
                WHERE client_msg_id = ?
                """,
                arguments: [clientMsgId]
            )
        }
    }

    func markFailed(clientMsgId: String, retryAfter: TimeInterval? = nil) throws {
        let nextRetryAt = retryAfter.map { Self.sqliteTimestamp(Date().addingTimeInterval($0)) }
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE messages SET local_state = 'failed' WHERE client_msg_id = ?", arguments: [clientMsgId])
            try db.execute(
                sql: """
                UPDATE pending_outbox
                SET retry_count = retry_count + 1, next_retry_at = ?
                WHERE client_msg_id = ?
                """,
                arguments: [nextRetryAt, clientMsgId]
            )
        }
    }

    func markSent(_ response: SendMessageResponse, senderAccountId: String) throws {
        try dbQueue.write { db in
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
            try db.execute(sql: "DELETE FROM pending_outbox WHERE client_msg_id = ?", arguments: [response.clientMsgId])
        }
    }

    func insertMediaTransfer(
        prepared: PreparedMediaUpload, dialogId: String, clientMsgId: String,
        caption: String, replyToMsgId: Int64?
    ) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO media_transfers (
                  transfer_id, dialog_id, client_msg_id, caption, reply_to_msg_id,
                  kind, content_type, file_name, byte_size, sha256, duration_ms, width, height,
                  encrypted_source_path, encrypted_thumbnail_path, state, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', datetime('now'))
                ON CONFLICT(transfer_id) DO NOTHING
                """,
                arguments: [
                    prepared.transferId, dialogId, clientMsgId, caption, replyToMsgId,
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
            try db.execute(
                sql: "UPDATE media_transfers SET next_retry_at = NULL, last_error = NULL WHERE client_msg_id = ?",
                arguments: [clientMsgId]
            )
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
                SELECT * FROM media_transfers
                WHERE state != 'complete' AND (next_retry_at IS NULL OR next_retry_at <= ?)
                ORDER BY created_at, transfer_id LIMIT ?
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
                sql: "SELECT COUNT(*) FROM media_transfers WHERE next_retry_at IS NULL OR next_retry_at <= ?",
                arguments: [nowText]
            ) ?? 0
            if due > 0 { return 0 }
            guard let next = try String.fetchOne(
                db,
                sql: "SELECT MIN(next_retry_at) FROM media_transfers WHERE next_retry_at > ?",
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
            try db.execute(
                sql: "DELETE FROM messages WHERE client_msg_id = ? AND msg_id IS NULL",
                arguments: [clientMsgId]
            )
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
        }
    }

    func applyMessageMutation(_ response: MessageMutationResponse) throws {
        try dbQueue.write { db in
            try upsertMessage(db, message: response.message, localState: "sent")
        }
    }

    func applyDifference(_ difference: DifferenceResponse, accountId: String) throws {
        try dbQueue.write { db in
            if difference.kind == "difference_too_long" {
                try db.execute(sql: "DELETE FROM message_reactions")
                try db.execute(sql: "DELETE FROM messages")
                try db.execute(sql: "DELETE FROM dialog_members")
                try db.execute(sql: "DELETE FROM dialogs")
                try db.execute(sql: "DELETE FROM pending_outbox")
                return
            } else {
                for update in difference.updates ?? [] {
                    switch update.type {
                    case "message.new", "message.edited", "message.deleted", "reaction.updated":
                        guard let message = update.message else { continue }
                        try upsertDialog(
                            db,
                            dialogId: message.dialogId,
                            type: "direct",
                            title: update.dialogTitle,
                            lastMsgId: message.msgId,
                            updatedAt: message.serverTs
                        )
                        try upsertMessage(db, message: message, localState: "sent")
                    case "dialog.created":
                        guard let dialogId = update.dialogId else { continue }
                        try upsertDialog(
                            db,
                            dialogId: dialogId,
                            type: "direct",
                            title: update.dialogTitle,
                            lastMsgId: 0,
                            updatedAt: nil
                        )
                    case "read.updated":
                        guard
                            let dialogId = update.dialogId,
                            let accountId = update.readerAccountId,
                            let maxReadMsgId = update.maxReadMsgId
                        else { continue }
                        try markRead(db, dialogId: dialogId, accountId: accountId, maxReadMsgId: maxReadMsgId)
                    default:
                        continue
                    }
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

    func messages(dialogId: String) throws -> [LocalMessage] {
        try dbQueue.read { db in
            let reactionRows = try Row.fetchAll(
                db,
                sql: """
                SELECT msg_id, account_id, emoji
                FROM message_reactions
                WHERE dialog_id = ?
                ORDER BY msg_id, account_id
                """,
                arguments: [dialogId]
            )
            var reactionsByMessage: [Int64: [CloudReaction]] = [:]
            for row in reactionRows {
                let msgId: Int64 = row["msg_id"]
                reactionsByMessage[msgId, default: []].append(
                    CloudReaction(accountId: row["account_id"], emoji: row["emoji"])
                )
            }
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
            return rows.map { row in
                let msgId: Int64? = row["msg_id"]
                return Self.message(from: row, reactions: msgId.flatMap { reactionsByMessage[$0] } ?? [])
            }
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
                SELECT client_msg_id, dialog_id, body, reply_to_msg_id,
                       forwarded_from_dialog_id, forwarded_from_msg_id, retry_count, next_retry_at
                FROM pending_outbox
                WHERE next_retry_at IS NULL OR next_retry_at <= ?
                ORDER BY created_at ASC, client_msg_id ASC
                LIMIT ?
                """,
                arguments: [nowText, limit]
            )
            return rows.map(Self.pendingOutboxItem(from:))
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
                WHERE next_retry_at IS NULL OR next_retry_at <= ?
                """,
                arguments: [nowText]
            ) ?? 0
            if dueCount > 0 {
                return 0
            }

            guard let next = try String.fetchOne(
                db,
                sql: """
                SELECT MIN(next_retry_at)
                FROM pending_outbox
                WHERE next_retry_at > ?
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
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT
                  d.dialog_id,
                  d.type,
                  d.title,
                  d.last_msg_id,
                  d.updated_at,
                  m.text AS last_text,
                  m.state AS last_state,
                  m.sender_account_id AS last_sender_account_id,
                  m.local_state AS last_local_state,
                  m.server_ts AS last_server_ts,
                  (
                    SELECT COUNT(*)
                    FROM messages unread
                    WHERE unread.dialog_id = d.dialog_id
                      AND unread.msg_id IS NOT NULL
                      AND unread.sender_account_id != ?
                      AND unread.state = 'visible'
                      AND unread.msg_id > COALESCE((
                        SELECT member.last_read_msg_id
                        FROM dialog_members member
                        WHERE member.dialog_id = d.dialog_id
                          AND member.account_id = ?
                      ), 0)
                  ) AS unread_count
                FROM dialogs d
                LEFT JOIN messages m ON m.rowid = (
                  SELECT rowid
                  FROM messages
                  WHERE dialog_id = d.dialog_id
                  ORDER BY COALESCE(msg_id, 9223372036854775807) DESC, rowid DESC
                  LIMIT 1
                )
                ORDER BY d.updated_at DESC, d.dialog_id DESC
                """,
                arguments: [accountId, accountId]
            )
            return rows.map(Self.dialog(from:))
        }
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

    private static func migrate(_ dbQueue: DatabaseQueue) throws {
        try dbQueue.write { db in
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
              created_at TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS media_transfers_retry_idx
              ON media_transfers(state, next_retry_at, created_at);
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
        }
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
              type = excluded.type,
              title = COALESCE(excluded.title, dialogs.title),
              last_msg_id = MAX(dialogs.last_msg_id, excluded.last_msg_id),
              updated_at = MAX(dialogs.updated_at, excluded.updated_at)
            """,
            arguments: [dialogId, type, title, lastMsgId, updatedAt]
        )
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
    }

    private func markRead(_ db: Database, dialogId: String, accountId: String, maxReadMsgId: Int64) throws {
        try db.execute(
            sql: """
            INSERT INTO dialog_members (dialog_id, account_id, role, last_read_msg_id)
            VALUES (?, ?, 'member', ?)
            ON CONFLICT(dialog_id, account_id) DO UPDATE SET
              last_read_msg_id = MAX(dialog_members.last_read_msg_id, excluded.last_read_msg_id)
            """,
            arguments: [dialogId, accountId, maxReadMsgId]
        )
    }

    private func upsertMessage(_ db: Database, message: CloudMessage, localState: String) throws {
        try db.execute(
            sql: """
            INSERT INTO messages (
              local_id, dialog_id, msg_id, client_msg_id, sender_account_id, kind, text,
              reply_to_msg_id, forwarded_from_account_id, forwarded_from_dialog_id,
              forwarded_from_msg_id, is_forwarded, edit_version, state, server_ts, local_state,
              media_json
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
              media_json = excluded.media_json,
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
                message.media.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
            ]
        )
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
    }

    private static func message(from row: Row, reactions: [CloudReaction]) -> LocalMessage {
        LocalMessage(
            localId: row["local_id"],
            dialogId: row["dialog_id"],
            msgId: row["msg_id"],
            clientMsgId: row["client_msg_id"],
            senderAccountId: row["sender_account_id"],
            kind: row["kind"],
            text: row["text"],
            replyToMsgId: row["reply_to_msg_id"],
            forwardedFromAccountId: row["forwarded_from_account_id"],
            forwardedFromDialogId: row["forwarded_from_dialog_id"],
            forwardedFromMsgId: row["forwarded_from_msg_id"],
            isForwarded: row["is_forwarded"],
            reactions: reactions,
            media: (row["media_json"] as String?).flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(CloudMedia.self, from: $0) },
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
            replyToMsgId: row["reply_to_msg_id"], kind: row["kind"],
            contentType: row["content_type"], fileName: row["file_name"],
            byteSize: row["byte_size"], sha256: row["sha256"], durationMs: row["duration_ms"],
            width: row["width"], height: row["height"],
            encryptedSourcePath: row["encrypted_source_path"],
            encryptedThumbnailPath: row["encrypted_thumbnail_path"], mediaId: row["media_id"],
            uploadOffset: row["upload_offset"], state: row["state"],
            retryCount: row["retry_count"], nextRetryAt: row["next_retry_at"],
            lastError: row["last_error"]
        )
    }

    private static func dialog(from row: Row) -> LocalDialog {
        LocalDialog(
            dialogId: row["dialog_id"],
            type: row["type"],
            title: row["title"],
            lastMsgId: row["last_msg_id"],
            updatedAt: row["updated_at"],
            lastText: row["last_text"],
            lastState: row["last_state"],
            lastSenderAccountId: row["last_sender_account_id"],
            lastLocalState: row["last_local_state"],
            lastServerTs: row["last_server_ts"],
            unreadCount: row["unread_count"]
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
            retryCount: row["retry_count"],
            nextRetryAt: row["next_retry_at"]
        )
    }

    private static func sqliteTimestamp(_ date: Date) -> String {
        makeSQLiteDateFormatter().string(from: date)
    }

    private static func makeSQLiteDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }

    private static func removeSQLiteFiles(at path: String) throws {
        let fileManager = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let candidate = path + suffix
            if fileManager.fileExists(atPath: candidate) {
                try fileManager.removeItem(atPath: candidate)
            }
        }
    }

    private func deleteReplicaData(_ db: Database, includeMediaTransfers: Bool) throws {
        try db.execute(sql: "DELETE FROM message_reactions")
        try db.execute(sql: "DELETE FROM messages")
        try db.execute(sql: "DELETE FROM dialog_members")
        try db.execute(sql: "DELETE FROM dialogs")
        try db.execute(sql: "DELETE FROM pending_outbox")
        if includeMediaTransfers { try db.execute(sql: "DELETE FROM media_transfers") }
    }
}

nonisolated struct LocalDatabaseKeyStore {
    private let service: String
    private let account: String

    init(service: String = "com.toj.cloud-db", account: String = "sqlcipher-key") {
        self.service = service
        self.account = account
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
