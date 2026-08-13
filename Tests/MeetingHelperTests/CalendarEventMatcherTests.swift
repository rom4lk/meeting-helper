import XCTest
@testable import MeetingHelper

final class CalendarEventMatcherTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func event(
        id: String = "event-1",
        iCalUID: String? = nil,
        title: String,
        startsIn minutes: Double = 0,
        lasts duration: Double = 60,
        attendees: [CalendarAttendee] = [],
        calendarTitle: String = "me@work.com"
    ) -> CalendarEvent {
        CalendarEvent(
            id: id,
            iCalUID: iCalUID ?? id,
            calendarTitle: calendarTitle,
            title: title,
            start: now.addingTimeInterval(minutes * 60),
            end: now.addingTimeInterval((minutes + duration) * 60),
            organizerEmail: nil,
            attendees: attendees
        )
    }

    private func meeting(_ title: String = "Meeting info", detectedIn minutes: Double = 0) -> DetectedMeeting {
        DetectedMeeting(
            kind: .googleMeet,
            title: title,
            audioPrefixes: [],
            detectedAt: now.addingTimeInterval(minutes * 60)
        )
    }

    private func attendee(_ email: String = "ivan@example.com") -> CalendarAttendee {
        CalendarAttendee(email: email)
    }

    private func currentUser(_ status: CalendarAttendee.ResponseStatus) -> CalendarAttendee {
        CalendarAttendee(email: "me@work.com", responseStatus: status, isSelf: true)
    }

    // MARK: - Time window

    func testEventOutsideToleranceIsNotACandidate() {
        let stale = event(id: "stale", title: "Roadmap review", startsIn: -120, lasts: 30)

        XCTAssertTrue(CalendarEventMatcher.candidates(for: meeting(), in: [stale]).isEmpty)
    }

    func testJoiningShortlyBeforeTheOnlyEventStillMatches() {
        let upcoming = event(title: "Roadmap review", startsIn: 5)

        XCTAssertEqual(CalendarEventMatcher.bestMatch(for: meeting(), in: [upcoming])?.event.id, "event-1")
    }

    func testSingleEventMatchesWithoutWindowTitleOverlap() {
        let calendarEvent = event(title: "Quarterly roadmap review", startsIn: -5)

        let match = CalendarEventMatcher.bestMatch(
            for: meeting("Unrelated window title"),
            in: [calendarEvent]
        )

        XCTAssertEqual(match?.event.title, "Quarterly roadmap review")
    }

    // MARK: - Multiple candidates

    func testEventWithInvitedAttendeesWinsOverEventWithoutThem() {
        let empty = event(id: "empty", title: "Focus time")
        let invited = event(id: "invited", title: "Roadmap review", attendees: [attendee()])

        let match = CalendarEventMatcher.bestMatch(for: meeting(), in: [empty, invited])

        XCTAssertEqual(match?.event.id, "invited")
    }

    func testCurrentUserDoesNotCountAsAnInvitedAttendee() {
        let selfOnly = event(id: "self-only", title: "Focus time", attendees: [currentUser(.accepted)])
        let invited = event(id: "invited", title: "Roadmap review", attendees: [attendee()])

        let match = CalendarEventMatcher.bestMatch(for: meeting(), in: [selfOnly, invited])

        XCTAssertEqual(match?.event.id, "invited")
    }

    func testAcceptedEventWinsWhenSeveralHaveInvitedAttendees() {
        let unanswered = event(
            id: "unanswered",
            title: "Planning",
            attendees: [currentUser(.needsAction), attendee("olga@example.com")]
        )
        let accepted = event(
            id: "accepted",
            title: "Roadmap review",
            attendees: [currentUser(.accepted), attendee()]
        )

        let match = CalendarEventMatcher.bestMatch(for: meeting(), in: [unanswered, accepted])

        XCTAssertEqual(match?.event.id, "accepted")
    }

    func testSeveralEventsWithAttendeesAndNoAcceptedEventAreAmbiguous() {
        let first = event(id: "first", title: "Planning", attendees: [attendee("olga@example.com")])
        let second = event(id: "second", title: "Review", attendees: [attendee()])

        XCTAssertNil(CalendarEventMatcher.bestMatch(for: meeting(), in: [first, second]))
    }

    func testSeveralAcceptedEventsWithAttendeesAreAmbiguous() {
        let first = event(
            id: "first",
            title: "Planning",
            attendees: [currentUser(.accepted), attendee("olga@example.com")]
        )
        let second = event(
            id: "second",
            title: "Review",
            attendees: [currentUser(.accepted), attendee()]
        )

        XCTAssertNil(CalendarEventMatcher.bestMatch(for: meeting(), in: [first, second]))
    }

    func testSeveralEventsWithoutInvitedAttendeesAreAmbiguous() {
        let first = event(id: "first", title: "Roadmap review")
        let second = event(id: "second", title: "Focus time")

        XCTAssertNil(CalendarEventMatcher.bestMatch(for: meeting("Roadmap review"), in: [first, second]))
    }

    func testNoEventsProduceNoMatch() {
        XCTAssertNil(CalendarEventMatcher.bestMatch(for: meeting(), in: []))
    }

    // MARK: - Deduplication

    func testSameEventInTwoAccountsKeepsTheAcceptedCopy() {
        let declined = event(
            id: "personal",
            iCalUID: "shared-uid",
            title: "Roadmap review",
            attendees: [CalendarAttendee(email: "me@personal.com", responseStatus: .declined, isSelf: true)],
            calendarTitle: "me@personal.com"
        )
        let accepted = event(
            id: "work",
            iCalUID: "shared-uid",
            title: "Roadmap review",
            attendees: [currentUser(.accepted)]
        )

        let deduplicated = CalendarEventMatcher.deduplicate([declined, accepted])

        XCTAssertEqual(deduplicated.count, 1)
        XCTAssertEqual(deduplicated.first?.id, "work")
    }

    func testDifferentEventsAreNotDeduplicated() {
        let first = event(id: "first", title: "Roadmap review")
        let second = event(id: "second", title: "Retrospective", startsIn: 60)

        XCTAssertEqual(CalendarEventMatcher.deduplicate([first, second]).count, 2)
    }

    func testTwoOccurrencesOfTheSameSeriesAreBothKept() {
        let standup = event(id: "first", iCalUID: "series", title: "Standup", lasts: 15)
        let nextStandup = event(id: "second", iCalUID: "series", title: "Standup", startsIn: 60, lasts: 15)

        XCTAssertEqual(CalendarEventMatcher.deduplicate([standup, nextStandup]).count, 2)
    }
}
