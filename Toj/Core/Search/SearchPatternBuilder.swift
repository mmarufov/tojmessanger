import Foundation

/// The two column-qualified MATCH expressions a single user query expands into.
///
/// `exact` searches only the exact columns and `folded` only the folded ones, so a hit's tier is
/// unambiguous: whichever expression returned it. The store runs `exact` first and `folded` for
/// what it missed, which is what makes "exact ranks above folded" a property of the query plan
/// rather than a scoring heuristic.
///
/// Unlike version 2, `folded` is **never nil**. Its predecessor omitted the folded tier whenever
/// the query itself contained nothing foldable, which silently broke the common case: `точики` is
/// unchanged by Tajik folding, so no folded tier ran, so it could not reach a stored `тоҷикӣ` —
/// exactly the query the folded column exists to serve.
nonisolated struct SearchPattern: Equatable, Sendable {
    /// Restricted to ``SearchIndexSchema/exactColumns``.
    let exact: String
    /// Restricted to ``SearchIndexSchema/foldedColumns``. Includes the Latin transliteration
    /// alternative, which belongs here because it produces Cyrillic in folded space.
    let folded: String
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

    /// Builds the MATCH expressions for `query`, or `nil` when it contains nothing searchable
    /// (whitespace, punctuation, or emoji only).
    ///
    /// - Parameter prefixMatching: Whether the final term matches as a prefix. True while the user
    ///   is typing; false once they submit, where whole-word matching is less surprising.
    static func pattern(for query: String, prefixMatching: Bool = true) -> SearchPattern? {
        let clamped = clamp(query)
        let exactTerms = terms(in: SearchTextNormalizer.exact(clamped))
        guard !exactTerms.isEmpty else { return nil }

        // The folded tier always runs. Its terms come from foldedForm, which equals the exact form
        // when the query holds no Tajik letters — and that is precisely when it is needed, because
        // a Russian-keyboard query is already in folded space while the stored Tajik text is not.
        var foldedAlternatives = [expression(terms(in: SearchTextNormalizer.foldedForm(clamped)),
                                             prefixMatching: prefixMatching)]
        if let candidate = SearchTextNormalizer.cyrillicCandidate(clamped) {
            let candidateTerms = terms(in: SearchTextNormalizer.foldedForm(candidate))
            if !candidateTerms.isEmpty {
                foldedAlternatives.append(expression(candidateTerms, prefixMatching: prefixMatching))
            }
        }

        return SearchPattern(
            exact: qualify(expression(exactTerms, prefixMatching: prefixMatching),
                           with: SearchIndexSchema.exactColumns),
            folded: qualify(foldedAlternatives.joined(separator: " OR "),
                            with: SearchIndexSchema.foldedColumns)
        )
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

    private struct Term: Equatable {
        let text: String
        /// Set when the term was truncated, so the shortened form still matches the original word.
        let forcePrefix: Bool
    }

    private static func terms(in normalized: String) -> [Term] {
        SearchTextNormalizer.tokens(normalized)
            .prefix(maximumTerms)
            .map { token in
                guard token.count > maximumTermLength else {
                    return Term(text: token, forcePrefix: false)
                }
                return Term(text: String(token.prefix(maximumTermLength)), forcePrefix: true)
            }
    }

}
