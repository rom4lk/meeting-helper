import Foundation

/// Root mean square of a block of samples.
///
/// The one loudness measure the whole pipeline shares: capture levels, the VAD threshold and the
/// echo gate's envelopes are all RMS, so they stay comparable with each other.
func rootMeanSquare<Samples: Collection>(_ samples: Samples) -> Float where Samples.Element == Float {
    guard !samples.isEmpty else { return 0 }
    var sum: Float = 0
    for sample in samples { sum += sample * sample }
    return (sum / Float(samples.count)).squareRoot()
}

/// An amplitude as decibels relative to full scale, floored at −120 dB so silence stays finite.
func decibels(_ value: Float) -> Float {
    20 * log10(max(value, 1e-6))
}
