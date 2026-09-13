import AVFoundation
import Foundation

/// Joins recorded tracks of several meetings into one continuous track.
///
/// The two tracks of a recording rarely have the same length — the system tap attaches once the
/// meeting app touches audio, and neither source stops on the same buffer. Each recording therefore
/// gets a span, and both of its tracks are padded with silence to fill it, so that the microphone
/// and the system track of the next recording start at exactly the same offset.
enum TrackConcatenation {
    struct Failure: LocalizedError {
        let reason: String

        var errorDescription: String? { reason }
    }

    private static let blockSize: AVAudioFrameCount = 16_000 // 1 second

    /// Length of a recorded track in frames. Zero for a file that is missing or unreadable, which
    /// is how a recording with no microphone or no system audio presents itself.
    static func frameCount(at url: URL) -> AVAudioFramePosition {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        return file.length
    }

    /// Writes every source in turn, padding each one with silence to its span.
    ///
    /// A `nil` source contributes silence for the whole of its span, which is what keeps the
    /// timeline intact when one of the recordings has no track of this kind at all.
    static func concatenate(
        sources: [URL?],
        spans: [AVAudioFramePosition],
        outputURL: URL
    ) throws {
        guard sources.count == spans.count else {
            throw Failure(reason: "Each source needs a span.")
        }
        let totalFrames = spans.reduce(0, +)
        guard totalFrames > 0 else {
            throw Failure(reason: "Nothing to join: the recordings hold no audio.")
        }

        let format = AudioTrackWriter.targetFormat
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: AudioTrackWriter.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = try AVAudioFile(
            forWriting: outputURL,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        for (source, span) in zip(sources, spans) {
            var written: AVAudioFramePosition = 0

            // A source that is named but cannot be opened is an error, not silence: padding over
            // it would produce a joined track that quietly lost one recording's audio.
            if let source {
                guard let input = try? AVAudioFile(forReading: source) else {
                    throw Failure(
                        reason: "\(source.lastPathComponent) is missing or cannot be read."
                    )
                }
                guard input.processingFormat.sampleRate == AudioTrackWriter.sampleRate else {
                    throw Failure(
                        reason: "\(source.lastPathComponent) is not a 16 kHz recording."
                    )
                }
                // A track longer than its span cannot happen while spans are the longer of the two
                // tracks, but truncating keeps the contract explicit either way.
                let readable = min(input.length, span)
                while written < readable {
                    let frames = AVAudioFrameCount(min(Int64(blockSize), readable - written))
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
                        throw Failure(reason: "Out of memory while joining the recordings.")
                    }
                    try input.read(into: buffer, frameCount: frames)
                    guard buffer.frameLength > 0 else { break }
                    try output.write(from: buffer)
                    written += AVAudioFramePosition(buffer.frameLength)
                }
            }

            try writeSilence(frames: span - written, to: output, format: format)
        }
    }

    private static func writeSilence(
        frames: AVAudioFramePosition,
        to output: AVAudioFile,
        format: AVAudioFormat
    ) throws {
        var remaining = frames
        while remaining > 0 {
            let count = AVAudioFrameCount(min(Int64(blockSize), remaining))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else {
                throw Failure(reason: "Out of memory while joining the recordings.")
            }
            buffer.frameLength = count
            guard let channel = buffer.floatChannelData?[0] else {
                throw Failure(reason: "Cannot write silence into the joined track.")
            }
            channel.update(repeating: 0, count: Int(count))
            try output.write(from: buffer)
            remaining -= AVAudioFramePosition(count)
        }
    }
}
