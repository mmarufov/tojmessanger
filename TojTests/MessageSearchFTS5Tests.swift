import GRDB
import XCTest
@testable import Toj

/// Exercises the search layer against a real SQLCipher-backed FTS5 table.
///
/// The pure tests pin what the normalizer and pattern builder *produce*. These pin that what they
/// produce is actually accepted and behaves as intended by the engine that will run it on device —
/// which is a different claim, and the one that matters. A pattern can be well-formed by our rules
/// and still be rejected by FTS5's grammar; only executing it proves otherwise.
final class MessageSearchFTS5Tests: XCTestCase {
    private var dbQueue: DatabaseQueue!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.usePassphrase(Data(repeating: 0x5A, count: 32))
        }
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
            let version = try SearchIndexSchema.sqliteVersionNumber(db)
            XCTAssertGreaterThanOrEqual(
                version, SearchIndexSchema.minimumSQLiteVersionNumber,
                "contentless_delete needs 3.43; pod resolved an older SQLCipher"
            )
            XCTAssertTrue(try SearchIndexSchema.supportsContentlessDelete(db))
        }
    }

    func testAuthoritativeSchemaCreatesAndConfigures() throws {
        try dbQueue.write { db in
            try SearchIndexSchema.createVirtualTable(db)
            let exists = try Bool.fetchOne(db, sql: """
                SELECT count(*) > 0 FROM sqlite_master
                WHERE type = 'table' AND name = 'message_search'
                """)
            XCTAssertEqual(exists, true)
        }
    }

    /// `automerge` and `deletemerge` are config inserts, not CREATE options — FTS5 rejects them
    /// there. This pins that we keep them in the right place.
    func testMergeOptionsAreRejectedAsCreateOptions() throws {
        try dbQueue.write { db in
            XCTAssertThrowsError(
                try db.execute(sql: """
                    CREATE VIRTUAL TABLE bad USING fts5(x, content = '', automerge = 8)
                    """)
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

    /// The premise the Tajik fold table rests on. Version 1 asserted the opposite in a comment and
    /// dropped ӣ and ӯ handling on that basis.
    func testUnicode61DoesNotFoldCyrillic() throws {
        for (raw, expected) in [("ё", "ё"), ("й", "й"), ("ӣ", "ӣ"), ("ӯ", "ӯ"),
                                ("ҷ", "ҷ"), ("ғ", "ғ"), ("ҳ", "ҳ"), ("қ", "қ")] {
            XCTAssertEqual(try tokenize(raw), [expected], "unicode61 changed its treatment of \(raw)")
        }
    }

    func testUnicode61RemovesLatinDiacriticsAndFoldsTitlecase() throws {
        XCTAssertEqual(try tokenize("Café"), ["cafe"])
        XCTAssertEqual(try tokenize("cafe\u{0301}"), ["cafe"])
        XCTAssertEqual(try tokenize("İstanbul"), ["istanbul"])
        XCTAssertEqual(try tokenize("ǅ"), ["ǆ"])
    }

    func testUnicode61TokenClasses() throws {
        XCTAssertEqual(try tokenize("½ ² 5"), ["5", "²", "½"])
        XCTAssertEqual(try tokenize("abc\u{E000}def"), ["abc\u{E000}def"], "private use is a token class")
        XCTAssertEqual(try tokenize("a\u{1F600}b"), ["a", "b"], "emoji separate")
    }

    /// Whatever the normalizer emits is what the tokenizer sees, so the two must agree on token
    /// boundaries or a stored term and its query term can differ.
    func testNormalizerTokenizationMatchesTheEngine() throws {
        for sample in ["Салом, ҷони ман!", "Café Rumi", "½ ² 5", "file2024.pdf",
                       "abc\u{E000}def", "тоҷикӣ", "ёлка йогурт", "日本語"] {
            let folded = SearchTextNormalizer.foldedForm(sample)
            XCTAssertEqual(
                try tokenize(folded).sorted(),
                SearchTextNormalizer.tokens(folded).sorted(),
                "token boundaries diverge for \(sample.debugDescription)"
            )
        }
    }

    // MARK: - Adversarial patterns

    private static let adversarialQueries = [
        "AND", "OR", "NOT", "NEAR", "NEAR(a b, 2)", "a AND (b OR c)", "a OR b", "a NOT b",
        "\"", "\"\"", "\"unterminated", "a\"b", "''", "'; DROP TABLE message_search; --",
        "*", "**", "a*", "^abc", "-abc", "a:b", "{col}:x", "column:value",
        "(", ")", "()", "((()))", "{", "}", "[", "]", "+", "~", "%", "_",
        "\u{0301}", "\u{0301}\u{0308}", " \u{0301} ", "🙂", "🇹🇯",
        "тоҷикӣ", "точики", "salom", "chon", "½", "²", "\u{E000}", "日本語",
        String(repeating: "a", count: 10_000),
        String(repeating: "a ", count: 5_000),
        String(repeating: "ҷ", count: 4_000),
        String(repeating: "🙂", count: 4_000),
    ]

    /// Every expression the builder can emit, executed. This is the guarantee that matters: user
    /// text can never reach MATCH in a form that raises SQLITE_ERROR at query time.
    func testEveryAdversarialPatternExecutes() throws {
        try dbQueue.write { db in
            try SearchIndexSchema.createVirtualTable(db)
            try db.execute(sql: """
                INSERT INTO message_search(rowid, exact, folded, file_name, link_text, dialog_token)
                VALUES (1, 'салом ҷони ман', 'салом чони ман', 'report.pdf', 'example com', 'aabb')
                """)

            for query in Self.adversarialQueries {
                guard let pattern = SearchPatternBuilder.pattern(for: query) else { continue }
                var expressions = [pattern.exact]
                if let folded = pattern.folded { expressions.append(folded) }
                expressions += expressions.map {
                    SearchPatternBuilder.scoped($0, toDialog: "2F3A9B10-4C5D-6E7F-8A9B-0C1D2E3F4A5B")
                }

                for expression in expressions {
                    XCTAssertNoThrow(
                        try Int.fetchAll(
                            db, sql: "SELECT rowid FROM message_search WHERE message_search MATCH ?",
                            arguments: [expression]
                        ),
                        "rejected for \(query.prefix(32).debugDescription): \(expression.prefix(120))"
                    )
                }
            }
        }
    }

    func testPatternsAlsoExecuteWithoutPrefixMatching() throws {
        try dbQueue.write { db in
            try SearchIndexSchema.createVirtualTable(db)
            for query in Self.adversarialQueries {
                guard let pattern = SearchPatternBuilder.pattern(for: query, prefixMatching: false)
                else { continue }
                XCTAssertNoThrow(
                    try Int.fetchAll(
                        db, sql: "SELECT rowid FROM message_search WHERE message_search MATCH ?",
                        arguments: [pattern.exact]
                    ),
                    "rejected for \(query.prefix(32).debugDescription)"
                )
            }
        }
    }

    // MARK: - End-to-end behaviour

    func testRussianKeyboardQueryFindsTajikMessageEndToEnd() throws {
        try dbQueue.write { db in
            try SearchIndexSchema.createVirtualTable(db)
            try index(db, rowid: 1, text: "Салом, ҷони ман", dialogId: "aa-bb")
            try index(db, rowid: 2, text: "Привет как дела", dialogId: "aa-bb")

            XCTAssertEqual(try search(db, "чони"), [1], "Russian-keyboard spelling must reach Tajik text")
            XCTAssertEqual(try search(db, "ҷони"), [1], "the exact spelling must too")
            XCTAssertEqual(try search(db, "chon"), [1], "Latin transliteration must too")
            XCTAssertEqual(try search(db, "привет"), [2])
        }
    }

    /// ё and й are no longer folded, so these stay distinct rather than collapsing together.
    func testYoAndShortIRemainDistinct() throws {
        try dbQueue.write { db in
            try SearchIndexSchema.createVirtualTable(db)
            try index(db, rowid: 1, text: "ёлка", dialogId: "aa-bb")
            try index(db, rowid: 2, text: "елка", dialogId: "aa-bb")
            XCTAssertEqual(try search(db, "ёлка"), [1])
            XCTAssertEqual(try search(db, "елка"), [2])
        }
    }

    func testDialogScopingRestrictsResults() throws {
        try dbQueue.write { db in
            try SearchIndexSchema.createVirtualTable(db)
            try index(db, rowid: 1, text: "салом", dialogId: "aa-bb")
            try index(db, rowid: 2, text: "салом", dialogId: "cc-dd")

            let pattern = try XCTUnwrap(SearchPatternBuilder.pattern(for: "салом"))
            let scoped = SearchPatternBuilder.scoped(pattern.exact, toDialog: "aa-bb")
            XCTAssertEqual(
                try Int.fetchAll(
                    db, sql: "SELECT rowid FROM message_search WHERE message_search MATCH ? ORDER BY rowid",
                    arguments: [scoped]
                ),
                [1]
            )
        }
    }

    func testContentlessDeleteRemovesTermsSoDeletedTextIsNotSearchable() throws {
        try dbQueue.write { db in
            try SearchIndexSchema.createVirtualTable(db)
            try index(db, rowid: 1, text: "конфиденциальный", dialogId: "aa-bb")
            XCTAssertEqual(try search(db, "конфиденциальный"), [1])

            try db.execute(sql: "DELETE FROM message_search WHERE rowid = 1")
            XCTAssertEqual(try search(db, "конфиденциальный"), [], "deleted text stayed searchable")
        }
    }

    // MARK: - Helpers

    /// Round-trips text through a throwaway table configured like the real one, returning the terms
    /// the engine actually produced.
    private func tokenize(_ text: String) throws -> [String] {
        try dbQueue.write { db in
            try db.execute(sql: "DROP TABLE IF EXISTS probe")
            try db.execute(sql: "DROP TABLE IF EXISTS probe_vocab")
            try db.execute(sql: """
                CREATE VIRTUAL TABLE probe USING fts5(x, tokenize = '\(SearchIndexSchema.tokenize)')
                """)
            try db.execute(sql: "INSERT INTO probe(x) VALUES (?)", arguments: [text])
            try db.execute(sql: "CREATE VIRTUAL TABLE probe_vocab USING fts5vocab(probe, row)")
            return try String.fetchAll(db, sql: "SELECT term FROM probe_vocab ORDER BY term")
        }
    }

    private func index(_ db: Database, rowid: Int, text: String, dialogId: String) throws {
        try db.execute(
            sql: """
                INSERT INTO message_search(rowid, exact, folded, file_name, link_text, dialog_token)
                VALUES (?, ?, ?, '', '', ?)
                """,
            arguments: [
                rowid,
                SearchTextNormalizer.exact(text),
                SearchTextNormalizer.folded(text) ?? "",
                SearchPatternBuilder.dialogToken(dialogId),
            ]
        )
    }

    /// Mirrors the two-tier query the store will run: exact first, folded only for what it missed.
    private func search(_ db: Database, _ query: String) throws -> [Int] {
        guard let pattern = SearchPatternBuilder.pattern(for: query) else { return [] }
        let sql = "SELECT rowid FROM message_search WHERE message_search MATCH ? ORDER BY rowid"
        var hits = try Int.fetchAll(db, sql: sql, arguments: [pattern.exact])
        if let folded = pattern.folded {
            for hit in try Int.fetchAll(db, sql: sql, arguments: [folded]) where !hits.contains(hit) {
                hits.append(hit)
            }
        }
        return hits.sorted()
    }
}
