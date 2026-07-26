import XCTest
@testable import Toj

final class SearchPatternBuilderTests: XCTestCase {
    /// Every one of these is either an FTS5 operator or malformed syntax. Passed through verbatim
    /// they raise SQLITE_ERROR at query time — a crash that only real user text triggers.
    private let adversarialQueries = [
        "AND", "OR", "NOT", "NEAR", "NEAR(a b, 2)",
        "\"", "\"\"", "\"unterminated", "a\"b",
        "*", "**", "a*", "^abc", "-abc", "a:b", "{col}:x",
        "(", ")", "()", "a AND (b OR c)",
        "a OR b", "a NOT b", "column:value",
        "'; DROP TABLE messages; --",
        String(repeating: "a", count: 10_000),
        String(repeating: "a ", count: 500),
    ]

    // MARK: - Safety

    func testOperatorsAndQuotesAreNeutralized() {
        XCTAssertEqual(SearchPatternBuilder.pattern(for: "AND")?.exact, "\"and\"*")
        XCTAssertEqual(SearchPatternBuilder.pattern(for: "column:value")?.exact, "\"column\" AND \"value\"*")
        XCTAssertEqual(SearchPatternBuilder.pattern(for: "^abc")?.exact, "\"abc\"*")
        // Trailing single-character terms stay exact — see
        // `testSingleCharacterFinalTermDoesNotBecomeAPrefix`.
        XCTAssertEqual(SearchPatternBuilder.pattern(for: "a OR b")?.exact, "\"a\" AND \"or\" AND \"b\"")
        XCTAssertEqual(SearchPatternBuilder.pattern(for: "a*")?.exact, "\"a\"")
    }

    /// Operator characters are not alphanumeric, so tokenization drops them by construction. This
    /// pins that property rather than the specific escaping, which is the actual guarantee.
    func testNoAdversarialInputEmitsOperatorCharacters() {
        for query in adversarialQueries {
            guard let pattern = SearchPatternBuilder.pattern(for: query) else { continue }
            for expression in [pattern.exact, pattern.folded].compactMap({ $0 }) {
                // Strip the structural tokens we emit ourselves, then assert nothing dangerous is left.
                let body = expression
                    .replacingOccurrences(of: " AND ", with: " ")
                    .replacingOccurrences(of: " OR ", with: " ")
                    .replacingOccurrences(of: "\"", with: "")
                    .replacingOccurrences(of: "*", with: "")
                XCTAssertFalse(
                    body.contains(where: { "():^-".contains($0) }),
                    "operator character survived for input \(query.prefix(40)): \(expression.prefix(80))"
                )
            }
        }
    }

    func testUnsearchableInputProducesNoPattern() {
        XCTAssertNil(SearchPatternBuilder.pattern(for: ""))
        XCTAssertNil(SearchPatternBuilder.pattern(for: "   "))
        XCTAssertNil(SearchPatternBuilder.pattern(for: "!!! ??? ..."))
        XCTAssertNil(SearchPatternBuilder.pattern(for: "🙂👋"))
        XCTAssertNil(SearchPatternBuilder.pattern(for: "\""))
    }

    // MARK: - Shape

    func testPrefixAppliesOnlyToTheLastTerm() {
        XCTAssertEqual(
            SearchPatternBuilder.pattern(for: "hello wor")?.exact,
            "\"hello\" AND \"wor\"*"
        )
    }

    func testPrefixIsOmittedWhenNotTyping() {
        XCTAssertEqual(
            SearchPatternBuilder.pattern(for: "hello wor", prefixMatching: false)?.exact,
            "\"hello\" AND \"wor\""
        )
    }

    /// A one-character prefix scan walks most of the term index for no precision gain.
    func testSingleCharacterFinalTermDoesNotBecomeAPrefix() {
        XCTAssertEqual(SearchPatternBuilder.pattern(for: "a")?.exact, "\"a\"")
        XCTAssertEqual(SearchPatternBuilder.pattern(for: "hello a")?.exact, "\"hello\" AND \"a\"")
    }

    func testTermCountIsCapped() throws {
        let query = (1...20).map { "term\($0)" }.joined(separator: " ")
        let pattern = try XCTUnwrap(SearchPatternBuilder.pattern(for: query))
        XCTAssertEqual(
            pattern.exact.components(separatedBy: " AND ").count,
            SearchPatternBuilder.maximumTerms
        )
    }

    /// A truncated term must still match the word it came from, so it is forced to a prefix even
    /// when it is not the last term.
    func testOverlongTermsAreTruncatedAndForcedToPrefix() {
        let long = String(repeating: "a", count: 100)
        let pattern = SearchPatternBuilder.pattern(for: "\(long) tail")
        let expected = "\"\(String(repeating: "a", count: SearchPatternBuilder.maximumTermLength))\"* AND \"tail\"*"
        XCTAssertEqual(pattern?.exact, expected)
    }

    // MARK: - Tiering

    func testFoldedTierIsAbsentWhenNothingToFold() {
        XCTAssertNil(SearchPatternBuilder.pattern(for: "привет")?.folded)
    }

    func testFoldedTierCarriesTheRussianKeyboardForm() {
        let pattern = SearchPatternBuilder.pattern(for: "тоҷикӣ")
        XCTAssertEqual(pattern?.exact, "\"тоҷикӣ\"*")
        XCTAssertEqual(pattern?.folded, "\"точики\"*")
    }

    /// Latin input gets a transliteration alternative. The store only runs the folded tier when the
    /// exact tier under-fills a page, so an English query never pays for this.
    func testLatinInputGetsATransliterationAlternative() {
        XCTAssertEqual(SearchPatternBuilder.pattern(for: "salom")?.folded, "\"салом\"*")
    }

    // MARK: - Dialog scoping

    func testDialogTokenStripsHyphensSoTheUUIDIsOneToken() {
        XCTAssertEqual(
            SearchPatternBuilder.dialogToken("2F3A9B10-4C5D-6E7F-8A9B-0C1D2E3F4A5B"),
            "2f3a9b104c5d6e7f8a9b0c1d2e3f4a5b"
        )
        XCTAssertEqual(SearchTextNormalizer.tokens(SearchPatternBuilder.dialogToken("a-b-c")).count, 1)
    }

    func testScopingBindsTheColumnFilterToTheDialogPhraseOnly() {
        let scoped = SearchPatternBuilder.scoped("\"salom\"*", toDialog: "aa-bb")
        XCTAssertEqual(scoped, "{dialog_token} : \"aabb\" AND (\"salom\"*)")
    }
}
