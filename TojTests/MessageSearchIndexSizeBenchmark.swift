import GRDB
import XCTest
@testable import Toj

/// Measures replica cost of the folded-column design on a 100k-message corpus.
///
/// Opt in with `TOJ_SEARCH_BENCHMARK=1`; it takes tens of seconds and writes a few hundred MB of
/// scratch, so it does not belong in the default run. It exists because "populate the folded
/// columns unconditionally" was a correctness argument made without a size number attached, and
/// this is a market where replica size is a real constraint.
///
/// Three designs, all preserving exact-tier-first ordering:
///
/// - **dense** — folded columns always written. Correct, and the largest.
/// - **sparse** — folded columns written only when they differ from exact. Smallest, and *wrong*:
///   a row whose body is literally `точики` has an empty folded column, so the Tajik spelling
///   `тоҷикӣ` — which folds to `точики` — can never reach it.
/// - **sparseWideFallback** — sparse storage, but the folded tier searches the exact columns too.
///   Recovers what sparse loses, because a row that needed no folding already sits in exact space.
///
/// `testSparseStorageIsOnlyCorrectWithTheWideFallback` runs unconditionally and pins the
/// correctness claim; only the size measurement is gated.
final class MessageSearchIndexSizeBenchmark: XCTestCase {
    private static let messageCount = 100_000

    // MARK: - Correctness (always runs)

    /// The measurement is only interesting if sparse is a live option, and it is only a live option
    /// if the wide fallback rescues it. Both halves are asserted here.
    func testSparseStorageIsOnlyCorrectWithTheWideFallback() throws {
        let (dbQueue, cleanup) = try makeDatabase()
        defer { cleanup() }

        try dbQueue.write { db in
            try SearchIndexSchema.createVirtualTable(db)
            // Body is literally the Russian-keyboard spelling, so folded == exact and sparse
            // storage would leave the folded columns empty.
            try insert(db, rowid: 1, body: "точики забон", sparse: true)
            try insert(db, rowid: 2, body: "тоҷикӣ забон", sparse: true)

            let plan = try XCTUnwrap(SearchPatternBuilder.prepare("тоҷикӣ"))
            let sql = "SELECT rowid FROM message_search WHERE message_search MATCH ? ORDER BY rowid"

            let exactHits = try Int.fetchAll(db, sql: sql, arguments: [plan.exactExpression])
            XCTAssertEqual(exactHits, [2], "only the Tajik spelling is a literal match")

            let narrow = try Int.fetchAll(db, sql: sql, arguments: [plan.foldedExpression])
            XCTAssertFalse(
                narrow.contains(1),
                "sparse + folded-only columns loses row 1 — this is why the shipped design is dense"
            )

            let wide = try Int.fetchAll(
                db, sql: sql,
                arguments: [SearchPatternBuilder.qualify(
                    plan.foldedAlternatives
                        .map { $0.map { SearchPatternBuilder.quote($0.text) + ($0.isPrefix ? "*" : "") }
                            .joined(separator: " AND ") }
                        .joined(separator: " OR "),
                    with: SearchIndexSchema.exactColumns + SearchIndexSchema.foldedColumns
                )]
            )
            XCTAssertEqual(wide, [1, 2], "the wide fallback recovers what sparse storage drops")
        }
    }

    // MARK: - Size (gated)

    func testIndexSizeAcrossDesigns() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["TOJ_SEARCH_BENCHMARK"] == "1",
            "Set TOJ_SEARCH_BENCHMARK=1 for the 100k-message index size benchmark"
        )

        let corpus = Self.corpus(count: Self.messageCount)
        var report: [(String, Int, TimeInterval)] = []

        for (label, sparse, prefixes) in [
            ("dense,   prefix='2 3 4'", false, "2 3 4"),
            ("dense,   prefix='2 3'", false, "2 3"),
            ("dense,   prefix='2'", false, "2"),
            ("sparse,  prefix='2 3 4'", true, "2 3 4"),
            ("dense,   no prefix index", false, ""),
            ("sparse,  no prefix index", true, ""),
        ] {
            let (dbQueue, cleanup) = try makeDatabase()
            defer { cleanup() }
            try dbQueue.write { db in
                try db.execute(sql: Self.createSQL(prefixes: prefixes))
                for sql in SearchIndexSchema.configureMergeSQL { try db.execute(sql: sql) }
            }
            for chunk in stride(from: 0, to: corpus.count, by: 5_000) {
                let slice = corpus[chunk..<min(chunk + 5_000, corpus.count)]
                try dbQueue.write { db in
                    for (offset, body) in slice.enumerated() {
                        try insert(db, rowid: chunk + offset + 1, body: body, sparse: sparse)
                    }
                }
            }
            try dbQueue.write { db in
                try db.execute(sql: "INSERT INTO message_search(message_search) VALUES('optimize')")
            }
            let bytes = try dbQueue.read { db in
                let pages = try Int.fetchOne(db, sql: "PRAGMA page_count") ?? 0
                let size = try Int.fetchOne(db, sql: "PRAGMA page_size") ?? 0
                return pages * size
            }
            // A two-character prefix is the worst case: least selective, and the query the user
            // issues after typing two letters.
            let plan = try XCTUnwrap(SearchPatternBuilder.prepare("са"))
            var slowest: TimeInterval = 0
            try dbQueue.read { db in
                for _ in 0..<20 {
                    let started = Date()
                    _ = try Int.fetchAll(
                        db, sql: "SELECT rowid FROM message_search WHERE message_search MATCH ? LIMIT 60",
                        arguments: [plan.exactExpression]
                    )
                    slowest = max(slowest, Date().timeIntervalSince(started))
                }
            }
            report.append((label, bytes, slowest))
        }

        let baseline = report[0].1
        print("\n=== message_search, \(Self.messageCount) messages ===")
        for (label, bytes, slowest) in report {
            let mb = Double(bytes) / 1_048_576
            let delta = Double(bytes - baseline) / Double(baseline) * 100
            print(String(format: "  %-26s %7.1f MB  %+6.1f%%   2-char prefix worst %5.1f ms",
                         (label as NSString).utf8String!, mb, delta, slowest * 1000))
        }
        print("  ~\(baseline / Self.messageCount) bytes per message at the shipped design\n")

        XCTAssertGreaterThan(baseline, 0)
    }

    // MARK: - Fixtures

    /// Deterministic mix approximating a Tajik user's replica: mostly Russian and Latin, with a
    /// fifth of messages carrying the Tajik letters that make folding differ from exact.
    private static func corpus(count: Int) -> [String] {
        let russian = ["привет", "как", "дела", "спасибо", "хорошо", "завтра", "встреча", "домой"]
        let tajik = ["тоҷикӣ", "ҷони", "ғафуров", "қишлоқ", "ҳаво", "ӯро", "салом", "рафтам"]
        let latin = ["hello", "meeting", "tomorrow", "report", "thanks", "photo", "please", "call"]

        var generator = SystemRandomNumberGenerator()
        _ = generator
        var seed: UInt64 = 0x5EED
        func next(_ bound: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((seed >> 33) % UInt64(bound))
        }

        return (0..<count).map { index in
            let pool: [String]
            switch index % 5 {
            case 0: pool = tajik                    // 20% carry Tajik letters
            case 1, 2: pool = latin
            default: pool = russian
            }
            return (0..<12).map { _ in pool[next(pool.count)] }.joined(separator: " ")
        }
    }

    private static func createSQL(prefixes: String) -> String {
        """
        CREATE VIRTUAL TABLE message_search USING fts5(
            exact, file_name, link_text,
            folded, file_name_folded, link_text_folded,
            dialog_token,
            tokenize = '\(SearchIndexSchema.tokenize)',
            \(prefixes.isEmpty ? "" : "prefix = '\(prefixes)',")
            content = '', contentless_delete = 1
        )
        """
    }

    private func makeDatabase() throws -> (DatabaseQueue, () -> Void) {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.prepareDatabase { db in try db.usePassphrase(Data(repeating: 0x5A, count: 32)) }
        let queue = try DatabaseQueue(
            path: directory.appending(path: "bench.sqlite").path, configuration: configuration
        )
        return (queue, { try? FileManager.default.removeItem(at: directory) })
    }

    private func insert(_ db: Database, rowid: Int, body: String, sparse: Bool) throws {
        let exact = SearchTextNormalizer.exact(body)
        let folded = SearchTextNormalizer.foldedForm(body)
        try db.execute(
            sql: """
                INSERT INTO message_search(
                    rowid, exact, file_name, link_text,
                    folded, file_name_folded, link_text_folded, dialog_token
                ) VALUES (?, ?, '', '', ?, '', '', 'aabb')
                """,
            arguments: [rowid, exact, sparse && folded == exact ? "" : folded]
        )
    }
}
