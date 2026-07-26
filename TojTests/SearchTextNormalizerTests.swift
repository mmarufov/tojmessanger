import XCTest
@testable import Toj

final class SearchTextNormalizerTests: XCTestCase {
    /// Mixed Tajik, Russian, Latin, digits, punctuation, emoji and combining marks. Used by the
    /// invariant tests, which must hold for every input rather than a hand-picked few.
    private let corpus = [
        "Салом, ҷони ман!",
        "ТОҶИКӢ",
        "тоҷикӣ",
        "Ғафуров қишлоқ ҳаво ӯро",
        "Привет, как дела?",
        "Hello world",
        "İstanbul ıssız",
        "Straße",
        "naïve café",
        "1234 5678",
        "🇹🇯 salom 👋",
        "",
        "   ",
        "!!!???",
        "e\u{0301}galite\u{0301}",  // combining acute
    ]

    // MARK: - Folding

    func testFoldsTajikDescendersToRussianKeyboardLookalikes() {
        XCTAssertEqual(SearchTextNormalizer.foldedForm("тоҷикӣ"), "точики")
        XCTAssertEqual(SearchTextNormalizer.foldedForm("Ғафуров"), "гафуров")
        XCTAssertEqual(SearchTextNormalizer.foldedForm("қишлоқ"), "кишлок")
        XCTAssertEqual(SearchTextNormalizer.foldedForm("ҳаво"), "хаво")
        XCTAssertEqual(SearchTextNormalizer.foldedForm("ӯро"), "уро")
        XCTAssertEqual(SearchTextNormalizer.foldedForm("ҷони"), "чони")
    }

    func testFoldsUppercaseTajikToo() {
        XCTAssertEqual(SearchTextNormalizer.foldedForm("ТОҶИКӢ"), "точики")
        XCTAssertEqual(SearchTextNormalizer.foldedForm("ҚИШЛОҚ"), "кишлок")
    }

    func testExactPreservesTajikLettersAndOnlyLowercases() {
        XCTAssertEqual(SearchTextNormalizer.exact("ТОҶИКӢ"), "тоҷикӣ")
        XCTAssertEqual(SearchTextNormalizer.exact("Ғафуров"), "ғафуров")
    }

    func testFoldedIsNilWhenNothingToFold() {
        XCTAssertNil(SearchTextNormalizer.folded("hello world"))
        XCTAssertNil(SearchTextNormalizer.folded("привет"))
        XCTAssertNotNil(SearchTextNormalizer.folded("тоҷикӣ"))
    }

    /// The whole point of the folded column: a Russian keyboard has no ҷ, so users type ч.
    func testRussianKeyboardSpellingReachesTajikText() {
        XCTAssertEqual(
            SearchTextNormalizer.foldedForm("тоҷикӣ"),
            SearchTextNormalizer.foldedForm("точики"),
            "a Russian-keyboard query and the Tajik original must land on the same folded form"
        )
    }

    // MARK: - Invariants

    /// If this breaks, indexed text and query text disagree and search silently half-works.
    func testNormalizationIsIdempotent() {
        for input in corpus {
            let exact = SearchTextNormalizer.exact(input)
            XCTAssertEqual(SearchTextNormalizer.exact(exact), exact, "exact not idempotent: \(input)")

            let folded = SearchTextNormalizer.foldedForm(input)
            XCTAssertEqual(
                SearchTextNormalizer.foldedForm(folded), folded,
                "foldedForm not idempotent: \(input)"
            )
        }
    }

    /// Highlight ranges are found in the folded text and applied to the original, so the two must
    /// agree scalar-for-scalar. `String.lowercased()` and `String.folding(options:)` both fail this.
    func testNormalizationIsScalarPreserving() {
        for input in corpus {
            XCTAssertEqual(
                SearchTextNormalizer.exact(input).unicodeScalars.count,
                input.unicodeScalars.count,
                "exact changed scalar count: \(input)"
            )
            XCTAssertEqual(
                SearchTextNormalizer.foldedForm(input).unicodeScalars.count,
                input.unicodeScalars.count,
                "foldedForm changed scalar count: \(input)"
            )
        }
    }

    /// `İ` full-case-lowercases to `i` + U+0307, which would break scalar preservation, and under a
    /// Turkish locale a naive implementation would map `I` to `ı` instead of `i`.
    func testTurkishDottedAndDotlessIFoldToPlainI() {
        XCTAssertEqual(SearchTextNormalizer.exact("İ"), "i")
        XCTAssertEqual(SearchTextNormalizer.exact("ı"), "i")
        XCTAssertEqual(SearchTextNormalizer.exact("İstanbul"), "istanbul")
    }

    func testNormalizationIgnoresCurrentLocale() {
        // Nothing in the normalizer consults Locale; this pins that so a future refactor to
        // `lowercased(with:)` fails loudly rather than corrupting Turkish and Azeri text.
        XCTAssertEqual(SearchTextNormalizer.exact("TITLE Iı İ"), "title ii i")
    }

    // MARK: - Tokenization

    func testTokensSplitOnNonAlphanumerics() {
        XCTAssertEqual(SearchTextNormalizer.tokens("салом, ҷони ман!"), ["салом", "ҷони", "ман"])
        XCTAssertEqual(SearchTextNormalizer.tokens("a-b_c.d"), ["a", "b", "c", "d"])
        XCTAssertEqual(SearchTextNormalizer.tokens("file2024.pdf"), ["file2024", "pdf"])
    }

    func testTokensDropPunctuationOnlyInput() {
        XCTAssertEqual(SearchTextNormalizer.tokens("!!! ??? ..."), [])
        XCTAssertEqual(SearchTextNormalizer.tokens("   "), [])
        XCTAssertEqual(SearchTextNormalizer.tokens(""), [])
    }

    // MARK: - Latin transliteration

    func testCyrillicCandidateTransliteratesTajikLatin() {
        XCTAssertEqual(SearchTextNormalizer.cyrillicCandidate("salom"), "салом")
        XCTAssertEqual(SearchTextNormalizer.cyrillicCandidate("chon"), "чон")
        XCTAssertEqual(SearchTextNormalizer.cyrillicCandidate("shab"), "шаб")
    }

    func testCyrillicCandidatePrefersLongestDigraph() {
        // "shch" must win over "sh", which must win over "s".
        XCTAssertEqual(SearchTextNormalizer.cyrillicCandidate("shchi"), "щи")
    }

    func testCyrillicCandidateIsNilForCyrillicOrMixedInput() {
        XCTAssertNil(SearchTextNormalizer.cyrillicCandidate("салом"))
        XCTAssertNil(SearchTextNormalizer.cyrillicCandidate("salom салом"))
        XCTAssertNil(SearchTextNormalizer.cyrillicCandidate("123"))
    }
}
