import CryptoKit
import XCTest
@testable import Toj

final class SearchTextNormalizerTests: XCTestCase {
    /// Tajik, Russian, Latin, titlecase, numerics, private-use, emoji, decomposed diacritics,
    /// non-accepted combining marks, CJK and astral scalars. The invariant tests hold for all of it.
    private let corpus = [
        "Салом, ҷони ман!", "ТОҶИКӢ", "тоҷикӣ", "точики",
        "Ғафуров қишлоқ ҳаво ӯро", "Привет, как дела?", "ёлка йогурт",
        "Hello world", "İstanbul ıssız", "Straße", "naïve café",
        "e\u{0301}galite\u{0301}", "a\u{0301}b", "\u{0301}ab", "ab\u{0301}", "a\u{05B0}b",
        "1234 ½ ² ³", "ǅ ǆ Ǆ", "abc\u{E000}def", "\u{E000}",
        "🇹🇯 salom 👋", "日本語", "", "   ", "!!!???", "a-b_c.d",
    ]

    // MARK: - Three scalar classes

    /// unicode61 does not divide scalars in two. Version 2 assumed it did and classified the 25
    /// accepted diacritics as separators, so any text with a combining mark tokenized differently
    /// from the index that stored it.
    func testScalarClassification() {
        XCTAssertEqual(SearchTextNormalizer.classify("a"), .token)
        XCTAssertEqual(SearchTextNormalizer.classify("½"), .token)
        XCTAssertEqual(SearchTextNormalizer.classify("²"), .token)
        XCTAssertEqual(SearchTextNormalizer.classify("日"), .token)
        XCTAssertEqual(SearchTextNormalizer.classify("\u{E000}"), .token, "private use is Co")
        XCTAssertEqual(SearchTextNormalizer.classify("\u{0301}"), .ignored, "accepted diacritic")
        XCTAssertEqual(SearchTextNormalizer.classify("\u{0308}"), .ignored)
        XCTAssertEqual(SearchTextNormalizer.classify(" "), .separator)
        XCTAssertEqual(SearchTextNormalizer.classify("-"), .separator)
        XCTAssertEqual(SearchTextNormalizer.classify("\u{1F600}"), .separator, "assigned emoji")
        XCTAssertEqual(
            SearchTextNormalizer.classify("\u{1F642}"), .token,
            "unicode61 defaults scalars newer than its tables to alphanumeric"
        )
        XCTAssertEqual(
            SearchTextNormalizer.classify("\u{05B0}"), .separator,
            "a combining mark unicode61 does not accept still separates"
        )
        XCTAssertEqual(SearchUnicodeTables.ignoredScalars.count, 25)
    }

    /// The regression that motivated the three-class model.
    func testIgnoredDiacriticsDoNotEndTokens() {
        XCTAssertEqual(SearchTextNormalizer.tokens("e\u{0301}galite\u{0301}"), ["egalite"])
        XCTAssertEqual(SearchTextNormalizer.tokens("a\u{0301}b"), ["ab"])
        XCTAssertEqual(SearchTextNormalizer.tokens("a\u{0301}\u{0308}b"), ["ab"])
        XCTAssertEqual(SearchTextNormalizer.tokens("ab\u{0301}"), ["ab"])
    }

    /// An ignored scalar is dropped rather than opening a token, so a leading diacritic behaves
    /// like a separator without being one.
    func testLeadingDiacriticsDoNotStartTokens() {
        XCTAssertEqual(SearchTextNormalizer.tokens("\u{0301}ab"), ["ab"])
        XCTAssertEqual(SearchTextNormalizer.tokens("\u{0301}"), [])
        XCTAssertEqual(SearchTextNormalizer.tokens("\u{0301}\u{0308}\u{0300}"), [])
    }

    func testNonAcceptedCombiningMarksSeparate() {
        XCTAssertEqual(SearchTextNormalizer.tokens("a\u{05B0}b"), ["a", "b"])
    }

    func testTokenClassesMatchMeasuredTable() {
        XCTAssertEqual(SearchTextNormalizer.tokens("½ ² 5"), ["½", "²", "5"])
        XCTAssertEqual(SearchTextNormalizer.tokens("abc\u{E000}def"), ["abc\u{E000}def"])
        XCTAssertEqual(SearchTextNormalizer.tokens("салом, ҷони ман!"), ["салом", "ҷони", "ман"])
        XCTAssertEqual(SearchTextNormalizer.tokens("a-b_c.d"), ["a", "b", "c", "d"])
        XCTAssertEqual(SearchTextNormalizer.tokens("!!! ??? 😀"), [])
    }

    // MARK: - Folding

    func testFoldsTheSixTajikLetters() {
        XCTAssertEqual(SearchTextNormalizer.foldedForm("тоҷикӣ"), "точики")
        XCTAssertEqual(SearchTextNormalizer.foldedForm("Ғафуров"), "гафуров")
        XCTAssertEqual(SearchTextNormalizer.foldedForm("қишлоқ"), "кишлок")
        XCTAssertEqual(SearchTextNormalizer.foldedForm("ҳаво"), "хаво")
        XCTAssertEqual(SearchTextNormalizer.foldedForm("ӯро"), "уро")
        XCTAssertEqual(SearchTextNormalizer.foldedForm("ТОҶИКӢ"), "точики")
        XCTAssertEqual(SearchTextNormalizer.tajikFolds.count, 6, "deliberately six")
    }

    func testDoesNotFoldYoOrShortI() {
        XCTAssertEqual(SearchTextNormalizer.foldedForm("ёлка"), "ёлка")
        XCTAssertEqual(SearchTextNormalizer.foldedForm("йогурт"), "йогурт")
        XCTAssertNil(SearchTextNormalizer.folded("ёлка йогурт"))
    }

    func testLatinDiacriticsAndTitlecaseFoldViaTheTable() {
        XCTAssertEqual(SearchTextNormalizer.exact("Café"), "cafe")
        XCTAssertEqual(SearchTextNormalizer.exact("naïve"), "naive")
        XCTAssertEqual(SearchTextNormalizer.exact("ǅ"), "ǆ")
        XCTAssertEqual(SearchTextNormalizer.exact("Ǆ"), "ǆ")
        XCTAssertEqual(SearchTextNormalizer.exact("İstanbul"), "istanbul")
        XCTAssertEqual(SearchTextNormalizer.exact("ıssız"), "ıssız", "unicode61 leaves ı alone")
    }

    // MARK: - Invariants

    func testNormalizationIsIdempotent() {
        for input in corpus {
            let exact = SearchTextNormalizer.exact(input)
            XCTAssertEqual(SearchTextNormalizer.exact(exact), exact, "exact: \(input.debugDescription)")
            let folded = SearchTextNormalizer.foldedForm(input)
            XCTAssertEqual(
                SearchTextNormalizer.foldedForm(folded), folded, "folded: \(input.debugDescription)"
            )
        }
    }

    /// The identity range mapping in `highlightRanges` is only sound while this holds. Ignored and
    /// separator scalars pass through untouched precisely so it does.
    func testNormalizationIsScalarPreserving() {
        for input in corpus {
            XCTAssertEqual(
                SearchTextNormalizer.exact(input).unicodeScalars.count,
                input.unicodeScalars.count, "exact: \(input.debugDescription)"
            )
            XCTAssertEqual(
                SearchTextNormalizer.foldedForm(input).unicodeScalars.count,
                input.unicodeScalars.count, "folded: \(input.debugDescription)"
            )
        }
    }

    func testNormalizationIgnoresCurrentLocale() {
        XCTAssertEqual(SearchTextNormalizer.exact("TITLE Iı İ"), "title iı i")
    }

    /// `tokens` and `highlightRanges` must never disagree about token boundaries, which is why both
    /// go through `forEachToken`.
    func testTokenWalkerSpansAgreeWithTokens() {
        for input in corpus {
            let folded = SearchTextNormalizer.foldedForm(input)
            var walked: [String] = []
            var spans: [Range<Int>] = []
            SearchTextNormalizer.forEachToken(in: folded) { token, span in
                walked.append(token)
                spans.append(span)
            }
            XCTAssertEqual(walked, SearchTextNormalizer.tokens(folded), input.debugDescription)
            let scalars = Array(folded.unicodeScalars)
            for (token, span) in zip(walked, spans) {
                XCTAssertLessThanOrEqual(span.upperBound, scalars.count)
                // The span covers the token plus any ignored scalars interleaved within it.
                let slice = String(String.UnicodeScalarView(scalars[span]))
                XCTAssertEqual(
                    SearchTextNormalizer.tokens(slice), [token],
                    "span does not re-tokenize to its own token"
                )
            }
        }
    }

    // MARK: - Highlighting

    func testAsciiQueryHighlightsAccentedOriginal() throws {
        let original = "Meet at Café Rumi"
        let ranges = SearchTextNormalizer.highlightRanges(of: "cafe", in: original)
        XCTAssertEqual(ranges.map { String(original[$0]) }, ["Café"])
    }

    func testHighlightSpansInternalDecomposedDiacritics() throws {
        let original = "Say e\u{0301}galite\u{0301} now"
        let ranges = SearchTextNormalizer.highlightRanges(of: "egalite", in: original)
        XCTAssertEqual(ranges.map { String(original[$0]) }, ["e\u{0301}galite\u{0301}"])
    }

    func testHighlightCoversTrailingDecomposedDiacritic() {
        let original = "Meet at Cafe\u{0301} Rumi"
        let ranges = SearchTextNormalizer.highlightRanges(of: "cafe", in: original)
        XCTAssertEqual(ranges.map { String(original[$0]) }, ["Cafe\u{0301}"])
    }

    func testHighlightExcludesLeadingDiacriticThatStartsNoToken() {
        let original = "\u{0301}ab cd"
        let ranges = SearchTextNormalizer.highlightRanges(of: "ab", in: original)
        XCTAssertEqual(ranges.map { String(original[$0]) }, ["ab"])
    }

    func testHighlightFindsTajikTextFromRussianKeyboardQuery() {
        let original = "Салом ҷони ман"
        let ranges = SearchTextNormalizer.highlightRanges(of: "чони", in: original)
        XCTAssertEqual(ranges.map { String(original[$0]) }, ["ҷони"])
    }

    /// Transliteration reaches rows through the folded tier, so highlighting has to consider the
    /// same alternative or a result renders with nothing marked.
    func testHighlightConsidersTransliterationCandidate() {
        XCTAssertEqual(
            SearchTextNormalizer.highlightRanges(of: "chon", in: "Салом ҷон").map { String("Салом ҷон"[$0]) },
            ["ҷон"]
        )
        XCTAssertEqual(
            SearchTextNormalizer.highlightRanges(of: "salom", in: "Салом ҷон").map { String("Салом ҷон"[$0]) },
            ["Салом"]
        )
    }

    func testHighlightIsTokenAlignedAndPrefixMatching() {
        let original = "salom salomat malosa"
        XCTAssertEqual(
            SearchTextNormalizer.highlightRanges(of: "salom", in: original).map { String(original[$0]) },
            ["salom", "salomat"]
        )
    }

    func testHighlightHandlesEmptyAndUnmatchedQueries() {
        XCTAssertTrue(SearchTextNormalizer.highlightRanges(of: "", in: "salom").isEmpty)
        XCTAssertTrue(SearchTextNormalizer.highlightRanges(of: "!!!", in: "salom").isEmpty)
        XCTAssertTrue(SearchTextNormalizer.highlightRanges(of: "zzz", in: "salom").isEmpty)
    }

    // MARK: - Transliteration

    func testCyrillicCandidate() {
        XCTAssertEqual(SearchTextNormalizer.cyrillicCandidate("salom"), "салом")
        XCTAssertEqual(SearchTextNormalizer.cyrillicCandidate("chon"), "чон")
        XCTAssertEqual(SearchTextNormalizer.cyrillicCandidate("shchi"), "щи")
        XCTAssertNil(SearchTextNormalizer.cyrillicCandidate("салом"))
        XCTAssertNil(SearchTextNormalizer.cyrillicCandidate("salom салом"))
        XCTAssertNil(SearchTextNormalizer.cyrillicCandidate("123"))
    }

    // MARK: - Cross-implementation contract

    /// Loaded from the test bundle, not from a Mac source path, so this passes on a device and in a
    /// detached build. The same file is committed under server/src for Bun to consume.
    func testMatchesSharedNormalizerVectors() throws {
        let decoded = try Self.loadVectors()

        XCTAssertEqual(decoded.normalizerVersion, SearchTextNormalizer.version)
        XCTAssertEqual(decoded.tokenize, SearchIndexSchema.tokenize)
        XCTAssertGreaterThan(decoded.vectors.count, 30)

        for vector in decoded.vectors {
            let label = vector.input.debugDescription
            XCTAssertEqual(SearchTextNormalizer.exact(vector.input), vector.exact, "exact \(label)")
            XCTAssertEqual(SearchTextNormalizer.folded(vector.input), vector.folded, "folded \(label)")
            XCTAssertEqual(
                SearchTextNormalizer.tokens(SearchTextNormalizer.foldedForm(vector.input)),
                vector.tokens, "tokens \(label)"
            )
        }
    }

    /// Recomputes every manifest digest in Swift and compares against the committed file.
    ///
    /// This replaced a single hand-pinned constant. The constant covered the tables and maps but
    /// nothing else, and a regex in CI covered only the token-affecting edits someone had thought
    /// to enumerate — neither could see a change to `classify`, `forEachToken`, or the tokenizer
    /// string. The manifest is total: `behavior` digests what the walker actually produces, which
    /// is the only way to cover a state machine.
    ///
    /// Serialization must match `scripts/generate-search-manifest.py` byte for byte, including
    /// sorting by UTF-8 bytes — Swift compares Strings under canonical equivalence, so sorting by
    /// `String` would disagree with Python on the decomposed vectors.
    func testManifestDigestsMatchSwiftBehaviour() throws {
        let manifest = try Self.loadManifest()

        XCTAssertEqual(
            manifest.tokenizer, SearchIndexSchema.tokenize,
            "the manifest is the single source for the tokenizer configuration"
        )
        XCTAssertEqual(manifest.normalizerVersion, SearchTextNormalizer.version)

        // tables
        var hasher = SHA256()
        func feed(_ value: UInt32) {
            hasher.update(data: withUnsafeBytes(of: value.littleEndian) { Data($0) })
        }
        for (name, values) in [
            ("separatorRanges", SearchUnicodeTables.separatorRanges),
            ("ignoredScalars", SearchUnicodeTables.ignoredScalars),
            ("foldPairs", SearchUnicodeTables.foldPairs),
        ] {
            hasher.update(data: Data("\(name):\(values.count)".utf8))
            for value in values { feed(value) }
        }
        XCTAssertEqual(Self.hex(hasher.finalize()), manifest.digests.tables, "tables digest")

        // maps
        hasher = SHA256()
        func feedMap(_ name: String, _ pairs: [(String, UInt32)]) {
            let sorted = pairs.sorted { Array($0.0.utf8).lexicographicallyPrecedes(Array($1.0.utf8)) }
            hasher.update(data: Data("\(name):\(sorted.count)".utf8))
            for (key, value) in sorted {
                hasher.update(data: Data(key.utf8))
                hasher.update(data: Data([0x1F]))
                hasher.update(data: withUnsafeBytes(of: value.littleEndian) { Data($0) })
                hasher.update(data: Data([0x1E]))
            }
        }
        feedMap("tajikFolds", SearchTextNormalizer.tajikFolds.map { (String($0.key), $0.value.value) })
        feedMap("latinDigraphs", SearchTextNormalizer.latinDigraphs.map { ($0.key, $0.value.value) })
        feedMap("latinLetters", SearchTextNormalizer.latinLetters.map { (String($0.key), $0.value.value) })
        XCTAssertEqual(Self.hex(hasher.finalize()), manifest.digests.maps, "maps digest")

        // behavior — computed from Swift's own output, not read back from the fixture, so a
        // divergence between Swift and the generator surfaces here rather than shipping.
        let vectors = try Self.loadVectors().vectors
            .sorted { Array($0.input.utf8).lexicographicallyPrecedes(Array($1.input.utf8)) }
        hasher = SHA256()
        for vector in vectors {
            hasher.update(data: Data(vector.input.utf8))
            hasher.update(data: Data([0x1F]))
            hasher.update(data: Data(SearchTextNormalizer.exact(vector.input).utf8))
            hasher.update(data: Data([0x1F]))
            hasher.update(data: Data((SearchTextNormalizer.folded(vector.input) ?? "").utf8))
            hasher.update(data: Data([0x1F]))
            let tokens = SearchTextNormalizer.tokens(SearchTextNormalizer.foldedForm(vector.input))
            hasher.update(data: Data(tokens.joined(separator: "\u{1E}").utf8))
            hasher.update(data: Data([0x1D]))
        }
        XCTAssertEqual(
            Self.hex(hasher.finalize()), manifest.digests.behavior,
            """
            Swift's normalizer output no longer matches the manifest. If this was intended, bump \
            normalizerVersion in the manifest and SearchTextNormalizer, then regenerate with \
            scripts/generate-search-manifest.py.
            """
        )
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func loadManifest() throws -> Manifest {
        let url = try XCTUnwrap(
            Bundle(for: SearchTextNormalizerTests.self)
                .url(forResource: "search-tokenizer-manifest", withExtension: "json"),
            "manifest is not in the TojTests resource bundle"
        )
        return try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
    }

    private static func loadVectors() throws -> NormalizerVectorFile {
        let url = try XCTUnwrap(
            Bundle(for: SearchTextNormalizerTests.self)
                .url(forResource: "search-normalizer-vectors", withExtension: "json")
        )
        return try JSONDecoder().decode(NormalizerVectorFile.self, from: Data(contentsOf: url))
    }

    private struct Manifest: Decodable {
        let tokenizer: String
        let normalizerVersion: Int
        let digests: Digests

        struct Digests: Decodable {
            let tables: String
            let maps: String
            let behavior: String
        }
    }

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
