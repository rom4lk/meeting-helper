import XCTest
@testable import MeetingHelper

final class DetectedMeetingTests: XCTestCase {
    func testManualRecordingCapturesAllSystemAudio() {
        let meeting = detectedMeeting(kind: .manual, audioPrefixes: [])

        XCTAssertTrue(meeting.capturesAllSystemAudio)
        XCTAssertEqual(meeting.audioSourceDisplayName, "All system audio")
    }

    func testAutomaticRecordingKeepsApplicationScopedAudio() {
        let zoom = detectedMeeting(kind: .zoom, audioPrefixes: MeetingApp.zoom.audioBundleIDPrefixes)
        let chrome = detectedMeeting(kind: .googleMeet, audioPrefixes: MeetingApp.chrome.audioBundleIDPrefixes)

        XCTAssertFalse(zoom.capturesAllSystemAudio)
        XCTAssertEqual(zoom.audioSourceDisplayName, "Zoom")
        XCTAssertFalse(chrome.capturesAllSystemAudio)
        XCTAssertEqual(chrome.audioSourceDisplayName, "Google Chrome")
    }

    func testMicrophoneAppUsesItsResolvedApplicationName() {
        let meeting = DetectedMeeting(
            kind: .microphoneApp,
            title: "Calls call",
            audioPrefixes: ["com.example.calls"],
            detectedAt: Date(),
            triggerBundleID: "com.example.calls",
            audioSourceName: "Calls"
        )

        XCTAssertFalse(meeting.capturesAllSystemAudio)
        XCTAssertEqual(meeting.audioSourceDisplayName, "Calls")
    }

    func testMicrophoneAppKindRoundTripsThroughMetadataEncoding() throws {
        let data = try JSONEncoder().encode(DetectedMeeting.Kind.microphoneApp)

        XCTAssertEqual(
            try JSONDecoder().decode(DetectedMeeting.Kind.self, from: data),
            .microphoneApp
        )
    }

    private func detectedMeeting(
        kind: DetectedMeeting.Kind,
        audioPrefixes: [String]
    ) -> DetectedMeeting {
        DetectedMeeting(
            kind: kind,
            title: "Test meeting",
            audioPrefixes: audioPrefixes,
            detectedAt: Date()
        )
    }
}
