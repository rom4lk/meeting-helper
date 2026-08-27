import Foundation

/// The part of an utterance that is actually speech, and how much of it there is.
///
/// The VAD hands on a padded utterance: 300 ms of pre-roll before the first spoken frame, and the
/// 800 ms of silence it takes to close one. Recognition wants that run-up, but the speaker model
/// must not be given it. The padding alone puts every utterance over the floor below which the
/// diarizer only matches an already-heard voice and refuses to invent one, so a half-second "mhm"
/// gets to found a speaker of its own; and the silence dilutes the embedding, which pushes even a
/// familiar voice past the match threshold. Together they split one person across a handful of ids.
struct VoicedSpan: Equatable {
    /// Below this a frame is silence. The absolute floor the VAD opens an utterance against — its
    /// own threshold rises with the room but never falls under this.
    static let silenceThreshold: Float = 0.006

    /// Samples from the start of the utterance: the first spoken frame to the end of the last.
    /// Pauses inside are kept — cutting them would splice the waveform the embedding reads.
    let range: Range<Int>
    /// How much of the span is speech, with the pauses inside it left out. This is the number the
    /// diarizer weighs against its minimum, so it has to mean what it says.
    let duration: TimeInterval

    var isEmpty: Bool { range.isEmpty }

    /// Measures an utterance frame by frame, in the same 100 ms unit the VAD works in.
    static func of(_ samples: [Float]) -> VoicedSpan {
        let frame = SourceTranscriber.frameSize
        var first: Int?
        var last = 0
        var voiced = 0

        for start in stride(from: 0, to: samples.count, by: frame) {
            let end = min(start + frame, samples.count)
            guard rootMeanSquare(samples[start..<end]) > silenceThreshold else { continue }
            if first == nil { first = start }
            last = end
            voiced += end - start
        }

        guard let first else { return VoicedSpan(range: 0..<0, duration: 0) }
        return VoicedSpan(
            range: first..<last,
            duration: Double(voiced) / AudioTrackWriter.sampleRate
        )
    }
}
