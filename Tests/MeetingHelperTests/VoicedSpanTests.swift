import XCTest
@testable import MeetingHelper

final class VoicedSpanTests: XCTestCase {
    private let frame = SourceTranscriber.frameSize

    private func frames(_ amplitudes: [Float]) -> [Float] {
        amplitudes.flatMap { [Float](repeating: $0, count: SourceTranscriber.frameSize) }
    }

    func testThePreRollAndTheClosingSilenceAreLeftOut() {
        let span = VoicedSpan.of(frames([0, 0, 0, 0.1, 0.1, 0, 0, 0, 0, 0, 0, 0, 0]))

        XCTAssertEqual(span.range, (3 * frame)..<(5 * frame))
        XCTAssertEqual(span.duration, 0.2, accuracy: 0.001)
    }

    func testAPauseInsideAPhraseStaysInTheSpanButNotInTheDuration() {
        let span = VoicedSpan.of(frames([0.1, 0, 0, 0.1]))

        XCTAssertEqual(span.range, 0..<(4 * frame))
        XCTAssertEqual(span.duration, 0.2, accuracy: 0.001)
    }

    func testAnUtteranceWithNothingAudibleInItHasNoSpan() {
        let span = VoicedSpan.of(frames([0, 0.001, 0]))

        XCTAssertTrue(span.isEmpty)
        XCTAssertEqual(span.duration, 0)
    }

    /// What the padding used to do on its own: 300 ms of pre-roll and 800 ms of closing silence put
    /// a single spoken frame over the second above which the diarizer invents a new voice.
    func testPaddingAloneNoLongerLiftsAnInterjectionOverASecond() {
        let padded = frames([0, 0, 0, 0.1, 0, 0, 0, 0, 0, 0, 0, 0])

        XCTAssertGreaterThan(Double(padded.count) / AudioTrackWriter.sampleRate, 1)
        XCTAssertLessThan(VoicedSpan.of(padded).duration, 1)
    }

    func testATrailingPartialFrameStillCounts() {
        let span = VoicedSpan.of(frames([0.1]) + [Float](repeating: 0.1, count: 800))

        XCTAssertEqual(span.range, 0..<(frame + 800))
        XCTAssertEqual(span.duration, 0.15, accuracy: 0.001)
    }
}
