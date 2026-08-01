import GRDB
import XCTest
@testable import Toj

/// Jump-to-message and in-chat navigation at the model layer.
///
/// These sit on a real `CloudLocalStore` because the behaviour under test is "does opening a
/// conversation land on the right message", and the anchor logic reads local state to decide.
@MainActor
final class SearchNavigationTests: XCTestCase {
    private var directory: URL!
    private var store: CloudLocalStore!
    private var model: CloudAppModel!

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try CloudLocalStore(
            path: directory.appending(path: "cloud.sqlite").path,
            key: Data(repeating: 0x24, count: 32)
        )
        model = CloudAppModel(localStore: store, useDefaultLocalStore: false)
    }

    override func tearDown() async throws {
        model = nil
        store = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try await super.tearDown()
    }

    // MARK: - Jump to message

    /// Opening from the chat list keeps the existing behaviour: bottom of the conversation.
    func testOpeningWithoutAFocusAnchorsAtTheBottom() async throws {
        try await seed(messages: 5)
        model.prepareConversationOpen(dialogId: "d1")
        XCTAssertEqual(model.openingTimelineAnchor, .bottom)
        XCTAssertNil(model.focusedSearchMsgId, "no search, no flash")
    }

    /// Opening from a search result anchors on the match instead of resetting to the bottom, which
    /// is what `beginConversationSelection` unconditionally did before.
    func testOpeningFromASearchResultAnchorsOnTheMatch() async throws {
        try await seed(messages: 20)
        model.prepareConversationOpen(dialogId: "d1", focusMsgId: 7)

        XCTAssertEqual(model.openingTimelineAnchor, .saved(msgId: 7))
        XCTAssertEqual(model.focusedSearchMsgId, 7, "the match is flagged for the flash")
    }

    /// The focus is one-shot. A later visit to the same conversation must not replay the highlight,
    /// which without clearing would look like a bug rather than a hint.
    func testFocusIsConsumedAndNotReplayed() async throws {
        try await seed(messages: 10)
        model.prepareConversationOpen(dialogId: "d1", focusMsgId: 3)
        XCTAssertEqual(model.focusedSearchMsgId, 3)

        model.clearSearchFocus()
        model.deselectDialog("d1")
        model.prepareConversationOpen(dialogId: "d1")

        XCTAssertNil(model.focusedSearchMsgId)
        XCTAssertEqual(model.openingTimelineAnchor, .bottom)
    }

    /// A match outside the loaded window still anchors on the match; the window is fetched around
    /// it rather than the jump silently landing wherever history happens to end.
    func testJumpToAMatchOutsideTheLoadedWindowStillAnchorsOnIt() async throws {
        try await seed(messages: 300)
        model.prepareConversationOpen(dialogId: "d1")
        await model.selectDialog("d1")

        await model.jumpToSearchMatch(12)

        XCTAssertEqual(model.openingTimelineAnchor, .saved(msgId: 12))
        XCTAssertEqual(model.focusedSearchMsgId, 12)
    }

    // MARK: - In-chat search

    func testInChatSearchFindsMatchesAndReportsPosition() async throws {
        try await seed(messages: 6, matchingEvery: 2)   // msgIds 2, 4, 6 match
        await openConversationAndIndex()

        model.openInChatSearch()
        await model.updateInChatSearch(query: "needle")

        let state = try XCTUnwrap(model.inChatSearch)
        XCTAssertEqual(state.matches, [6, 4, 2], "newest first")
        XCTAssertEqual(state.currentIndex, 0)
        XCTAssertEqual(state.positionLabel, "1 of 3")
        XCTAssertEqual(model.focusedSearchMsgId, 6, "opening a search jumps to the newest match")
    }

    /// Next walks toward older messages and wraps, because a find bar that dead-ends makes the user
    /// retype to get back to the start.
    func testNextAndPreviousWalkMatchesAndWrap() async throws {
        try await seed(messages: 6, matchingEvery: 2)
        await openConversationAndIndex()
        model.openInChatSearch()
        await model.updateInChatSearch(query: "needle")

        await model.stepInChatSearch(forward: true)
        XCTAssertEqual(model.inChatSearch?.positionLabel, "2 of 3")
        XCTAssertEqual(model.focusedSearchMsgId, 4)

        await model.stepInChatSearch(forward: true)
        XCTAssertEqual(model.inChatSearch?.positionLabel, "3 of 3")
        XCTAssertEqual(model.focusedSearchMsgId, 2)

        await model.stepInChatSearch(forward: true)
        XCTAssertEqual(model.inChatSearch?.positionLabel, "1 of 3", "next wraps to the newest")

        await model.stepInChatSearch(forward: false)
        XCTAssertEqual(model.inChatSearch?.positionLabel, "3 of 3", "previous wraps backwards")
    }

    func testInChatSearchReportsNoMatchesWithoutCrashingOnStep() async throws {
        try await seed(messages: 4)
        await openConversationAndIndex()
        model.openInChatSearch()
        await model.updateInChatSearch(query: "absent")

        let state = try XCTUnwrap(model.inChatSearch)
        XCTAssertTrue(state.isEmpty)
        XCTAssertNil(state.positionLabel)

        await model.stepInChatSearch(forward: true)   // must be a no-op, not a crash
        XCTAssertNil(model.inChatSearch?.currentIndex)
    }

    func testClosingInChatSearchClearsTheFlash() async throws {
        try await seed(messages: 4, matchingEvery: 2)
        await openConversationAndIndex()
        model.openInChatSearch()
        await model.updateInChatSearch(query: "needle")
        XCTAssertNotNil(model.focusedSearchMsgId)

        model.closeInChatSearch()
        XCTAssertNil(model.inChatSearch)
        XCTAssertNil(model.focusedSearchMsgId, "closing the bar removes the highlight")
    }

    func testInChatSearchIsScopedToTheOpenConversation() async throws {
        // d1 matches on even ids, d2 on every id. Both dialogs reuse msg_ids 1...4, which is
        // exactly the situation where a scoping bug hides: the ids alone cannot tell them apart.
        try await seed(messages: 4, matchingEvery: 2, dialogId: "d1")
        try await seed(messages: 4, matchingEvery: 1, dialogId: "d2")
        await openConversationAndIndex()

        model.openInChatSearch()
        await model.updateInChatSearch(query: "needle")
        XCTAssertEqual(model.inChatSearch?.matches, [4, 2], "only d1's matches")

        // The store's own scoped query is the ground truth for what each conversation contains.
        let inD1 = try await store.searchInDialog("d1", query: "needle")
        let inD2 = try await store.searchInDialog("d2", query: "needle")
        XCTAssertEqual(inD1, [4, 2])
        XCTAssertEqual(inD2, [4, 3, 2, 1], "d2 has more matches, and none of them leaked into d1")
    }

    // MARK: - Helpers

    private func openConversationAndIndex() async {
        model.prepareConversationOpen(dialogId: "d1")
        await model.selectDialog("d1")
        await model.refreshSearchCoordinatorForTesting()
    }

    private func seed(
        messages count: Int, matchingEvery stride: Int = 0, dialogId: String = "d1"
    ) async throws {
        try await store.dbQueue.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO dialogs(dialog_id, type, title, last_msg_id, updated_at)
                VALUES (?, 'group', 'Test', ?, datetime('now'))
                """, arguments: [dialogId, count])
            for index in 1...count {
                let matches = stride > 0 && index % stride == 0
                try db.execute(sql: """
                    INSERT INTO messages(local_id, dialog_id, msg_id, client_msg_id,
                                         sender_account_id, kind, text, is_forwarded, edit_version,
                                         state, server_ts, local_state)
                    VALUES (?, ?, ?, ?, 'a1', 'text', ?, 0, 0, 'visible', ?, 'sent')
                    """, arguments: [
                        "\(dialogId):\(index)", dialogId, index, "\(dialogId)-c\(index)",
                        matches ? "needle \(index)" : "filler \(index)",
                        String(format: "2026-07-%02dT09:00:00Z", min(28, index)),
                    ])
            }
        }
    }
}
