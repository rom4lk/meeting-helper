import EventKit
import XCTest
@testable import MeetingHelper

final class EventKitConversionTests: XCTestCase {

    // MARK: - Participant addresses

    func testReadsTheAddressOutOfAMailtoURL() {
        let url = URL(string: "mailto:ivan.petrov@example.com")!

        XCTAssertEqual(CalendarAttendee.emailAddress(inParticipantURL: url), "ivan.petrov@example.com")
    }

    func testIgnoresWhatFollowsTheAddress() {
        let url = URL(string: "mailto:ivan@example.com?subject=Standup")!

        XCTAssertEqual(CalendarAttendee.emailAddress(inParticipantURL: url), "ivan@example.com")
    }

    func testDecodesAnEscapedAddress() {
        let url = URL(string: "mailto:ivan%2Bcal@example.com")!

        XCTAssertEqual(CalendarAttendee.emailAddress(inParticipantURL: url), "ivan+cal@example.com")
    }

    /// EventKit identifies some participants — rooms and equipment on certain servers — by a URL
    /// that is not an address at all. Those carry no identity worth keeping.
    func testRefusesAParticipantThatIsNotAnAddress() {
        XCTAssertNil(CalendarAttendee.emailAddress(inParticipantURL: URL(string: "https://example.com/rooms/42")!))
        XCTAssertNil(CalendarAttendee.emailAddress(inParticipantURL: URL(string: "mailto:")!))
        XCTAssertNil(CalendarAttendee.emailAddress(inParticipantURL: URL(string: "mailto:not-an-address")!))
    }

    // MARK: - Response status

    func testMapsTheAnswersAnInvitationCanCarry() {
        XCTAssertEqual(CalendarAttendee.ResponseStatus(.accepted), .accepted)
        XCTAssertEqual(CalendarAttendee.ResponseStatus(.declined), .declined)
        XCTAssertEqual(CalendarAttendee.ResponseStatus(.tentative), .tentative)
        XCTAssertEqual(CalendarAttendee.ResponseStatus(.pending), .needsAction)
        XCTAssertEqual(CalendarAttendee.ResponseStatus(.delegated), .needsAction)
        XCTAssertEqual(CalendarAttendee.ResponseStatus(.unknown), .needsAction)
    }
}
