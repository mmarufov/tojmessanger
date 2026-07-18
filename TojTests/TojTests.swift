import XCTest
@testable import Toj

final class SmokeTests: XCTestCase {
    func testHarnessRuns() {
        XCTAssertTrue(true)
    }
}

final class ContactsFeatureTests: XCTestCase {
    func testPhoneNormalizationKeepsInternationalPrefixAndDigits() {
        XCTAssertEqual(TojContactsStore.normalized("+992 90 123-45-67"), "+992901234567")
        XCTAssertEqual(TojContactsStore.normalized("(408) 555-3514"), "4085553514")
    }

    func testContactsSortByNameAutomatically() {
        let contacts = [
            TojAddressBookContact(id: "z", givenName: "Zarina", familyName: "", phoneNumbers: ["+3"], thumbnailData: nil),
            TojAddressBookContact(id: "a", givenName: "Aziz", familyName: "", phoneNumbers: ["+1"], thumbnailData: nil),
            TojAddressBookContact(id: "m", givenName: "Madina", familyName: "", phoneNumbers: ["+2"], thumbnailData: nil)
        ]

        XCTAssertEqual(TojAddressBookContact.sorted(contacts).map { $0.id }, ["a", "m", "z"])
    }
}

final class ChatSearchDrawerBehaviorTests: XCTestCase {
    func testReturningFromScrolledChatsCannotRevealSearchInTheSameGesture() {
        let revealWasArmed = ChatSearchDrawerBehavior.revealIsArmed(startingAt: 160)

        XCTAssertFalse(revealWasArmed)
        XCTAssertEqual(
            ChatSearchDrawerBehavior.revealProgress(at: 30, revealWasArmed: revealWasArmed),
            0
        )
        XCTAssertFalse(
            ChatSearchDrawerBehavior.shouldOpen(
                wasOpen: false,
                revealWasArmed: revealWasArmed,
                offset: 30
            )
        )
    }

    func testFreshPullFromTopOpensOnlyAfterRevealThreshold() {
        let revealWasArmed = ChatSearchDrawerBehavior.revealIsArmed(
            startingAt: ChatSearchDrawerBehavior.height
        )

        XCTAssertTrue(revealWasArmed)
        XCTAssertFalse(
            ChatSearchDrawerBehavior.shouldOpen(
                wasOpen: false,
                revealWasArmed: revealWasArmed,
                offset: 31
            )
        )
        XCTAssertTrue(
            ChatSearchDrawerBehavior.shouldOpen(
                wasOpen: false,
                revealWasArmed: revealWasArmed,
                offset: 30
            )
        )
    }
}
