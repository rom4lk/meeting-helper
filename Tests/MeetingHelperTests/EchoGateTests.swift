import XCTest
@testable import MeetingHelper

final class EchoGateTests: XCTestCase {
    private let length = EchoGate.minimumSamples * 2

    /// Deterministic broadband noise, computed from the absolute sample index so that a shifted
    /// window is the same signal seen from a different point. Speech-like in the only way that
    /// matters here: it never repeats, so nothing lines up with it by accident.
    private func voice(seed: Int, count: Int, from: Int = 0) -> [Float] {
        (from..<(from + count)).map { index in
            var bits = UInt64(bitPattern: Int64(index)) &* 0x9E37_79B9_7F4A_7C15
            bits = bits &+ UInt64(bitPattern: Int64(seed)) &* 0xBF58_476D_1CE4_E5B9
            bits ^= bits >> 30
            bits = bits &* 0xBF58_476D_1CE4_E5B9
            bits ^= bits >> 27
            return Float(Int32(truncatingIfNeeded: bits)) / Float(Int32.max)
        }
    }

    /// What the microphone hears: the playback, attenuated by the room.
    private func microphone(seed: Int = 0, count: Int? = nil) -> [Float] {
        voice(seed: seed, count: count ?? length).map { $0 * 0.05 }
    }

    /// The reference window the gate is handed, carrying the alignment slack at both ends. The
    /// content lines up with the microphone `offset` samples away from the estimated delay.
    private func reference(
        seed: Int = 0,
        count: Int? = nil,
        misalignedBy offset: Int = 0
    ) -> [Float] {
        let span = EchoGate.alignmentSpan
        return voice(seed: seed, count: (count ?? length) + 2 * span, from: offset - span)
    }

    func testAttenuatedCopyOfThePlaybackIsEcho() {
        XCTAssertTrue(EchoGate.isEcho(microphone: microphone(), reference: reference()))
    }

    /// The estimated delay is never exact, so the gate refines it within the alignment slack.
    func testEchoIsFoundAcrossTheAlignmentSlack() {
        for offset in stride(from: -EchoGate.alignmentSpan, through: EchoGate.alignmentSpan, by: 32) {
            XCTAssertTrue(
                EchoGate.isEcho(
                    microphone: microphone(),
                    reference: reference(misalignedBy: offset)
                ),
                "Echo misaligned by \(offset) samples was not recognized"
            )
        }
    }

    func testEchoBeyondTheAlignmentSlackIsKept() {
        XCTAssertFalse(
            EchoGate.isEcho(
                microphone: microphone(),
                reference: reference(misalignedBy: EchoGate.alignmentSpan * 4)
            )
        )
    }

    /// Level is not the test any more: speech stays speech however far below the playback it sits.
    func testQuietSpeechOverPlaybackIsKept() {
        let ownVoice = voice(seed: 40, count: length).map { $0 * 0.01 }

        XCTAssertLessThan(
            EchoGate.correlation(ownVoice, voice(seed: 0, count: length)),
            EchoGate.minimumCorrelation
        )
        XCTAssertFalse(EchoGate.isEcho(microphone: ownVoice, reference: reference()))
    }

    /// Playback that is loud in the microphone is still playback — the old level test would have
    /// kept this one.
    func testLoudEchoIsStillEcho() {
        let loud = voice(seed: 0, count: length).map { $0 * 0.9 }

        XCTAssertTrue(EchoGate.isEcho(microphone: loud, reference: reference()))
    }

    func testPolarityInvertedEchoIsFound() {
        let inverted = voice(seed: 0, count: length).map { $0 * -0.05 }

        XCTAssertTrue(EchoGate.isEcho(microphone: inverted, reference: reference()))
    }

    func testSilentReferenceIsKept() {
        let silence = [Float](repeating: 0, count: length + 2 * EchoGate.alignmentSpan)

        XCTAssertFalse(EchoGate.isEcho(microphone: microphone(), reference: silence))
    }

    func testTooShortAWindowIsKept() {
        let short = EchoGate.minimumSamples - 1

        XCTAssertFalse(
            EchoGate.isEcho(
                microphone: microphone(count: short),
                reference: reference(count: short)
            )
        )
    }

    func testReferenceOfTheWrongLengthIsKept() {
        XCTAssertFalse(
            EchoGate.isEcho(microphone: microphone(), reference: voice(seed: 0, count: length))
        )
    }
}
