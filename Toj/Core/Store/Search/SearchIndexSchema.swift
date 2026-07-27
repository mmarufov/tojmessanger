import Foundation
import GRDB

/// The authoritative definition of the FTS5 index that backs message search.
///
/// This type owns the DDL and nothing else. The `v10` migration that creates the ordinary tables
/// and triggers, and the indexer that drains them, are separate — deliberately, because the
/// virtual table is **not** created by the migrator.
///
/// ## Why the virtual table is created outside the migration
///
/// A throwing migration makes `CloudLocalStore.init` throw, which routes the caller into the
/// quarantine path and can cost a user every chat they have — over an index that is derived and
/// rebuildable from `messages`. So ``createVirtualTable(_:)`` is called later, by the indexer,
/// inside its own `do`/`catch`: if it fails, search reports itself unavailable and the app is
/// otherwise untouched.
///
/// ## Tokenizer
///
/// ``tokenize`` must stay in step with `scripts/generate-search-unicode-tables.py`, which probes a
/// table configured exactly this way to produce the tables `SearchTextNormalizer` folds with.
/// Changing it changes what tokens exist and requires bumping `SearchTextNormalizer.version`.
nonisolated enum SearchIndexSchema {
    static let tokenize = "unicode61 remove_diacritics 2"

    /// `contentless_delete=1` needs SQLite 3.43. SQLCipher 4.10.0 ships 3.50.4, so this is
    /// satisfied — but it is probed at runtime rather than assumed, because the pod is resolved
    /// from a lockfile that a future bump could move backwards.
    static let minimumSQLiteVersionNumber = 3_043_000

    /// Contentless because we never call `snippet()` or `highlight()`: displayed text and its
    /// match ranges are computed in Swift from `messages.text`, so the FTS content shadow table
    /// would be a duplicate copy of every message for nothing. Halves the index.
    ///
    /// Note that `'rebuild'` does not work on contentless tables, which is why repair drops and
    /// recreates rather than rebuilding in place.
    ///
    /// `dialog_token` carries the dialog UUID with hyphens stripped so it tokenizes as one term.
    /// Without it, in-chat search MATCHes the whole corpus and filters afterwards.
    ///
    /// ## Column layout: every text column exists in both tiers
    ///
    /// Three kinds of text are searchable, and each is stored twice — once exact, once folded:
    ///
    /// | source                     | exact tier   | folded tier         |
    /// |----------------------------|--------------|---------------------|
    /// | message body **and media caption** (both live in `messages.text`) | `exact` | `folded` |
    /// | attachment filename        | `file_name`  | `file_name_folded`  |
    /// | extracted link host + path | `link_text`  | `link_text_folded`  |
    ///
    /// The folded columns are populated **unconditionally**, not only when they differ from their
    /// exact counterpart. Writing them only when different saves index space but breaks the tier
    /// asymmetrically: a query of `тоҷикӣ` folds to `точики`, and a row whose body is literally
    /// `точики` would have an empty folded column and so could never be reached from the Tajik
    /// spelling. Paying for the duplicate postings makes the folded tier a complete fallback index.
    ///
    /// ## Measured, on 100k messages (`MessageSearchIndexSizeBenchmark`)
    ///
    /// | design                     | size    | worst 2-char prefix |
    /// |----------------------------|---------|---------------------|
    /// | dense, `prefix='2 3 4'`    | 30.5 MB | 0.7 ms              |
    /// | **dense, `prefix='2'`**    | **18.6 MB** | **0.1 ms**      |
    /// | sparse, `prefix='2 3 4'`   | 22.0 MB | 0.2 ms              |
    /// | dense, no prefix index     | 12.5 MB | 1.0 ms              |
    ///
    /// The duplication is not where the cost was. Prefix indexes accounted for 18 MB of the
    /// original 30.5 MB while the folded columns cost 8.5 MB, so trimming `prefix` to a single
    /// length saves more than sparse storage would have — and keeps the correctness sparse gives
    /// up. `prefix='2'` also measured *fastest*, a smaller index having better locality; longer
    /// prefixes fall back to a term-index scan, which is cheap because they are more selective.
    ///
    /// ~195 bytes per message at the shipped design.
    static let createVirtualTableSQL = """
        CREATE VIRTUAL TABLE message_search USING fts5(
            exact,
            file_name,
            link_text,
            folded,
            file_name_folded,
            link_text_folded,
            dialog_token,
            tokenize = '\(tokenize)',
            prefix = '2',
            content = '',
            contentless_delete = 1
        )
        """

    /// Columns the exact tier searches: what the user literally wrote.
    static let exactColumns = ["exact", "file_name", "link_text"]

    /// Columns the fallback tier searches. `dialog_token` is in neither — it is a scoping key, and
    /// leaving it out keeps a dialog id from matching as if it were message text.
    static let foldedColumns = ["folded", "file_name_folded", "link_text_folded"]

    /// Merge tuning. These are *not* valid `CREATE VIRTUAL TABLE` options — FTS5 rejects them
    /// there with "unrecognized option" — and must be applied as config inserts afterwards.
    ///
    /// Edits are delete-plus-insert, so a chatty account accumulates tombstones; `automerge` keeps
    /// the steady state healthy and `deletemerge` triggers a merge once a segment is 10% deletions.
    static let configureMergeSQL = [
        "INSERT INTO message_search(message_search, rank) VALUES('automerge', 8)",
        "INSERT INTO message_search(message_search, rank) VALUES('deletemerge', 10)",
    ]

    static let dropVirtualTableSQL = "DROP TABLE IF EXISTS message_search"

    /// `sqlite_version()` as a comparable integer, e.g. 3.50.4 becomes 3_050_004.
    static func sqliteVersionNumber(_ db: Database) throws -> Int {
        let version = try String.fetchOne(db, sql: "SELECT sqlite_version()") ?? "0.0.0"
        let parts = version.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 3 else { return 0 }
        return parts[0] * 1_000_000 + parts[1] * 1_000 + parts[2]
    }

    /// Whether this build can store the index at all.
    ///
    /// Two independent things can be missing: FTS5 itself (a compile-time flag on SQLCipher) and
    /// `contentless_delete` (a version floor). Probing rather than asserting keeps a pod bump from
    /// silently producing an index that cannot delete rows — which would leave deleted message
    /// text searchable, a privacy bug rather than a broken feature.
    ///
    /// - Important: Requires a **writable** connection. The probe creates and drops a temporary
    ///   table, which GRDB's `read` blocks with `query_only`, so calling this inside a read
    ///   transaction reports `false` no matter what the build supports. Call it from the same write
    ///   that goes on to create the index.
    static func supportsContentlessDelete(_ db: Database) throws -> Bool {
        guard try sqliteVersionNumber(db) >= minimumSQLiteVersionNumber else { return false }
        do {
            try db.execute(sql: """
                CREATE VIRTUAL TABLE temp.__toj_fts_probe USING fts5(
                    x, content = '', contentless_delete = 1
                )
                """)
            try db.execute(sql: "DROP TABLE temp.__toj_fts_probe")
            return true
        } catch {
            return false
        }
    }

    /// Creates the index and applies its merge tuning. Callers own the failure policy.
    static func createVirtualTable(_ db: Database) throws {
        try db.execute(sql: createVirtualTableSQL)
        for sql in configureMergeSQL {
            try db.execute(sql: sql)
        }
    }
}
