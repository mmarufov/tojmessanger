import GRDB
import XCTest
@testable import Toj

/// Measures replica size and query latency for the `message_search` design on a realistic corpus.
///
/// The first version of this benchmark drew from 24 distinct words. That made every prefix scan
/// hit a handful of terms and every index implausibly small, which is precisely the regime where
/// `prefix='2'` looks free — so it could not support the decision it was used to make. The corpus
/// here is high-cardinality (~15k vocabulary, Zipf-distributed) and carries the four text kinds the
/// schema actually indexes: bodies, captions, filenames and links, spread over 40 dialogs.
///
/// `prefix='2'` means three-or-more-character prefixes fall back to a term-index scan, so those are
/// measured explicitly rather than assumed cheap. Cold numbers reopen the database first; warm
/// numbers report p50 and p95 rather than a single worst case.
///
/// Set `TOJ_SEARCH_BENCHMARK=1` in the test scheme's environment to run the measurement. The
/// correctness tests below always run, and so do the regression gates once the measurement has.
final class MessageSearchIndexSizeBenchmark: XCTestCase {
    private static let messageCount = 100_000
    private static let dialogCount = 40

    /// Must match the variant this schema actually ships, or the gates measure something else.
    private static let shippedLabel = "dense  prefix='2 3'"

    /// Conservative ceilings for the shipped design, set with headroom over measured values so
    /// they catch a regression in kind rather than flapping on noise.
    private static let maximumBytesPerMessage = 460
    private static let maximumWarmP95Milliseconds = 40.0
    private static let maximumColdMilliseconds = 60.0

    // MARK: - Correctness (always runs)

    /// Sparse storage is only a candidate if a widened fallback rescues it; both halves are pinned
    /// here so the rejected design stays honest rather than becoming folklore.
    func testSparseStorageIsOnlyCorrectWithTheWideFallback() throws {
        let harness = try Harness(design: .dense, prefixes: "2")
        defer { harness.cleanup() }

        try harness.dbQueue.write { db in
            // Body is literally the Russian-keyboard spelling, so folded == exact and sparse
            // storage would leave the folded columns empty.
            try Harness.insert(db, rowid: 1, body: "точики забон", dialogId: "aa-bb", design: .sparse)
            try Harness.insert(db, rowid: 2, body: "тоҷикӣ забон", dialogId: "aa-bb", design: .sparse)

            let plan = try XCTUnwrap(SearchPatternBuilder.prepare("тоҷикӣ"))
            let sql = "SELECT rowid FROM message_search WHERE message_search MATCH ? ORDER BY rowid"

            XCTAssertEqual(
                try Int.fetchAll(db, sql: sql, arguments: [plan.exactExpression]), [2],
                "only the Tajik spelling is a literal match"
            )
            XCTAssertFalse(
                try Int.fetchAll(db, sql: sql, arguments: [plan.foldedExpression]).contains(1),
                "sparse + folded-only columns loses row 1 — this is why the shipped design is dense"
            )
            XCTAssertEqual(
                try Int.fetchAll(db, sql: sql, arguments: [Design.sparse.foldedExpression(plan)]),
                [1, 2],
                "the wide fallback recovers what sparse storage drops"
            )
        }
    }

    /// The wide fallback is what makes sparse comparable, so it must also preserve tier order:
    /// exact-tier rows first, folded-tier rows after, never a sorted union.
    func testWideFallbackPreservesExactFirstOrdering() throws {
        for design in [Design.dense, .sparse] {
            let harness = try Harness(design: design, prefixes: "2")
            defer { harness.cleanup() }
            try harness.dbQueue.write { db in
                // Reversed rowids so a sorted union would return [1, 2] and hide the bug.
                try Harness.insert(db, rowid: 1, body: "тоҷикӣ", dialogId: "aa-bb", design: design)
                try Harness.insert(db, rowid: 2, body: "точики", dialogId: "aa-bb", design: design)
                let tiered = try harness.tiered(db, "точики")
                XCTAssertEqual(tiered.exact, [2], "\(design)")
                XCTAssertEqual(tiered.folded, [1], "\(design)")
                XCTAssertEqual(tiered.all, [2, 1], "\(design) lost exact-first ordering")
            }
        }
    }

    // MARK: - Measurement (gated)

    func testIndexSizeAndLatencyAcrossDesigns() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["TOJ_SEARCH_BENCHMARK"] == "1",
            "Set TOJ_SEARCH_BENCHMARK=1 in the scheme environment for the 100k-message benchmark"
        )

        let corpus = Corpus(count: Self.messageCount, dialogs: Self.dialogCount)
        var results: [Result] = []

        let variants: [(String, Design, String)] = [
            (Self.shippedLabel, .dense, "2 3"),          // shipped
            ("dense  prefix='2'", .dense, "2"),
            ("dense  prefix='2 3 4'", .dense, "2 3 4"),
            ("dense  prefix='2 3 4 5'", .dense, "2 3 4 5"),
            ("dense  no prefix", .dense, ""),
            ("sparse+wide prefix='2'", .sparse, "2"),
            ("sparse+wide no prefix", .sparse, ""),
        ]

        for (label, design, prefixes) in variants {
            let harness = try Harness(design: design, prefixes: prefixes)
            defer { harness.cleanup() }
            try harness.load(corpus)
            results.append(try harness.measure(label: label, corpus: corpus))
        }

        Self.report(results)

        // Gates apply to the shipped design only; the others exist for comparison.
        // Matched exactly: "dense  prefix='2'" is a prefix of "dense  prefix='2 3'", so
        // hasPrefix would silently gate the wrong variant.
        let shipped = try XCTUnwrap(results.first { $0.label == Self.shippedLabel })
        let perMessage = shipped.bytes / Self.messageCount
        XCTAssertLessThanOrEqual(
            perMessage, Self.maximumBytesPerMessage,
            "shipped index grew to \(perMessage) B/message"
        )
        for measurement in shipped.queries {
            XCTAssertLessThanOrEqual(
                measurement.warmP95 * 1000, Self.maximumWarmP95Milliseconds,
                "\(measurement.name) warm p95 regressed"
            )
            XCTAssertLessThanOrEqual(
                measurement.cold * 1000, Self.maximumColdMilliseconds,
                "\(measurement.name) cold regressed"
            )
        }
    }

    private static func report(_ results: [Result]) {
        func pad(_ text: String, _ width: Int) -> String {
            text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
        }
        func lead(_ text: String, _ width: Int) -> String {
            text.count >= width ? text : String(repeating: " ", count: width - text.count) + text
        }

        print("\n=== message_search: \(messageCount) messages, \(dialogCount) dialogs ===")
        print(pad("design", 24) + lead("size", 10) + lead("B/msg", 8))
        for result in results {
            let mb = String(format: "%.1f MB", Double(result.bytes) / 1_048_576)
            print(pad(result.label, 24) + lead(mb, 10) + lead("\(result.bytes / messageCount)", 8))
        }

        print("\n--- latency ms: cold (after reopen) / warm p50 / warm p95 ---")
        let names = results.first?.queries.map(\.name) ?? []
        print(pad("design", 24) + names.map { lead($0, 19) }.joined())
        for result in results {
            let cells = result.queries.map { measurement in
                lead(String(format: "%.1f/%.1f/%.1f",
                            measurement.cold * 1000,
                            measurement.warmP50 * 1000,
                            measurement.warmP95 * 1000), 19)
            }
            print(pad(result.label, 24) + cells.joined())
        }
        print("")
    }

    // MARK: - Designs

    enum Design: CustomStringConvertible {
        /// Folded columns always written; folded tier searches folded columns only.
        case dense
        /// Folded columns written only when they differ; folded tier must also search the exact
        /// columns, or rows that needed no folding become unreachable from a Tajik query.
        case sparse

        var description: String { self == .dense ? "dense" : "sparse+wide" }

        func foldedExpression(_ plan: PreparedSearchQuery) -> String {
            let body = plan.foldedAlternatives
                .map { alternative in
                    alternative
                        .map { SearchPatternBuilder.quote($0.text) + ($0.isPrefix ? "*" : "") }
                        .joined(separator: " AND ")
                }
                .joined(separator: " OR ")
            switch self {
            case .dense:
                return SearchPatternBuilder.qualify(body, with: SearchIndexSchema.foldedColumns)
            case .sparse:
                return SearchPatternBuilder.qualify(
                    body, with: SearchIndexSchema.exactColumns + SearchIndexSchema.foldedColumns
                )
            }
        }
    }

    struct Measurement {
        let name: String
        let cold: TimeInterval
        let warmP50: TimeInterval
        let warmP95: TimeInterval
    }

    struct Result {
        let label: String
        let bytes: Int
        let queries: [Measurement]
    }

    // MARK: - Corpus

    /// A deterministic, high-cardinality corpus. Cardinality is the variable the first benchmark got
    /// wrong: with a tiny vocabulary every prefix matches almost nothing and the index barely grows,
    /// which flatters exactly the choice under test.
    struct Corpus {
        struct Message {
            let dialog: String
            let body: String
            let fileName: String
            let linkText: String
        }

        let messages: [Message]
        let dialogs: [String]

        init(count: Int, dialogs dialogCount: Int) {
            var seed: UInt64 = 0xC0FFEE
            func next(_ bound: Int) -> Int {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return Int((seed >> 33) % UInt64(bound))
            }

            // ~15k distinct words built from realistic stems and affixes across the three scripts
            // the app sees, so prefixes of every length have many candidates.
            let russianStems = ["привет", "встреч", "завтра", "спасиб", "хорош", "работ", "город",
                                "машин", "деньг", "врем", "друз", "семь", "школ", "книг"]
            let tajikStems = ["тоҷик", "ҷони", "ғафур", "қишлоқ", "ҳаво", "ӯро", "салом", "рафт",
                              "дӯст", "хона", "модар", "падар", "барод", "хоҳар"]
            let latinStems = ["meeting", "report", "invoice", "project", "message", "picture",
                              "holiday", "morning", "evening", "contract", "delivery", "package"]
            let suffixes = ["", "а", "ы", "ой", "ам", "ах", "ов", "ing", "ed", "s", "er", "ion",
                            "и", "ро", "ат", "он", "ҳо", "ест", "ани", "ик"]

            func vocabulary(_ stems: [String]) -> [String] {
                var words: [String] = []
                for stem in stems {
                    for suffix in suffixes {
                        for index in 0..<20 { words.append("\(stem)\(suffix)\(index == 0 ? "" : String(index))") }
                    }
                }
                return words
            }
            let russian = vocabulary(russianStems)
            let tajik = vocabulary(tajikStems)
            let latin = vocabulary(latinStems)

            /// Zipf-ish: squaring a uniform draw concentrates mass on early entries, so a handful of
            /// words dominate as in real messages while the tail stays long.
            func zipf(_ pool: [String]) -> String {
                let uniform = Double(next(10_000)) / 10_000
                return pool[min(pool.count - 1, Int(uniform * uniform * Double(pool.count)))]
            }

            self.dialogs = (0..<dialogCount).map { index in
                String(format: "%08x-0000-4000-8000-%012x", index &* 2_654_435_761, index)
            }

            var built: [Message] = []
            built.reserveCapacity(count)
            for index in 0..<count {
                // Every fifth message carries Tajik letters, so the folded columns diverge for 20%
                // of rows — the ratio that decides how much sparse storage could ever save.
                let pool = index % 5 == 0 ? tajik : (index % 5 == 1 || index % 5 == 2 ? latin : russian)
                let body = (0..<(8 + next(13))).map { _ in zipf(pool) }.joined(separator: " ")
                built.append(Message(
                    dialog: dialogs[next(dialogCount)],
                    body: body,
                    // 15% attachments, 10% links — captions share the body column, as in the schema.
                    fileName: index % 7 == 0 ? "\(zipf(latin))_\(index).pdf" : "",
                    linkText: index % 10 == 0 ? "\(zipf(latin)) example com \(zipf(latin))" : ""
                ))
            }
            self.messages = built
        }

        /// Terms drawn from the corpus itself, so measured queries hit real posting lists.
        var probeTerms: (short: String, medium: String, long: String, longer: String) {
            ("пр", "при", "прив", "привет")
        }
    }

    // MARK: - Harness

    final class Harness {
        let dbQueue: DatabaseQueue
        private let directory: URL
        private let design: Design
        private let path: String
        private let configuration: Configuration

        init(design: Design, prefixes: String) throws {
            self.design = design
            directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            path = directory.appending(path: "bench.sqlite").path

            var configuration = Configuration()
            configuration.prepareDatabase { db in try db.usePassphrase(Data(repeating: 0x5A, count: 32)) }
            self.configuration = configuration
            dbQueue = try DatabaseQueue(path: path, configuration: configuration)

            try dbQueue.write { db in
                try db.execute(sql: """
                    CREATE VIRTUAL TABLE message_search USING fts5(
                        exact, file_name, link_text,
                        folded, file_name_folded, link_text_folded,
                        dialog_token,
                        tokenize = '\(SearchIndexSchema.tokenize)',
                        \(prefixes.isEmpty ? "" : "prefix = '\(prefixes)',")
                        content = '', contentless_delete = 1
                    )
                    """)
                for sql in SearchIndexSchema.configureMergeSQL { try db.execute(sql: sql) }
            }
        }

        func cleanup() { try? FileManager.default.removeItem(at: directory) }

        func load(_ corpus: Corpus) throws {
            for chunk in stride(from: 0, to: corpus.messages.count, by: 5_000) {
                let upper = min(chunk + 5_000, corpus.messages.count)
                try dbQueue.write { db in
                    for index in chunk..<upper {
                        let message = corpus.messages[index]
                        try Self.insert(
                            db, rowid: index + 1, body: message.body,
                            fileName: message.fileName, linkText: message.linkText,
                            dialogId: message.dialog, design: self.design
                        )
                    }
                }
            }
            try dbQueue.write { db in
                try db.execute(sql: "INSERT INTO message_search(message_search) VALUES('optimize')")
            }
        }

        static func insert(
            _ db: Database, rowid: Int, body: String,
            fileName: String = "", linkText: String = "", dialogId: String, design: Design
        ) throws {
            let exact = (SearchTextNormalizer.exact(body),
                         SearchTextNormalizer.exact(fileName),
                         SearchTextNormalizer.exact(linkText))
            var folded = (SearchTextNormalizer.foldedForm(body),
                          SearchTextNormalizer.foldedForm(fileName),
                          SearchTextNormalizer.foldedForm(linkText))
            if design == .sparse {
                if folded.0 == exact.0 { folded.0 = "" }
                if folded.1 == exact.1 { folded.1 = "" }
                if folded.2 == exact.2 { folded.2 = "" }
            }
            try db.execute(
                sql: """
                    INSERT INTO message_search(
                        rowid, exact, file_name, link_text,
                        folded, file_name_folded, link_text_folded, dialog_token
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [rowid, exact.0, exact.1, exact.2, folded.0, folded.1, folded.2,
                            SearchPatternBuilder.dialogToken(dialogId)]
            )
        }

        func measure(label: String, corpus: Corpus) throws -> Result {
            let bytes = try dbQueue.read { db in
                (try Int.fetchOne(db, sql: "PRAGMA page_count") ?? 0)
                    * (try Int.fetchOne(db, sql: "PRAGMA page_size") ?? 0)
            }
            let terms = corpus.probeTerms
            let dialog = corpus.dialogs[0]

            let cases: [(String, (Database) throws -> Void)] = [
                ("prefix-2", { db in try self.run(db, terms.short) }),
                ("prefix-3", { db in try self.run(db, terms.medium) }),
                ("prefix-4", { db in try self.run(db, terms.long) }),
                ("prefix-6+", { db in try self.run(db, terms.longer) }),
                ("multi-term", { db in try self.run(db, "\(terms.longer) \(terms.medium)") }),
                ("folded", { db in try self.run(db, "точики") }),
                ("translit", { db in try self.run(db, "chon") }),
                ("scoped", { db in try self.run(db, terms.medium, dialog: dialog) }),
                ("tiered-full", { db in _ = try self.tiered(db, "точики") }),
            ]

            var measurements: [Measurement] = []
            for (name, work) in cases {
                // Cold: a fresh connection, so SQLite's page cache does not carry over.
                let cold = try DatabaseQueue(path: path, configuration: configuration)
                let coldStart = Date()
                try cold.read { try work($0) }
                let coldElapsed = Date().timeIntervalSince(coldStart)

                var samples: [TimeInterval] = []
                try dbQueue.read { db in
                    for _ in 0..<5 { try work(db) }          // warm the cache
                    for _ in 0..<40 {
                        let started = Date()
                        try work(db)
                        samples.append(Date().timeIntervalSince(started))
                    }
                }
                samples.sort()
                measurements.append(Measurement(
                    name: name,
                    cold: coldElapsed,
                    warmP50: samples[samples.count / 2],
                    warmP95: samples[Int(Double(samples.count) * 0.95)]
                ))
            }
            return Result(label: label, bytes: bytes, queries: measurements)
        }

        private func run(_ db: Database, _ query: String, dialog: String? = nil) throws {
            guard let plan = SearchPatternBuilder.prepare(query) else { return }
            var expression = plan.exactExpression
            if let dialog { expression = SearchPatternBuilder.scoped(expression, toDialog: dialog) }
            _ = try Int.fetchAll(
                db, sql: "SELECT rowid FROM message_search WHERE message_search MATCH ? LIMIT 60",
                arguments: [expression]
            )
        }

        struct Tiered {
            let exact: [Int]
            let folded: [Int]
            var all: [Int] { exact + folded.filter { !exact.contains($0) } }
        }

        /// The complete shipped query: exact tier, then the folded tier for what it missed.
        func tiered(_ db: Database, _ query: String) throws -> Tiered {
            guard let plan = SearchPatternBuilder.prepare(query) else {
                return Tiered(exact: [], folded: [])
            }
            let sql = "SELECT rowid FROM message_search WHERE message_search MATCH ? ORDER BY rowid LIMIT 60"
            let exact = try Int.fetchAll(db, sql: sql, arguments: [plan.exactExpression])
            let folded = try Int.fetchAll(
                db, sql: sql, arguments: [design.foldedExpression(plan)]
            )
            return Tiered(exact: exact, folded: folded.filter { !exact.contains($0) })
        }
    }
}
