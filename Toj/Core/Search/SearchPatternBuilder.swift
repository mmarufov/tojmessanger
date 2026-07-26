import Foundation

/// The two MATCH expressions a single user query expands into.
///
/// `exact` is tried first and its hits rank above `folded`'s — see the two-tier query in
/// `MessageSearchStore`. `folded` is `nil` when the query contains nothing foldable and no Latin
/// transliteration, which is the common case for pure-Latin input; the caller then runs one query
/// instead of two.
nonisolated struct SearchPattern: Equatable, Sendable {
    let exact: String
    let folded: String?
}

/// Builds FTS5 `MATCH` expressions from untrusted user input.
///
/// **User input must never reach `MATCH` verbatim.** In FTS5 `"`, `*`, `^`, `:`, `-`, `(`, `)` and
/// the bare words `AND` / `OR` / `NOT` / `NEAR` are operators, so a query as ordinary as `AND` or
/// an unbalanced `"` raises `SQLITE_ERROR` at *query* time — a crash-shaped bug that only fires on
/// real user text, never on developer text.
///
/// So nothing is escaped or sanitized in place. Input is tokenized with ``SearchTextNormalizer``,
/// each token is re-emitted as a quoted FTS5 phrase, and the phrases are joined with explicit
/// operators. Operator characters cannot survive because they are not alphanumeric and therefore
/// never appear inside a token.
nonisolated enum SearchPatternBuilder {
    /// Beyond this, extra terms cost query time without improving precision.
    static let maximumTerms = 8

    /// Terms longer than this are truncated and matched as prefixes, so a pasted 60-character
    /// token still finds its message instead of silently matching nothing.
    static let maximumTermLength = 32

    /// A one-character prefix scan walks most of the term index. Exact matching for single
    /// characters is both faster and closer to what the user meant.
    static let minimumPrefixLength = 2

    /// Builds the MATCH expressions for `query`, or `nil` when it contains nothing searchable
    /// (whitespace, punctuation, or emoji only).
    ///
    /// - Parameter prefixMatching: Whether the final term matches as a prefix. True while the user
    ///   is typing; false once they submit, where whole-word matching is less surprising.
    static func pattern(for query: String, prefixMatching: Bool = true) -> SearchPattern? {
        let exactTerms = terms(in: SearchTextNormalizer.exact(query))
        guard !exactTerms.isEmpty else { return nil }

        let exact = expression(exactTerms, prefixMatching: prefixMatching)

        var alternatives: [String] = []
        let foldedTerms = terms(in: SearchTextNormalizer.foldedForm(query))
        if foldedTerms != exactTerms {
            alternatives.append(expression(foldedTerms, prefixMatching: prefixMatching))
        }
        if let candidate = SearchTextNormalizer.cyrillicCandidate(query) {
            let candidateTerms = terms(in: candidate)
            if !candidateTerms.isEmpty, candidateTerms != exactTerms, candidateTerms != foldedTerms {
                alternatives.append(expression(candidateTerms, prefixMatching: prefixMatching))
            }
        }

        return SearchPattern(
            exact: exact,
            folded: alternatives.isEmpty ? nil : alternatives.joined(separator: " OR ")
        )
    }

    /// Restricts an expression to one dialog using the indexed `dialog_token` column.
    ///
    /// Without this the in-chat search MATCHes the whole corpus and filters afterwards, which
    /// degrades badly in a large group. The column filter binds only to the dialog phrase; the
    /// trailing expression stays unrestricted, which is what lets it match any text column.
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

    // MARK: - Internals

    /// Joins terms with `AND`, marking the last one as a prefix when requested.
    private static func expression(_ terms: [Term], prefixMatching: Bool) -> String {
        terms.enumerated().map { index, term in
            let isLast = index == terms.count - 1
            let usePrefix = term.forcePrefix
                || (prefixMatching && isLast && term.text.count >= minimumPrefixLength)
            return quote(term.text) + (usePrefix ? "*" : "")
        }
        .joined(separator: " AND ")
    }

    /// Emits an FTS5 string literal. Doubling `"` is the only escape the grammar defines, and
    /// tokens cannot contain `"` anyway — this is belt-and-braces for a token rule that changes.
    private static func quote(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private struct Term: Equatable {
        let text: String
        /// Set when the term was truncated, so the shortened form still matches the original word.
        let forcePrefix: Bool
    }

    private static func terms(in normalized: String) -> [Term] {
        SearchTextNormalizer.tokens(normalized)
            .filter(isSearchable)
            .prefix(maximumTerms)
            .map { token in
                guard token.count > maximumTermLength else {
                    return Term(text: token, forcePrefix: false)
                }
                return Term(text: String(token.prefix(maximumTermLength)), forcePrefix: true)
            }
    }

    /// Drops tokens the tokenizer would reduce to nothing — a run of combining marks, for example.
    /// An empty phrase (`""`) is a syntax error in FTS5, so these must never reach the expression.
    private static func isSearchable(_ token: String) -> Bool {
        token.unicodeScalars.contains { scalar in
            scalar.properties.isAlphabetic || CharacterSet.decimalDigits.contains(scalar)
        }
    }
}
