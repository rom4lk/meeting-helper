import Foundation

/// What the gate concluded about one microphone utterance.
enum EchoVerdict {
    /// Speaker leakage: at the route's delay it is a copy of what the app was playing.
    case echo
    /// Compared against the system track and kept.
    case speech
    /// Nothing usable to compare against, so the utterance is kept without a check.
    case undecided
}

/// Decides whether a microphone signal is speaker playback leaking back in rather than speech.
///
/// Echo is the playback attenuated and coloured by the room, so shifted by the route's delay it
/// still lines up with the reference sample for sample. Two people talking at once do not: their
/// waveforms are unrelated whatever their levels. That makes the normalised cross-correlation the
/// whole test, and a normalised measure is what carries between machines — speaker volume,
/// microphone gain, distance and room all cancel out of it, and those are exactly what an absolute
/// level threshold cannot survive.
///
/// Thresholds are measured, not guessed — see `knowledge/echo-gate-calibration.md`.
enum EchoGate {
    /// Measured over whole utterances: echo 0.25…0.51, speech 0.00…0.15.
    static let minimumCorrelation: Float = 0.25
    /// Samples of slack around the estimated delay, ±6 ms. `EchoDelayEstimator` finds the route's
    /// delay to within a few milliseconds, and the path itself moves a little between utterances;
    /// searching the neighbourhood recovers what a single fixed alignment misses.
    static let alignmentSpan = 96
    /// Alignments are tried every 1 ms. Finer steps cost time and find nothing new.
    static let alignmentStep = 16
    /// Decibels. Below this the reference is silence and there is nothing to have leaked.
    static let minimumReferenceLevel: Float = -50
    /// 300 ms. Shorter windows do not carry enough signal for a correlation to mean anything.
    static let minimumSamples = 4_800

    /// `microphone` is the utterance; `reference` covers the same stretch of the meeting, already
    /// shifted back by the route's delay and extended by `alignmentSpan` at both ends so the
    /// alignment can be refined.
    static func isEcho(microphone: [Float], reference: [Float]) -> Bool {
        guard microphone.count >= minimumSamples,
              reference.count == microphone.count + 2 * alignmentSpan
        else { return false }

        for start in stride(from: 0, through: 2 * alignmentSpan, by: alignmentStep) {
            let candidate = Array(reference[start..<(start + microphone.count)])
            guard decibels(rootMeanSquare(candidate)) >= minimumReferenceLevel else { continue }

            if correlation(microphone, candidate) >= minimumCorrelation { return true }
        }

        return false
    }

    /// How much of one waveform is a scaled copy of the other, regardless of level. Taken as a
    /// magnitude because some output paths invert polarity, which says nothing about the source.
    static func correlation(_ lhs: [Float], _ rhs: [Float]) -> Float {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }

        let count = Double(lhs.count)
        let leftMean = lhs.reduce(0) { $0 + Double($1) } / count
        let rightMean = rhs.reduce(0) { $0 + Double($1) } / count

        var covariance = 0.0
        var leftVariance = 0.0
        var rightVariance = 0.0
        for index in lhs.indices {
            let left = Double(lhs[index]) - leftMean
            let right = Double(rhs[index]) - rightMean
            covariance += left * right
            leftVariance += left * left
            rightVariance += right * right
        }

        guard leftVariance > 0, rightVariance > 0 else { return 0 }
        return Float(abs(covariance / (leftVariance * rightVariance).squareRoot()))
    }
}
