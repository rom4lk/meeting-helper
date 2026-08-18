import XCTest
@testable import MeetingHelper

final class MeetingKindDisplayNameTests: XCTestCase {
    func testGenericMicrophoneMeetingNamesTheApplication() {
        let meeting = Meeting(title: "Telegram call", kind: .microphoneApp, audioSourceName: "Telegram")

        XCTAssertEqual(meeting.kindDisplayName, "Microphone app: Telegram")
    }

    func testMeetingWithoutAnAudioSourceNameShowsTheKindAlone() {
        let meeting = Meeting(title: "Standup", kind: .zoom)

        XCTAssertEqual(meeting.kindDisplayName, "Zoom")
    }

    func testMergedMeetingKeepsTheJoinedKinds() {
        let meeting = Meeting(
            title: "Merged",
            kind: .microphoneApp,
            audioSourceName: "Telegram",
            mergedSegments: [
                segment(kind: .microphoneApp),
                segment(kind: .manual)
            ]
        )

        XCTAssertEqual(meeting.kindDisplayName, "Microphone app + Manual")
    }

    private func segment(kind: DetectedMeeting.Kind) -> MergedMeetingSegment {
        MergedMeetingSegment(
            sourceID: UUID(),
            title: "Part",
            kind: kind,
            startedAt: Date(),
            offset: 0,
            duration: 60
        )
    }
}
