import Accelerate
import Foundation
import os

/// Measures how long speaker playback takes to reach the microphone again.
///
/// The delay belongs to the audio route — output buffering, the air, input buffering — not to the
/// moment, so it is worth measuring once and reusing. Reusing it is also what makes the gate cheap:
/// with the delay known, deciding on an utterance is one dot product instead of a search.
///
/// A single window is not enough to find it. Speech correlates with itself, so the peak of one
/// window's correlation curve lands anywhere between 21 and 42 ms on measured recordings. Summing
/// the curves first and taking the peak afterwards averages that noise away and leaves the one
/// alignment every window agrees on.
///
/// Observations keep arriving after the estimate is trusted, so switching output to a Bluetooth
/// headset mid-meeting moves the estimate instead of stranding it.
final class EchoDelayEstimator: Sendable {
    /// 0…200 ms of route latency to consider. Measured recordings sit near 22 ms; the headroom is
    /// for Bluetooth output.
    static let maximumDelay = 3_200
    /// Samples per observation, 500 ms. Long enough for the curve to have a peak, short enough
    /// that clock drift between the two capture devices cannot smear it.
    static let windowSamples = 8_000
    /// How much the reference has to extend before the window so every delay can be tried.
    static var referenceSamples: Int { windowSamples + maximumDelay }
    /// Observations to accumulate before the peak is trusted.
    static let minimumObservations = 8
    /// Only windows that already look like leakage on their own are worth accumulating. Windows of
    /// plain speech have no peak to contribute and only blur the sum.
    static let minimumCandidatePeak: Float = 0.25
    /// Applied to the accumulated curve per observation, so the estimate follows the route rather
    /// than averaging over everything since the recording started. Roughly a 50-observation memory.
    static let decay = 0.98
    /// Decibels. A quieter reference has nothing in it to have leaked.
    static let minimumReferenceLevel: Float = -50

    private struct Storage {
        var curve = [Double](repeating: 0, count: EchoDelayEstimator.maximumDelay + 1)
        var observations = 0
    }

    private let storage = OSAllocatedUnfairLock(initialState: Storage())

    /// The route's delay in samples, or `nil` while too few observations have accumulated. Callers
    /// treat `nil` as "cannot judge" and let the utterance through.
    var delay: Int? {
        storage.withLock { state in
            guard state.observations >= Self.minimumObservations else { return nil }
            guard let peak = state.curve.indices.max(by: { state.curve[$0] < state.curve[$1] })
            else { return nil }
            return Self.maximumDelay - peak
        }
    }

    /// Adds one window to the accumulated curve. `reference` covers the same span extended by
    /// `maximumDelay` at the front, so every delay can be tried.
    func observe(microphone: [Float], reference: [Float]) {
        guard microphone.count == Self.windowSamples,
              reference.count == Self.referenceSamples,
              decibels(rootMeanSquare(reference)) >= Self.minimumReferenceLevel
        else { return }

        let curve = Self.correlationCurve(microphone: microphone, reference: reference)
        guard let peak = curve.max(), peak >= Self.minimumCandidatePeak else { return }

        storage.withLock { state in
            for index in curve.indices {
                state.curve[index] = state.curve[index] * Self.decay + Double(curve[index])
            }
            state.observations += 1
        }
    }

    /// Normalised cross-correlation at every delay in 0…`maximumDelay`, indexed the way
    /// `reference` is laid out: index 0 is the largest delay, the last index is no delay at all.
    static func correlationCurve(microphone: [Float], reference: [Float]) -> [Float] {
        let count = maximumDelay + 1
        var products = [Float](repeating: 0, count: count)
        // vDSP_conv slides `microphone` along `reference` and takes the dot product at each
        // position, which is exactly the correlation numerator at each delay.
        vDSP_conv(
            reference, 1,
            microphone, 1,
            &products, 1,
            vDSP_Length(count), vDSP_Length(windowSamples)
        )

        // Running energy of every reference window, so each product can be normalised by the
        // window it came from rather than by the whole span.
        var energy = [Float](repeating: 0, count: count)
        var running: Float = 0
        for index in 0..<windowSamples {
            running += reference[index] * reference[index]
        }
        energy[0] = running
        for index in 1..<count {
            running += reference[index + windowSamples - 1] * reference[index + windowSamples - 1]
            running -= reference[index - 1] * reference[index - 1]
            energy[index] = max(running, 0)
        }

        var microphoneEnergy: Float = 0
        for sample in microphone {
            microphoneEnergy += sample * sample
        }
        let microphoneNorm = microphoneEnergy.squareRoot()
        guard microphoneNorm > 0 else { return [Float](repeating: 0, count: count) }

        for index in 0..<count {
            let norm = microphoneNorm * energy[index].squareRoot()
            products[index] = norm > 0 ? abs(products[index] / norm) : 0
        }
        return products
    }
}
