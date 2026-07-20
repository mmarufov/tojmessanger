import XCTest
@testable import Toj

/// Opt-in release-performance fixtures matching the local-first acceptance dataset. They are
/// skipped in ordinary CI because constructing the encrypted 100k-message replica is intentional
/// load work. Run with `TOJ_PERFORMANCE_FIXTURES=1` on the representative physical iPhone and
/// capture the `LocalFirst` signposts in Instruments.
final class LocalFirstPerformanceTests: XCTestCase {
    func testLargeEncryptedReplicaFixture() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["TOJ_PERFORMANCE_FIXTURES"] == "1",
            "Set TOJ_PERFORMANCE_FIXTURES=1 for the 100k-message performance fixture"
        )

        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = try CloudLocalStore(
            path: directory.appending(path: "cloud.sqlite").path,
            key: Data(repeating: 0x71, count: 32)
        )
        let accountId = "performance-account"

        for index in 0..<1_000 {
            let dialogId = "fixture-dialog-\(index)"
            try await store.upsertDialog(
                dialogId: dialogId,
                title: "Fixture \(index)",
                lastMsgId: index == 0 ? 100_000 : Int64(index),
                updatedAt: "2026-07-16 00:\(String(format: "%02d", index % 60)):00"
            )
            try await store.saveMembers(
                dialogId: dialogId,
                members: [
                    BootstrapDialogMember(
                        accountId: accountId,
                        role: "member",
                        lastReadMsgId: index == 0 ? 99_000 : 0
                    ),
                ]
            )
        }

        let hotDialogId = "fixture-dialog-0"
        for pageStart in stride(from: 1, through: 100_000, by: 1_000) {
            let pageEnd = min(100_000, pageStart + 999)
            let messages = (pageStart...pageEnd).map { msgId in
                CloudMessage(
                    dialogId: hotDialogId,
                    msgId: Int64(msgId),
                    senderAccountId: msgId.isMultiple(of: 3) ? accountId : "fixture-peer",
                    clientMsgId: "fixture-message-\(msgId)",
                    kind: "text",
                    text: "Encrypted fixture message \(msgId)",
                    reactions: (msgId == pageEnd ? (0..<100).map {
                        CloudReaction(accountId: "reactor-\($0)", emoji: "👍")
                    } : []),
                    editVersion: 0,
                    state: "visible",
                    serverTs: "2026-07-16T00:00:00.000Z"
                )
            }
            try await store.applyHistoryPage(
                HistoryPageResponse(
                    dialogId: hotDialogId,
                    messages: messages,
                    nextBeforeMsgId: pageStart == 1 ? nil : Int64(pageStart),
                    hasMore: pageStart > 1
                )
            )
        }

        let twoGigabytes: Int64 = 2 * 1_024 * 1_024 * 1_024
        for index in 0..<2_048 {
            try await store.upsertMediaCacheEntry(
                MediaCacheEntry(
                    mediaId: "fixture-media-\(index)",
                    variant: "full",
                    encryptedPath: "fixture/\(index)",
                    byteSize: twoGigabytes / 2_048,
                    cachedBytes: twoGigabytes / 2_048,
                    contiguousOffset: twoGigabytes / 2_048,
                    state: "complete",
                    lastAccessedAt: "2026-07-16 00:00:00",
                    protectedUntil: nil
                )
            )
        }

        let clock = ContinuousClock()
        let dialogStart = clock.now
        let dialogs = try await store.dialogs(accountId: accountId)
        let dialogDuration = dialogStart.duration(to: clock.now)
        let timelineStart = clock.now
        let timeline = try await store.timeline(dialogId: hotDialogId, window: .initial)
        let timelineDuration = timelineStart.duration(to: clock.now)
        let mediaUsage = try await store.downloadedMediaUsageBytes()

        XCTAssertEqual(dialogs.count, 1_000)
        XCTAssertEqual(timeline.messages.count, TimelineWindow.initialLimit)
        XCTAssertEqual(mediaUsage, twoGigabytes)
        await MainActor.run {
            XCTContext.runActivity(named: "Fixture timings") { activity in
                activity.add(XCTAttachment(
                    string: "dialogs=\(dialogDuration), timeline=\(timelineDuration)"
                ))
            }
        }
    }
}
