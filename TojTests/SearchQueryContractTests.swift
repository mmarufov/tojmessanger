import GRDB
import XCTest
@testable import Toj

/// Asserts that MATCH construction and highlighting stay one contract.
///
/// Both consume ``PreparedSearchQuery``, but consuming the same value is not the same as agreeing
/// about it. Each case here runs the query against a live SQLCipher FTS5 table *and* highlights the
/// same text, then asserts the two answers are consistent:
///
/// - **If FTS5 returns the row, highlighting must mark something.** A result the user can see but
///   cannot locate is the failure this suite exists to catch.
/// - **Every highlighted token must be one FTS5 could have matched.** The reverse implication does
///   not hold and is not asserted: a multi-term query is a conjunction, so a row can contain one
///   term — and legitimately highlight it — without matching overall.
final class SearchQueryContractTests: XCTestCase {
    private var dbQueue: DatabaseQueue!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        var configuration = Configuration()
        configuration.prepareDatabase { db in try db.usePassphrase(Data(repeating: 0x5A, count: 32)) }
        dbQueue = try DatabaseQueue(
            path: directory.appending(path: "contract.sqlite").path, configuration: configuration
        )
        try dbQueue.write { try SearchIndexSchema.createVirtualTable($0) }
    }

    override func tearDownWithError() throws {
        dbQueue = nil
        try super.tearDownWithError()
    }

    // MARK: - The cases

    /// A one-character term is not prefix-matched, so it must reach the token `a` and nothing else.
    /// Highlighting used `hasPrefix` unconditionally and marked `apple` in rows FTS never returned.
    func testOneCharacterExactTermDoesNotMatchLongerWords() throws {
        try assertContract(query: "a", text: "a apple avocado", matched: true, highlights: ["a"])
        try assertContract(query: "a", text: "apple avocado", matched: false, highlights: [])
    }

    func testMultiTermQueryPrefixMatchesOnlyTheFinalTerm() throws {
        try assertContract(
            query: "hello wor", text: "hello world", matched: true, highlights: ["hello", "world"]
        )
        // "hello" is a whole-word term, so a row containing only "hell" cannot match it.
        try assertContract(query: "hello wor", text: "hell world", matched: false, highlights: ["world"])
    }

    func testPrefixMatchingDisabledRequiresWholeWords() throws {
        try assertContract(
            query: "wor", text: "world", prefixMatching: false, matched: false, highlights: []
        )
        try assertContract(
            query: "world", text: "world", prefixMatching: false, matched: true, highlights: ["world"]
        )
    }

    /// A term longer than the cap is truncated *and* forced to a prefix, so it still reaches the
    /// word it came from. Highlighting must apply the same rule or the row matches with nothing
    /// marked.
    func testOverlongTermIsTruncatedAndStillHighlights() throws {
        let word = String(repeating: "a", count: 100)
        try assertContract(query: word, text: "prefix \(word) suffix", matched: true, highlights: [word])
    }

    func testOnlyTheFirstEightTermsAreSearched() throws {
        let terms = (1...20).map { "term\($0)" }
        let plan = try XCTUnwrap(SearchPatternBuilder.prepare(terms.joined(separator: " ")))
        XCTAssertEqual(plan.exactTerms.count, SearchPatternBuilder.maximumTerms)

        // A row holding only the first eight still matches, because terms 9+ were never searched.
        try assertContract(
            query: terms.joined(separator: " "),
            text: terms.prefix(8).joined(separator: " "),
            matched: true,
            highlights: Array(terms.prefix(8))
        )
    }

    func testMillionScalarPasteIsClampedAndStillAgrees() throws {
        let paste = String(repeating: "салом ", count: 200_000)  // ~1.2M scalars
        let plan = try XCTUnwrap(SearchPatternBuilder.prepare(paste))
        XCTAssertLessThanOrEqual(plan.exactTerms.count, SearchPatternBuilder.maximumTerms)
        try assertContract(query: paste, text: "салом ҷони ман", matched: true, highlights: ["салом"])
    }

    /// A 16 KB message with thousands of matches. Guards the hoist: the scalar array used to be
    /// rebuilt inside the token loop, making this quadratic in the number of matches.
    func testLargeMessageWithThousandsOfMatchesHighlightsQuickly() throws {
        let body = String(repeating: "салом ҷони ман ", count: 1_100)  // ~16 KB UTF-8
        XCTAssertGreaterThan(body.utf8.count, 16_000)

        let plan = try XCTUnwrap(SearchPatternBuilder.prepare("салом"))
        let started = Date()
        let ranges = SearchTextNormalizer.highlightRanges(of: plan, in: body)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(ranges.count, 1_100, "every occurrence must be marked")
        XCTAssertLessThan(elapsed, 0.5, "highlighting a 16 KB message must not be quadratic")
        try assertContract(query: "салом", text: body, matched: true, highlights: nil)
    }

    // MARK: - Plan integrity

    /// The limits belong to the plan, so both consumers inherit them rather than reimplementing.
    func testPlanCarriesEveryBound() throws {
        let long = String(repeating: "z", count: 100)
        let plan = try XCTUnwrap(SearchPatternBuilder.prepare("\(long) alpha beta"))
        XCTAssertEqual(plan.exactTerms[0].text.count, SearchPatternBuilder.maximumTermLength)
        XCTAssertTrue(plan.exactTerms[0].isPrefix, "truncated terms are prefixes even mid-query")
        XCTAssertFalse(plan.exactTerms[1].isPrefix, "interior terms are whole words")
        XCTAssertTrue(plan.exactTerms[2].isPrefix, "the trailing term is a prefix while typing")
        XCTAssertTrue(plan.prefixMatching)
    }

    func testPlanKeepsTransliterationInTheFoldedTierOnly() throws {
        let plan = try XCTUnwrap(SearchPatternBuilder.prepare("chon"))
        XCTAssertEqual(plan.exactTerms.map(\.text), ["chon"])
        XCTAssertEqual(plan.foldedAlternatives.map { $0.map(\.text) }, [["chon"], ["чон"]])
    }

    func testPlanExpressionsMatchTheFlattenedPattern() throws {
        for query in ["салом", "тоҷикӣ", "chon", "hello wor", "a"] {
            let plan = try XCTUnwrap(SearchPatternBuilder.prepare(query))
            let pattern = try XCTUnwrap(SearchPatternBuilder.pattern(for: query))
            XCTAssertEqual(plan.exactExpression, pattern.exact, query)
            XCTAssertEqual(plan.foldedExpression, pattern.folded, query)
        }
    }

    // MARK: - Harness

    /// Runs `query` against a table holding only `text`, and highlights the same text with the same
    /// plan.
    ///
    /// - Parameter highlights: Expected highlighted substrings, or `nil` to assert only the
    ///   consistency rules rather than an exact list.
    private func assertContract(
        query: String,
        text: String,
        prefixMatching: Bool = true,
        matched: Bool,
        highlights: [String]?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let plan = try XCTUnwrap(
            SearchPatternBuilder.prepare(query, prefixMatching: prefixMatching), file: file, line: line
        )

        let rows: [Int] = try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM message_search")
            try db.execute(
                sql: """
                    INSERT INTO message_search(
                        rowid, exact, file_name, link_text,
                        folded, file_name_folded, link_text_folded, dialog_token
                    ) VALUES (1, ?, '', '', ?, '', '', 'aabb')
                    """,
                arguments: [SearchTextNormalizer.exact(text), SearchTextNormalizer.foldedForm(text)]
            )
            let sql = "SELECT rowid FROM message_search WHERE message_search MATCH ?"
            let exact = try Int.fetchAll(db, sql: sql, arguments: [plan.exactExpression])
            let folded = try Int.fetchAll(db, sql: sql, arguments: [plan.foldedExpression])
            return exact + folded.filter { !exact.contains($0) }
        }

        XCTAssertEqual(!rows.isEmpty, matched, "FTS match for \(query.prefix(24).debugDescription)",
                       file: file, line: line)

        let ranges = SearchTextNormalizer.highlightRanges(of: plan, in: text)
        let marked = ranges.map { String(text[$0]) }

        if let highlights {
            XCTAssertEqual(marked, highlights, "highlights for \(query.prefix(24).debugDescription)",
                           file: file, line: line)
        }

        // Contract 1: a visible result must be locatable.
        if !rows.isEmpty {
            XCTAssertFalse(
                marked.isEmpty,
                "FTS matched but nothing highlighted for \(query.prefix(24).debugDescription)",
                file: file, line: line
            )
        }

        // Contract 2: nothing is marked that no term could have matched.
        let terms = plan.allTerms
        for token in marked.map({ SearchTextNormalizer.exact($0) }) {
            let folded = SearchTextNormalizer.foldedForm(token)
            XCTAssertTrue(
                terms.contains { $0.matches(SearchTextNormalizer.tokens(token).first ?? token) }
                    || terms.contains { $0.matches(SearchTextNormalizer.tokens(folded).first ?? folded) },
                "highlighted \(token.debugDescription) matches no term",
                file: file, line: line
            )
        }
    }
}
