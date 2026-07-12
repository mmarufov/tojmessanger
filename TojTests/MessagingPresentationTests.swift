import XCTest
@testable import Toj

final class MessagingPresentationTests: XCTestCase {
    func testCapabilitySetsKeepProductionTruthful() {
        XCTAssertTrue(MessagingCapabilities.productionText.isEmpty)
        XCTAssertTrue(MessagingCapabilities.demo.contains(.media))
        XCTAssertTrue(MessagingCapabilities.demo.contains(.voiceNotes))
        XCTAssertTrue(MessagingCapabilities.demo.contains(.groups))
        XCTAssertTrue(MessagingCapabilities.demo.contains(.calls))
    }

    func testEveryMessageActionHasAccessibleCopyAndSymbol() {
        for action in MessageAction.allCases {
            XCTAssertFalse(action.title.isEmpty)
            XCTAssertFalse(action.systemImage.isEmpty)
        }
    }

    func testPresentationStatesAreValueTypes() {
        XCTAssertEqual(
            ComposerViewState(mode: .text, text: "Hello", canSend: true),
            ComposerViewState(mode: .text, text: "Hello", canSend: true)
        )
        XCTAssertNotEqual(
            ConversationViewState(phase: .content, connection: .connected, unreadBelow: 0),
            ConversationViewState(phase: .partial(message: "Offline"), connection: .offline, unreadBelow: 2)
        )
    }

    @MainActor
    func testDemoEnablesRichCapabilitiesAndProductionModelDoesNot() {
        let model = CloudAppModel()
        XCTAssertEqual(model.capabilities, .productionText)

        model.enterDemoMode()

        XCTAssertEqual(model.capabilities, .demo)
    }

    @MainActor
    func testDemoSearchScopesMessagesAndAttachments() async {
        let model = CloudAppModel()
        model.enterDemoMode()

        XCTAssertEqual(model.dialogs(matching: "Олично", scope: .messages).map(\.id), ["demo-mehrona"])
        XCTAssertEqual(model.dialogs(matching: "Шоми", scope: .media).map(\.id), ["demo-mehrona"])
        XCTAssertEqual(model.dialogs(matching: "Toj-Brief", scope: .files).map(\.id), ["demo-firooz"])
        XCTAssertTrue(model.dialogs(matching: "anything", scope: .links).isEmpty)
        XCTAssertEqual(model.dialogs(matching: "Документы", scope: .chats).map(\.id), ["demo-firooz"])
        XCTAssertTrue(model.dialogs(matching: "Документы", scope: .people).isEmpty)
    }

    @MainActor
    func testDraftPersistsPerConversationAndAppearsInChatRow() async {
        let model = CloudAppModel()
        model.enterDemoMode()

        await model.selectDialog("demo-mehrona")
        model.draft = "Паёми нотамом"
        model.deselectDialog("demo-mehrona")

        XCTAssertEqual(model.dialogs.first(where: { $0.id == "demo-mehrona" })?.draftPreview, "Паёми нотамом")

        await model.selectDialog("demo-mehrona")
        XCTAssertEqual(model.draft, "Паёми нотамом")
    }

    @MainActor
    func testOpeningDemoConversationClearsUnreadWithoutDroppingOrganizationState() async {
        let model = CloudAppModel()
        model.enterDemoMode()
        let before = model.dialogs.first(where: { $0.id == "demo-mehrona" })
        XCTAssertEqual(before?.isPinned, true)
        XCTAssertEqual(before?.mentionCount, 1)

        await model.selectDialog("demo-mehrona")

        let after = model.dialogs.first(where: { $0.id == "demo-mehrona" })
        XCTAssertEqual(after?.unreadCount, 0)
        XCTAssertEqual(after?.mentionCount, 0)
        XCTAssertEqual(after?.isPinned, true)
    }

    @MainActor
    func testReplyAndEditComposerModesAreDeterministic() async throws {
        let model = CloudAppModel()
        model.enterDemoMode()
        await model.selectDialog("demo-mehrona")
        let incoming = try XCTUnwrap(model.lines.first(where: { !$0.mine }))
        let outgoing = try XCTUnwrap(model.lines.first(where: { $0.mine }))

        model.beginReply(to: incoming)
        XCTAssertEqual(model.composerMode, .replying(messageId: incoming.id, preview: incoming.text))

        model.beginEditing(outgoing)
        XCTAssertEqual(model.composerMode, .editing(messageId: outgoing.id, original: outgoing.text))
        XCTAssertEqual(model.draft, outgoing.text)

        model.cancelComposerMode()
        XCTAssertEqual(model.composerMode, .text)
        XCTAssertTrue(model.draft.isEmpty)
    }

    @MainActor
    func testDemoChatOrganizationStateChangesWithoutServerMutation() {
        let model = CloudAppModel()
        model.enterDemoMode()

        model.toggleMuted("demo-mehrona")
        model.togglePinned("demo-firooz")
        model.archive("demo-aziz")

        XCTAssertEqual(model.dialogs.first(where: { $0.id == "demo-mehrona" })?.isMuted, true)
        XCTAssertEqual(model.dialogs.first?.id, "demo-mehrona", "Existing pinned chat remains first")
        XCTAssertFalse(model.dialogs(matching: "", scope: .chats).contains(where: { $0.id == "demo-aziz" }))
    }

    @MainActor
    func testDemoReactionAndDeletionUpdateTheActiveConversation() async throws {
        let model = CloudAppModel()
        model.enterDemoMode()
        await model.selectDialog("demo-mehrona")
        let line = try XCTUnwrap(model.lines.first)

        model.reactToDemoMessage(line.id, reaction: "🔥")
        XCTAssertEqual(model.lines.first(where: { $0.id == line.id })?.reactions, ["🔥"])

        model.reactToDemoMessage(line.id, reaction: "🔥")
        XCTAssertEqual(model.lines.first(where: { $0.id == line.id })?.reactions, [])

        model.deleteDemoMessage(line.id)
        XCTAssertFalse(model.lines.contains(where: { $0.id == line.id }))
    }

    @MainActor
    func testDemoAttachmentAndVoiceNoteUsePresentationPayloads() async throws {
        let model = CloudAppModel()
        model.enterDemoMode()
        await model.selectDialog("demo-firooz")

        model.sendDemoAttachment(.video(name: "Шом", duration: "0:24"), caption: "Нигар")
        let video = try XCTUnwrap(model.lines.last)
        XCTAssertEqual(video.text, "Нигар")
        XCTAssertEqual(video.attachment, .video(name: "Шом", duration: "0:24"))

        model.beginDemoRecording()
        XCTAssertEqual(model.composerMode, .recording(elapsedSeconds: 0))
        model.finishDemoRecording()
        XCTAssertEqual(model.lines.last?.attachment, .voice(duration: "0:08"))
        XCTAssertEqual(model.composerMode, .text)
    }

    @MainActor
    func testSendingAnEditUpdatesInsteadOfAppending() async throws {
        let model = CloudAppModel()
        model.enterDemoMode()
        await model.selectDialog("demo-mehrona")
        let outgoing = try XCTUnwrap(model.lines.first(where: { $0.mine }))
        let originalCount = model.lines.count

        model.beginEditing(outgoing)
        model.draft = "Паёми таҳриршуда"
        await model.sendDraft()

        XCTAssertEqual(model.lines.count, originalCount)
        XCTAssertEqual(model.lines.first(where: { $0.id == outgoing.id })?.text, "Паёми таҳриршуда")
        XCTAssertEqual(model.lines.first(where: { $0.id == outgoing.id })?.isEdited, true)
        XCTAssertEqual(model.composerMode, .text)
    }
}
