import Foundation

/// A user query reduced to the exact set of terms that will be searched — the single source of
/// truth for both the FTS5 MATCH expression and highlighting.
///
/// Before this existed, `SearchPatternBuilder` and `SearchTextNormalizer.highlightRanges` each
/// re-derived terms from the raw query string. They agreed on the easy cases and diverged on every
/// bounded one, because only the builder applied the limits:
///
/// - the scalar and UTF-8 clamp,
/// - the eight-term cap,
/// - 32-character truncation,
/// - **per-term prefix flags**, and
/// - which alternatives belong to which tier.
///
/// The prefix divergence was the visible one. A query of `a` emits `"a"` — no trailing `*`, because
/// a one-character prefix scan walks most of the term index — so FTS5 matches only the token `a`.
/// Highlighting matched on `hasPrefix` unconditionally, so it marked `apple` in a row the query had
/// never matched. Terms now carry ``Term/isPrefix`` and both consumers honour it.
nonisolated struct PreparedSearchQuery: Equatable, Sendable {
    /// One search term, already normalized, capped and truncated.
    nonisolated struct Term: Equatable, Sendable {
        let text: String
        /// Whether this term matches token prefixes. Set for the trailing term while the user types
        /// and for any term truncation shortened, so the shortened form still reaches its word.
        let isPrefix: Bool

        /// The same test FTS5 applies, so highlighting marks a token if and only if the term could
        /// have matched it.
        func matches(_ token: String) -> Bool {
            isPrefix ? token.hasPrefix(text) : token == text
        }
    }

    /// Terms in exact space, searched against ``SearchIndexSchema/exactColumns``.
    let exactTerms: [Term]

    /// Alternatives in folded space, searched against ``SearchIndexSchema/foldedColumns``. Always
    /// at least one — the Tajik-folded query — plus the Latin transliteration candidate when the
    /// input looks like transliteration. Terms within an alternative are ANDed; alternatives are
    /// ORed.
    let foldedAlternatives: [[Term]]

    /// Retained so a plan round-trips: rebuilding from the same query and flag is deterministic.
    let prefixMatching: Bool

    var isEmpty: Bool { exactTerms.isEmpty }

    /// Every term across both tiers, for highlighting, which does not care which tier produced a
    /// hit — only whether a token could have been matched at all.
    var allTerms: [Term] { exactTerms + foldedAlternatives.flatMap { $0 } }

    // MARK: - Expressions

    var exactExpression: String {
        SearchPatternBuilder.qualify(
            Self.conjunction(exactTerms), with: SearchIndexSchema.exactColumns
        )
    }

    var foldedExpression: String {
        SearchPatternBuilder.qualify(
            foldedAlternatives.map(Self.conjunction).joined(separator: " OR "),
            with: SearchIndexSchema.foldedColumns
        )
    }

    private static func conjunction(_ terms: [Term]) -> String {
        terms.map { term in
            SearchPatternBuilder.quote(term.text) + (term.isPrefix ? "*" : "")
        }
        .joined(separator: " AND ")
    }
}
