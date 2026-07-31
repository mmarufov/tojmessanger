import Foundation
import GRDB
import os

/// Keeps `message_search` in step with `messages`, and owns every failure the index can suffer.
///
/// The triggers installed by `v12-message-search` record *that* a message changed; this decides
/// what that means. It exists as a separate actor rather than methods on `CloudLocalStore` because
/// its failure policy is the opposite of the store's: the store must surface errors, and this must
/// swallow them. Search is derived data. Nothing it does may ever cost a user a message.
///
/// ## The virtual table is created here, not by the migrator
///
/// A throwing migration makes `CloudLocalStore.init` throw, which routes the caller into the
/// quarantine path. Creating the index in ``bootstrap()`` instead means a build without FTS5, or a
/// SQLCipher too old for `contentless_delete`, disables search and leaves everything else working.
///
/// ## Ordering
///
/// The live queue drains first and the backfill second, so a message that just arrived is findable
/// before history from 2019 is. The backfill walks dialogs most-recently-active first and, within
/// a dialog, newest first — riding the existing `messages_dialog_order_idx` and mirroring how
/// `dialog_history_state` already paginates.
actor SearchIndexer {
    /// Rows per write transaction. Small enough that a drain never holds the writer long enough to
    /// stall a send, large enough that per-transaction overhead stays amortised.
    static let defaultBudget = 200

    /// Beyond this many pending entries a search waits for the backfill rather than the queue;
    /// draining synchronously past it would put unbounded work on a keystroke.
    static let shallowQueueDepth = 200

    /// Tombstones accumulate because an edit is delete-plus-insert. Past this, run a bounded merge.
    static let deletesBeforeMerge = 512

    enum Status: String {
        case bootstrapping
        case ready
        case rebuilding
        /// The build cannot host the index. Search reports itself unavailable; nothing else changes.
        case unavailable
    }

    struct DrainOutcome: Equatable {
        let indexed: Int
        let removed: Int
        /// More entries were waiting than the budget allowed.
        let hasMore: Bool
    }

    struct Coverage: Equatable {
        let status: Status
        let indexed: Int
        let total: Int
        let queueDepth: Int
        let dialogsComplete: Int
        let dialogsTotal: Int

        var isComplete: Bool { status == .ready && queueDepth == 0 && dialogsComplete == dialogsTotal }
    }

    /// Session-scoped failure count, for tests and diagnostics.
    var repairFailures: Int { sessionRepairFailures }

    struct AuditReport: Equatable {
        let missing: Int
        let orphaned: Int
        let stale: Int
        var isClean: Bool { missing == 0 && orphaned == 0 && stale == 0 }
    }

    /// Repair attempts that actually *failed*, this session only.
    ///
    /// Deliberately not the persisted `rebuild_count`, which counts every discard — including the
    /// intentional ones from an integrity recovery or a schema-version change. Gating on that
    /// number means a handful of legitimate rebuilds permanently disable search on a device whose
    /// index is fine. Scoping to the session also gives a relaunch a clean try, which matters
    /// because the usual cause of a failed build is an app update away from being fixed.
    static let maximumSessionRepairFailures = 3

    private let store: CloudLocalStore
    private let signposter = OSSignposter(subsystem: "com.toj.Toj", category: "SearchIndex")

    /// In flight repair, if any. Repair is expensive and idempotent, so concurrent callers join the
    /// running one rather than starting a second — several queries can fail on the same corruption
    /// within milliseconds, and each would otherwise drop and recreate the table under the others.
    private var repairTask: Task<Void, Never>?
    private var sessionRepairFailures = 0

    init(store: CloudLocalStore) {
        self.store = store
    }

    private nonisolated var dbQueue: DatabasePool { store.dbQueue }

    // MARK: - Bootstrap

    /// Creates the index if it is absent and reconciles it with the current normalizer.
    ///
    /// Never throws. A failure here means search is off, which is a degraded feature, not a broken
    /// app — and the caller is a detached background task with nobody to report to.
    func bootstrap() async {
        do {
            let state = try await readState()

            let existing = try await dbQueue.read { db in
                try db.tableExists("message_search")
            }

            if !existing {
                try await createIndex()
            } else if state.indexSchemaVersion != Self.indexSchemaVersion {
                // The column layout moved. Contentless tables cannot rebuild in place.
                try await dbQueue.write { db in
                    try SearchIndexSchema.discardIndex(db, reason: "index schema version changed")
                }
                try await createIndex()
            } else if state.normalizerVersion != SearchTextNormalizer.version {
                // Folding rules changed but the shape did not, so the index stays queryable while
                // every row is re-enqueued underneath it.
                try await dbQueue.write { db in
                    try db.execute(sql: """
                        INSERT INTO search_index_queue(client_msg_id, op)
                        SELECT client_msg_id, 'upsert' FROM messages WHERE true
                        ON CONFLICT(client_msg_id) DO UPDATE SET op = 'upsert'
                        """)
                    try db.execute(sql: """
                        UPDATE search_index_state
                           SET normalizer_version = ?, updated_at = datetime('now')
                         WHERE id = 1
                        """, arguments: [SearchTextNormalizer.version])
                }
            }

            try await seedBackfill()
            try await setStatus(.ready)
        } catch {
            try? await markUnavailable(error)
        }
    }

    /// Bumped when the virtual table's columns change, forcing a drop-and-rebuild.
    static let indexSchemaVersion = 1

    private func createIndex() async throws {
        try await dbQueue.write { db in
            guard try SearchIndexSchema.supportsContentlessDelete(db) else {
                throw SearchIndexError.unsupportedBuild
            }
            try SearchIndexSchema.createVirtualTable(db)
            try db.execute(sql: """
                UPDATE search_index_state
                   SET index_schema_version = ?, normalizer_version = ?, status = 'bootstrapping',
                       last_error = NULL, updated_at = datetime('now')
                 WHERE id = 1
                """, arguments: [Self.indexSchemaVersion, SearchTextNormalizer.version])
        }
    }

    /// One row per dialog, so the backfill has somewhere to record its cursor. Cheap: dialogs are
    /// counted in hundreds, not hundreds of thousands.
    private func seedBackfill() async throws {
        try await dbQueue.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO search_backfill_state (dialog_id, next_before_msg_id, completed)
                SELECT dialog_id, NULL, 0 FROM dialogs
                """)
        }
    }

    // MARK: - Draining

    /// Applies pending queue entries. Returns what it did so a caller can loop until idle.
    @discardableResult
    func drain(budget: Int = SearchIndexer.defaultBudget) async throws -> DrainOutcome {
        guard try await readState().status == .ready else {
            return DrainOutcome(indexed: 0, removed: 0, hasMore: false)
        }
        let interval = signposter.beginInterval("SearchIndexDrain")
        defer { signposter.endInterval("SearchIndexDrain", interval) }

        do {
            return try await dbQueue.write { db in try Self.drainBatch(db, budget: budget) }
        } catch {
            try await handleIndexFailure(error)
            throw error
        }
    }

    /// Drains only when the backlog is small enough to sit in front of a query.
    ///
    /// Called immediately before a search so a message the user just sent is findable. Past the
    /// threshold the backlog belongs to the background drain; blocking a keystroke on it would
    /// trade a correct-but-slow search for an unusable one.
    func drainIfShallow(maxDepth: Int = SearchIndexer.shallowQueueDepth) async throws {
        let depth = try await dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM search_index_queue") ?? 0
        }
        guard depth > 0, depth <= maxDepth else { return }
        _ = try await drain(budget: maxDepth)
    }

    private static func drainBatch(_ db: Database, budget: Int) throws -> DrainOutcome {
        let entries = try Row.fetchAll(db, sql: """
            SELECT client_msg_id, op FROM search_index_queue
            ORDER BY enqueued_at, client_msg_id LIMIT ?
            """, arguments: [budget])
        guard !entries.isEmpty else { return DrainOutcome(indexed: 0, removed: 0, hasMore: false) }

        var indexed = 0
        var removed = 0
        for entry in entries {
            let clientMsgId: String = entry["client_msg_id"]
            if entry["op"] as String == "delete" {
                try removeDoc(db, clientMsgId: clientMsgId)
                removed += 1
            } else if try indexMessage(db, clientMsgId: clientMsgId) {
                indexed += 1
            } else {
                // Not indexable — service message, deleted, or gone. Any doc it had must go too.
                try removeDoc(db, clientMsgId: clientMsgId)
                removed += 1
            }
            try db.execute(
                sql: "DELETE FROM search_index_queue WHERE client_msg_id = ?", arguments: [clientMsgId]
            )
        }

        try db.execute(sql: """
            UPDATE search_index_state
               SET indexed_count = (SELECT count(*) FROM message_search_docs),
                   deletes_since_merge = deletes_since_merge + ?,
                   updated_at = datetime('now')
             WHERE id = 1
            """, arguments: [removed])

        let remaining = try Int.fetchOne(db, sql: "SELECT count(*) FROM search_index_queue") ?? 0
        return DrainOutcome(indexed: indexed, removed: removed, hasMore: remaining > 0)
    }

    // MARK: - Row indexing

    /// Writes one message into the index. Returns false when the message should not be indexed at
    /// all, which the caller turns into a removal.
    @discardableResult
    static func indexMessage(_ db: Database, clientMsgId: String) throws -> Bool {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT m.local_id, m.dialog_id, m.msg_id, m.sender_account_id, m.kind, m.text,
                   m.state, m.edit_version, m.server_ts,
                   (SELECT group_concat(mm.file_name, ' ') FROM message_media mm
                     WHERE mm.local_id = m.local_id) AS file_names,
                   (SELECT count(*) FROM message_media mm WHERE mm.local_id = m.local_id) AS media_count,
                   d.access_state
              FROM messages m
              LEFT JOIN dialogs d ON d.dialog_id = m.dialog_id
             WHERE m.client_msg_id = ?
            """, arguments: [clientMsgId])
        else { return false }

        let state: String = row["state"]
        let kind: String = row["kind"]
        let accessState: String? = row["access_state"]

        // Service rows carry generated text, not something a user wrote; deleted rows must not stay
        // searchable; a revoked group's contents must disappear with its access.
        guard state == "visible", kind != "service",
              accessState == nil || accessState == "active" || accessState == "pending"
        else { return false }

        let body: String = row["text"]
        let fileName: String = row["file_names"] ?? ""
        let links = Self.extractLinks(from: body)
        let linkText = links.map { "\($0.host) \($0.path)" }.joined(separator: " ")

        let docId = try upsertDoc(db, clientMsgId: clientMsgId, row: row, links: links)

        // Delete-then-insert: contentless FTS5 has no UPDATE, and a stale posting would keep the
        // pre-edit text findable.
        try db.execute(sql: "DELETE FROM message_search WHERE rowid = ?", arguments: [docId])
        try db.execute(
            sql: """
                INSERT INTO message_search(
                    rowid, exact, file_name, link_text,
                    folded, file_name_folded, link_text_folded, dialog_token
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                docId,
                SearchTextNormalizer.exact(body),
                SearchTextNormalizer.exact(fileName),
                SearchTextNormalizer.exact(linkText),
                // Written unconditionally: see SearchIndexSchema on why sparse folded columns break
                // the folded tier asymmetrically.
                SearchTextNormalizer.foldedForm(body),
                SearchTextNormalizer.foldedForm(fileName),
                SearchTextNormalizer.foldedForm(linkText),
                SearchPatternBuilder.dialogToken(row["dialog_id"]),
            ]
        )
        return true
    }

    private static func upsertDoc(
        _ db: Database, clientMsgId: String, row: Row, links: [(host: String, path: String, url: String)]
    ) throws -> Int64 {
        try db.execute(
            sql: """
                INSERT INTO message_search_docs (
                    client_msg_id, local_id, dialog_id, msg_id, sender_account_id, kind,
                    state, edit_version, sort_ts, has_media, link_count
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(client_msg_id) DO UPDATE SET
                    local_id = excluded.local_id, dialog_id = excluded.dialog_id,
                    msg_id = excluded.msg_id, sender_account_id = excluded.sender_account_id,
                    kind = excluded.kind, state = excluded.state,
                    edit_version = excluded.edit_version, sort_ts = excluded.sort_ts,
                    has_media = excluded.has_media, link_count = excluded.link_count
                """,
            arguments: [
                clientMsgId, row["local_id"], row["dialog_id"], row["msg_id"],
                row["sender_account_id"], row["kind"], row["state"], row["edit_version"],
                Self.sortTimestamp(row["server_ts"]),
                (row["media_count"] as Int? ?? 0) > 0 ? 1 : 0,
                links.count,
            ]
        )
        let docId = try Int64.fetchOne(
            db, sql: "SELECT doc_id FROM message_search_docs WHERE client_msg_id = ?",
            arguments: [clientMsgId]
        ) ?? 0

        try db.execute(sql: "DELETE FROM message_links WHERE doc_id = ?", arguments: [docId])
        for (position, link) in links.enumerated() {
            try db.execute(
                sql: "INSERT INTO message_links(doc_id, position, url, host) VALUES (?, ?, ?, ?)",
                arguments: [docId, position, link.url, link.host]
            )
        }
        return docId
    }

    private static func removeDoc(_ db: Database, clientMsgId: String) throws {
        guard let docId = try Int64.fetchOne(
            db, sql: "SELECT doc_id FROM message_search_docs WHERE client_msg_id = ?",
            arguments: [clientMsgId]
        ) else { return }
        try db.execute(sql: "DELETE FROM message_search WHERE rowid = ?", arguments: [docId])
        try db.execute(sql: "DELETE FROM message_search_docs WHERE doc_id = ?", arguments: [docId])
    }

    /// Epoch milliseconds, because `server_ts` is stored in more than one format and ordering must
    /// key on time rather than on `doc_id` — a backfilled 2019 message gets a *higher* doc id than
    /// one sent today.
    static func sortTimestamp(_ raw: String?) -> Int64 {
        guard let raw, !raw.isEmpty else { return 0 }
        for formatter in [isoFormatter, isoFractionalFormatter] {
            if let date = formatter.date(from: raw) { return Int64(date.timeIntervalSince1970 * 1000) }
        }
        if let date = sqliteFormatter.date(from: raw) {
            return Int64(date.timeIntervalSince1970 * 1000)
        }
        return 0
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let isoFractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let sqliteFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func extractLinks(from text: String) -> [(host: String, path: String, url: String)] {
        guard let linkDetector, !text.isEmpty else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return linkDetector.matches(in: text, range: range).compactMap { match in
            guard let url = match.url, let host = url.host() else { return nil }
            return (host: host, path: url.path(), url: url.absoluteString)
        }
    }

    // MARK: - Backfill

    /// Indexes one page of history. Returns true while work remains.
    ///
    /// Walks dialogs most-recently-active first, and newest-first within a dialog, so a device that
    /// has already pulled years of history indexes what the user is likely to search before what
    /// they are not.
    @discardableResult
    func backfillStep(budget: Int = SearchIndexer.defaultBudget) async throws -> Bool {
        guard try await readState().status == .ready else { return false }
        let interval = signposter.beginInterval("SearchIndexBackfill")
        defer { signposter.endInterval("SearchIndexBackfill", interval) }

        return try await dbQueue.write { db in
            guard let target = try Row.fetchOne(db, sql: """
                SELECT b.dialog_id, b.next_before_msg_id, b.pending_swept
                  FROM search_backfill_state b
                  JOIN dialogs d ON d.dialog_id = b.dialog_id
                 WHERE b.completed = 0
                 ORDER BY d.updated_at DESC
                 LIMIT 1
                """) else { return false }

            let dialogId: String = target["dialog_id"]
            let before: Int64? = target["next_before_msg_id"]

            // Optimistic rows have no msg_id, so the descending walk never reaches them. They are
            // few, and only pre-existing ones matter because new ones are trigger-covered.
            if target["pending_swept"] as Int? ?? 0 == 0 {
                try db.execute(sql: """
                    INSERT INTO search_index_queue(client_msg_id, op)
                    SELECT client_msg_id, 'upsert' FROM messages
                     WHERE dialog_id = ? AND msg_id IS NULL
                    ON CONFLICT(client_msg_id) DO UPDATE SET op = 'upsert'
                    """, arguments: [dialogId])
                try db.execute(sql: """
                    UPDATE search_backfill_state SET pending_swept = 1 WHERE dialog_id = ?
                    """, arguments: [dialogId])
            }

            let rows = try Row.fetchAll(db, sql: """
                SELECT client_msg_id, msg_id FROM messages
                 WHERE dialog_id = ? AND msg_id IS NOT NULL
                   AND (? IS NULL OR msg_id < ?)
                 ORDER BY msg_id DESC LIMIT ?
                """, arguments: [dialogId, before, before, budget])

            if rows.isEmpty {
                try db.execute(sql: """
                    UPDATE search_backfill_state SET completed = 1 WHERE dialog_id = ?
                    """, arguments: [dialogId])
                return true  // Another dialog may still need work.
            }

            for row in rows {
                let clientMsgId: String = row["client_msg_id"]
                if try !Self.indexMessage(db, clientMsgId: clientMsgId) {
                    try Self.removeDoc(db, clientMsgId: clientMsgId)
                }
            }

            let lowest = rows.compactMap { $0["msg_id"] as Int64? }.min()
            try db.execute(sql: """
                UPDATE search_backfill_state
                   SET next_before_msg_id = ?, completed = ?
                 WHERE dialog_id = ?
                """, arguments: [lowest, rows.count < budget ? 1 : 0, dialogId])
            try db.execute(sql: """
                UPDATE search_index_state
                   SET indexed_count = (SELECT count(*) FROM message_search_docs),
                       updated_at = datetime('now')
                 WHERE id = 1
                """)
            return true
        }
    }

    // MARK: - Maintenance, audit, repair

    /// Bounded tombstone merge. The negative rank caps pages touched, so this is safe between
    /// batches; `'optimize'` is O(index) and belongs in a background task, never here.
    func runMaintenance() async throws {
        guard try await readState().status == .ready else { return }
        try await dbQueue.write { db in
            let pending = try Int.fetchOne(
                db, sql: "SELECT deletes_since_merge FROM search_index_state WHERE id = 1"
            ) ?? 0
            guard pending > Self.deletesBeforeMerge else { return }
            try db.execute(sql: "INSERT INTO message_search(message_search, rank) VALUES('merge', -64)")
            try db.execute(sql: """
                UPDATE search_index_state
                   SET deletes_since_merge = 0, last_optimized_at = datetime('now')
                 WHERE id = 1
                """)
        }
    }

    /// Finds and repairs drift between `messages` and the index.
    ///
    /// The triggers make drift nearly impossible, which is exactly why this exists: "nearly" is not
    /// a guarantee, and a silent divergence is invisible until a user's search misses a message.
    /// The stale check is the regression detector for a write path that somehow bypassed a trigger.
    @discardableResult
    func audit() async throws -> AuditReport {
        guard try await readState().status == .ready else { return AuditReport(missing: 0, orphaned: 0, stale: 0) }

        return try await dbQueue.write { db in
            // FTS5's own consistency. A throw here means the index itself is damaged.
            try db.execute(sql: "INSERT INTO message_search(message_search) VALUES('integrity-check')")

            // Indexable rows with no doc, inside territory the backfill claims to have finished.
            let missing = try String.fetchAll(db, sql: """
                SELECT m.client_msg_id FROM messages m
                  JOIN search_backfill_state b ON b.dialog_id = m.dialog_id AND b.completed = 1
                  LEFT JOIN message_search_docs x ON x.client_msg_id = m.client_msg_id
                 WHERE x.client_msg_id IS NULL AND m.state = 'visible' AND m.kind <> 'service'
                 LIMIT 500
                """)

            // Docs whose message is gone.
            let orphaned = try String.fetchAll(db, sql: """
                SELECT x.client_msg_id FROM message_search_docs x
                  LEFT JOIN messages m ON m.client_msg_id = x.client_msg_id
                 WHERE m.client_msg_id IS NULL LIMIT 500
                """)

            // Docs that disagree with their message about anything the index depends on.
            let stale = try String.fetchAll(db, sql: """
                SELECT m.client_msg_id FROM messages m
                  JOIN message_search_docs x ON x.client_msg_id = m.client_msg_id
                 WHERE x.edit_version <> m.edit_version OR x.state <> m.state
                    OR x.local_id <> m.local_id
                    OR (x.msg_id IS NULL) <> (m.msg_id IS NULL)
                    OR (x.msg_id IS NOT NULL AND m.msg_id IS NOT NULL AND x.msg_id <> m.msg_id)
                 LIMIT 500
                """)

            for clientMsgId in missing + stale {
                try db.execute(sql: """
                    INSERT INTO search_index_queue(client_msg_id, op) VALUES (?, 'upsert')
                    ON CONFLICT(client_msg_id) DO UPDATE SET op = 'upsert'
                    """, arguments: [clientMsgId])
            }
            for clientMsgId in orphaned {
                try Self.removeDoc(db, clientMsgId: clientMsgId)
            }
            try db.execute(sql: """
                UPDATE search_index_state SET last_audit_at = datetime('now') WHERE id = 1
                """)

            return AuditReport(missing: missing.count, orphaned: orphaned.count, stale: stale.count)
        }
    }

    /// Discards and rebuilds the index from `messages`.
    ///
    /// Single-flight: concurrent callers await the repair already running instead of starting
    /// another. Never throws — repair is the last resort, and a failure here means search stays off
    /// rather than that anything else breaks.
    func repair() async {
        if let repairTask {
            await repairTask.value
            return
        }
        let task = Task { await self.performRepair() }
        repairTask = task
        await task.value
        repairTask = nil
    }

    private func performRepair() async {
        do {
            try await setStatus(.rebuilding)
            try await dbQueue.write { db in
                try SearchIndexSchema.discardIndex(db, reason: "repair")
            }
            try await createIndex()
            try await seedBackfill()
            try await setStatus(.ready)
            sessionRepairFailures = 0
        } catch {
            sessionRepairFailures += 1
            if sessionRepairFailures >= Self.maximumSessionRepairFailures {
                try? await markUnavailable(error)
            } else {
                // Leave the status alone so a later attempt can still run; the index is absent, so
                // queries find nothing rather than wrong things.
                try? await recordError(error)
            }
        }
    }

    // MARK: - Coverage and state

    func coverage() async throws -> Coverage {
        try await dbQueue.read { db in
            let state = try Row.fetchOne(db, sql: "SELECT * FROM search_index_state WHERE id = 1")
            return Coverage(
                status: Status(rawValue: state?["status"] ?? "") ?? .bootstrapping,
                indexed: state?["indexed_count"] ?? 0,
                total: try Int.fetchOne(db, sql: """
                    SELECT count(*) FROM messages WHERE state = 'visible' AND kind <> 'service'
                    """) ?? 0,
                queueDepth: try Int.fetchOne(db, sql: "SELECT count(*) FROM search_index_queue") ?? 0,
                dialogsComplete: try Int.fetchOne(
                    db, sql: "SELECT count(*) FROM search_backfill_state WHERE completed = 1") ?? 0,
                dialogsTotal: try Int.fetchOne(db, sql: "SELECT count(*) FROM search_backfill_state") ?? 0
            )
        }
    }

    private struct State {
        let status: Status
        let indexSchemaVersion: Int
        let normalizerVersion: Int
        let rebuildCount: Int
        let lastError: String?
    }

    private func readState() async throws -> State {
        try await dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM search_index_state WHERE id = 1")
            else { return State(status: .bootstrapping, indexSchemaVersion: 0, normalizerVersion: 0, rebuildCount: 0, lastError: nil) }
            return State(
                status: Status(rawValue: row["status"] ?? "") ?? .bootstrapping,
                indexSchemaVersion: row["index_schema_version"] ?? 0,
                normalizerVersion: row["normalizer_version"] ?? 0,
                rebuildCount: row["rebuild_count"] ?? 0,
                lastError: row["last_error"]
            )
        }
    }

    private func setStatus(_ status: Status) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: """
                UPDATE search_index_state SET status = ?, updated_at = datetime('now') WHERE id = 1
                """, arguments: [status.rawValue])
        }
    }

    private func markUnavailable(_ error: Error) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: """
                UPDATE search_index_state
                   SET status = 'unavailable', last_error = ?, updated_at = datetime('now')
                 WHERE id = 1
                """, arguments: ["\(error)"])
        }
    }

    /// Routes a query-time failure to repair when it looks like index damage, and re-raises
    /// otherwise. Nothing outside the search layer joins `message_search`, so corruption here can
    /// never propagate into a read path that matters.
    private func handleIndexFailure(_ error: Error) async throws {
        guard Self.isIndexCorruption(error) else { return }
        guard sessionRepairFailures < Self.maximumSessionRepairFailures else {
            try await markUnavailable(error)
            return
        }
        // Detached so the failing query returns now; the caller is already handling an error and
        // does not need to wait for a rebuild. `repair()` is single-flight, so a burst of failing
        // queries produces one rebuild.
        Task { await self.repair() }
    }

    /// Records a failure without declaring the index permanently unavailable.
    private func recordError(_ error: Error) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: """
                UPDATE search_index_state SET last_error = ?, updated_at = datetime('now')
                 WHERE id = 1
                """, arguments: ["\(error)"])
        }
    }

    static func isIndexCorruption(_ error: Error) -> Bool {
        if let dbError = error as? DatabaseError {
            if dbError.resultCode == .SQLITE_CORRUPT { return true }
            let message = dbError.message ?? ""
            return message.contains("database disk image is malformed")
                || message.contains("no such table: message_search")
                || message.contains("fts5: ")
        }
        return false
    }
}

enum SearchIndexError: Error {
    /// FTS5 is missing, or SQLCipher predates `contentless_delete`.
    case unsupportedBuild
}
