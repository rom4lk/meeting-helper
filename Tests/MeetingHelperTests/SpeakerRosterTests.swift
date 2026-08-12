import XCTest
@testable import MeetingHelper

final class SpeakerRosterTests: XCTestCase {

    private let ivan = CalendarAttendee(email: "ivan@example.com", displayName: "Ivan Petrov")
    private let olga = CalendarAttendee(email: "olga@example.com", displayName: "Olga Sokolova")

    // MARK: - Naming from the invitation

    func testTheOnlyInvitedPersonNamesTheFirstVoice() {
        var roster = SpeakerRoster(attendees: [ivan])

        let speaker = roster.note("1")

        XCTAssertEqual(speaker.name, "Ivan Petrov")
        XCTAssertEqual(speaker.attendeeEmail, "ivan@example.com")
    }

    /// The whole reason the one-on-one shortcut is limited to the first voice: a call with one
    /// person on the invitation can still have somebody else join it, and that voice must not be
    /// handed a name nothing supports.
    func testAnUnplannedSecondVoiceIsNotGivenTheInvitedPersonsName() {
        var roster = SpeakerRoster(attendees: [ivan])
        roster.note("1")

        let stranger = roster.note("2")

        XCTAssertNil(stranger.name)
        XCTAssertNil(stranger.attendeeEmail)
        XCTAssertEqual(stranger.displayName, "Speaker 2")
        XCTAssertEqual(roster.speaker(id: "1")?.name, "Ivan Petrov")
    }

    func testAGroupMeetingNamesNobodyOnItsOwn() {
        var roster = SpeakerRoster(attendees: [ivan, olga])

        XCTAssertNil(roster.note("1").name)
        XCTAssertEqual(roster.note("1").displayName, "Speaker 1")
    }

    func testAMeetingWithoutAnInvitationNamesNobody() {
        var roster = SpeakerRoster()

        XCTAssertNil(roster.note("1").name)
    }

    func testARecognizedVoiceIsNamedWhicheverOrderItIsHeardIn() {
        var roster = SpeakerRoster(attendees: [ivan, olga])
        roster.note("1")

        let recognized = roster.note("known-1", recognizedAs: "OLGA@example.com")

        XCTAssertEqual(recognized.name, "Olga Sokolova")
        XCTAssertEqual(recognized.attendeeEmail, "olga@example.com")
    }

    func testAProfileForSomebodyNotOnTheInvitationNamesNothing() {
        var roster = SpeakerRoster(attendees: [ivan, olga])

        XCTAssertNil(roster.note("known-1", recognizedAs: "stranger@example.com").name)
    }

    func testNotingTheSameVoiceTwiceKeepsTheFirstAnswer() {
        var roster = SpeakerRoster(attendees: [ivan, olga])
        roster.note("1")
        roster.note("2")

        XCTAssertEqual(roster.note("1").ordinal, 1)
        XCTAssertEqual(roster.speakers.count, 2)
    }

    // MARK: - Correcting a name

    /// The repair path for the case above. When the uninvited person spoke first and took the
    /// name, pointing the invited person at the voice that really is theirs has to leave the other
    /// one unnamed rather than produce two people with the same name.
    func testNamingAVoiceTakesThatNameOffTheOneThatHeldIt() {
        var roster = SpeakerRoster(attendees: [ivan])
        roster.note("1")
        roster.note("2")

        roster.assign(ivan, to: "2")

        XCTAssertEqual(roster.speaker(id: "2")?.name, "Ivan Petrov")
        XCTAssertNil(roster.speaker(id: "1")?.name)
        XCTAssertEqual(roster.speaker(id: "1")?.displayName, "Speaker 1")
    }

    func testClearingANameLeavesTheVoiceNumbered() {
        var roster = SpeakerRoster(attendees: [ivan])
        roster.note("1")

        roster.assign(nil, to: "1")

        XCTAssertNil(roster.speaker(id: "1")?.name)
        XCTAssertNil(roster.speaker(id: "1")?.attendeeEmail)
    }

    func testAssigningToAVoiceThatWasNeverHeardChangesNothing() {
        var roster = SpeakerRoster(attendees: [ivan])
        roster.note("1")

        roster.assign(olga, to: "nope")

        XCTAssertEqual(roster.speakers.count, 1)
        XCTAssertEqual(roster.speaker(id: "1")?.name, "Ivan Petrov")
    }

    func testRosterSurvivesRoundTrippingThroughAMeeting() throws {
        var roster = SpeakerRoster(attendees: [ivan])
        roster.note("1")
        roster.note("2")

        let encoded = try JSONEncoder().encode(roster.speakers)
        let decoded = try JSONDecoder().decode([MeetingSpeaker].self, from: encoded)

        XCTAssertEqual(decoded, roster.speakers)
        XCTAssertEqual(decoded[1].displayName, "Speaker 2")
    }
}
