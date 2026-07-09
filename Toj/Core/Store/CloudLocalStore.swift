import Foundation
import GRDB
import Security

struct LocalMessage: Identifiable, Equatable, Sendable {
    let localId: String
    var id: String { localId }
    let dialogId: String
    let msgId: Int64?
    let clientMsgId: String
    let senderAccountId: String
    let kind: String
    let text: String
    let state: String
    let serverTs: String?
    let localState: String
}

struct LocalDialog: Identifiable, Equatable, Sendable {
    let dialogId: String
    var id: String { dialogId }
    let type: String
    let title: String?
    let lastMsgId: Int64
    let updatedAt: String
    let lastText: String?
    let lastSenderAccountId: String?
    let lastLocalState: String?
    let lastServerTs: String?
}

struct PendingOutboxItem: Identifiable, Equatable, Sendable {
    let clientMsgId: String
    var id: String { clientMsgId }
    let dialogId: String
    let body: String
    let retryCount: Int
    let nextRetryAt: String?
}

actor CloudLocalStore {
    private let dbQueue: DatabaseQueue

    static func `default`() throws -> CloudLocalStore {
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

        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.usePassphrase(key)
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        do {
            return try CloudLocalStore(path: path, configuration: configuration)
        } catch {
            try removeSQLiteFiles(at: path)
            return try CloudLocalStore(path: path, configuration: configuration)
        }
    }

    init(path: String, configuration: Configuration) throws {
        dbQueue = try DatabaseQueue(path: path, configuration: configuration)
        try migrate()
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
            try deleteReplicaData(db)
        }
    }

    func beginBootstrap(accountId: String) throws {
        try dbQueue.write { db in
            try deleteReplicaData(db)
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

    func insertSending(dialogId: String, clientMsgId: String, text: String, senderAccountId: String) throws -> LocalMessage {
        let localId = "pending:\(clientMsgId)"
        try dbQueue.write { db in
            try upsertDialog(db, dialogId: dialogId, type: "direct", title: nil, lastMsgId: 0, updatedAt: nil)
            try db.execute(
                sql: """
                INSERT INTO messages (
                  local_id, dialog_id, msg_id, client_msg_id, sender_account_id, kind, text, state, server_ts, local_state
                )
                VALUES (?, ?, NULL, ?, ?, 'text', ?, 'visible', NULL, 'sending')
                ON CONFLICT(client_msg_id) DO UPDATE SET text = excluded.text, local_state = 'sending'
                """,
                arguments: [localId, dialogId, clientMsgId, senderAccountId, text]
            )
            try db.execute(
                sql: """
                INSERT INTO pending_outbox (client_msg_id, dialog_id, body, created_at)
                VALUES (?, ?, ?, datetime('now'))
                ON CONFLICT(client_msg_id) DO UPDATE SET body = excluded.body, next_retry_at = NULL
                """,
                arguments: [clientMsgId, dialogId, text]
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

    func applyDifference(_ difference: DifferenceResponse, accountId: String) throws {
        try dbQueue.write { db in
            if difference.kind == "difference_too_long" {
                try db.execute(sql: "DELETE FROM messages")
                try db.execute(sql: "DELETE FROM dialog_members")
                try db.execute(sql: "DELETE FROM dialogs")
                try db.execute(sql: "DELETE FROM pending_outbox")
                return
            } else {
                for update in difference.updates ?? [] {
                    switch update.type {
                    case "message.new":
                        guard let message = update.message else { continue }
                        try upsertDialog(
                            db,
                            dialogId: message.dialogId,
                            type: "direct",
                            title: nil,
                            lastMsgId: message.msgId,
                            updatedAt: message.serverTs
                        )
                        try upsertMessage(db, message: message, localState: "sent")
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
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT local_id, dialog_id, msg_id, client_msg_id, sender_account_id, kind, text, state, server_ts, local_state
                FROM messages
                WHERE dialog_id = ?
                ORDER BY COALESCE(msg_id, 9223372036854775807), rowid
                """,
                arguments: [dialogId]
            )
            return rows.map(Self.message(from:))
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
                SELECT client_msg_id, dialog_id, body, retry_count, next_retry_at
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

    func dialogs() throws -> [LocalDialog] {
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
                  m.sender_account_id AS last_sender_account_id,
                  m.local_state AS last_local_state,
                  m.server_ts AS last_server_ts
                FROM dialogs d
                LEFT JOIN messages m ON m.rowid = (
                  SELECT rowid
                  FROM messages
                  WHERE dialog_id = d.dialog_id
                  ORDER BY COALESCE(msg_id, 9223372036854775807) DESC, rowid DESC
                  LIMIT 1
                )
                ORDER BY d.updated_at DESC, d.dialog_id DESC
                """
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

    private func migrate() throws {
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
              retry_count INTEGER NOT NULL DEFAULT 0,
              next_retry_at TEXT,
              created_at TEXT NOT NULL DEFAULT (datetime('now'))
            );
            """)
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
              local_id, dialog_id, msg_id, client_msg_id, sender_account_id, kind, text, state, server_ts, local_state
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(client_msg_id) DO UPDATE SET
              local_id = excluded.local_id,
              dialog_id = excluded.dialog_id,
              msg_id = excluded.msg_id,
              sender_account_id = excluded.sender_account_id,
              kind = excluded.kind,
              text = excluded.text,
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
                message.state,
                message.serverTs,
                localState
            ]
        )
    }

    private static func message(from row: Row) -> LocalMessage {
        LocalMessage(
            localId: row["local_id"],
            dialogId: row["dialog_id"],
            msgId: row["msg_id"],
            clientMsgId: row["client_msg_id"],
            senderAccountId: row["sender_account_id"],
            kind: row["kind"],
            text: row["text"],
            state: row["state"],
            serverTs: row["server_ts"],
            localState: row["local_state"]
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
            lastSenderAccountId: row["last_sender_account_id"],
            lastLocalState: row["last_local_state"],
            lastServerTs: row["last_server_ts"]
        )
    }

    private static func pendingOutboxItem(from row: Row) -> PendingOutboxItem {
        PendingOutboxItem(
            clientMsgId: row["client_msg_id"],
            dialogId: row["dialog_id"],
            body: row["body"],
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

    private func deleteReplicaData(_ db: Database) throws {
        try db.execute(sql: "DELETE FROM messages")
        try db.execute(sql: "DELETE FROM dialog_members")
        try db.execute(sql: "DELETE FROM dialogs")
        try db.execute(sql: "DELETE FROM pending_outbox")
    }
}

private struct LocalDatabaseKeyStore {
    private let service = "com.toj.cloud-db"
    private let account = "sqlcipher-key"

    func loadOrCreateKey() throws -> Data {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data {
            return data
        }
        if status != errSecItemNotFound {
            throw KeychainError(status: status)
        }

        var bytes = [UInt8](repeating: 0, count: 32)
        let randomStatus = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard randomStatus == errSecSuccess else {
            throw KeychainError(status: randomStatus)
        }

        let data = Data(bytes)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError(status: addStatus)
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
