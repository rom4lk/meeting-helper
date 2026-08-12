import XCTest
@testable import MeetingHelper

final class EchoDelayEstimatorTests: XCTestCase {
    /// Deterministic broadband noise. Speech-like in the only way that matters here: it never
    /// repeats, so nothing lines up with it by accident.
    private func voice(seed: Int, count: Int) -> [Float] {
        (0..<count).map { index in
            var bits = UInt64(bitPattern: Int64(index)) &* 0x9E37_79B9_7F4A_7C15
            bits = bits &+ UInt64(bitPattern: Int64(seed)) &* 0xBF58_476D_1CE4_E5B9
            bits ^= bits >> 30
            bits = bits &* 0xBF58_476D_1CE4_E5B9
            bits ^= bits >> 27
            return Float(Int32(truncatingIfNeeded: bits)) / Float(Int32.max)
        }
    }

    /// A reference window whose content reaches the microphone `delay` samples later.
    private func observation(delay: Int, seed: Int, attenuation: Float = 0.05)
        -> (microphone: [Float], reference: [Float]) {
        let reference = voice(seed: seed, count: EchoDelayEstimator.referenceSamples)
        let start = EchoDelayEstimator.maximumDelay - delay
        let microphone = Array(reference[start..<(start + EchoDelayEstimator.windowSamples)])
            .map { $0 * attenuation }
        return (microphone, reference)
    }

    func testDelayIsUnknownUntilEnoughObservations() {
        let estimator = EchoDelayEstimator()

        for index in 0..<(EchoDelayEstimator.minimumObservations - 1) {
            let sample = observation(delay: 360, seed: index)
            estimator.observe(microphone: sample.microphone, reference: sample.reference)
        }

        XCTAssertNil(estimator.delay)
    }

    func testDelayIsFoundOnceEnoughObservationsAccumulate() {
        let estimator = EchoDelayEstimator()

        for index in 0..<EchoDelayEstimator.minimumObservations {
            let sample = observation(delay: 360, seed: index)
            estimator.observe(microphone: sample.microphone, reference: sample.reference)
        }

        XCTAssertEqual(estimator.delay ?? -1, 360, accuracy: 16)
    }

    /// Windows of unrelated speech carry no peak and must not count towards the estimate.
    func testUncorrelatedWindowsAreNotObservations() {
        let estimator = EchoDelayEstimator()

        for index in 0..<(EchoDelayEstimator.minimumObservations * 2) {
            let reference = voice(seed: index, count: EchoDelayEstimator.referenceSamples)
            let microphone = voice(seed: index + 500, count: EchoDelayEstimator.windowSamples)
                .map { $0 * 0.05 }
            estimator.observe(microphone: microphone, reference: reference)
        }

        XCTAssertNil(estimator.delay)
    }

    func testSilentReferenceIsNotAnObservation() {
        let estimator = EchoDelayEstimator()
        let silence = [Float](repeating: 0, count: EchoDelayEstimator.referenceSamples)

        for _ in 0..<EchoDelayEstimator.minimumObservations {
            estimator.observe(
                microphone: [Float](repeating: 0, count: EchoDelayEstimator.windowSamples),
                reference: silence
            )
        }

        XCTAssertNil(estimator.delay)
    }

    func testWindowsOfTheWrongLengthAreIgnored() {
        let estimator = EchoDelayEstimator()

        for index in 0..<EchoDelayEstimator.minimumObservations {
            let sample = observation(delay: 360, seed: index)
            estimator.observe(
                microphone: Array(sample.microphone.dropLast()),
                reference: sample.reference
            )
        }

        XCTAssertNil(estimator.delay)
    }

    /// Switching output mid-meeting moves the delay; the decay has to let the estimate follow.
    func testEstimateFollowsARouteChange() {
        let estimator = EchoDelayEstimator()

        for index in 0..<EchoDelayEstimator.minimumObservations {
            let sample = observation(delay: 360, seed: index)
            estimator.observe(microphone: sample.microphone, reference: sample.reference)
        }
        XCTAssertEqual(estimator.delay ?? -1, 360, accuracy: 16)

        for index in 0..<200 {
            let sample = observation(delay: 2_400, seed: index)
            estimator.observe(microphone: sample.microphone, reference: sample.reference)
        }

        XCTAssertEqual(estimator.delay ?? -1, 2_400, accuracy: 16)
    }
}
