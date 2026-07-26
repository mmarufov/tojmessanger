import Foundation

/// Normalizes message text and queries into the two forms the search index stores.
///
/// Toj's users type Tajik Cyrillic, Russian, and Latin transliteration — frequently on a Russian
/// keyboard that has no ҷ ғ ҳ қ keys, so "тоҷикӣ" gets typed as "точики". The index therefore holds
/// two forms of every message:
///
/// - ``exact(_:)`` — a scalar-preserving lowercase. What the user actually wrote.
/// - ``foldedForm(_:)`` — additionally collapses the Tajik-only letters onto their Russian
///   keyboard lookalikes, so a Russian-keyboard query still reaches a Tajik message.
///
/// Queries are normalized with the same functions, and results matching on the exact form are
/// ranked above results that only matched the folded form (see `MessageSearchStore`).
///
/// ## Invariants
///
/// Three properties are load-bearing; each has a test in `SearchTextNormalizerTests`.
///
/// 1. **Idempotent** — `exact(exact(x)) == exact(x)` and likewise for `foldedForm`. If this breaks,
///    indexed text and query text disagree and search silently half-works.
/// 2. **Scalar-preserving** — one Unicode scalar in, exactly one out. Search highlighting locates a
///    match in the *folded* text and maps that range back onto the *original* text for display;
///    that mapping is only the identity if folding never changes scalar count. This rules out
///    `String.folding(options:)` and `String.lowercased()`, both of which can grow a string
///    (`ß` → `ss`, `İ` → `i` + U+0307).
/// 3. **Locale-independent** — identical output under `tr_TR` (the İ/ı trap) and `ru_RU`. Nothing
///    here consults `Locale`.
///
/// ``cyrillicCandidate(_:)`` is deliberately exempt from (2): digraphs like `ch` → `ч` change
/// length. It is only ever used to widen a query, never to compute a highlight offset.
nonisolated enum SearchTextNormalizer {
    /// Bumping this triggers an incremental background reindex on next launch.
    ///
    /// Bump whenever ``exact(_:)`` or ``foldedForm(_:)`` changes what they emit for any input.
    /// `SearchIndexer.bootstrap()` compares this against `search_index_state.normalizer_version`.
    /// The server keeps a matching constant in `server/src/search.ts`; a client whose version
    /// disagrees with the server's falls back to local-only search rather than returning subtly
    /// wrong results.
    static let version = 1

    // MARK: - Public API

    /// Scalar-preserving lowercase. The form the user actually typed, case-normalized.
    static func exact(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map(lowercaseScalar)))
    }

    /// ``exact(_:)`` with Tajik-only letters collapsed onto their Russian keyboard lookalikes.
    ///
    /// Returns the same value as ``exact(_:)`` when the text contains nothing foldable, which is
    /// the common case for Latin text. Prefer ``folded(_:)`` when storing, so identical forms are
    /// not written twice.
    static func foldedForm(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { foldScalar(lowercaseScalar($0)) }))
    }

    /// The folded form, or `nil` when it is identical to ``exact(_:)``.
    ///
    /// The indexer writes `nil` as an empty FTS column, so pure-Latin messages cost nothing extra.
    static func folded(_ text: String) -> String? {
        let exactForm = exact(text)
        let folded = String(
            String.UnicodeScalarView(exactForm.unicodeScalars.map(foldScalar))
        )
        return folded == exactForm ? nil : folded
    }

    /// Splits normalized text into the tokens FTS5's `unicode61` tokenizer would produce.
    ///
    /// Mirrors `unicode61`'s default rule: a token is a maximal run of alphanumerics, everything
    /// else separates. Used to build MATCH patterns (`SearchPatternBuilder`) and to locate
    /// highlight ranges, so it must stay in step with the tokenizer configured in
    /// `SearchIndexSchema`.
    static func tokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if isTokenScalar(scalar) {
                current.append(scalar)
            } else if !current.isEmpty {
                tokens.append(String(current))
                current = String.UnicodeScalarView()
            }
        }
        if !current.isEmpty { tokens.append(String(current)) }
        return tokens
    }

    /// Transliterates a Latin query into its most likely Cyrillic spelling, or `nil` if the input
    /// is not plausibly Latin transliteration.
    ///
    /// Tajik speakers routinely type `salom` / `chon` for салом / ҷон, especially on devices
    /// without a Cyrillic keyboard installed. Rather than carry a third index column, the query
    /// layer ORs this candidate into the MATCH pattern — cheap, no index growth, and trivially
    /// reversible if it proves noisy.
    ///
    /// Not scalar-preserving: digraphs collapse two scalars into one. Never use the result to
    /// compute highlight offsets.
    static func cyrillicCandidate(_ text: String) -> String? {
        let lowered = exact(text)
        guard lowered.unicodeScalars.contains(where: isLatinLetter),
              !lowered.unicodeScalars.contains(where: isCyrillicLetter) else { return nil }

        var result = String.UnicodeScalarView()
        let scalars = Array(lowered.unicodeScalars)
        var index = 0
        while index < scalars.count {
            // Longest match first: "shch" before "sh" before "s".
            var matched = false
            for length in stride(from: min(4, scalars.count - index), through: 2, by: -1) {
                let digraph = String(String.UnicodeScalarView(scalars[index..<(index + length)]))
                if let replacement = Self.latinDigraphs[digraph] {
                    result.append(replacement)
                    index += length
                    matched = true
                    break
                }
            }
            if matched { continue }
            result.append(Self.latinLetters[scalars[index]] ?? scalars[index])
            index += 1
        }
        let candidate = String(result)
        return candidate == lowered ? nil : candidate
    }

    // MARK: - Scalar mapping

    /// Lowercases a single scalar, refusing any mapping that would change scalar count.
    ///
    /// Swift's full Unicode case mapping is locale-independent but not length-preserving, so we
    /// only accept single-scalar results and fall back to the identity otherwise. ``caseOverrides``
    /// then handles the few length-changing cases we care about by hand.
    private static func lowercaseScalar(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        if let override = Self.caseOverrides[scalar] { return override }
        if scalar.properties.isLowercase || !scalar.properties.isUppercase { return scalar }
        let lowered = String(scalar).lowercased().unicodeScalars
        guard lowered.count == 1, let single = lowered.first else { return scalar }
        return single
    }

    private static func foldScalar(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        Self.cyrillicFolds[scalar] ?? scalar
    }

    private static func isTokenScalar(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.alphanumerics.contains(scalar)
    }

    private static func isLatinLetter(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
    }

    private static func isCyrillicLetter(_ scalar: Unicode.Scalar) -> Bool {
        (0x0400...0x04FF).contains(Int(scalar.value))
    }

    // MARK: - Tables

    /// Case mappings Swift would otherwise expand into multiple scalars.
    ///
    /// `İ` lowercases to `i` + U+0307 COMBINING DOT ABOVE, and `ı` is already lowercase but should
    /// still match a plain `i` for search purposes. Both appear in Turkish text, which shows up in
    /// this market often enough to matter.
    private static let caseOverrides: [Unicode.Scalar: Unicode.Scalar] = [
        "\u{0130}": "i",  // İ LATIN CAPITAL LETTER I WITH DOT ABOVE
        "\u{0131}": "i",  // ı LATIN SMALL LETTER DOTLESS I
    ]

    /// Tajik letters folded onto the Russian keyboard letters users substitute for them.
    ///
    /// Only the four descender letters strictly need to be here. `unicode61 remove_diacritics 2`
    /// already folds ӣ→и, ӯ→у, ё→е and й→и inside SQLite, but the highlight-range search runs in
    /// Swift over the same folded text, so the two must agree — hence the redundant entries.
    private static let cyrillicFolds: [Unicode.Scalar: Unicode.Scalar] = [
        "\u{04B7}": "\u{0447}",  // ҷ -> ч
        "\u{0493}": "\u{0433}",  // ғ -> г
        "\u{04B3}": "\u{0445}",  // ҳ -> х
        "\u{049B}": "\u{043A}",  // қ -> к
        "\u{04E3}": "\u{0438}",  // ӣ -> и
        "\u{04EF}": "\u{0443}",  // ӯ -> у
        "\u{0451}": "\u{0435}",  // ё -> е
        "\u{0439}": "\u{0438}",  // й -> и
    ]

    private static let latinDigraphs: [String: Unicode.Scalar] = [
        "shch": "\u{0449}",  // щ
        "sch": "\u{0449}",   // щ
        "ch": "\u{0447}",    // ч
        "sh": "\u{0448}",    // ш
        "kh": "\u{0445}",    // х
        "zh": "\u{0436}",    // ж
        "ts": "\u{0446}",    // ц
        "gh": "\u{0433}",    // г  (Tajik ғ folds to г anyway)
        "yo": "\u{0435}",    // ё -> е, already folded
        "yu": "\u{044E}",    // ю
        "ya": "\u{044F}",    // я
    ]

    private static let latinLetters: [Unicode.Scalar: Unicode.Scalar] = [
        "a": "\u{0430}", "b": "\u{0431}", "v": "\u{0432}", "g": "\u{0433}",
        "d": "\u{0434}", "e": "\u{0435}", "z": "\u{0437}", "i": "\u{0438}",
        "y": "\u{0438}", "k": "\u{043A}", "l": "\u{043B}", "m": "\u{043C}",
        "n": "\u{043D}", "o": "\u{043E}", "p": "\u{043F}", "r": "\u{0440}",
        "s": "\u{0441}", "t": "\u{0442}", "u": "\u{0443}", "f": "\u{0444}",
        "h": "\u{0445}", "c": "\u{0446}", "j": "\u{0447}", "q": "\u{043A}",
        "w": "\u{0432}", "x": "\u{0445}",
    ]
}
