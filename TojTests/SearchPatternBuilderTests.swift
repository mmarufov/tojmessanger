import XCTest
@testable import Toj

final class SearchPatternBuilderTests: XCTestCase {
    /// Every one of these is an FTS5 operator or malformed syntax. Passed through verbatim they
    /// raise SQLITE_ERROR at query time — a fault only real user text triggers.
    /// `MessageSearchFTS5Tests` executes each against a live table; this pins the emitted shape.
    static let adversarialQueries = [
        "AND", "OR", "NOT", "NEAR", "NEAR(a b, 2)", "a AND (b OR c)", "a OR b", "a NOT b",
        "\"", "\"\"", "\"unterminated", "a\"b", "''", "'; DROP TABLE message_search; --",
        "*", "**", "a*", "^abc", "-abc", "a:b", "{col}:x", "column:value",
        "(", ")", "()", "((()))", "{", "}", "[", "]", "+", "~", "%", "_",
        "\u{0301}", "\u{0301}\u{0308}", " \u{0301} ", "🙂", "🇹🇯",
        "тоҷикӣ", "точики", "salom", "chon", "½", "²", "\u{E000}", "日本語",
        "e\u{0301}galite\u{0301}", "a\u{0301}b", "a\u{05B0}b",
        String(repeating: "a", count: 10_000),
        String(repeating: "ҷ", count: 4_000),
        String(repeating: "🙂", count: 4_000),
    ]

    /// The only inputs that legitimately produce no pattern: those with no token characters at all.
    /// Listed explicitly so a test cannot quietly skip a case that *should* have produced one.
    static let expectedNilQueries: Set<String> = [
        "\"", "\"\"", "''", "*", "**", "(", ")", "()", "((()))", "{", "}", "[", "]",
        "+", "~", "%", "_", "\u{0301}", "\u{0301}\u{0308}", " \u{0301} ", "🇹🇯",
    ]

    // MARK: - Safety

    func testOperatorsAndQuotesAreNeutralized() {
        XCTAssertEqual(exact(of: "AND"), "\"and\"*")
        XCTAssertEqual(exact(of: "column:value"), "\"column\" AND \"value\"*")
        XCTAssertEqual(exact(of: "a OR b"), "\"a\" AND \"or\" AND \"b\"")
        // `_` is a separator in the measured table, so message_search is two terms, not one.
        XCTAssertEqual(
            exact(of: "'; DROP TABLE message_search; --"),
            "\"drop\" AND \"table\" AND \"message\" AND \"search\"*"
        )
    }

    /// Nil is a real answer for some inputs and a bug for others. Asserting the partition stops a
    /// `guard ... else { continue }` from silently excusing a regression.
    func testOnlyTokenlessInputProducesNoPattern() {
        for query in Self.adversarialQueries {
            let pattern = SearchPatternBuilder.pattern(for: query)
            if Self.expectedNilQueries.contains(query) {
                XCTAssertNil(pattern, "expected no pattern for \(query.debugDescription)")
            } else {
                XCTAssertNotNil(pattern, "expected a pattern for \(query.debugDescription)")
            }
        }
    }

    /// These are token characters in the measured table, so they must produce real patterns. The
    /// removed Unicode-properties filter rejected all three.
    /// Emoji are not one class. unicode61 defaults *unassigned* scalars to alphanumeric, so an
    /// emoji newer than this SQLite's tables is a token character while an older one separates.
    /// Worth pinning: it is surprising, version-dependent, and only discoverable by measuring.
    func testEmojiClassificationFollowsTheMeasuredTableNotIntuition() {
        XCTAssertEqual(SearchTextNormalizer.classify("\u{1F600}"), .separator, "😀 is assigned")
        XCTAssertEqual(SearchTextNormalizer.classify("\u{1F642}"), .token, "🙂 postdates the tables")
        XCTAssertNotNil(SearchPatternBuilder.pattern(for: "🙂"))
        XCTAssertNil(SearchPatternBuilder.pattern(for: "😀"))
    }

    func testNumericAndPrivateUseQueriesProducePatterns() {
        for query in ["½", "²", "\u{E000}", "½²", "abc\u{E000}def"] {
            XCTAssertNotNil(
                SearchPatternBuilder.pattern(for: query),
                "measured tokenizer accepts \(query.debugDescription) as a token"
            )
        }
    }

    // MARK: - Tier semantics

    /// The exact tier must not be able to match folded columns, or "exact ranks above folded"
    /// becomes meaningless — every folded hit would also appear in the exact tier.
    func testExactTierIsRestrictedToExactColumns() {
        let pattern = SearchPatternBuilder.pattern(for: "салом")
        XCTAssertEqual(pattern?.exact, "{exact file_name link_text} : (\"салом\"*)")
    }

    func testFoldedTierIsRestrictedToFoldedColumns() {
        let pattern = SearchPatternBuilder.pattern(for: "салом")
        XCTAssertEqual(pattern?.folded, "{folded file_name_folded link_text_folded} : (\"салом\"*)")
    }

    /// The version 2 bug. `точики` is unchanged by Tajik folding, so version 2 emitted no folded
    /// tier and could not reach a stored `тоҷикӣ` — the exact query the folded column exists for.
    func testFoldedTierRunsEvenWhenTheQueryIsUnchangedByFolding() {
        let pattern = SearchPatternBuilder.pattern(for: "точики")
        XCTAssertEqual(pattern?.exact, "{exact file_name link_text} : (\"точики\"*)")
        XCTAssertEqual(
            pattern?.folded, "{folded file_name_folded link_text_folded} : (\"точики\"*)",
            "the folded tier must always run"
        )
    }

    func testTajikQueryFoldsInTheFoldedTierOnly() {
        let pattern = SearchPatternBuilder.pattern(for: "тоҷикӣ")
        XCTAssertEqual(pattern?.exact, "{exact file_name link_text} : (\"тоҷикӣ\"*)")
        XCTAssertEqual(pattern?.folded, "{folded file_name_folded link_text_folded} : (\"точики\"*)")
    }

    /// Transliteration produces Cyrillic in folded space, so it belongs in the folded tier and
    /// nowhere else.
    func testTransliterationAppearsOnlyInTheFoldedTier() {
        let pattern = SearchPatternBuilder.pattern(for: "chon")
        XCTAssertEqual(pattern?.exact, "{exact file_name link_text} : (\"chon\"*)")
        XCTAssertEqual(
            pattern?.folded,
            "{folded file_name_folded link_text_folded} : (\"chon\"* OR \"чон\"*)"
        )
    }

    func testEveryTextColumnParticipatesInItsTier() {
        let pattern = SearchPatternBuilder.pattern(for: "report")
        for column in SearchIndexSchema.exactColumns {
            XCTAssertTrue(pattern?.exact.contains(column) == true, "exact tier omits \(column)")
        }
        for column in SearchIndexSchema.foldedColumns {
            XCTAssertTrue(pattern?.folded.contains(column) == true, "folded tier omits \(column)")
        }
        XCTAssertFalse(pattern?.exact.contains("dialog_token") == true, "scoping key is not text")
        XCTAssertFalse(pattern?.folded.contains("dialog_token") == true)
    }

    // MARK: - Shape

    func testPrefixAppliesOnlyToTheLastTerm() {
        XCTAssertEqual(exact(of: "hello wor"), "\"hello\" AND \"wor\"*")
        XCTAssertEqual(
            SearchPatternBuilder.pattern(for: "hello wor", prefixMatching: false)
                .map { strip($0.exact) },
            "\"hello\" AND \"wor\""
        )
    }

    func testSingleCharacterFinalTermDoesNotBecomeAPrefix() {
        XCTAssertEqual(exact(of: "a"), "\"a\"")
        XCTAssertEqual(exact(of: "hello a"), "\"hello\" AND \"a\"")
    }

    func testTermCountIsCapped() throws {
        let query = (1...20).map { "term\($0)" }.joined(separator: " ")
        let pattern = try XCTUnwrap(SearchPatternBuilder.pattern(for: query))
        XCTAssertEqual(
            strip(pattern.exact).components(separatedBy: " AND ").count,
            SearchPatternBuilder.maximumTerms
        )
    }

    func testOverlongTermsAreTruncatedAndForcedToPrefix() {
        let long = String(repeating: "a", count: 100)
        let truncated = String(repeating: "a", count: SearchPatternBuilder.maximumTermLength)
        XCTAssertEqual(exact(of: "\(long) tail"), "\"\(truncated)\"* AND \"tail\"*")
    }

    // MARK: - Budgets

    func testHugePasteIsClampedBeforeNormalization() {
        let paste = String(repeating: "салом ", count: 200_000)
        XCTAssertLessThanOrEqual(
            SearchPatternBuilder.clamp(paste).unicodeScalars.count,
            SearchPatternBuilder.maximumQueryScalars
        )
        let started = Date()
        XCTAssertNotNil(SearchPatternBuilder.pattern(for: paste))
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5, "clamping must bound the work")
    }

    func testClampRespectsTheUTF8BudgetForAstralScalars() {
        let clamped = SearchPatternBuilder.clamp(String(repeating: "\u{1F600}", count: 2_000))
        XCTAssertLessThanOrEqual(clamped.utf8.count, SearchPatternBuilder.maximumQueryBytes)
        XCTAssertLessThanOrEqual(
            clamped.unicodeScalars.count, SearchPatternBuilder.maximumQueryScalars
        )
    }

    func testClampNeverSplitsAScalar() {
        for count in [1, 7, 255, 256, 257, 1_000] {
            let clamped = SearchPatternBuilder.clamp(String(repeating: "ҷ", count: count))
            XCTAssertTrue(clamped.unicodeScalars.allSatisfy { $0 == "ҷ" })
        }
    }

    func testDecomposedDiacriticsYieldTheBaseToken() {
        XCTAssertEqual(exact(of: "cafe\u{0301}"), "\"cafe\"*")
        XCTAssertEqual(exact(of: "e\u{0301}galite\u{0301}"), "\"egalite\"*")
        XCTAssertEqual(exact(of: "a\u{05B0}b"), "\"a\" AND \"b\"", "unaccepted mark separates")
        XCTAssertNil(SearchPatternBuilder.pattern(for: "\u{0301}\u{0308}\u{0300}"))
    }

    // MARK: - Dialog scoping

    func testDialogTokenStripsHyphens() {
        XCTAssertEqual(
            SearchPatternBuilder.dialogToken("2F3A9B10-4C5D-6E7F-8A9B-0C1D2E3F4A5B"),
            "2f3a9b104c5d6e7f8a9b0c1d2e3f4a5b"
        )
        XCTAssertEqual(SearchTextNormalizer.tokens(SearchPatternBuilder.dialogToken("a-b-c")).count, 1)
    }

    /// Scoping has to compose with an already column-qualified tier without disturbing it.
    func testScopingComposesWithBothQualifiedTiers() throws {
        let pattern = try XCTUnwrap(SearchPatternBuilder.pattern(for: "салом"))
        XCTAssertEqual(
            SearchPatternBuilder.scoped(pattern.exact, toDialog: "aa-bb"),
            "{dialog_token} : \"aabb\" AND ({exact file_name link_text} : (\"салом\"*))"
        )
        XCTAssertEqual(
            SearchPatternBuilder.scoped(pattern.folded, toDialog: "aa-bb"),
            "{dialog_token} : \"aabb\" AND ({folded file_name_folded link_text_folded} : (\"салом\"*))"
        )
    }

    // MARK: - Helpers

    /// The exact tier with its column filter removed, for asserting term shape.
    private func exact(of query: String) -> String? {
        SearchPatternBuilder.pattern(for: query).map { strip($0.exact) }
    }

    private func strip(_ expression: String) -> String {
        guard let open = expression.firstIndex(of: "("),
              expression.hasSuffix(")") else { return expression }
        return String(expression[expression.index(after: open)..<expression.index(before: expression.endIndex)])
    }
}
