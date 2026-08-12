import XCTest
@testable import MeetingHelper

final class EchoReferenceTests: XCTestCase {
    private func ramp(from first: Int, count: Int) -> [Float] {
        (0..<count).map { Float(first + $0) }
    }

    func testWindowFollowsTheTimeline() {
        let reference = EchoReference()
        reference.append(ramp(from: 0, count: 16_000))

        XCTAssertEqual(reference.coveredUntil, 1, accuracy: 0.001)

        let window = reference.window(startingAt: 0.5, sampleCount: 3)
        XCTAssertEqual(window, [8_000, 8_001, 8_002])
    }

    func testSamplesArriveInAnyChunkSize() {
        let reference = EchoReference()
        let samples = ramp(from: 0, count: 4_800)

        for chunk in stride(from: 0, to: samples.count, by: 700) {
            reference.append(Array(samples[chunk..<min(chunk + 700, samples.count)]))
        }

        XCTAssertEqual(reference.coveredUntil, 0.3, accuracy: 0.001)
        XCTAssertEqual(reference.window(startingAt: 0.1, sampleCount: 2), [1_600, 1_601])
    }

    func testWindowBeyondCoverageIsUnavailable() {
        let reference = EchoReference()
        reference.append(ramp(from: 0, count: 1_600))

        XCTAssertTrue(reference.hasData)
        XCTAssertNil(reference.window(startingAt: 0.05, sampleCount: 1_600))
        XCTAssertNil(reference.window(startingAt: -0.1, sampleCount: 10))
    }

    func testNoDataBeforeAnythingIsAppended() {
        let reference = EchoReference()

        XCTAssertEqual(reference.coveredUntil, 0)
        XCTAssertFalse(reference.hasData)
        XCTAssertNil(reference.window(startingAt: 0, sampleCount: 10))
    }

    /// The ring keeps the most recent minute and hands back the right samples once it has wrapped.
    func testSamplesOlderThanTheBufferAreUnavailable() {
        let reference = EchoReference()
        for second in 0..<70 {
            reference.append(ramp(from: second * 16_000, count: 16_000))
        }

        XCTAssertEqual(reference.coveredUntil, 70, accuracy: 0.001)
        XCTAssertNil(reference.window(startingAt: 0, sampleCount: 10))
        XCTAssertEqual(reference.window(startingAt: 69, sampleCount: 2), [1_104_000, 1_104_001])
        XCTAssertEqual(reference.window(startingAt: 10, sampleCount: 2), [160_000, 160_001])
    }
}
