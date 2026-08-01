import Foundation

/// The two column-qualified MATCH expressions a single user query expands into.
///
/// A flattened view of ``PreparedSearchQuery`` for callers that only need the SQL. Anything that
/// also highlights should hold the plan instead, so it applies the same limits and prefix flags.
nonisolated struct SearchPattern: Equatable, Sendable {
    /// Restricted to ``SearchIndexSchema/exactColumns``.
    let exact: String
    /// Restricted to ``SearchIndexSchema/foldedColumns``. Includes the Latin transliteration
    /// alternative, which belongs here because it produces Cyrillic in folded space.
    let folded: String
}

/// Reduces untrusted user input to a bounded ``PreparedSearchQuery``.
///
/// **User input must never reach `MATCH` verbatim.** In FTS5 `"`, `*`, `^`, `:`, `-`, `(`, `)` and
/// the bare words `AND` / `OR` / `NOT` / `NEAR` are operators, so a query as ordinary as `AND` or
/// an unbalanced `"` raises `SQLITE_ERROR` at *query* time — a crash-shaped bug that only fires on
/// real user text, never on developer text.
///
/// So nothing is escaped or sanitized in place. Input is tokenized with ``SearchTextNormalizer``,
/// each token is re-emitted as a quoted FTS5 phrase, and the phrases are joined with explicit
/// operators. Operator characters cannot survive because the measured tokenizer table classifies
/// every one of them as a separator, so they never appear inside a token.
nonisolated enum SearchPatternBuilder {
    /// Beyond this, extra terms cost query time without improving precision.
    static let maximumTerms = 8

    /// Terms longer than this are truncated and matched as prefixes, so a pasted 60-character
    /// token still finds its message instead of silently matching nothing.
    static let maximumTermLength = 32

    /// A one-character prefix scan walks most of the term index. Exact matching for single
    /// characters is both faster and closer to what the user meant.
    static let minimumPrefixLength = 2

    /// Scalar budget applied to raw input *before* any normalization.
    ///
    /// A search field can receive a multi-megabyte paste, and normalization is O(scalars) with an
    /// allocation per form. Clamping first bounds that work to a constant regardless of input, and
    /// it runs on the main actor's debounce path, so it must not be O(paste).
    static let maximumQueryScalars = 512

    /// UTF-8 budget applied alongside ``maximumQueryScalars``. Astral scalars cost four bytes
    /// each, so a scalar-only cap still admits a 2 KB query; this bounds the byte cost too.
    static let maximumQueryBytes = 1024

    /// Reduces `query` to the bounded plan both MATCH construction and highlighting consume, or
    /// `nil` when it holds nothing searchable (whitespace, punctuation, or an emoji the tokenizer
    /// treats as a separator).
    ///
    /// - Parameter prefixMatching: Whether the final term matches as a prefix. True while the user
    ///   is typing; false once they submit, where whole-word matching is less surprising.
    static func prepare(_ query: String, prefixMatching: Bool = true) -> PreparedSearchQuery? {
        let clamped = clamp(query)
        let exactTerms = terms(in: SearchTextNormalizer.exact(clamped), prefixMatching: prefixMatching)
        guard !exactTerms.isEmpty else { return nil }

        // The folded tier always runs. Its terms come from foldedForm, which equals the exact form
        // when the query holds no Tajik letters — and that is precisely when it is needed, because
        // a Russian-keyboard query is already in folded space while the stored Tajik text is not.
        var alternatives = [
            terms(in: SearchTextNormalizer.foldedForm(clamped), prefixMatching: prefixMatching)
        ]
        if let candidate = SearchTextNormalizer.cyrillicCandidate(clamped) {
            let candidateTerms = terms(
                in: SearchTextNormalizer.foldedForm(candidate), prefixMatching: prefixMatching
            )
            if !candidateTerms.isEmpty { alternatives.append(candidateTerms) }
        }

        return PreparedSearchQuery(
            exactTerms: exactTerms,
            foldedAlternatives: alternatives,
            prefixMatching: prefixMatching
        )
    }

    /// The MATCH expressions alone. Equivalent to ``prepare(_:prefixMatching:)`` followed by the
    /// plan's expression properties.
    static func pattern(for query: String, prefixMatching: Bool = true) -> SearchPattern? {
        prepare(query, prefixMatching: prefixMatching).map {
            SearchPattern(exact: $0.exactExpression, folded: $0.foldedExpression)
        }
    }

    /// Restricts an expression to a column set using FTS5's `{a b} : (...)` filter.
    ///
    /// The parentheses matter: a column filter binds to the phrase that follows it, so
    /// `{exact} : "a" AND "b"` would restrict only `"a"` and let `"b"` match any column.
    static func qualify(_ expression: String, with columns: [String]) -> String {
        "{\(columns.joined(separator: " "))} : (\(expression))"
    }

    /// Restricts an expression to one dialog using the indexed `dialog_token` column.
    ///
    /// Without this the in-chat search MATCHes the whole corpus and filters afterwards, which
    /// degrades badly in a large group. The column filter binds only to the dialog phrase; the
    /// trailing expression keeps its own column qualification.
    static func scoped(_ expression: String, toDialog dialogId: String) -> String {
        "{dialog_token} : \(quote(dialogToken(dialogId))) AND (\(expression))"
    }

    /// The single-token form of a dialog id.
    ///
    /// Dialog ids are UUIDs, and `unicode61` splits on the hyphens — five tokens per row, none of
    /// them selective. Stripping the hyphens leaves 32 hex characters that tokenize as one term.
    static func dialogToken(_ dialogId: String) -> String {
        SearchTextNormalizer.exact(dialogId).replacingOccurrences(of: "-", with: "")
    }

    /// Emits an FTS5 string literal. Doubling `"` is the only escape the grammar defines, and
    /// tokens cannot contain `"` anyway — this is belt-and-braces for a token rule that changes.
    static func quote(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Truncates raw input to the scalar and UTF-8 budgets before anything walks it.
    ///
    /// Cuts on a scalar boundary, never mid-scalar, so the result is always valid. Because only
    /// ``maximumTerms`` terms survive anyway, a query long enough to hit either budget has already
    /// contributed every term it can, and truncating changes no result the user would notice.
    static func clamp(_ query: String) -> String {
        var scalars = String.UnicodeScalarView()
        var bytes = 0
        for scalar in query.unicodeScalars {
            let width = UTF8.width(scalar)
            if scalars.count >= maximumQueryScalars || bytes + width > maximumQueryBytes { break }
            scalars.append(scalar)
            bytes += width
        }
        return String(scalars)
    }

    // MARK: - Internals

    /// Applies the term cap, truncation and prefix rules in one place, so the plan is the only
    /// description of what will be searched.
    private static func terms(
        in normalized: String, prefixMatching: Bool
    ) -> [PreparedSearchQuery.Term] {
        let tokens = Array(SearchTextNormalizer.tokens(normalized).prefix(maximumTerms))
        return tokens.enumerated().map { index, token in
            if token.count > maximumTermLength {
                // Truncated terms are always prefixes, even mid-query, so the shortened form still
                // reaches the word it came from.
                return PreparedSearchQuery.Term(
                    text: String(token.prefix(maximumTermLength)), isPrefix: true
                )
            }
            let isLast = index == tokens.count - 1
            return PreparedSearchQuery.Term(
                text: token,
                isPrefix: prefixMatching && isLast && token.count >= minimumPrefixLength
            )
        }
    }
}
