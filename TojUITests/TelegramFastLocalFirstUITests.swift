import XCTest

@MainActor
final class TelegramFastLocalFirstUITests: XCTestCase {
    private enum Fixture {
        static let primaryDialog = "00000000-0000-4000-8000-000000000201"
        static let secondDialog = "00000000-0000-4000-8000-000000000202"
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
