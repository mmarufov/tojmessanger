import GRDB
import XCTest
@testable import Toj

/// Covers the v12 migration, the enqueue triggers, and everything the indexer does when things go
/// wrong.
///
/// Built on real `CloudLocalStore` instances against temp directories, the same way
/// `CloudLocalStoreTests` works, because the triggers and the migration are the subject — a mock
/// database would test the mock.
final class SearchIndexerTests: XCTestCase {
    private var directory: URL!
    private var store: CloudLocalStore!
    private var indexer: SearchIndexer!

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try CloudLocalStore(
            path: directory.appending(path: "cloud.sqlite").path,
            key: Data(repeating: 0x42, count: 32)
        )
        indexer = SearchIndexer(store: store)
    }

    override func tearDown() async throws {
        indexer = nil
        store = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try await super.tearDown()
    }

    // MARK: - Migration

    /// The migration must not create the virtual table. A throwing migration makes
    /// `CloudLocalStore.init` throw, which routes into quarantine — over derived data.
    func testMigrationIsDDLOnlyAndCreatesNoVirtualTable() async throws {
        try await store.dbQueue.read { db in
            for table in ["message_search_docs", "message_links", "search_index_queue",
                          "search_backfill_state", "search_index_state"] {
                XCTAssertTrue(try db.tableExists(table), "\(table) missing")
            }
            XCTAssertFalse(
                try db.tableExists("message_search"),
                "the migration must leave the virtual table to the indexer"
            )
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT count(*) FROM search_index_state"), 1,
                "the singleton state row is seeded"
            )
        }
    }

    func testMigrationRegistersEveryEnqueueTrigger() async throws {
        let triggers = try await store.dbQueue.read { db in
            try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master WHERE type = 'trigger'
                  AND name LIKE 'search_queue_%' ORDER BY name
                """)
        }
        XCTAssertEqual(triggers, [
            // Access changes matter as much as message changes: a revocation must reach the index,
            // and a regrant must bring the conversation back.
            "search_queue_dialog_access_au",
            "search_queue_media_ad", "search_queue_media_ai", "search_queue_media_au",
            "search_queue_messages_ad", "search_queue_messages_ai", "search_queue_messages_au",
        ])
    }

    /// The triggers must work before the index exists, or the queue would drop everything written
    /// between migration and bootstrap.
    func testTriggersEnqueueBeforeTheIndexExists() async throws {
        try await insertMessage(clientMsgId: "c1", text: "салом ҷони ман")
        let queued = try await queueEntries()
        XCTAssertEqual(queued, [["c1", "upsert"]])
    }

    func testTriggersCollapseRepeatedEditsIntoOneEntry() async throws {
        try await insertMessage(clientMsgId: "c1", text: "first")
        try await store.dbQueue.write { db in
            for version in 1...5 {
                try db.execute(
                    sql: "UPDATE messages SET text = ?, edit_version = ? WHERE client_msg_id = 'c1'",
                    arguments: ["edit \(version)", version]
                )
            }
        }
        let actual1 = try await queueEntries().count
        XCTAssertEqual(actual1, 1, "the queue is a set keyed by message")
    }

    func testDeleteTriggerEnqueuesARemoval() async throws {
        try await insertMessage(clientMsgId: "c1", text: "secret")
        try await bootstrapAndDrain()
        try await store.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM messages WHERE client_msg_id = 'c1'")
        }
        let actual2 = try await queueEntries()
        XCTAssertEqual(actual2, [["c1", "delete"]])
    }

    func testMediaTriggerEnqueuesTheOwningMessage() async throws {
        try await insertMessage(clientMsgId: "c1", text: "see attached")
        try await bootstrapAndDrain()
        try await store.dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO message_media(local_id, dialog_id, msg_id, media_id, kind, content_type,
                                          file_name, byte_size, has_thumbnail)
                VALUES ('d1:1', 'd1', 1, 'm1', 'file', 'application/pdf', 'ҳисобот.pdf', 10, 0)
                """)
        }
        let actual3 = try await queueEntries()
        XCTAssertEqual(actual3, [["c1", "upsert"]], "a filename change reindexes")
    }

    // MARK: - Indexing lifecycle

    func testBootstrapCreatesTheIndexAndDrainMakesMessagesSearchable() async throws {
        try await insertMessage(clientMsgId: "c1", text: "салом ҷони ман")
        await indexer.bootstrap()

        let created = try await store.dbQueue.read { try $0.tableExists("message_search") }
        XCTAssertTrue(created)
        let actual4 = try await indexer.coverage().status
        XCTAssertEqual(actual4, .ready)

        let outcome = try await indexer.drain()
        XCTAssertEqual(outcome.indexed, 1)
        let actual5 = try await searchRowids("чони")
        XCTAssertEqual(actual5, [1], "folded tier reaches the Tajik spelling")
    }

    func testEditRemovesTheOldTermAndAddsTheNew() async throws {
        try await insertMessage(clientMsgId: "c1", text: "original")
        try await bootstrapAndDrain()
        let actual6 = try await searchRowids("original").count
        XCTAssertEqual(actual6, 1)

        try await store.dbQueue.write { db in
            try db.execute(sql: """
                UPDATE messages SET text = 'replacement', edit_version = 1 WHERE client_msg_id = 'c1'
                """)
        }
        _ = try await indexer.drain()

        let actual7 = try await searchRowids("original").isEmpty
        XCTAssertTrue(actual7, "pre-edit text stayed searchable")
        let actual8 = try await searchRowids("replacement").count
        XCTAssertEqual(actual8, 1)
    }

    func testDeletedForAllIsRemovedFromTheIndex() async throws {
        try await insertMessage(clientMsgId: "c1", text: "конфиденциально")
        try await bootstrapAndDrain()
        let actual9 = try await searchRowids("конфиденциально").count
        XCTAssertEqual(actual9, 1)

        try await store.dbQueue.write { db in
            try db.execute(sql: "UPDATE messages SET state = 'deleted_for_all' WHERE client_msg_id = 'c1'")
        }
        _ = try await indexer.drain()
        let actual10 = try await searchRowids("конфиденциально").isEmpty
        XCTAssertTrue(actual10, "deleted text must not remain searchable")
    }

    func testServiceMessagesAreNeverIndexed() async throws {
        try await insertMessage(clientMsgId: "c1", text: "added to the group", kind: "service")
        try await bootstrapAndDrain()
        let actual11 = try await searchRowids("added").isEmpty
        XCTAssertTrue(actual11)
    }

    /// `markSent` rewrites `local_id`, so keying on it would orphan the doc. `client_msg_id` is
    /// stable across the rewrite.
    func testLocalIdRewriteKeepsTheSameDocAndPicksUpTheMsgId() async throws {
        try await insertMessage(clientMsgId: "c1", text: "pending message", localId: "pending:c1", msgId: nil)
        try await bootstrapAndDrain()
        let firstDoc = try await docId(for: "c1")

        try await store.dbQueue.write { db in
            try db.execute(sql: """
                UPDATE messages SET local_id = 'd1:7', msg_id = 7 WHERE client_msg_id = 'c1'
                """)
        }
        _ = try await indexer.drain()

        let actual12 = try await docId(for: "c1")
        XCTAssertEqual(actual12, firstDoc, "the doc identity must survive the rewrite")
        try await store.dbQueue.read { db in
            XCTAssertEqual(
                try Int64.fetchOne(
                    db, sql: "SELECT msg_id FROM message_search_docs WHERE client_msg_id = 'c1'"), 7
            )
        }
        let actual13 = try await searchRowids("pending").count
        XCTAssertEqual(actual13, 1)
    }

    /// Revocation goes through the production `revokeGroupAccess`, not a hand-seeded queue entry.
    ///
    /// Two separate guarantees, and the test asserts both because either alone is insufficient:
    /// the query filter hides content the instant `access_state` flips, and the index removal makes
    /// that durable — the FTS table holds the message text itself, so a filter is only a promise
    /// the next query has to keep.
    func testRevokeGroupAccessHidesAndThenRemovesContent() async throws {
        try await insertMessage(clientMsgId: "c1", text: "groupsecret", localId: "d1:1", msgId: 1)
        try await bootstrapAndDrain()
        let before = try await searchRowids("groupsecret").count
        XCTAssertEqual(before, 1)

        try await store.revokeGroupAccess(dialogId: "d1", reason: "removed by owner")

        // Immediate: the production query filters on access_state, before any drain runs.
        let visibleImmediately = try await store.searchMessages(
            MessageSearchRequest(query: "groupsecret")
        ).hits
        XCTAssertTrue(visibleImmediately.isEmpty, "revoked content must vanish from results at once")

        // Durable: the real path enqueued removals, so the text leaves the index too.
        let queued = try await queueEntries()
        XCTAssertEqual(queued, [["c1", "delete"]], "revocation enqueues removal via the trigger")

        _ = try await indexer.drain()
        let indexed = try await searchRowids("groupsecret")
        XCTAssertTrue(indexed.isEmpty, "revoked message text must not remain in the index")
    }

    /// Re-adding a member must bring their history back, or a regrant silently leaves the
    /// conversation unsearchable forever.
    func testGroupRegrantRestoresSearchability() async throws {
        try await insertMessage(clientMsgId: "c1", text: "groupsecret", localId: "d1:1", msgId: 1)
        try await bootstrapAndDrain()

        try await store.revokeGroupAccess(dialogId: "d1", reason: "removed by owner")
        _ = try await indexer.drain()
        let afterRevoke = try await searchRowids("groupsecret")
        XCTAssertTrue(afterRevoke.isEmpty)

        // The acked archive survives revocation until the purge finalizes, so a regrant before then
        // has something to restore. This is the same UPDATE the grant path issues.
        try await store.dbQueue.write { db in
            try db.execute(sql: """
                UPDATE dialogs SET access_state = 'active', updated_at = datetime('now')
                 WHERE dialog_id = 'd1'
                """)
        }
        let requeued = try await queueEntries()
        XCTAssertEqual(requeued, [["c1", "upsert"]], "regrant re-enqueues the dialog")

        _ = try await indexer.drain()
        let restored = try await searchMessagesText("groupsecret")
        XCTAssertEqual(restored, ["groupsecret"], "a re-added member sees their history again")
    }

    /// Revocation also rewinds the backfill cursor, so history that was never indexed the first
    /// time is not skipped after a regrant.
    func testRegrantRewindsTheBackfillCursor() async throws {
        try await insertMessage(clientMsgId: "c1", text: "history", localId: "d1:1", msgId: 1)
        await indexer.bootstrap()
        while try await indexer.backfillStep() {}
        let completedBefore = try await store.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT completed FROM search_backfill_state WHERE dialog_id = 'd1'")
        }
        XCTAssertEqual(completedBefore, 1)

        try await store.revokeGroupAccess(dialogId: "d1", reason: "removed")
        try await store.dbQueue.write { db in
            try db.execute(sql: "UPDATE dialogs SET access_state = 'active' WHERE dialog_id = 'd1'")
        }
        let completedAfter = try await store.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT completed FROM search_backfill_state WHERE dialog_id = 'd1'")
        }
        XCTAssertEqual(completedAfter, 0, "a regranted dialog must be walked again")
    }

    // MARK: - Repair

    /// Several queries can fail on the same corruption within milliseconds. Without single-flight
    /// each would drop and recreate the table under the others.
    func testConcurrentRepairsCollapseIntoOne() async throws {
        try await insertMessage(clientMsgId: "c1", text: "survivor", localId: "d1:1", msgId: 1)
        try await bootstrapAndDrain()

        let before = try await store.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT rebuild_count FROM search_index_state WHERE id = 1") ?? 0
        }
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 { group.addTask { await self.indexer.repair() } }
        }
        let after = try await store.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT rebuild_count FROM search_index_state WHERE id = 1") ?? 0
        }

        XCTAssertLessThanOrEqual(
            after - before, 2,
            "eight concurrent repairs must not produce eight rebuilds"
        )
        let status = try await indexer.coverage().status
        XCTAssertEqual(status, .ready)
    }

    /// An intentional discard is not a repair failure. Gating on the persisted `rebuild_count`
    /// meant a few legitimate rebuilds could permanently disable search on a healthy device.
    func testIntentionalDiscardsDoNotCountAsRepairFailures() async throws {
        try await insertMessage(clientMsgId: "c1", text: "survivor", localId: "d1:1", msgId: 1)
        try await bootstrapAndDrain()

        for reason in ["integrity recovery", "replica wipe", "index schema version changed"] {
            try await store.dbQueue.write { db in
                try SearchIndexSchema.discardIndex(db, reason: reason)
            }
            await indexer.bootstrap()
        }

        let failures = await indexer.repairFailures
        XCTAssertEqual(failures, 0, "discards are not failures")
        let status = try await indexer.coverage().status
        XCTAssertEqual(status, .ready, "three deliberate discards must leave search working")

        let recorded = try await store.dbQueue.read { db in
            try String.fetchOne(
                db, sql: "SELECT last_discard_reason FROM search_index_state WHERE id = 1")
        }
        XCTAssertEqual(recorded, "index schema version changed", "the reason is recorded separately")
        let lastError = try await store.dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT last_error FROM search_index_state WHERE id = 1")
        }
        XCTAssertNil(lastError, "a deliberate discard must not look like an error")
    }

    // MARK: - Backfill

    func testBackfillIndexesExistingHistoryAndIsResumable() async throws {
        for index in 1...12 {
            try await insertMessage(
                clientMsgId: "c\(index)", text: "history item \(index)",
                localId: "d1:\(index)", msgId: Int64(index)
            )
        }
        await indexer.bootstrap()
        // Clear the queue so only the backfill can account for what gets indexed.
        try await store.dbQueue.write { db in try db.execute(sql: "DELETE FROM search_index_queue") }

        var steps = 0
        while try await indexer.backfillStep(budget: 5), steps < 20 { steps += 1 }

        let coverage = try await indexer.coverage()
        XCTAssertEqual(coverage.indexed, 12, "every message ends up indexed")
        XCTAssertEqual(coverage.dialogsComplete, coverage.dialogsTotal)
        let actual16 = try await searchRowids("history").count
        XCTAssertEqual(actual16, 12)
    }

    func testBackfillSweepsPendingRowsThatTheDescendingWalkMisses() async throws {
        try await insertMessage(clientMsgId: "sent", text: "acked", localId: "d1:1", msgId: 1)
        try await insertMessage(clientMsgId: "pending", text: "unacked", localId: "pending:x", msgId: nil)
        await indexer.bootstrap()
        try await store.dbQueue.write { db in try db.execute(sql: "DELETE FROM search_index_queue") }

        _ = try await indexer.backfillStep()
        _ = try await indexer.drain()   // the sweep enqueues; the drain applies

        let actual17 = try await searchRowids("unacked").count
        XCTAssertEqual(actual17, 1, "pending rows must be reachable")
    }

    // MARK: - Corruption safety

    /// The single most important behaviour here: a corrupt derived index must not cost the user
    /// their chats.
    func testCorruptIndexIsRecoveredWithoutQuarantiningTheReplica() async throws {
        try await insertMessage(clientMsgId: "c1", text: "survivor")
        try await bootstrapAndDrain()

        try await store.dbQueue.write { db in
            // Damage the FTS shadow table the way real corruption would.
            try db.execute(sql: "UPDATE message_search_data SET block = zeroblob(64) WHERE id > 1")
        }

        // The replica itself is still readable throughout.
        let messageCount = try await store.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM messages") ?? 0
        }
        XCTAssertEqual(messageCount, 1, "message data is untouched by index damage")

        await indexer.repair()
        let actual18 = try await indexer.coverage().status
        XCTAssertEqual(actual18, .ready)

        _ = try await indexer.backfillStep()
        let actual19 = try await searchRowids("survivor").count
        XCTAssertEqual(actual19, 1, "repair rebuilds from messages")
    }

    /// `verifyIntegrity` used to condemn the whole replica when `quick_check` tripped over the FTS
    /// shadow tables — losing every chat over rebuildable data.
    func testIntegrityRecoveryDiscardsTheIndexBeforeCondemningTheReplica() async throws {
        try await insertMessage(clientMsgId: "c1", text: "survivor")
        try await bootstrapAndDrain()

        // A healthy store passes and keeps its index.
        try await store.verifyIntegrity()
        let actual20 = try await store.dbQueue.read { try $0.tableExists("message_search") }
        XCTAssertTrue(actual20)

        // Data survives a forced discard, and the state records why.
        try await store.dbQueue.write { db in try SearchIndexSchema.discardIndex(db) }
        try await store.verifyIntegrity()
        let remaining = try await store.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM messages") ?? 0
        }
        XCTAssertEqual(remaining, 1, "discarding the index must never touch messages")
    }

    func testDiscardIndexClearsEveryDerivedTable() async throws {
        try await insertMessage(clientMsgId: "c1", text: "see https://example.com/report now")
        try await bootstrapAndDrain()
        try await store.dbQueue.read { db in
            XCTAssertGreaterThan(try Int.fetchOne(db, sql: "SELECT count(*) FROM message_links") ?? 0, 0)
        }

        try await store.dbQueue.write { db in try SearchIndexSchema.discardIndex(db) }
        try await store.dbQueue.read { db in
            XCTAssertFalse(try db.tableExists("message_search"))
            for table in ["message_search_docs", "message_links", "search_index_queue",
                          "search_backfill_state"] {
                XCTAssertEqual(
                    try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table)"), 0, "\(table) not cleared"
                )
            }
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT status FROM search_index_state WHERE id = 1"),
                "bootstrapping"
            )
        }
    }

    func testCorruptionClassificationRecognisesIndexDamage() {
        XCTAssertTrue(SearchIndexer.isIndexCorruption(
            DatabaseError(resultCode: .SQLITE_CORRUPT, message: "database disk image is malformed")))
        XCTAssertTrue(SearchIndexer.isIndexCorruption(
            DatabaseError(resultCode: .SQLITE_ERROR, message: "no such table: message_search")))
        XCTAssertFalse(SearchIndexer.isIndexCorruption(
            DatabaseError(resultCode: .SQLITE_CONSTRAINT, message: "UNIQUE constraint failed")))
    }

    // MARK: - Audit

    func testAuditRepairsMissingOrphanedAndStaleDocs() async throws {
        for index in 1...3 {
            try await insertMessage(
                clientMsgId: "c\(index)", text: "auditable \(index)",
                localId: "d1:\(index)", msgId: Int64(index)
            )
        }
        try await bootstrapAndDrain()
        while try await indexer.backfillStep() {}

        try await store.dbQueue.write { db in
            // Mutate the index behind the indexer's back, which is what drift looks like.
            try db.execute(sql: "DELETE FROM message_search_docs WHERE client_msg_id = 'c1'")
            try db.execute(sql: """
                INSERT INTO message_search_docs(client_msg_id, local_id, dialog_id, msg_id,
                    sender_account_id, kind, state, edit_version, sort_ts)
                VALUES ('ghost', 'x', 'd1', 99, 'a1', 'text', 'visible', 0, 0)
                """)
            try db.execute(sql: "UPDATE message_search_docs SET edit_version = 99 WHERE client_msg_id = 'c2'")
        }

        let report = try await indexer.audit()
        XCTAssertEqual(report.missing, 1)
        XCTAssertEqual(report.orphaned, 1)
        XCTAssertEqual(report.stale, 1)

        _ = try await indexer.drain()
        let actual21 = try await indexer.audit().isClean
        XCTAssertTrue(actual21, "audit must converge")
    }

    // MARK: - Timestamps

    /// Ordering keys on time, not doc id: a backfilled 2019 message gets a higher doc id than one
    /// sent today. `server_ts` appears in more than one format.
    func testSortTimestampParsesBothStoredFormats() {
        let iso = SearchIndexer.sortTimestamp("2026-07-12T09:00:00Z")
        let sqlite = SearchIndexer.sortTimestamp("2026-07-12 10:00:00")
        XCTAssertGreaterThan(iso, 0)
        XCTAssertGreaterThan(sqlite, iso, "10:00 must sort after 09:00 across formats")
        XCTAssertEqual(SearchIndexer.sortTimestamp(nil), 0)
        XCTAssertEqual(SearchIndexer.sortTimestamp("not a date"), 0)
    }

    func testLinkExtractionFeedsTheLinkColumns() async throws {
        try await insertMessage(clientMsgId: "c1", text: "docs at https://example.com/reports/2026 ok")
        try await bootstrapAndDrain()

        try await store.dbQueue.read { db in
            let host = try String.fetchOne(db, sql: "SELECT host FROM message_links LIMIT 1")
            XCTAssertEqual(host, "example.com")
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT link_count FROM message_search_docs WHERE client_msg_id = 'c1'"),
                1
            )
        }
        let actual22 = try await searchRowids("example").count
        XCTAssertEqual(actual22, 1, "link text is searchable")
    }

    // MARK: - Helpers

    private func bootstrapAndDrain() async throws {
        await indexer.bootstrap()
        _ = try await indexer.drain()
    }

    private func insertMessage(
        clientMsgId: String, text: String, kind: String = "text",
        localId: String? = nil, msgId: Int64? = 1, dialogId: String = "d1"
    ) async throws {
        try await store.dbQueue.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO dialogs(dialog_id, type, title, last_msg_id, updated_at)
                VALUES (?, 'group', 'Test', 0, datetime('now'))
                """, arguments: [dialogId])
            try db.execute(sql: """
                INSERT INTO messages(local_id, dialog_id, msg_id, client_msg_id, sender_account_id,
                                     kind, text, is_forwarded, edit_version, state, server_ts,
                                     local_state)
                VALUES (?, ?, ?, ?, 'a1', ?, ?, 0, 0, 'visible', '2026-07-12T09:00:00Z', 'sent')
                """, arguments: [localId ?? "\(dialogId):\(msgId ?? 0)", dialogId, msgId,
                                 clientMsgId, kind, text])
        }
    }

    private func queueEntries() async throws -> [[String]] {
        try await store.dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT client_msg_id, op FROM search_index_queue ORDER BY client_msg_id
                """).map { [$0["client_msg_id"], $0["op"]] }
        }
    }

    private func docId(for clientMsgId: String) async throws -> Int64? {
        try await store.dbQueue.read { db in
            try Int64.fetchOne(
                db, sql: "SELECT doc_id FROM message_search_docs WHERE client_msg_id = ?",
                arguments: [clientMsgId]
            )
        }
    }

    /// Text of every hit the production query API returns.
    private func searchMessagesText(_ query: String) async throws -> [String] {
        try await store.searchMessages(MessageSearchRequest(query: query)).hits.map(\.text)
    }

    /// Runs the shipped two-tier query and returns matching doc ids.
    private func searchRowids(_ query: String) async throws -> [Int64] {
        guard let plan = SearchPatternBuilder.prepare(query) else { return [] }
        return try await store.dbQueue.read { db in
            guard try db.tableExists("message_search") else { return [] }
            let sql = "SELECT rowid FROM message_search WHERE message_search MATCH ? ORDER BY rowid"
            let exact = try Int64.fetchAll(db, sql: sql, arguments: [plan.exactExpression])
            let folded = try Int64.fetchAll(db, sql: sql, arguments: [plan.foldedExpression])
            return exact + folded.filter { !exact.contains($0) }
        }
    }
}
