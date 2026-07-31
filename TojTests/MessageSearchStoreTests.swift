import GRDB
import XCTest
@testable import Toj

/// The production query API: tiering, scopes, browse mode, keyset pagination, and the access filter.
final class MessageSearchStoreTests: XCTestCase {
    private var directory: URL!
    private var store: CloudLocalStore!
    private var indexer: SearchIndexer!

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try CloudLocalStore(
            path: directory.appending(path: "cloud.sqlite").path,
            key: Data(repeating: 0x37, count: 32)
        )
        indexer = SearchIndexer(store: store)
    }

    override func tearDown() async throws {
        indexer = nil
        store = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try await super.tearDown()
    }

    // MARK: - Tiering

    /// Exact before folded, as a property of the query plan rather than a sort. The rowids are
    /// arranged so a sorted union would return the opposite order.
    func testExactHitsPrecedeFoldedHits() async throws {
        try await insert(1, "тоҷикӣ забон")   // reachable only through folding
        try await insert(2, "точики забон")   // literal match
        try await index()

        let hits = try await store.searchMessages(MessageSearchRequest(query: "точики")).hits
        XCTAssertEqual(hits.map(\.tier), [.exact, .folded])
        XCTAssertEqual(hits.map(\.text), ["точики забон", "тоҷикӣ забон"])
    }

    func testFoldedTierReachesTajikTextWithNoExactRow() async throws {
        try await insert(1, "Салом, тоҷикӣ забон")
        try await index()

        let hits = try await store.searchMessages(MessageSearchRequest(query: "точики")).hits
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.tier, .folded)
    }

    func testTransliterationResolvesThroughTheFoldedTier() async throws {
        try await insert(1, "Салом ҷон")
        try await index()
        let hits = try await store.searchMessages(MessageSearchRequest(query: "chon")).hits
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.tier, .folded)
    }

    func testHitsCarryTheOriginalTextNotTheNormalizedForm() async throws {
        try await insert(1, "Café Rumi")
        try await index()
        let hits = try await store.searchMessages(MessageSearchRequest(query: "cafe")).hits
        XCTAssertEqual(hits.first?.text, "Café Rumi", "display text must be what the bubble shows")
    }

    // MARK: - Scopes

    func testScopesFilterByKind() async throws {
        try await insert(1, "beach", kind: "photo")
        try await insert(2, "notes", kind: "file")
        try await insert(3, "plain", kind: "text")
        try await index()

        let media = try await store.searchMessages(
            MessageSearchRequest(query: "", scope: .media)).hits
        XCTAssertEqual(media.map(\.msgId), [1])

        let files = try await store.searchMessages(
            MessageSearchRequest(query: "", scope: .files)).hits
        XCTAssertEqual(files.map(\.msgId), [2])
    }

    func testLinksScopeSelectsMessagesCarryingLinks() async throws {
        try await insert(1, "see https://example.com/report")
        try await insert(2, "no link here")
        try await index()

        let links = try await store.searchMessages(
            MessageSearchRequest(query: "", scope: .links)).hits
        XCTAssertEqual(links.map(\.msgId), [1])
    }

    /// An empty query with a scope is a browse, which is what makes the Media, Files and Links tabs
    /// useful before the user types.
    func testEmptyQueryBrowsesInReverseChronologicalOrder() async throws {
        for index in 1...5 {
            try await insert(Int64(index), "photo \(index)", kind: "photo", serverTs: "2026-07-1\(index)T09:00:00Z")
        }
        try await index()

        let hits = try await store.searchMessages(
            MessageSearchRequest(query: "", scope: .media)).hits
        XCTAssertEqual(hits.map(\.msgId), [5, 4, 3, 2, 1], "newest first")
    }

    /// Typed punctuation is not a browse. The user asked for something; showing everything would be
    /// a worse answer than showing nothing.
    func testTokenlessQueryReturnsNothingRatherThanBrowsing() async throws {
        try await insert(1, "anything")
        try await index()
        let hits = try await store.searchMessages(MessageSearchRequest(query: "!!! ???")).hits
        XCTAssertTrue(hits.isEmpty)
    }

    // MARK: - Pagination

    func testKeysetPaginationReturnsEachHitExactlyOnce() async throws {
        for index in 1...25 {
            try await insert(Int64(index), "paged item \(index)",
                             serverTs: "2026-07-\(String(format: "%02d", index))T09:00:00Z")
        }
        try await index()

        var seen: [Int64] = []
        var cursor: MessageSearchCursor?
        var pages = 0
        repeat {
            let page = try await store.searchMessages(
                MessageSearchRequest(query: "paged", limit: 7, cursor: cursor))
            seen += page.hits.compactMap(\.msgId)
            cursor = page.cursor
            pages += 1
        } while cursor != nil && pages < 10

        XCTAssertEqual(seen.count, 25)
        XCTAssertEqual(Set(seen).count, 25, "no hit may repeat across pages")
        XCTAssertEqual(seen, seen.sorted(by: >), "pages stay in recency order")
    }

    // MARK: - Dialog scoping

    func testDialogScopingRestrictsToOneConversation() async throws {
        try await insert(1, "салом", dialogId: "d1")
        try await insert(2, "салом", dialogId: "d2")
        try await index()

        let scoped = try await store.searchMessages(
            MessageSearchRequest(query: "салом", dialogId: "d1")).hits
        XCTAssertEqual(scoped.map(\.dialogId), ["d1"])
    }

    func testSearchInDialogReturnsMessageIdsForPrevNext() async throws {
        for index in 1...4 {
            try await insert(Int64(index), index.isMultiple(of: 2) ? "match here" : "other",
                             dialogId: "d1",
                             serverTs: "2026-07-0\(index)T09:00:00Z")
        }
        try await index()

        let ids = try await store.searchInDialog("d1", query: "match")
        XCTAssertEqual(ids, [4, 2], "newest first, only matches")
    }

    // MARK: - Access filtering

    /// The filter is what makes revocation instant; the index removal that follows makes it durable.
    func testRevokedDialogsAreFilteredBeforeAnyDrain() async throws {
        try await insert(1, "groupsecret", dialogId: "d1")
        try await index()
        let before = try await store.searchMessages(MessageSearchRequest(query: "groupsecret")).hits
        XCTAssertEqual(before.count, 1)

        try await store.revokeGroupAccess(dialogId: "d1", reason: "removed")

        let after = try await store.searchMessages(MessageSearchRequest(query: "groupsecret")).hits
        XCTAssertTrue(after.isEmpty, "no drain has run; the filter alone must hide it")
    }

    // MARK: - Degradation

    /// A missing index is a degraded feature, not an error. Callers get an empty page.
    func testMissingIndexReturnsEmptyRatherThanThrowing() async throws {
        try await insert(1, "anything")
        // No bootstrap: the virtual table does not exist.
        let page = try await store.searchMessages(MessageSearchRequest(query: "anything"))
        XCTAssertTrue(page.isEmpty)
        XCTAssertNil(page.cursor)
    }

    // MARK: - Helpers

    private func index() async throws {
        await indexer.bootstrap()
        _ = try await indexer.drain()
        while try await indexer.backfillStep() {}
        _ = try await indexer.drain()
    }

    private func insert(
        _ msgId: Int64, _ text: String, kind: String = "text",
        dialogId: String = "d1", serverTs: String = "2026-07-12T09:00:00Z"
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
                VALUES (?, ?, ?, ?, 'a1', ?, ?, 0, 0, 'visible', ?, 'sent')
                """, arguments: ["\(dialogId):\(msgId)", dialogId, msgId,
                                 "\(dialogId)-c\(msgId)", kind, text, serverTs])
        }
    }
}
