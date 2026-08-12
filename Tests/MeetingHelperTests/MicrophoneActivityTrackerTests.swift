import XCTest
@testable import MeetingHelper

final class MicrophoneActivityTrackerTests: XCTestCase {
    func testBundleFamilyMatchingDoesNotAcceptSimilarPrefixes() {
        XCTAssertTrue(AudioProcessLookup.bundleID("com.example.calls", belongsTo: "com.example.calls"))
        XCTAssertTrue(AudioProcessLookup.bundleID("com.example.calls.helper", belongsTo: "com.example.calls"))
        XCTAssertFalse(AudioProcessLookup.bundleID("com.example.calls-other", belongsTo: "com.example.calls"))
    }

    func testStartsAfterTwoConsecutivePositiveChecks() {
        var tracker = MicrophoneActivityTracker()

        XCTAssertNil(tracker.update(activeBundleIDs: Set(["com.example.calls"])))
        XCTAssertEqual(
            tracker.update(activeBundleIDs: Set(["com.example.calls"])),
            .start("com.example.calls")
        )
    }

    func testInterruptedCandidateMustAccumulatePositiveChecksAgain() {
        var tracker = MicrophoneActivityTracker()

        XCTAssertNil(tracker.update(activeBundleIDs: Set(["com.example.calls"])))
        XCTAssertNil(tracker.update(activeBundleIDs: []))
        XCTAssertNil(tracker.update(activeBundleIDs: Set(["com.example.calls"])))
        XCTAssertEqual(
            tracker.update(activeBundleIDs: Set(["com.example.calls"])),
            .start("com.example.calls")
        )
    }

    func testStopsAfterThreeConsecutiveNegativeChecks() {
        var tracker = MicrophoneActivityTracker()
        _ = tracker.update(activeBundleIDs: Set(["com.example.calls"]))
        _ = tracker.update(activeBundleIDs: Set(["com.example.calls"]))

        XCTAssertNil(tracker.update(activeBundleIDs: []))
        XCTAssertNil(tracker.update(activeBundleIDs: []))
        XCTAssertEqual(tracker.update(activeBundleIDs: []), .stop)
    }

    func testAContinuedStreamCancelsPendingStop() {
        var tracker = MicrophoneActivityTracker()
        _ = tracker.update(activeBundleIDs: Set(["com.example.calls"]))
        _ = tracker.update(activeBundleIDs: Set(["com.example.calls"]))

        XCTAssertNil(tracker.update(activeBundleIDs: []))
        XCTAssertNil(tracker.update(activeBundleIDs: Set(["com.example.calls"])))
        XCTAssertNil(tracker.update(activeBundleIDs: []))
        XCTAssertNil(tracker.update(activeBundleIDs: []))
        XCTAssertEqual(tracker.update(activeBundleIDs: []), .stop)
    }

    func testTracksTheAppThatStartedTheRecording() {
        var tracker = MicrophoneActivityTracker()
        _ = tracker.update(activeBundleIDs: Set(["com.example.calls"]))
        _ = tracker.update(activeBundleIDs: Set(["com.example.calls"]))

        XCTAssertNil(tracker.update(activeBundleIDs: Set(["com.example.other"])))
        XCTAssertNil(tracker.update(activeBundleIDs: Set(["com.example.other"])))
        XCTAssertEqual(
            tracker.update(activeBundleIDs: Set(["com.example.other"])),
            .stop
        )
    }
}
