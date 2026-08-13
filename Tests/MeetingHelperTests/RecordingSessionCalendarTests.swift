import XCTest
@testable import MeetingHelper

@MainActor
final class RecordingSessionCalendarTests: XCTestCase {

    private func makeSession(title: String = "Meet — abc-defg-hij") -> RecordingSession {
        RecordingSession(
            detected: DetectedMeeting(
                kind: .googleMeet,
                title: title,
                audioPrefixes: [],
                detectedAt: Date()
            ),
            settings: AppSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            engine: TranscriptionEngine(),
            profileStore: SpeakerProfileStore(url: .temporaryProfileStore())
        )
    }

    private func match(title: String) -> CalendarEventMatcher.Match {
        CalendarEventMatcher.Match(
            event: CalendarEvent(
                id: "event-1",
                iCalUID: "event-1",
                calendarTitle: "me@work.com",
                title: title,
                start: Date(),
                end: Date().addingTimeInterval(3600),
                organizerEmail: nil,
                attendees: [CalendarAttendee(email: "ivan@example.com")]
            )
        )
    }

    func testAMatchRenamesTheRecording() {
        let session = makeSession()

        session.apply(match(title: "Quarterly roadmap review"))

        XCTAssertEqual(session.title, "Quarterly roadmap review")
        XCTAssertEqual(session.calendar?.title, "Quarterly roadmap review")
    }

    func testAnEmptyCalendarTitleKeepsTheWindowTitleAndAttendees() {
        let session = makeSession(title: "Zoom topic")

        session.apply(match(title: "  "))

        XCTAssertEqual(session.title, "Zoom topic")
        XCTAssertEqual(session.calendar?.attendees.first?.email, "ivan@example.com")
    }

}
