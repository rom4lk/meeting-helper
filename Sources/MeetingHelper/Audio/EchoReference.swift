import Foundation
import os

/// The recent samples of the system audio track, kept on the shared recording timeline.
///
/// Speaker playback leaks into the microphone whenever the meeting is not listened to through
/// headphones, and both tracks then transcribe the same speech. `EchoGate` tells that leakage
/// apart from real speech by correlating the microphone against these samples, so what is stored
/// here is the reference signal — the audio as the app played it, before the room.
///
/// The waveform is kept rather than its loudness envelope because that is where the signal is:
/// the acoustic path delays playback by tens of milliseconds, which an envelope sampled every
/// 100 ms cannot resolve, and averaging away the fine structure leaves nothing that identifies
/// one voice as a copy of another.
///
/// Written from the system track's writer callback and read from the microphone transcriber's
/// queue, hence the lock.
final class EchoReference: Sendable {
    /// 60 s at `AudioTrackWriter.sampleRate` — long enough to cover any utterance the VAD can
    /// produce, with room to spare. 3.8 MB.
    static let capacity = 60 * Int(AudioTrackWriter.sampleRate)

    private struct Storage {
        var samples = [Float](repeating: 0, count: EchoReference.capacity)
        var writeIndex = 0
        var samplesWritten = 0
    }

    private let storage = OSAllocatedUnfairLock(initialState: Storage())

    /// How much of the timeline the reference covers, in seconds from the start of the recording.
    /// The writer pads gaps with silence, so this advances even while the meeting is quiet.
    var coveredUntil: TimeInterval {
        storage.withLock { Double($0.samplesWritten) / AudioTrackWriter.sampleRate }
    }

    /// Whether any system audio has been seen at all. False when the tap never started, which is
    /// the caller's signal that waiting for coverage is pointless.
    var hasData: Bool {
        storage.withLock { $0.samplesWritten > 0 }
    }

    func append(_ samples: [Float]) {
        storage.withLock { state in
            for sample in samples {
                state.samples[state.writeIndex] = sample
                state.writeIndex = state.writeIndex + 1 == Self.capacity ? 0 : state.writeIndex + 1
            }
            state.samplesWritten += samples.count
        }
    }

    /// The samples covering `[start, start + count)`, or `nil` when that span has already been
    /// overwritten in the ring or has not been written yet.
    func window(startingAt start: TimeInterval, sampleCount count: Int) -> [Float]? {
        guard start >= 0, count > 0 else { return nil }
        let first = Int((start * AudioTrackWriter.sampleRate).rounded())

        return storage.withLock { state in
            guard first + count <= state.samplesWritten,
                  state.samplesWritten - first <= Self.capacity
            else { return nil }

            var window = [Float](repeating: 0, count: count)
            var index = (state.writeIndex - (state.samplesWritten - first) + Self.capacity) % Self.capacity
            for position in 0..<count {
                window[position] = state.samples[index]
                index = index + 1 == Self.capacity ? 0 : index + 1
            }
            return window
        }
    }
}
