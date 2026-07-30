import XCTest

@MainActor
final class TelegramFastLocalFirstUITests: XCTestCase {
    private enum Fixture {
        static let primaryDialog = "00000000-0000-4000-8000-000000000201"
        static let secondDialog = "00000000-0000-4000-8000-000000000202"
        static let savedDialog = "00000000-0000-4000-8000-000000000203"
        static let photo = "00000000-0000-4000-8000-000000000301"
        static let video = "00000000-0000-4000-8000-000000000302"
    }

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        launch(reset: true)
    }

    func testColdOfflineOpenAndRapidChatSwitching() {
        XCTAssertTrue(
            app.staticTexts["Offline — showing saved chats"].waitForExistence(timeout: 3),
            "The fixture must remain explicitly offline while rendering the local replica."
        )

        openChat(Fixture.primaryDialog)
        XCTAssertTrue(element("conversation-\(Fixture.primaryDialog)").waitForExistence(timeout: 3))
        XCTAssertTrue(element("message-ui-fixture-text").waitForExistence(timeout: 3))
        XCTAssertTrue(element("message-ui-fixture-latest").exists)

        goBackToChats()
        openChat(Fixture.secondDialog)
        XCTAssertTrue(element("conversation-\(Fixture.secondDialog)").waitForExistence(timeout: 3))
        XCTAssertTrue(element("message-ui-fixture-second-chat").waitForExistence(timeout: 3))

        goBackToChats()
        openChat(Fixture.primaryDialog)
        XCTAssertTrue(element("conversation-\(Fixture.primaryDialog)").waitForExistence(timeout: 3))
        XCTAssertTrue(element("message-ui-fixture-latest").waitForExistence(timeout: 3))
    }

    func testSavedPhotoAndVideoOpenOfflineAcrossProcessRelaunch() {
        openChat(Fixture.primaryDialog)

        openMedia(Fixture.photo, towardOlderMessages: true)
        XCTAssertTrue(element("media-viewer-\(Fixture.photo)").waitForExistence(timeout: 5))
        dismissViewer()

        openMedia(Fixture.video, towardOlderMessages: false)
        XCTAssertTrue(element("media-viewer-\(Fixture.video)").waitForExistence(timeout: 5))

        // Kill while the cached video viewer is active. A new process must recover the same
        // encrypted bytes and durable representations without fixture reseeding or a server.
        app.terminate()
        launch(reset: false)
        openChat(Fixture.primaryDialog)
        openMedia(Fixture.photo, towardOlderMessages: true)
        XCTAssertTrue(
            element("media-viewer-\(Fixture.photo)").waitForExistence(timeout: 5),
            "A cached fullscreen photo must reopen from encrypted disk after process death."
        )
    }

    func testSavedMessagesSettingsRouteOpensEncryptedOfflineConversation() {
        let settingsTab = app.tabBars.buttons["Settings"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 3))
        settingsTab.tap()

        let savedMessages = app.buttons["settings-saved-messages"]
        XCTAssertTrue(savedMessages.waitForExistence(timeout: 3))
        savedMessages.tap()

        XCTAssertTrue(element("conversation-\(Fixture.savedDialog)").waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Saved Messages"].waitForExistence(timeout: 3))
        XCTAssertTrue(element("message-ui-fixture-saved-note").waitForExistence(timeout: 3))
    }

    func testDraftTextReplyAndThreeReorderedAttachmentsRestoreAfterTermination() {
        openChat(Fixture.primaryDialog)
        let composer = app.textFields["Message"]
        XCTAssertTrue(composer.waitForExistence(timeout: 3))
        XCTAssertEqual(composer.value as? String, "Persistent exact draft  ")
        XCTAssertTrue(app.staticTexts["Replying"].exists)
        for index in 0..<3 {
            XCTAssertTrue(element("draft-attachment-ui-draft-\(index)").exists)
        }

        let lastMenu = element("draft-attachment-menu-ui-draft-2")
        XCTAssertTrue(lastMenu.exists)
        lastMenu.tap()
        app.buttons["Move earlier"].tap()
        lastMenu.tap()
        app.buttons["Move earlier"].tap()
        XCTAssertTrue(
            element("draft-attachment-ui-draft-2").label.contains("Attachment 1 of 3")
        )

        composer.tap()
        composer.typeText("edited")
        app.terminate()
        launch(reset: false)
        openChat(Fixture.primaryDialog)
        XCTAssertEqual(app.textFields["Message"].value as? String, "editedPersistent exact draft  ")
        XCTAssertTrue(element("draft-attachment-ui-draft-2").label.contains("Attachment 1 of 3"))
        XCTAssertTrue(app.staticTexts["Replying"].exists)
    }

    func testRemoteDeviceClearConvergesAfterRelaunch() {
        openChat(Fixture.primaryDialog)
        XCTAssertTrue(element("draft-attachment-ui-draft-0").exists)
        app.terminate()
        app.launchEnvironment["TOJ_UI_FIXTURE_REMOTE_CLEAR"] = "1"
        launch(reset: false)
        openChat(Fixture.primaryDialog)
        XCTAssertFalse(element("draft-attachment-ui-draft-0").exists)
        XCTAssertEqual(app.textFields["Message"].value as? String, "Message")
    }

    func testDraftComposerAccessibilityAtLargestTypeAndReducedMotion() {
        app.terminate()
        app.launchArguments += [
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge",
            "-UIAccessibilityReduceMotionEnabled",
            "YES",
        ]
        launch(reset: false)
        openChat(Fixture.primaryDialog)
        XCTAssertTrue(app.textFields["Message"].isHittable)
        XCTAssertTrue(element("draft-attachment-ui-draft-0").label.contains("ready"))
        XCTAssertFalse(element("draft-attachment-ui-draft-0").label.isEmpty)
    }

    func testAcknowledgedAttachmentsCreateOneOptimisticGroupBeforeNetworking() {
        openChat(Fixture.primaryDialog)
        let send = app.buttons["Send"]
        XCTAssertTrue(send.waitForExistence(timeout: 3))
        send.tap()
        let pendingGroup = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'media-group-' AND identifier ENDSWITH '-pending'"))
            .firstMatch
        for _ in 0..<4 where !pendingGroup.exists {
            app.swipeUp()
        }
        XCTAssertTrue(pendingGroup.waitForExistence(timeout: 5))
        XCTAssertFalse(element("draft-attachment-ui-draft-0").exists)
    }

    func testAcknowledgedSingleAttachmentCreatesOptimisticMessageBeforeNetworking() {
        app.terminate()
        app.launchEnvironment["TOJ_UI_FIXTURE_SINGLE_DRAFT"] = "1"
        launch(reset: true)
        openChat(Fixture.primaryDialog)
        XCTAssertTrue(element("draft-attachment-ui-draft-0").exists)
        XCTAssertFalse(element("draft-attachment-ui-draft-1").exists)
        let send = app.buttons["Send"]
        XCTAssertTrue(send.waitForExistence(timeout: 3))
        send.tap()
        XCTAssertTrue(element("media-bubble-\(Fixture.photo)").waitForExistence(timeout: 5))
        XCTAssertFalse(element("draft-attachment-ui-draft-0").exists)
    }

    func testPartialAndFailedAlbumsExposeStableAccessiblePresentation() {
        openChat(Fixture.primaryDialog)
        let partial = element("media-group-00000000-0000-4000-8000-000000000601")
        XCTAssertTrue(partial.waitForExistence(timeout: 3))
        XCTAssertTrue(partial.label.localizedCaseInsensitiveContains("2 of 3"))

        goBackToChats()
        openChat(Fixture.secondDialog)
        let failed = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'media-group-'"))
            .matching(NSPredicate(format: "label CONTAINS[c] 'failed'"))
            .firstMatch
        XCTAssertTrue(failed.waitForExistence(timeout: 3))
        XCTAssertTrue(failed.label.localizedCaseInsensitiveContains("2 of 2"))
    }

    private func launch(reset: Bool) {
        app.launchEnvironment["TOJ_UI_FIXTURE"] = "telegram-fast"
        app.launchEnvironment["TOJ_UI_FIXTURE_RESET"] = reset ? "1" : "0"
        app.launch()
        XCTAssertTrue(
            app.buttons["chat-row-\(Fixture.primaryDialog)"].waitForExistence(timeout: 15),
            "The encrypted local chat list did not become ready."
        )
    }

    private func openChat(_ dialogID: String) {
        let row = app.buttons["chat-row-\(dialogID)"]
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        row.tap()
    }

    private func goBackToChats() {
        let back = app.buttons["Back"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 3))
        back.tap()
        XCTAssertTrue(app.buttons["chat-row-\(Fixture.primaryDialog)"].waitForExistence(timeout: 3))
    }

    private func openMedia(_ mediaID: String, towardOlderMessages: Bool) {
        let bubble = element("media-bubble-\(mediaID)")
        for _ in 0..<8 where !bubble.isHittable {
            towardOlderMessages ? app.swipeDown() : app.swipeUp()
        }
        XCTAssertTrue(bubble.waitForExistence(timeout: 3), "Media bubble \(mediaID) was not rendered.")
        XCTAssertTrue(bubble.isHittable, "Media bubble \(mediaID) could not be brought on screen.")
        bubble.tap()
    }

    private func dismissViewer() {
        let back = app.buttons["Back"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 3))
        back.tap()
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }
}
