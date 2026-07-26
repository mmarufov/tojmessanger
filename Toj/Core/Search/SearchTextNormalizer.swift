import Foundation

/// Normalizes message text and queries into the two forms the search index stores.
///
/// Toj's users type Tajik Cyrillic, Russian, and Latin transliteration — frequently on a Russian
/// keyboard that has no ҷ ғ ҳ қ keys, so "тоҷикӣ" gets typed as "точики". The index therefore holds
/// two forms of every message:
///
/// - ``exact(_:)`` — case folded and Latin diacritics removed. What the user actually wrote.
/// - ``foldedForm(_:)`` — additionally collapses the six Tajik letters onto the Russian keyboard
///   lookalikes users substitute for them.
///
/// Queries are normalized with the same functions, and results matching on the exact form rank
/// above results that only matched the folded form.
///
/// ## Two rules, both pinned
///
/// Case folding and Latin diacritic removal come from ``SearchUnicodeTables``, which is *generated
/// by probing the FTS5 tokenizer itself* (`scripts/generate-search-unicode-tables.py`). Nothing
/// here calls `String.lowercased()`, `String.folding(options:)`, or `Unicode.Scalar.Properties`:
/// those consult whichever ICU the runtime links, so their results can shift under us between OS
/// versions and cannot be reproduced by the Bun server. The generated table cannot.
///
/// Tajik folding is the one hand-authored rule, and it is deliberately only ``tajikFolds`` — six
/// entries. It exists precisely *because* unicode61 does not do it: the tokenizer leaves ҷ ғ ҳ қ ӣ
/// ӯ completely untouched, as `testUnicode61DoesNotFoldCyrillic` demonstrates against a live
/// SQLCipher table. Do not add ё→е or й→и here without an explicit product decision; unicode61
/// leaves those alone too, and folding them silently merges distinct Russian words.
///
/// ## Invariants
///
/// Each has a test in `SearchTextNormalizerTests`.
///
/// 1. **Idempotent** — `exact(exact(x)) == exact(x)`, likewise `foldedForm`. If this breaks,
///    indexed text and query text disagree and search silently half-works.
/// 2. **Scalar-preserving** — one scalar in, exactly one out, always. Every fold in the generated
///    table is one-to-one, and separators pass through untouched rather than being stripped, so
///    the normalized string indexes scalar-for-scalar against the original. That is what makes
///    ``highlightRanges(of:in:)`` a pure identity mapping instead of an offset table.
/// 3. **Runtime-independent** — output depends only on pinned tables, never on `Locale` or ICU.
///
/// ``cyrillicCandidate(_:)`` is exempt from (2): digraphs like `ch` → `ч` change length. It only
/// ever widens a query and is never used to compute a highlight offset.
nonisolated enum SearchTextNormalizer {
    /// Bumping this triggers an incremental background reindex on next launch.
    ///
    /// This must cover **every** rule that can change a token: ``tajikFolds``, the token-character
    /// classification, *and* the generated ``SearchUnicodeTables``. Regenerating those tables — for
    /// a new SQLite version, or a tokenizer configuration change in `SearchIndexSchema` — is a
    /// token-affecting change and requires a bump here even though this file did not change.
    /// `testGeneratedTablesMatchPinnedDigest` fails when the tables move without a bump.
    ///
    /// Version 2 corrected version 1, which folded ё and й on the false premise that unicode61
    /// already did so, and which derived case mappings from the runtime's ICU.
    static let version = 2

    /// The six Tajik letters absent from a Russian keyboard layout, mapped to what users type
    /// instead. unicode61 folds none of these — verified in `MessageSearchFTS5Tests`.
    static let tajikFolds: [Unicode.Scalar: Unicode.Scalar] = [
        "\u{04B7}": "\u{0447}",  // ҷ -> ч
        "\u{0493}": "\u{0433}",  // ғ -> г
        "\u{04B3}": "\u{0445}",  // ҳ -> х
        "\u{049B}": "\u{043A}",  // қ -> к
        "\u{04E3}": "\u{0438}",  // ӣ -> и
        "\u{04EF}": "\u{0443}",  // ӯ -> у
    ]

    // MARK: - Normalization

    /// Case folded with Latin diacritics removed, preserving scalar count.
    static func exact(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map(baseFold)))
    }

    /// ``exact(_:)`` with the six Tajik letters collapsed onto their Russian lookalikes.
    static func foldedForm(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { tajikFold(baseFold($0)) }))
    }

    /// The folded form, or `nil` when identical to ``exact(_:)``.
    ///
    /// The indexer writes `nil` as an empty FTS column, so text with no Tajik letters — the common
    /// case for Latin and Russian — costs no extra index space.
    static func folded(_ text: String) -> String? {
        let exactForm = exact(text)
        let foldedForm = String(String.UnicodeScalarView(exactForm.unicodeScalars.map(tajikFold)))
        return foldedForm == exactForm ? nil : foldedForm
    }

    /// Whether FTS5's `unicode61` treats this scalar as part of a token rather than a separator.
    ///
    /// Backed by the probed table, so it agrees with the tokenizer on the awkward cases: CJK and
    /// private-use scalars are token characters, `½` and `²` are token characters, emoji and
    /// combining marks are separators.
    static func isTokenScalar(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        var low = 0
        var high = SearchUnicodeTables.tokenRanges.count / 2 - 1
        while low <= high {
            let mid = (low + high) / 2
            let lower = SearchUnicodeTables.tokenRanges[mid * 2]
            let upper = SearchUnicodeTables.tokenRanges[mid * 2 + 1]
            if value < lower {
                high = mid - 1
            } else if value > upper {
                low = mid + 1
            } else {
                return true
            }
        }
        return false
    }

    /// Splits normalized text into the tokens `unicode61` would produce.
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

    // MARK: - Highlighting

    /// Locates `query`'s tokens inside `original`, returning ranges into the **original,
    /// undisplayed-unchanged** text.
    ///
    /// This is the payoff of scalar preservation. Folding maps scalar *i* of the original to scalar
    /// *i* of the folded form, so a match found in folded space is the same range in original
    /// space — no offset table, no drift. Searching `cafe` against `Café` folds the stored text to
    /// `cafe`, matches at scalars 0..<4, and hands back the range covering `Café` with its accent
    /// intact for display.
    ///
    /// Matching is token-aligned and prefix-based, mirroring the MATCH pattern: a query token
    /// highlights any whole token that starts with it.
    static func highlightRanges(of query: String, in original: String) -> [Range<String.Index>] {
        let needles = tokens(foldedForm(query))
        guard !needles.isEmpty else { return [] }

        let folded = Array(foldedForm(original).unicodeScalars)
        var boundaries = Array(original.unicodeScalars.indices)
        boundaries.append(original.unicodeScalars.endIndex)
        guard folded.count == boundaries.count - 1 else { return [] }  // invariant 2 broke; degrade

        var ranges: [Range<String.Index>] = []
        var start = 0
        while start < folded.count {
            guard isTokenScalar(folded[start]) else { start += 1; continue }
            var end = start
            while end < folded.count, isTokenScalar(folded[end]) { end += 1 }

            let token = String(String.UnicodeScalarView(folded[start..<end]))
            if needles.contains(where: token.hasPrefix) {
                // Pull in any combining marks trailing the token so an accent is not orphaned
                // outside the highlight when the source text is in decomposed form.
                var extended = end
                while extended < folded.count, isCombiningMark(folded[extended]) { extended += 1 }
                ranges.append(boundaries[start]..<boundaries[extended])
            }
            start = end
        }
        return ranges
    }

    // MARK: - Latin transliteration

    /// Transliterates a Latin query into its likely Cyrillic spelling, or `nil` when the input is
    /// not plausibly transliteration.
    ///
    /// Tajik speakers routinely type `salom` / `chon` for салом / ҷон, especially without a
    /// Cyrillic keyboard installed. This widens the query rather than adding a third index column.
    /// Output targets the *folded* space, so `j` and `q` map to ч and к rather than ҷ and қ.
    ///
    /// Not scalar-preserving: digraphs collapse two scalars into one. Never use for highlighting.
    static func cyrillicCandidate(_ text: String) -> String? {
        let lowered = exact(text)
        guard lowered.unicodeScalars.contains(where: isLatinLetter),
              !lowered.unicodeScalars.contains(where: isCyrillicLetter) else { return nil }

        var result = String.UnicodeScalarView()
        let scalars = Array(lowered.unicodeScalars)
        var index = 0
        while index < scalars.count {
            var matched = false
            // Longest digraph first: "shch" before "sh" before "s".
            for length in stride(from: min(4, scalars.count - index), through: 2, by: -1) {
                let candidate = String(String.UnicodeScalarView(scalars[index..<(index + length)]))
                if let replacement = Self.latinDigraphs[candidate] {
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

    private static let foldTable: [UInt32: UInt32] = {
        var table = [UInt32: UInt32](minimumCapacity: SearchUnicodeTables.foldPairs.count / 2)
        for index in stride(from: 0, to: SearchUnicodeTables.foldPairs.count, by: 2) {
            table[SearchUnicodeTables.foldPairs[index]] = SearchUnicodeTables.foldPairs[index + 1]
        }
        return table
    }()

    /// Case folding plus Latin diacritic removal, straight from the probed table.
    private static func baseFold(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        guard let folded = foldTable[scalar.value],
              let mapped = Unicode.Scalar(folded) else { return scalar }
        return mapped
    }

    private static func tajikFold(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        tajikFolds[scalar] ?? scalar
    }

    /// The combining-mark blocks, pinned rather than derived from `Unicode.Scalar.Properties` so
    /// highlighting stays runtime-independent like everything else here.
    private static func isCombiningMark(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0300...0x036F, 0x1AB0...0x1AFF, 0x1DC0...0x1DFF, 0x20D0...0x20FF, 0xFE20...0xFE2F:
            return true
        default:
            return false
        }
    }

    private static func isLatinLetter(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
    }

    private static func isCyrillicLetter(_ scalar: Unicode.Scalar) -> Bool {
        (0x0400...0x04FF).contains(scalar.value)
    }

    // MARK: - Transliteration tables

    private static let latinDigraphs: [String: Unicode.Scalar] = [
        "shch": "\u{0449}",  // щ
        "sch": "\u{0449}",   // щ
        "ch": "\u{0447}",    // ч
        "sh": "\u{0448}",    // ш
        "kh": "\u{0445}",    // х
        "zh": "\u{0436}",    // ж
        "ts": "\u{0446}",    // ц
        "gh": "\u{0433}",    // ғ folds to г
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
