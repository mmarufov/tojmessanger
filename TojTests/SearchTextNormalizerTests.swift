import CryptoKit
import XCTest
@testable import Toj

final class SearchTextNormalizerTests: XCTestCase {
    /// Mixed Tajik, Russian, Latin, titlecase, numerics, private-use, emoji, combining marks and
    /// astral scalars. The invariant tests must hold for every entry, not a hand-picked few.
    private let corpus = [
        "Салом, ҷони ман!", "ТОҶИКӢ", "тоҷикӣ", "точики",
        "Ғафуров қишлоқ ҳаво ӯро", "Привет, как дела?", "ёлка йогурт",
        "Hello world", "İstanbul ıssız", "Straße", "naïve café",
        "e\u{0301}galite\u{0301}", "1234 ½ ² ³", "ǅ ǆ Ǆ",
        "abc\u{E000}def", "\u{E000}", "🇹🇯 salom 👋", "日本語",
        "", "   ", "!!!???", "a-b_c.d",
    ]

    // MARK: - Tajik folding

    func testFoldsTheSixTajikLetters() {
        XCTAssertEqual(SearchTextNormalizer.foldedForm("тоҷикӣ"), "точики")
        XCTAssertEqual(SearchTextNormalizer.foldedForm("Ғафуров"), "гафуров")
        XCTAssertEqual(SearchTextNormalizer.foldedForm("қишлоқ"), "кишлок")
        XCTAssertEqual(SearchTextNormalizer.foldedForm("ҳаво"), "хаво")
        XCTAssertEqual(SearchTextNormalizer.foldedForm("ӯро"), "уро")
        XCTAssertEqual(SearchTextNormalizer.foldedForm("ТОҶИКӢ"), "точики")
    }

    /// ё and й were folded in version 1 on the false premise that unicode61 already did so. It does
    /// not, and folding them merges distinct Russian words. `MessageSearchFTS5Tests` proves the
    /// tokenizer leaves them alone; this pins that we do too.
    func testDoesNotFoldYoOrShortI() {
        XCTAssertEqual(SearchTextNormalizer.foldedForm("ёлка"), "ёлка")
        XCTAssertEqual(SearchTextNormalizer.foldedForm("йогурт"), "йогурт")
        XCTAssertNil(SearchTextNormalizer.folded("ёлка йогурт"))
        XCTAssertEqual(SearchTextNormalizer.tajikFolds.count, 6, "the folded set is deliberately six")
    }

    func testRussianKeyboardSpellingReachesTajikText() {
        XCTAssertEqual(
            SearchTextNormalizer.foldedForm("тоҷикӣ"),
            SearchTextNormalizer.foldedForm("точики")
        )
    }

    func testExactPreservesTajikLetters() {
        XCTAssertEqual(SearchTextNormalizer.exact("ТОҶИКӢ"), "тоҷикӣ")
        XCTAssertNil(SearchTextNormalizer.folded("hello world"))
        XCTAssertNotNil(SearchTextNormalizer.folded("тоҷикӣ"))
    }

    // MARK: - unicode61 parity

    func testLatinDiacriticsAreRemoved() {
        XCTAssertEqual(SearchTextNormalizer.exact("Café"), "cafe")
        XCTAssertEqual(SearchTextNormalizer.exact("naïve"), "naive")
        XCTAssertEqual(SearchTextNormalizer.exact("É"), "e")
    }

    /// Precomposed U+00E9 and decomposed e+U+0301 must reach the same token, as they do in the
    /// tokenizer. They get there differently: the precomposed scalar folds, while the combining
    /// mark is a separator that simply ends the token.
    func testPrecomposedAndDecomposedAccentsAgree() {
        XCTAssertEqual(SearchTextNormalizer.tokens(SearchTextNormalizer.exact("café")), ["cafe"])
        XCTAssertEqual(
            SearchTextNormalizer.tokens(SearchTextNormalizer.exact("cafe\u{0301}")), ["cafe"]
        )
    }

    func testTitlecaseScalarsFoldToLowercase() {
        XCTAssertEqual(SearchTextNormalizer.exact("ǅ"), "ǆ")
        XCTAssertEqual(SearchTextNormalizer.exact("Ǆ"), "ǆ")
        XCTAssertEqual(SearchTextNormalizer.exact("İstanbul"), "istanbul")
    }

    /// unicode61 leaves ı alone. Version 1 mapped it to i, diverging from the tokenizer for no
    /// benefit in a market that writes no Turkish.
    func testDotlessIIsNotFolded() {
        XCTAssertEqual(SearchTextNormalizer.exact("ıssız"), "ıssız")
    }

    func testNumericAndPrivateUseScalarsAreTokenCharacters() {
        XCTAssertTrue(SearchTextNormalizer.isTokenScalar("½"))
        XCTAssertTrue(SearchTextNormalizer.isTokenScalar("²"))
        XCTAssertTrue(SearchTextNormalizer.isTokenScalar("\u{E000}"), "private use is Co, a token class")
        XCTAssertTrue(SearchTextNormalizer.isTokenScalar("日"))
        XCTAssertEqual(SearchTextNormalizer.tokens("½ ² 5"), ["½", "²", "5"])
        XCTAssertEqual(SearchTextNormalizer.tokens("abc\u{E000}def"), ["abc\u{E000}def"])
    }

    func testEmojiAndPunctuationSeparate() {
        XCTAssertFalse(SearchTextNormalizer.isTokenScalar("\u{1F600}"))
        XCTAssertFalse(SearchTextNormalizer.isTokenScalar(" "))
        XCTAssertFalse(SearchTextNormalizer.isTokenScalar("-"))
        XCTAssertFalse(SearchTextNormalizer.isTokenScalar("\u{0301}"))
        XCTAssertEqual(SearchTextNormalizer.tokens("салом, ҷони ман!"), ["салом", "ҷони", "ман"])
        XCTAssertEqual(SearchTextNormalizer.tokens("a-b_c.d"), ["a", "b", "c", "d"])
        XCTAssertEqual(SearchTextNormalizer.tokens("!!! ??? 🙂"), [])
    }

    // MARK: - Invariants

    func testNormalizationIsIdempotent() {
        for input in corpus {
            let exact = SearchTextNormalizer.exact(input)
            XCTAssertEqual(SearchTextNormalizer.exact(exact), exact, "exact: \(input)")
            let folded = SearchTextNormalizer.foldedForm(input)
            XCTAssertEqual(SearchTextNormalizer.foldedForm(folded), folded, "folded: \(input)")
        }
    }

    /// The identity range mapping in `highlightRanges` is only sound while this holds.
    func testNormalizationIsScalarPreserving() {
        for input in corpus {
            XCTAssertEqual(
                SearchTextNormalizer.exact(input).unicodeScalars.count,
                input.unicodeScalars.count, "exact: \(input)"
            )
            XCTAssertEqual(
                SearchTextNormalizer.foldedForm(input).unicodeScalars.count,
                input.unicodeScalars.count, "folded: \(input)"
            )
        }
    }

    func testNormalizationIgnoresCurrentLocale() {
        // Nothing consults Locale or ICU; this fails loudly if someone reaches for
        // `lowercased(with:)` or `Unicode.Scalar.Properties`.
        XCTAssertEqual(SearchTextNormalizer.exact("TITLE Iı İ"), "title iı i")
    }

    // MARK: - Highlighting

    /// The range-mapping proof: a query without accents highlights text with them, and the range
    /// lands on the original characters so display keeps the accent.
    func testAsciiQueryHighlightsAccentedOriginal() throws {
        let original = "Meet at Café Rumi"
        let ranges = SearchTextNormalizer.highlightRanges(of: "cafe", in: original)
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(String(original[try XCTUnwrap(ranges.first)]), "Café")
    }

    func testHighlightAbsorbsTrailingCombiningMarks() throws {
        let original = "Meet at Cafe\u{0301} Rumi"
        let ranges = SearchTextNormalizer.highlightRanges(of: "cafe", in: original)
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(String(original[try XCTUnwrap(ranges.first)]), "Cafe\u{0301}")
    }

    func testHighlightFindsTajikTextFromRussianKeyboardQuery() throws {
        let original = "Салом ҷони ман"
        let ranges = SearchTextNormalizer.highlightRanges(of: "чони", in: original)
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(String(original[try XCTUnwrap(ranges.first)]), "ҷони")
    }

    func testHighlightIsTokenAlignedAndPrefixMatching() {
        let original = "salom salomat malosa"
        let ranges = SearchTextNormalizer.highlightRanges(of: "salom", in: original)
        XCTAssertEqual(ranges.map { String(original[$0]) }, ["salom", "salomat"])
    }

    func testHighlightHandlesEmptyAndUnmatchedQueries() {
        XCTAssertTrue(SearchTextNormalizer.highlightRanges(of: "", in: "salom").isEmpty)
        XCTAssertTrue(SearchTextNormalizer.highlightRanges(of: "!!!", in: "salom").isEmpty)
        XCTAssertTrue(SearchTextNormalizer.highlightRanges(of: "zzz", in: "salom").isEmpty)
    }

    // MARK: - Latin transliteration

    func testCyrillicCandidateTransliteratesTajikLatin() {
        XCTAssertEqual(SearchTextNormalizer.cyrillicCandidate("salom"), "салом")
        XCTAssertEqual(SearchTextNormalizer.cyrillicCandidate("chon"), "чон")
        XCTAssertEqual(SearchTextNormalizer.cyrillicCandidate("shchi"), "щи")
    }

    func testCyrillicCandidateIsNilForCyrillicOrMixedInput() {
        XCTAssertNil(SearchTextNormalizer.cyrillicCandidate("салом"))
        XCTAssertNil(SearchTextNormalizer.cyrillicCandidate("salom салом"))
        XCTAssertNil(SearchTextNormalizer.cyrillicCandidate("123"))
    }

    // MARK: - Cross-implementation contract

    /// Every vector in the shared fixture, which the Bun server must also satisfy. The expectations
    /// are produced by an independent Python implementation over the same probed tokenizer data,
    /// so agreement is evidence rather than a tautology.
    func testMatchesSharedNormalizerVectors() throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // TojTests
            .deletingLastPathComponent()      // repo root
            .appending(path: "server/src/search-normalizer-vectors.json")
        let data = try Data(contentsOf: fixture)
        let decoded = try JSONDecoder().decode(NormalizerVectorFile.self, from: data)

        XCTAssertEqual(
            decoded.normalizerVersion, SearchTextNormalizer.version,
            "regenerate the vectors when the normalizer version changes"
        )
        XCTAssertEqual(decoded.tokenize, SearchIndexSchema.tokenize)
        XCTAssertGreaterThan(decoded.vectors.count, 20)

        for vector in decoded.vectors {
            XCTAssertEqual(
                SearchTextNormalizer.exact(vector.input), vector.exact,
                "exact mismatch for \(vector.input.debugDescription)"
            )
            XCTAssertEqual(
                SearchTextNormalizer.folded(vector.input), vector.folded,
                "folded mismatch for \(vector.input.debugDescription)"
            )
            XCTAssertEqual(
                SearchTextNormalizer.tokens(SearchTextNormalizer.foldedForm(vector.input)),
                vector.tokens,
                "tokens mismatch for \(vector.input.debugDescription)"
            )
        }
    }

    /// `normalizer_version` has to cover the generated tables too, not just this file. Regenerating
    /// them for a new SQLite release is a token-affecting change that silently invalidates every
    /// on-device index unless the version moves with it.
    func testGeneratedTablesMatchPinnedDigest() {
        var hasher = SHA256()
        for value in SearchUnicodeTables.tokenRanges { hasher.update(data: withUnsafeBytes(of: value.littleEndian) { Data($0) }) }
        for value in SearchUnicodeTables.foldPairs { hasher.update(data: withUnsafeBytes(of: value.littleEndian) { Data($0) }) }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()

        XCTAssertEqual(
            digest, Self.pinnedTableDigest,
            """
            SearchUnicodeTables changed. That alters tokenization, so bump \
            SearchTextNormalizer.version, regenerate server/src/search-normalizer-vectors.json, \
            and update pinnedTableDigest.
            """
        )
    }

    /// Digest of the tables generated for normalizer version 2.
    private static let pinnedTableDigest =
        "39c343ab9c1ad006d41c7e0c093481f1af5fada1ed97c68b4623255a580768a4"

    private struct NormalizerVectorFile: Decodable {
        let normalizerVersion: Int
        let tokenize: String
        let vectors: [Vector]

        struct Vector: Decodable {
            let input: String
            let exact: String
            let folded: String?
            let tokens: [String]
        }
    }
}
