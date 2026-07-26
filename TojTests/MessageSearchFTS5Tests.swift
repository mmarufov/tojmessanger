import GRDB
import XCTest
@testable import Toj

/// Exercises the search layer against a real SQLCipher-backed FTS5 table.
///
/// The pure tests pin what the normalizer and pattern builder *produce*. These pin that what they
/// produce is accepted and behaves as intended by the engine that will run it on device — a
/// different claim, and the one that matters. A pattern can be well-formed by our rules and still
/// be rejected by FTS5's grammar; only executing it proves otherwise.
final class MessageSearchFTS5Tests: XCTestCase {
    private var dbQueue: DatabaseQueue!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        var configuration = Configuration()
        configuration.prepareDatabase { db in try db.usePassphrase(Data(repeating: 0x5A, count: 32)) }
        dbQueue = try DatabaseQueue(
            path: directory.appending(path: "search.sqlite").path, configuration: configuration
        )
    }

    override func tearDownWithError() throws {
        dbQueue = nil
        try super.tearDownWithError()
    }

    // MARK: - Environment

    func testSQLCipherProvidesFTS5WithContentlessDelete() throws {
        // A write connection: the probe creates and drops a temporary table, which GRDB's `read`
        // forbids via `query_only`. The indexer calls this from its bootstrap write for that reason.
        try dbQueue.write { db in
            XCTAssertGreaterThanOrEqual(
                try SearchIndexSchema.sqliteVersionNumber(db),
                SearchIndexSchema.minimumSQLiteVersionNumber
            )
            XCTAssertTrue(try SearchIndexSchema.supportsContentlessDelete(db))
        }
    }

    func testAuthoritativeSchemaCreatesAndConfigures() throws {
        try dbQueue.write { db in
            try SearchIndexSchema.createVirtualTable(db)
            XCTAssertEqual(
                try Bool.fetchOne(db, sql: """
                    SELECT count(*) > 0 FROM sqlite_master
                    WHERE type = 'table' AND name = 'message_search'
                    """),
                true
            )
        }
    }

    /// `automerge` and `deletemerge` are config inserts, not CREATE options — FTS5 rejects them
    /// there. Pins that we keep them in the right place.
    func testMergeOptionsAreRejectedAsCreateOptions() throws {
        try dbQueue.write { db in
            XCTAssertThrowsError(
                try db.execute(sql: "CREATE VIRTUAL TABLE bad USING fts5(x, content='', automerge=8)")
            )
        }
    }

    /// Contentless tables cannot rebuild in place, which is why repair drops and recreates.
    func testContentlessTableCannotRebuildInPlace() throws {
        try dbQueue.write { db in
            try SearchIndexSchema.createVirtualTable(db)
            XCTAssertThrowsError(
                try db.execute(sql: "INSERT INTO message_search(message_search) VALUES('rebuild')")
            )
        }
    }

    // MARK: - Tokenizer ground truth

    /// The premise the Tajik fold table rests on. Version 1 asserted the opposite in a comment.
    func testUnicode61DoesNotFoldCyrillic() throws {
        for raw in ["ё", "й", "ӣ", "ӯ", "ҷ", "ғ", "ҳ", "қ"] {
            XCTAssertEqual(try tokenize(raw), [raw], "unicode61 changed its treatment of \(raw)")
        }
    }

    /// The three-class model, measured. Version 2 treated the accepted diacritics as separators and
    /// so split these into two tokens each.
    func testAcceptedDiacriticsAreIgnoredRatherThanSeparating() throws {
        XCTAssertEqual(try tokenize("e\u{0301}galite\u{0301}"), ["egalite"])
        XCTAssertEqual(try tokenize("a\u{0301}b"), ["ab"])
        XCTAssertEqual(try tokenize("\u{0301}ab"), ["ab"])
        XCTAssertEqual(try tokenize("a\u{05B0}b"), ["a", "b"], "unaccepted mark separates")
    }

    func testUnicode61FoldsLatinDiacriticsAndTitlecase() throws {
        XCTAssertEqual(try tokenize("Café"), ["cafe"])
        XCTAssertEqual(try tokenize("İstanbul"), ["istanbul"])
        XCTAssertEqual(try tokenize("ǅ"), ["ǆ"])
    }

    func testUnicode61TokenClasses() throws {
        XCTAssertEqual(try tokenize("½ ² 5"), ["5", "²", "½"])
        XCTAssertEqual(try tokenize("abc\u{E000}def"), ["abc\u{E000}def"])
        XCTAssertEqual(try tokenize("a\u{1F600}b"), ["a", "b"])
    }

    /// Whatever the normalizer emits is what the tokenizer sees, so the two must agree on token
    /// boundaries or a stored term and its query term can differ.
    func testNormalizerTokenizationMatchesTheEngine() throws {
        for sample in ["Салом, ҷони ман!", "Café Rumi", "½ ² 5", "file2024.pdf", "abc\u{E000}def",
                       "тоҷикӣ", "ёлка йогурт", "日本語", "e\u{0301}galite\u{0301}", "a\u{0301}b",
                       "\u{0301}ab", "a\u{05B0}b"] {
            let folded = SearchTextNormalizer.foldedForm(sample)
            XCTAssertEqual(
                try tokenize(folded).sorted(), SearchTextNormalizer.tokens(folded).sorted(),
                "token boundaries diverge for \(sample.debugDescription)"
            )
        }
    }

    // MARK: - Adversarial patterns

    /// Every expression the builder can emit, executed in all four forms. This is the guarantee
    /// that matters: user text can never reach MATCH in a form that raises SQLITE_ERROR.
    func testEveryAdversarialPatternExecutes() throws {
        try dbQueue.write { db in
            try SearchIndexSchema.createVirtualTable(db)
            try insert(db, rowid: 1, body: "салом ҷони ман", fileName: "report.pdf",
                       linkText: "example com", dialogId: "aa-bb")

            for query in SearchPatternBuilderTests.adversarialQueries {
                guard let pattern = SearchPatternBuilder.pattern(for: query) else {
                    XCTAssertTrue(
                        SearchPatternBuilderTests.expectedNilQueries.contains(query),
                        "unexpectedly skipped \(query.debugDescription)"
                    )
                    continue
                }
                for expression in [
                    pattern.exact,
                    pattern.folded,
                    SearchPatternBuilder.scoped(pattern.exact, toDialog: "aa-bb"),
                    SearchPatternBuilder.scoped(pattern.folded, toDialog: "aa-bb"),
                ] {
                    XCTAssertNoThrow(
                        try Int.fetchAll(
                            db, sql: "SELECT rowid FROM message_search WHERE message_search MATCH ?",
                            arguments: [expression]
                        ),
                        "rejected for \(query.prefix(32).debugDescription): \(expression.prefix(140))"
                    )
                }
            }
        }
    }

    /// Token characters the removed Unicode-properties filter rejected. These must not merely
    /// execute — they must find the row.
    func testNumericAndPrivateUseQueriesMatchRealRows() throws {
        try dbQueue.write { db in
            try SearchIndexSchema.createVirtualTable(db)
            try insert(db, rowid: 1, body: "½ portion", dialogId: "aa-bb")
            try insert(db, rowid: 2, body: "² exponent", dialogId: "aa-bb")
            try insert(db, rowid: 3, body: "abc\u{E000}def", dialogId: "aa-bb")

            XCTAssertEqual(try tiered(db, "½").all, [1])
            XCTAssertEqual(try tiered(db, "²").all, [2])
            XCTAssertEqual(try tiered(db, "abc\u{E000}def").all, [3])
        }
    }

    // MARK: - Tier semantics

    /// Competing rows: one matches the exact tier, one only the folded tier. The merged order must
    /// place the exact hit first because of which tier answered, not because of a sort.
    func testExactHitOutranksFoldedHitForTheSameQuery() throws {
        try dbQueue.write { db in
            try SearchIndexSchema.createVirtualTable(db)
            // Deliberately reversed rowids so a sorted union would return [1, 2] and hide the bug.
            try insert(db, rowid: 1, body: "тоҷикӣ", dialogId: "aa-bb")   // folded-tier hit only
            try insert(db, rowid: 2, body: "точики", dialogId: "aa-bb")   // exact-tier hit

            let result = try tiered(db, "точики")
            XCTAssertEqual(result.exact, [2], "the literal spelling is the exact-tier hit")
            XCTAssertEqual(result.folded, [1], "the Tajik spelling is reachable only when folded")
            XCTAssertEqual(result.all, [2, 1], "exact tier must come first, not a sorted union")
        }
    }

    /// The version 2 regression: a query unchanged by Tajik folding still has to search the folded
    /// column, or the Russian-keyboard spelling can never reach Tajik text.
    func testFoldedQueryFindsTajikTextWithNoExactRowPresent() throws {
        try dbQueue.write { db in
            try SearchIndexSchema.createVirtualTable(db)
            try insert(db, rowid: 1, body: "Салом, тоҷикӣ забон", dialogId: "aa-bb")

            let result = try tiered(db, "точики")
            XCTAssertEqual(result.exact, [], "nothing is literally spelled точики")
            XCTAssertEqual(result.folded, [1], "the folded tier must still run and find it")
        }
    }

    func testTajikSpellingFindsItselfInTheExactTier() throws {
        try dbQueue.write { db in
            try SearchIndexSchema.createVirtualTable(db)
            try insert(db, rowid: 1, body: "тоҷикӣ", dialogId: "aa-bb")
            let result = try tiered(db, "тоҷикӣ")
            XCTAssertEqual(result.exact, [1])
        }
    }

    func testTransliterationResolvesThroughTheFoldedTier() throws {
        try dbQueue.write { db in
            try SearchIndexSchema.createVirtualTable(db)
            try insert(db, rowid: 1, body: "Салом ҷон", dialogId: "aa-bb")
            let result = try tiered(db, "chon")
            XCTAssertEqual(result.exact, [], "chon is not literally present")
            XCTAssertEqual(result.folded, [1])
        }
    }

    /// Filenames and link text participate in both tiers alongside the body and caption.
    func testFilenameAndLinkTextParticipateInBothTiers() throws {
        try dbQueue.write { db in
            try SearchIndexSchema.createVirtualTable(db)
            try insert(db, rowid: 1, body: "see attached", fileName: "ҳисобот.pdf", dialogId: "aa-bb")
            try insert(db, rowid: 2, body: "link", linkText: "тоҷикистон example com", dialogId: "aa-bb")

            XCTAssertEqual(try tiered(db, "ҳисобот").exact, [1], "filename in the exact tier")
            XCTAssertEqual(try tiered(db, "хисобот").folded, [1], "filename in the folded tier")
            XCTAssertEqual(try tiered(db, "тоҷикистон").exact, [2], "link text in the exact tier")
            XCTAssertEqual(try tiered(db, "точикистон").folded, [2], "link text in the folded tier")
        }
    }

    func testCaptionsAreSearchableAsBody() throws {
        try dbQueue.write { db in
            try SearchIndexSchema.createVirtualTable(db)
            // Captions share messages.text with bodies, so they land in the same columns.
            try insert(db, rowid: 1, body: "тӯйи арӯсӣ", fileName: "IMG_0042.HEIC", dialogId: "aa-bb")
            XCTAssertEqual(try tiered(db, "туйи").folded, [1])
            XCTAssertEqual(try tiered(db, "img_0042").exact, [1])
        }
    }

    func testYoAndShortIRemainDistinct() throws {
        try dbQueue.write { db in
            try SearchIndexSchema.createVirtualTable(db)
            try insert(db, rowid: 1, body: "ёлка", dialogId: "aa-bb")
            try insert(db, rowid: 2, body: "елка", dialogId: "aa-bb")
            XCTAssertEqual(try tiered(db, "ёлка").all, [1])
            XCTAssertEqual(try tiered(db, "елка").all, [2])
        }
    }

    // MARK: - Scoping and deletion

    func testDialogScopingComposesWithBothTiers() throws {
        try dbQueue.write { db in
            try SearchIndexSchema.createVirtualTable(db)
            try insert(db, rowid: 1, body: "тоҷикӣ", dialogId: "aa-bb")
            try insert(db, rowid: 2, body: "тоҷикӣ", dialogId: "cc-dd")

            let pattern = try XCTUnwrap(SearchPatternBuilder.pattern(for: "точики"))
            let sql = "SELECT rowid FROM message_search WHERE message_search MATCH ? ORDER BY rowid"
            XCTAssertEqual(
                try Int.fetchAll(db, sql: sql,
                                 arguments: [SearchPatternBuilder.scoped(pattern.folded, toDialog: "aa-bb")]),
                [1]
            )
            XCTAssertEqual(
                try Int.fetchAll(db, sql: sql,
                                 arguments: [SearchPatternBuilder.scoped(pattern.exact, toDialog: "aa-bb")]),
                []
            )
        }
    }

    func testContentlessDeleteRemovesTermsSoDeletedTextIsNotSearchable() throws {
        try dbQueue.write { db in
            try SearchIndexSchema.createVirtualTable(db)
            try insert(db, rowid: 1, body: "конфиденциальный", dialogId: "aa-bb")
            XCTAssertEqual(try tiered(db, "конфиденциальный").all, [1])

            try db.execute(sql: "DELETE FROM message_search WHERE rowid = 1")
            XCTAssertEqual(try tiered(db, "конфиденциальный").all, [], "deleted text stayed searchable")
        }
    }

    // MARK: - Helpers

    private func tokenize(_ text: String) throws -> [String] {
        try dbQueue.write { db in
            try db.execute(sql: "DROP TABLE IF EXISTS probe_vocab")
            try db.execute(sql: "DROP TABLE IF EXISTS probe")
            try db.execute(sql: """
                CREATE VIRTUAL TABLE probe USING fts5(x, tokenize = '\(SearchIndexSchema.tokenize)')
                """)
            try db.execute(sql: "INSERT INTO probe(x) VALUES (?)", arguments: [text])
            try db.execute(sql: "CREATE VIRTUAL TABLE probe_vocab USING fts5vocab(probe, row)")
            return try String.fetchAll(db, sql: "SELECT term FROM probe_vocab ORDER BY term")
        }
    }

    /// Writes a row the way the indexer will: exact and folded variants of every text column, with
    /// the folded ones populated unconditionally.
    private func insert(
        _ db: Database, rowid: Int, body: String,
        fileName: String = "", linkText: String = "", dialogId: String
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO message_search(
                    rowid, exact, file_name, link_text,
                    folded, file_name_folded, link_text_folded, dialog_token
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                rowid,
                SearchTextNormalizer.exact(body),
                SearchTextNormalizer.exact(fileName),
                SearchTextNormalizer.exact(linkText),
                SearchTextNormalizer.foldedForm(body),
                SearchTextNormalizer.foldedForm(fileName),
                SearchTextNormalizer.foldedForm(linkText),
                SearchPatternBuilder.dialogToken(dialogId),
            ]
        )
    }

    private struct TieredResult {
        let exact: [Int]
        let folded: [Int]
        /// Exact tier first, then folded-tier rows the exact tier did not already return. Order is
        /// tier membership, never a sort.
        var all: [Int] { exact + folded.filter { !exact.contains($0) } }
    }

    /// Mirrors the two-tier query the store will run.
    private func tiered(_ db: Database, _ query: String) throws -> TieredResult {
        guard let pattern = SearchPatternBuilder.pattern(for: query) else {
            return TieredResult(exact: [], folded: [])
        }
        let sql = "SELECT rowid FROM message_search WHERE message_search MATCH ? ORDER BY rowid"
        let exact = try Int.fetchAll(db, sql: sql, arguments: [pattern.exact])
        let folded = try Int.fetchAll(db, sql: sql, arguments: [pattern.folded])
        return TieredResult(exact: exact, folded: folded.filter { !exact.contains($0) })
    }
}
