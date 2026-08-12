# The echo gate: what it is and how its thresholds were measured

Rewritten 2026-08-10 after the gate was found to catch nothing on a real meeting. The measurements
behind the first version are kept in [what the envelope gate got wrong](#what-the-envelope-gate-got-wrong)
because they explain why the design changed. Read
[acoustic-echo-cancellation.md](acoustic-echo-cancellation.md) first: it records why the macOS
voice-processing unit was removed instead of fixed, and this gate is what replaced it.

## What the gate does

Nothing to the audio. `mic.wav` still contains the speaker leakage, and so does the mixdown. The
gate only decides whether a microphone utterance is worth sending to Whisper, and which part of it
([EchoGate.swift](../Sources/MeetingHelper/Audio/EchoGate.swift),
[EchoDelayEstimator.swift](../Sources/MeetingHelper/Audio/EchoDelayEstimator.swift),
[EchoReference.swift](../Sources/MeetingHelper/Audio/EchoReference.swift), called from
`SourceTranscriber.closeUtterance`).

It works on the waveform, not its envelope. Both tracks share a timeline —
[AudioTrackWriter](../Sources/MeetingHelper/Audio/AudioTrackWriter.swift) puts them there — so the
only unknown is the acoustic delay, and once that is known, echo is the reference sample for sample.

Three steps:

| | |
|---|---|
| **Measure the route** | Accumulate the normalised cross-correlation curve over lags 0…200 ms across windows that already look like leakage; the delay is the peak of the sum. |
| **Label each window** | Every 100 ms, take the 300 ms ending there: silent, leakage, or speech. |
| **Decide** | Drop the utterance when half its audible windows are leakage; otherwise trim leaked windows off its ends and keep the rest. |

Everything short of a confident verdict passes: no reference, a window older than the 60 s buffer,
coverage that has not arrived within 0.5 s, a delay not yet measured.
`TranscriptDeduplicator` is the second net, and dropping real speech is the worse failure.

The gate is on by default and can be turned off in Settings. Off means `RecordingSession` never
builds an `EchoReference`, so the system track is not buffered and no utterance waits for it —
the 0.5 s coverage wait is the gate's only latency cost.

## The thresholds

| | | why |
|---|---|---|
| Correlation, per window | ≥ 0.25 | Over whole utterances, echo measured 0.25…0.51 against speech 0.00…0.15. |
| Alignment search | ±6 ms around the estimate, 1 ms steps | The estimate lands within a few ms and the path itself moves between utterances. |
| Window | 300 ms, stepped 100 ms | Shorter carries too little signal; longer smears the boundary between leakage and the reply after it. |
| Leakage share to drop | ≥ 50 % of audible windows | Leaked phrases run above 60 %, speech over playback under 10 %. |
| Reference level | ≥ −50 dB | Below it the reference is silence and nothing can have leaked. |
| Delay search | 0…200 ms | Measured at 22 ms; the headroom is for Bluetooth output. |
| Observations before trusting the delay | 8, four per utterance | Two or three utterances, so the gate engages within the first minute. |
| Candidate peak to be counted | ≥ 0.25 | Windows of plain speech have no peak to contribute and only blur the sum. |
| Curve decay | 0.98 per observation | ~50-observation memory, so switching output mid-meeting moves the estimate. |

**Level is not part of the test.** That is the point of the rewrite: a normalised correlation
cancels speaker volume, microphone gain, distance and room, which is exactly what an absolute
level threshold cannot survive.

## What the numbers looked like

Labelled by hand against the transcript of `5D510227` — a 14-minute call over speakers, the
recording that exposed the old gate. Eight utterances are leakage, twenty-four are the user's own
speech, three are both glued together.

Whole-utterance correlation at the route's delay:

| | correlation |
|---|---|
| Leakage | 0.25 … 0.51 |
| Speech, system playing | 0.00 … 0.15 |
| Speech, system silent | reference below −50 dB, never compared |

Per-window at 300 ms, which is what the shipping rule counts:

| | share of windows over 0.25 |
|---|---|
| Leakage | 63 % |
| Speech | 4 % |

The delay estimate is the part that needed care. A single window's peak lands anywhere between
21 and 42 ms because speech correlates with itself; the summed curve peaks at 22.5 ms and stays
there. Feeding the estimate straight into the gate still costs recall — the running estimate
wanders ±5 ms over a meeting — which is why the gate searches ±6 ms around it rather than trusting
it exactly. With the search, every operating point from 0.22 to 0.25 catches all eight.

## Replaying the shipping code

Same recording, running the real `SourceTranscriber` + `EchoReference` + `EchoDelayEstimator` +
`EchoGate` over `mic.wav` and `system.wav`:

| | leakage dropped | speech lost |
|---|---|---|
| Envelope gate (before) | 0/8 | 0/24 |
| Whole-utterance correlation | 4/8 | 0/24 |
| **Window share, shipping** | **8/8** | **0/24** |

The middle row is why the decision counts windows instead of correlating the utterance as a whole:
one number over the whole span lets its length dilute the answer, since a leaked phrase carries the
pause around it.

Of the three glued utterances, the one at 286.5 s is trimmed correctly — 1.1 s of the far end's
words come off the front and the reply keeps its own offset. The other two are not: their leaked
halves are quiet enough that too few windows clear 0.25.

## Re-running it

The replay is a throwaway test, not part of the suite — it depends on recordings that are not in
the repository. Drop this into `Tests/MeetingHelperTests`, run
`xcodebuild ... test -only-testing:MeetingHelperTests/EchoGateFixtureTests`, then delete it and
`xcodegen generate` again.

Feeding the two tracks in step matters. Appending a whole `system.wav` up front makes every window
older than the reference's 60 s buffer fail open, which silently looks like a gate that does
nothing.

```swift
import AVFoundation
import XCTest
@testable import MeetingHelper

final class EchoGateFixtureTests: XCTestCase {
    private final class Kept: @unchecked Sendable {
        private let lock = NSLock()
        private var offsets: [TimeInterval] = []
        func append(_ offset: TimeInterval) { lock.lock(); offsets.append(offset); lock.unlock() }
        var all: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return offsets }
    }

    private func load(_ url: URL) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: file.processingFormat,
                  frameCapacity: AVAudioFrameCount(file.length)
              ),
              (try? file.read(into: buffer)) != nil,
              let channel = buffer.floatChannelData?[0]
        else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    func testGateOnARecordedMeeting() async throws {
        let directory = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(
            "Library/Application Support/MeetingHelper/Meetings/5D510227-BDB4-40FC-B10F-C3511453DC30"
        )
        guard let mic = load(directory.appendingPathComponent("mic.wav")),
              let system = load(directory.appendingPathComponent("system.wav"))
        else { return XCTFail("fixture not found") }

        let kept = Kept()
        let reference = EchoReference()
        let transcriber = SourceTranscriber(
            source: .me,
            language: "ru",
            realtimeUpdatesEnabled: false,
            echoReference: reference,
            transcribe: { _, _ in "line" },
            onUpdate: { update in
                if case .final(let line) = update { kept.append(line.offset) }
            }
        )

        // The reference stays a couple of seconds ahead and never outruns its 60 s buffer.
        let chunk = Int(AudioTrackWriter.sampleRate)
        var position = 0
        var filled = 0
        while position < mic.count {
            let target = min(position + chunk + 2 * chunk, system.count)
            if filled < target {
                reference.append(Array(system[filled..<target]))
                filled = target
            }
            transcriber.feed(Array(mic[position..<min(position + chunk, mic.count)]))
            position += chunk
            try? await Task.sleep(nanoseconds: 4_000_000)
        }
        await transcriber.finish(waitForTranscription: true)

        let leakage: [TimeInterval] = [134.8, 136.7, 233.8, 285.0, 403.0, 681.0, 756.7, 806.9]
        let speech: [TimeInterval] = [76.3, 84.3, 107.0, 145.2, 158.4, 169.4, 180.7, 190.1, 199.8,
                                      262.1, 269.8, 317.3, 328.2, 491.7, 502.9, 512.3, 525.1,
                                      529.2, 551.6, 614.7, 660.5, 754.2, 764.5, 819.2]
        let offsets = kept.all
        func survived(_ offset: TimeInterval) -> Bool {
            offsets.contains { $0 >= offset - 1.2 && $0 <= offset + 1.2 }
        }

        print("FIXTURE dropped \(leakage.filter { !survived($0) }.count)/\(leakage.count) leakage, "
              + "lost \(speech.filter { !survived($0) }.count)/\(speech.count) speech")
    }
}
```

## Caveats

- **The delay is measured, the correlation thresholds are not.** 0.25 and the 50 % share come from
  one recording on one machine. They are far more portable than the level threshold they replaced,
  because nothing in them scales with volume — but a very reverberant room spreads echo across many
  delays and lowers every correlation, which pushes the gate towards doing nothing. It fails open.
- **The gate does nothing until the delay is measured**, which takes two or three utterances with
  audible playback. Leakage before that is `TranscriptDeduplicator`'s problem.
- **A route change costs about fifty observations.** Plugging in Bluetooth mid-meeting moves the
  delay by hundreds of milliseconds, and until the curve follows, the gate's verdicts go to
  "speech" rather than to a wrong drop.
- **Headphones need no special handling.** There is no leakage, so nothing correlates and the gate
  never fires.
- **Clock drift is why the observation window is 500 ms.** The microphone and the system tap run on
  separate clocks; over a minute they can slide by milliseconds, which is enough to smear a
  correlation computed over that long. Over half a second it is negligible.

## What the envelope gate got wrong

The first gate compared the per-100 ms loudness envelopes of the two tracks, and dropped an
utterance whose envelope correlated ≥ 0.80 and sat ≥ 18 dB below the reference. Measurements from
2026-08-01, on a Mac mini with a C922 webcam microphone, showed echo at −19…−28 dB against speech
at −11…−13 dB, with a 4.7 dB margin.

On `5D510227` it caught **0 of 8** leaked utterances. Two independent reasons:

- **The level threshold does not travel.** On that recording the coupling is about 10 dB tighter:
  leakage sits at −7…−22 dB, and real speech reaches −11.9 dB. The classes do not separate on level
  at all, so no threshold works — not a tuning error but a design one.
- **The envelope cannot see the delay.** The route delay is 21–42 ms, inside a single 100 ms frame.
  The lag search over 0…500 ms in 100 ms steps always chose lag 0 and never contributed anything,
  and averaging 1600 samples into one number discards the structure that identifies one signal as a
  copy of another.

The gate still reported "filtered 23 of 104" on that meeting, because the counter counts drops and
cannot count misses. That is why the replay above exists.
