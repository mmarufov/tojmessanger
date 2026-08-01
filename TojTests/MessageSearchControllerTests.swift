import XCTest
@testable import Toj

/// Controller behaviour: debounce, cancellation, out-of-order safety, sectioning, coverage, and
/// pagination. Backed by a scripted fake so these assert the controller rather than SQLite.
@MainActor
final class MessageSearchControllerTests: XCTestCase {
    private var backend: ScriptedBackend!
    private var controller: MessageSearchController!

    override func setUp() async throws {
        try await super.setUp()
        backend = ScriptedBackend()
        controller = MessageSearchController(backend: backend, dialogs: { Self.dialogs })
    }

    // MARK: - Debounce and cancellation

    func testRapidTypingIssuesOneQuery() async throws {
        controller.scope = .messages
        for text in ["s", "sa", "sal", "salo", "salom"] {
            controller.query = text
        }
        try await settle()
        XCTAssertEqual(backend.queries, ["salom"], "intermediate keystrokes must not each hit the store")
    }

    /// A slow first response must not overwrite a fast second. Without a generation token this is
    /// the bug where results for text the user already replaced appear on screen.
    func testOutOfOrderResponsesNeverOverwriteNewerResults() async throws {
        controller.scope = .messages
        backend.delays = ["slow": .milliseconds(300)]
        backend.results = [
            "slow": [Self.hit(1, "slow result")],
            "fast": [Self.hit(2, "fast result")],
        ]

        controller.query = "slow"
        try await Task.sleep(for: .milliseconds(200))   // past the debounce, inside the delay
        controller.query = "fast"
        try await settle(for: .milliseconds(600))

        XCTAssertEqual(controller.sections.messages.map(\.text), ["fast result"])
    }

    /// Blanking the list on every keystroke reads as breakage; the previous answer stays until a
    /// new one arrives.
    func testResultsAreRetainedWhileTheNextQueryRuns() async throws {
        controller.scope = .messages
        backend.results = ["first": [Self.hit(1, "first result")]]
        controller.query = "first"
        try await settle()
        XCTAssertEqual(controller.sections.messages.count, 1)

        backend.delays = ["second": .milliseconds(300)]
        controller.query = "second"
        try await Task.sleep(for: .milliseconds(220))

        XCTAssertEqual(controller.phase, .searching)
        XCTAssertEqual(controller.sections.messages.count, 1, "the old answer stays visible")
    }

    func testClearingTheQueryReturnsToIdleAndDropsResults() async throws {
        controller.scope = .messages
        backend.results = ["salom": [Self.hit(1, "салом")]]
        controller.query = "salom"
        try await settle()
        XCTAssertEqual(controller.phase, .results)

        controller.query = ""
        try await settle()
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertTrue(controller.sections.isEmpty)
    }

    /// Media, Files and Links show content before the user types; Messages does not.
    func testBrowsingScopesQueryWithoutText() async throws {
        controller.scope = .media
        try await settle()
        XCTAssertEqual(backend.queries, [""], "a browsing scope queries with an empty string")

        backend.queries = []
        controller.scope = .messages
        try await settle()
        XCTAssertTrue(backend.queries.isEmpty, "Messages waits for text")
    }

    // MARK: - Sections

    func testChatsScopeMatchesTitlesWithTajikFolding() async throws {
        controller.scope = .chats
        controller.query = "точики"       // Russian-keyboard spelling
        try await settle()
        XCTAssertEqual(
            controller.sections.chats.map(\.title), ["Тоҷикӣ гурӯҳ"],
            "chat titles fold the same way message text does"
        )
    }

    func testChatsScopeExcludesArchived() {
        let matches = MessageSearchController.matchingDialogs(Self.dialogs, query: "archived")
        XCTAssertTrue(matches.isEmpty)
    }

    func testMessagesScopeDoesNotRenderChatRows() async throws {
        controller.scope = .messages
        backend.results = ["salom": [Self.hit(1, "салом")]]
        controller.query = "salom"
        try await settle()
        XCTAssertTrue(controller.sections.chats.isEmpty)
        XCTAssertEqual(controller.sections.messages.count, 1)
    }

    // MARK: - Phases

    func testNoMatchesReportsEmptyRatherThanDegraded() async throws {
        controller.scope = .messages
        controller.query = "nothingmatches"
        try await settle()
        XCTAssertEqual(controller.phase, .empty)
    }

    /// An unavailable index is a different answer from "no matches", and the screen must not
    /// conflate them — one invites retyping, the other does not.
    func testUnavailableIndexReportsDegraded() async throws {
        backend.coverageValue = Self.coverage(status: .unavailable, complete: 0, total: 3)
        controller.scope = .messages
        controller.query = "anything"
        try await settle()
        XCTAssertEqual(controller.phase, .degraded)
    }

    func testPartialCoverageIsSurfaced() async throws {
        backend.coverageValue = Self.coverage(status: .ready, complete: 12, total: 40)
        controller.scope = .messages
        backend.results = ["salom": [Self.hit(1, "салом")]]
        controller.query = "salom"
        try await settle()

        let message = try XCTUnwrap(controller.partialCoverageMessage)
        XCTAssertTrue(message.contains("12"), message)
        XCTAssertTrue(message.contains("40"), message)
    }

    func testCompleteCoverageShowsNoBanner() async throws {
        backend.coverageValue = Self.coverage(status: .ready, complete: 40, total: 40)
        controller.scope = .messages
        backend.results = ["salom": [Self.hit(1, "салом")]]
        controller.query = "salom"
        try await settle()
        XCTAssertNil(controller.partialCoverageMessage)
    }

    // MARK: - Pagination

    func testLoadMoreAppendsAndStopsAtTheEnd() async throws {
        controller.scope = .messages
        backend.results = ["page": (1...40).map { Self.hit(Int64($0), "page \($0)") }]
        backend.cursorAfterFirstPage = MessageSearchCursor(tier: .exact, sortTimestamp: 1, docId: 40)
        controller.query = "page"
        try await settle()
        XCTAssertEqual(controller.sections.messages.count, 40)

        backend.results = ["page": [Self.hit(41, "page 41")]]
        backend.cursorAfterFirstPage = nil
        controller.loadMore()
        try await settle()

        XCTAssertEqual(controller.sections.messages.count, 41, "the next page is appended")
        controller.loadMore()
        try await settle()
        XCTAssertEqual(controller.sections.messages.count, 41, "no cursor means no further pages")
    }

    /// A page that arrives after the query moved on must be dropped, not appended to unrelated
    /// results.
    func testLoadMoreForAStaleQueryIsDiscarded() async throws {
        controller.scope = .messages
        backend.results = ["page": (1...40).map { Self.hit(Int64($0), "page \($0)") }]
        backend.cursorAfterFirstPage = MessageSearchCursor(tier: .exact, sortTimestamp: 1, docId: 40)
        controller.query = "page"
        try await settle()

        backend.delays = ["page": .milliseconds(300)]
        controller.loadMore()
        controller.query = "different"      // invalidates the in-flight page
        try await settle(for: .milliseconds(600))

        XCTAssertFalse(
            controller.sections.messages.contains { $0.text.hasPrefix("page") },
            "a stale page must not be appended to a different query's results"
        )
    }

    // MARK: - Fixtures

    private func settle(for duration: Duration = .milliseconds(400)) async throws {
        try await Task.sleep(for: duration)
    }

    private static func hit(_ docId: Int64, _ text: String) -> MessageSearchHit {
        MessageSearchHit(
            docId: docId, clientMsgId: "c\(docId)", localId: "d1:\(docId)", dialogId: "d1",
            msgId: docId, senderAccountId: "a1", kind: "text", text: text,
            sortTimestamp: 1_000 - docId, hasMedia: false, tier: .exact
        )
    }

    private static func coverage(
        status: SearchIndexer.Status, complete: Int, total: Int
    ) -> SearchIndexer.Coverage {
        SearchIndexer.Coverage(
            status: status, indexed: complete, total: total, queueDepth: 0,
            dialogsComplete: complete, dialogsTotal: total
        )
    }

    private static let dialogs: [CloudAppModel.Dialog] = [
        CloudAppModel.Dialog(
            id: "d1", title: "Тоҷикӣ гурӯҳ", subtitle: "салом", updatedAt: "",
            isPending: false, unreadCount: 0
        ),
        CloudAppModel.Dialog(
            id: "d2", title: "Archived chat", subtitle: "old", updatedAt: "",
            isPending: false, unreadCount: 0, isArchived: true
        ),
    ]

    /// Records what was asked and replays scripted answers, optionally slowly.
    private final class ScriptedBackend: MessageSearchBackend, @unchecked Sendable {
        var queries: [String] = []
        var results: [String: [MessageSearchHit]] = [:]
        var delays: [String: Duration] = [:]
        var cursorAfterFirstPage: MessageSearchCursor?
        var coverageValue: SearchIndexer.Coverage?

        func search(_ request: MessageSearchRequest) async -> MessageSearchPage {
            queries.append(request.query)
            if let delay = delays[request.query] { try? await Task.sleep(for: delay) }
            return MessageSearchPage(
                hits: results[request.query] ?? [],
                cursor: request.cursor == nil ? cursorAfterFirstPage : nil
            )
        }

        func coverage() async -> SearchIndexer.Coverage? { coverageValue }
        func drainBeforeSearch() async {}
    }
}
