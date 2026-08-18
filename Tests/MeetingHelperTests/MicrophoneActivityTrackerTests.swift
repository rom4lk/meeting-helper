import XCTest
@testable import MeetingHelper

final class MicrophoneActivityTrackerTests: XCTestCase {
    /// An application holding the microphone without playing anything, which is what a microphone
    /// filter looks like. Playing applications are spelled out with `playing(_:)`.
    private func silent(_ bundleID: String) -> MicrophoneActivityTracker.Candidate {
        MicrophoneActivityTracker.Candidate(bundleID: bundleID, playsOutput: false)
    }

    private func playing(_ bundleID: String) -> MicrophoneActivityTracker.Candidate {
        MicrophoneActivityTracker.Candidate(bundleID: bundleID, playsOutput: true)
    }

    func testBundleFamilyMatchingDoesNotAcceptSimilarPrefixes() {
        XCTAssertTrue(AudioProcessLookup.bundleID("com.example.calls", belongsTo: "com.example.calls"))
        XCTAssertTrue(AudioProcessLookup.bundleID("com.example.calls.helper", belongsTo: "com.example.calls"))
        XCTAssertFalse(AudioProcessLookup.bundleID("com.example.calls-other", belongsTo: "com.example.calls"))
    }

    func testStartsAfterTwoConsecutivePositiveChecks() {
        var tracker = MicrophoneActivityTracker()

        XCTAssertNil(tracker.update(candidates: [silent("com.example.calls")]))
        XCTAssertEqual(
            tracker.update(candidates: [silent("com.example.calls")]),
            .start("com.example.calls")
        )
    }

    func testInterruptedCandidateMustAccumulatePositiveChecksAgain() {
        var tracker = MicrophoneActivityTracker()

        XCTAssertNil(tracker.update(candidates: [silent("com.example.calls")]))
        XCTAssertNil(tracker.update(candidates: []))
        XCTAssertNil(tracker.update(candidates: [silent("com.example.calls")]))
        XCTAssertEqual(
            tracker.update(candidates: [silent("com.example.calls")]),
            .start("com.example.calls")
        )
    }

    func testStopsAfterThreeConsecutiveNegativeChecks() {
        var tracker = MicrophoneActivityTracker()
        _ = tracker.update(candidates: [silent("com.example.calls")])
        _ = tracker.update(candidates: [silent("com.example.calls")])

        XCTAssertNil(tracker.update(candidates: []))
        XCTAssertNil(tracker.update(candidates: []))
        XCTAssertEqual(tracker.update(candidates: []), .stop)
    }

    func testAContinuedStreamCancelsPendingStop() {
        var tracker = MicrophoneActivityTracker()
        _ = tracker.update(candidates: [silent("com.example.calls")])
        _ = tracker.update(candidates: [silent("com.example.calls")])

        XCTAssertNil(tracker.update(candidates: []))
        XCTAssertNil(tracker.update(candidates: [silent("com.example.calls")]))
        XCTAssertNil(tracker.update(candidates: []))
        XCTAssertNil(tracker.update(candidates: []))
        XCTAssertEqual(tracker.update(candidates: []), .stop)
    }

    func testTracksTheAppThatStartedTheRecording() {
        var tracker = MicrophoneActivityTracker()
        _ = tracker.update(candidates: [silent("com.example.calls")])
        _ = tracker.update(candidates: [silent("com.example.calls")])

        XCTAssertNil(tracker.update(candidates: [silent("com.example.other")]))
        XCTAssertNil(tracker.update(candidates: [silent("com.example.other")]))
        XCTAssertEqual(
            tracker.update(candidates: [silent("com.example.other")]),
            .stop
        )
    }

    /// A microphone filter such as Krisp holds the input for the whole call and plays nothing, and
    /// its bundle ID can sort before the conferencing app's. Attributing the call to it scopes the
    /// output tap to a process that never plays, which records an empty system track.
    func testPrefersThePlayingAppOverAnEarlierSortingMicrophoneFilter() {
        var tracker = MicrophoneActivityTracker()
        let candidates = [silent("ai.filter.mic"), playing("com.example.calls")]

        XCTAssertNil(tracker.update(candidates: candidates))
        XCTAssertEqual(tracker.update(candidates: candidates), .start("com.example.calls"))
    }

    func testBundleIDOrderStillBreaksTiesBetweenPlayingApps() {
        var tracker = MicrophoneActivityTracker()
        let candidates = [playing("com.example.other"), playing("com.example.calls")]

        XCTAssertNil(tracker.update(candidates: candidates))
        XCTAssertEqual(tracker.update(candidates: candidates), .start("com.example.calls"))
    }

    /// A conferencing app can open its output stream a moment after it takes the microphone, so the
    /// pending candidate has to be given up once a playing application shows up.
    func testAPlayingAppTakesOverAPendingSilentCandidate() {
        var tracker = MicrophoneActivityTracker()

        XCTAssertNil(tracker.update(candidates: [silent("ai.filter.mic")]))
        XCTAssertNil(tracker.update(candidates: [silent("ai.filter.mic"), playing("com.example.calls")]))
        XCTAssertEqual(
            tracker.update(candidates: [silent("ai.filter.mic"), playing("com.example.calls")]),
            .start("com.example.calls")
        )
    }

    /// The countdown must survive a second application joining the microphone while neither plays,
    /// which is the case the sticky candidate exists for.
    func testASecondSilentAppDoesNotRestartTheCountdown() {
        var tracker = MicrophoneActivityTracker()

        XCTAssertNil(tracker.update(candidates: [silent("com.example.calls")]))
        XCTAssertEqual(
            tracker.update(candidates: [silent("ai.filter.mic"), silent("com.example.calls")]),
            .start("com.example.calls")
        )
    }

    /// Once a recording runs, the tracked application keeps it alive whether or not it plays: an
    /// output stream that closes mid-call must not end the meeting.
    func testTheTrackedAppKeepsTheRecordingAliveWhenItStopsPlaying() {
        var tracker = MicrophoneActivityTracker()
        _ = tracker.update(candidates: [playing("com.example.calls")])
        _ = tracker.update(candidates: [playing("com.example.calls")])

        XCTAssertNil(tracker.update(candidates: [silent("com.example.calls")]))
        XCTAssertNil(tracker.update(candidates: [silent("com.example.calls")]))
        XCTAssertNil(tracker.update(candidates: [silent("com.example.calls")]))
    }
}
