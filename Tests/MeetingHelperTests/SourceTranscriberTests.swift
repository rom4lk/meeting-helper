import XCTest
@testable import MeetingHelper

final class SourceTranscriberTests: XCTestCase {
    private actor ModelSpy: SpeechTranscribing {
        private(set) var models: [String] = []

        func transcribe(_ samples: [Float], language: String?, model: String) async -> String? {
            models.append(model)
            return "Final result"
        }
    }

    private final class RecognitionCalls: @unchecked Sendable {
        private let lock = NSLock()
        private var sampleCounts: [Int] = []

        func response(for samples: [Float]) -> String {
            lock.lock()
            sampleCounts.append(samples.count)
            let call = sampleCounts.count
            lock.unlock()
            return call < 3 ? "Preview \(call)" : "Final result"
        }

        var counts: [Int] {
            lock.lock()
            defer { lock.unlock() }
            return sampleCounts
        }
    }

    private final class TranscriptUpdates: @unchecked Sendable {
        private let lock = NSLock()
        private var previewLines: [TranscriptLine] = []
        private var finalLines: [TranscriptLine] = []

        func append(_ update: SourceTranscriptionUpdate) {
            lock.lock()
            defer { lock.unlock() }
            switch update {
            case .preview(let line):
                previewLines.append(line)
            case .final(let line):
                finalLines.append(line)
            case .removePreview:
                break
            }
        }

        var previews: [TranscriptLine] {
            lock.lock()
            defer { lock.unlock() }
            return previewLines
        }

        var finals: [TranscriptLine] {
            lock.lock()
            defer { lock.unlock() }
            return finalLines
        }
    }

    func testRealtimeModeUpdatesOnePreviewAndReplacesItWithTheFinalLine() async {
        let firstPreview = expectation(description: "First preview")
        let secondPreview = expectation(description: "Second preview")
        let final = expectation(description: "Final result")
        let calls = RecognitionCalls()
        let updates = TranscriptUpdates()

        let transcriber = SourceTranscriber(
            source: .others,
            language: "en",
            realtimeUpdatesEnabled: true,
            transcribe: { samples, _ in calls.response(for: samples) },
            onUpdate: { update in
                updates.append(update)
                switch update {
                case .preview:
                    if updates.previews.count == 1 {
                        firstPreview.fulfill()
                    } else {
                        secondPreview.fulfill()
                    }
                case .final:
                    final.fulfill()
                case .removePreview:
                    break
                }
            }
        )

        let twoSecondsOfSpeech = [Float](repeating: 0.1, count: 20 * SourceTranscriber.frameSize)
        transcriber.feed(twoSecondsOfSpeech)
        await fulfillment(of: [firstPreview], timeout: 1)

        transcriber.feed(twoSecondsOfSpeech)
        await fulfillment(of: [secondPreview], timeout: 1)

        transcriber.feed([Float](repeating: 0, count: 8 * SourceTranscriber.frameSize))
        await transcriber.finish(waitForTranscription: true)
        await fulfillment(of: [final], timeout: 1)

        let previews = updates.previews
        let finalLines = updates.finals
        XCTAssertEqual(previews.map(\.text), ["Preview 1", "Preview 2"])
        XCTAssertEqual(finalLines.map(\.text), ["Final result"])
        XCTAssertEqual(Set((previews + finalLines).map(\.id)).count, 1)
        XCTAssertEqual(calls.counts, [20, 40, 48].map { $0 * SourceTranscriber.frameSize })
    }

    func testDisabledRealtimeModeOnlyTranscribesTheFinalUtterance() async {
        let recognized = expectation(description: "Final result")
        let calls = RecognitionCalls()
        let speech = [Float](repeating: 0.1, count: 40 * SourceTranscriber.frameSize)
        let silence = [Float](repeating: 0, count: 8 * SourceTranscriber.frameSize)

        let transcriber = makeTranscriber(
            source: .others,
            language: "en",
            realtimeUpdatesEnabled: false,
            transcribe: { samples, _ in calls.response(for: samples) },
            onLine: { _ in recognized.fulfill() }
        )

        transcriber.feed(speech + silence)
        await transcriber.finish(waitForTranscription: true)
        await fulfillment(of: [recognized], timeout: 1)

        XCTAssertEqual(calls.counts, [48 * SourceTranscriber.frameSize])
    }

    /// The noise floor used to be learned from speech as well, so a long utterance raised the
    /// threshold above the speaker's own level and everything after that was read as silence.
    func testASustainedUtteranceReachesRecognitionWhole() async {
        let recognized = expectation(description: "Final result")
        let calls = RecognitionCalls()
        // 20 s of speech that keeps changing level the way a voice does, then the pause that
        // closes the utterance.
        let speech = (0..<200).flatMap { frame -> [Float] in
            let level: Float = frame.isMultiple(of: 2) ? 0.08 : 0.12
            return [Float](repeating: level, count: SourceTranscriber.frameSize)
        }
        let silence = [Float](repeating: 0, count: 8 * SourceTranscriber.frameSize)

        let transcriber = makeTranscriber(
            source: .others,
            language: "en",
            transcribe: { samples, _ in calls.response(for: samples) },
            onLine: { _ in recognized.fulfill() }
        )

        transcriber.feed(speech + silence)
        await transcriber.finish(waitForTranscription: true)
        await fulfillment(of: [recognized], timeout: 5)

        XCTAssertEqual(calls.counts, [208 * SourceTranscriber.frameSize])
    }

    func testFinishDoesNotWaitForTranscriptionWhenRecognitionIsNotReady() async {
        let transcriptionStarted = expectation(description: "Transcription started")
        let transcriber = makeTranscriber(
            source: .me,
            language: "en",
            transcribe: { _, _ in
                transcriptionStarted.fulfill()
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                return "This result should be discarded."
            },
            onLine: { _ in
                XCTFail("Cancelled transcription produced a line")
            }
        )

        let speech = [Float](repeating: 0.1, count: 4 * 1_600)
        let silence = [Float](repeating: 0, count: 8 * 1_600)
        transcriber.feed(speech + silence)
        await fulfillment(of: [transcriptionStarted], timeout: 1)

        let startedAt = Date()
        await transcriber.finish(waitForTranscription: false)

        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1)
    }

    func testEngineTranscriptionUsesTheModelCapturedByTheTranscriber() async {
        let final = expectation(description: "Final result")
        let engine = ModelSpy()
        let transcriber = SourceTranscriber(
            source: .others,
            engine: engine,
            model: "model-at-recording-start",
            language: "en",
            realtimeUpdatesEnabled: false,
            onUpdate: { update in
                guard case .final = update else { return }
                final.fulfill()
            }
        )

        let speech = [Float](repeating: 0.1, count: 40 * SourceTranscriber.frameSize)
        let silence = [Float](repeating: 0, count: 8 * SourceTranscriber.frameSize)
        transcriber.feed(speech + silence)
        await transcriber.finish(waitForTranscription: true)
        await fulfillment(of: [final], timeout: 1)

        let models = await engine.models
        XCTAssertEqual(models, ["model-at-recording-start"])
    }

    // MARK: - Speaker attribution

    /// Records what the speaker model was asked about, from whichever task the utterance closed on.
    private final class AttributionCalls: @unchecked Sendable {
        private let lock = NSLock()
        private var durations: [TimeInterval] = []
        private var sampleCounts: [Int] = []

        func answer(samples: [Float], duration: TimeInterval) -> String {
            lock.lock()
            durations.append(duration)
            sampleCounts.append(samples.count)
            let call = durations.count
            lock.unlock()
            return "voice-\(call)"
        }

        var observed: [TimeInterval] {
            lock.lock()
            defer { lock.unlock() }
            return durations
        }

        var counts: [Int] {
            lock.lock()
            defer { lock.unlock() }
            return sampleCounts
        }
    }

    func testTheFinalLineCarriesTheVoiceAndPreviewsDoNot() async {
        let final = expectation(description: "Final result")
        let attribution = AttributionCalls()
        let updates = TranscriptUpdates()

        let transcriber = SourceTranscriber(
            source: .others,
            language: "en",
            realtimeUpdatesEnabled: true,
            transcribe: { _, _ in "Anything" },
            attribute: { samples, duration in
                attribution.answer(samples: samples, duration: duration)
            },
            onUpdate: { update in
                updates.append(update)
                if case .final = update { final.fulfill() }
            }
        )

        let speech = [Float](repeating: 0.1, count: 40 * SourceTranscriber.frameSize)
        let silence = [Float](repeating: 0, count: 8 * SourceTranscriber.frameSize)
        transcriber.feed(speech + silence)
        await transcriber.finish(waitForTranscription: true)
        await fulfillment(of: [final], timeout: 1)

        XCTAssertEqual(updates.finals.map(\.speakerID), ["voice-1"])
        XCTAssertTrue(updates.previews.allSatisfy { $0.speakerID == nil })
        // One embedding for the utterance, not one per two-second preview of it.
        XCTAssertEqual(attribution.observed.count, 1)
        // The four seconds of speech, without the 800 ms of silence it took to close the utterance.
        XCTAssertEqual(attribution.observed.first ?? 0, 4.0, accuracy: 0.001)
        XCTAssertEqual(attribution.counts, [40 * SourceTranscriber.frameSize])
    }

    /// The padding is what used to make every "mhm" look like a second of speech, and a second is
    /// exactly the point above which the diarizer starts inventing voices.
    func testAShortInterjectionIsMeasuredWithoutItsPadding() async {
        let final = expectation(description: "Final result")
        let attribution = AttributionCalls()

        let transcriber = makeTranscriber(
            source: .others,
            language: "en",
            transcribe: { _, _ in "Mhm." },
            attribute: { samples, duration in
                attribution.answer(samples: samples, duration: duration)
            },
            onLine: { _ in final.fulfill() }
        )

        let speech = [Float](repeating: 0.1, count: 4 * SourceTranscriber.frameSize)
        let silence = [Float](repeating: 0, count: 8 * SourceTranscriber.frameSize)
        transcriber.feed(silence + speech + silence)
        await transcriber.finish(waitForTranscription: true)
        await fulfillment(of: [final], timeout: 1)

        XCTAssertEqual(attribution.observed.first ?? 0, 0.4, accuracy: 0.001)
        XCTAssertLessThan(attribution.observed.first ?? 0, 1)
        XCTAssertEqual(attribution.counts, [4 * SourceTranscriber.frameSize])
    }

    func testAnUnrecognizedPhraseNeverAsksWhoSaidIt() async {
        let removed = expectation(description: "Preview removed")
        let attribution = AttributionCalls()

        let transcriber = SourceTranscriber(
            source: .others,
            language: "en",
            realtimeUpdatesEnabled: false,
            transcribe: { _, _ in nil },
            attribute: { samples, duration in
                attribution.answer(samples: samples, duration: duration)
            },
            onUpdate: { update in
                if case .removePreview = update { removed.fulfill() }
            }
        )

        let speech = [Float](repeating: 0.1, count: 40 * SourceTranscriber.frameSize)
        let silence = [Float](repeating: 0, count: 8 * SourceTranscriber.frameSize)
        transcriber.feed(speech + silence)
        await transcriber.finish(waitForTranscription: true)
        await fulfillment(of: [removed], timeout: 1)

        XCTAssertTrue(attribution.observed.isEmpty)
    }

    func testWithoutAnAttributorLinesSimplyCarryNoVoice() async {
        let final = expectation(description: "Final result")
        let updates = TranscriptUpdates()

        let transcriber = makeTranscriber(
            source: .others,
            language: "en",
            transcribe: { _, _ in "Anything" },
            onLine: { line in
                updates.append(.final(line))
                final.fulfill()
            }
        )

        let speech = [Float](repeating: 0.1, count: 40 * SourceTranscriber.frameSize)
        let silence = [Float](repeating: 0, count: 8 * SourceTranscriber.frameSize)
        transcriber.feed(speech + silence)
        await transcriber.finish(waitForTranscription: true)
        await fulfillment(of: [final], timeout: 1)

        XCTAssertEqual(updates.finals.map(\.speakerID), [nil])
    }

    // MARK: - Echo gate

    /// Verdicts arrive on the main actor from a background task, so the test reads them under a lock.
    private final class Verdicts: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [EchoVerdict] = []

        func append(_ verdict: EchoVerdict) {
            lock.lock()
            values.append(verdict)
            lock.unlock()
        }

        var reported: [EchoVerdict] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

    /// One speech-shaped burst, surrounded by enough silence for the VAD to open and close it.
    private static let burst: [Float] = [0.05, 0.10, 0.14, 0.18, 0.20, 0.16, 0.11, 0.06]
    private static let silence = [Float](repeating: 0, count: 8)

    private func samples(_ amplitudes: [Float]) -> [Float] {
        amplitudes.flatMap { [Float](repeating: $0, count: SourceTranscriber.frameSize) }
    }

    // MARK: - Echo gate

    private static let acousticDelay = 360        // 22.5 ms, what the measured route comes to
    private static let leadingSilence = 16_000    // 1 s, so the first utterance has a reference

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

    /// Builds a system track of `count` bursts of playback separated by silence, and the
    /// microphone track that hears them through the room: the same signal, delayed and attenuated.
    private func meetingOverSpeakers(bursts count: Int, burstSeconds: Double = 2.5)
        -> (microphone: [Float], reference: EchoReference) {
        let burst = Int(burstSeconds * AudioTrackWriter.sampleRate)
        let gap = 16_000
        var system = [Float](repeating: 0, count: Self.leadingSilence)
        for index in 0..<count {
            system += voice(seed: index * 11, count: burst)
            system += [Float](repeating: 0, count: gap)
        }

        let microphone = (0..<system.count).map { index -> Float in
            let source = index - Self.acousticDelay
            return source >= 0 ? system[source] * 0.05 : 0
        }

        let reference = EchoReference()
        reference.append(system)
        return (microphone, reference)
    }

    /// Feeds audio the way capture does, a second at a time. Handing over the whole track at once
    /// closes every utterance in the same breath and lets their gate tasks race each other.
    private func feed(_ samples: [Float], to transcriber: SourceTranscriber) async {
        let chunk = Int(AudioTrackWriter.sampleRate)
        for position in stride(from: 0, to: samples.count, by: chunk) {
            transcriber.feed(Array(samples[position..<min(position + chunk, samples.count)]))
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// The gate cannot judge anything until it has measured the route, so the first utterances
    /// pass through and the ones after it are dropped.
    func testSpeakerLeakageIsNotTranscribedOnceTheDelayIsMeasured() async {
        let track = meetingOverSpeakers(bursts: 5)
        let verdicts = Verdicts()

        let lines = TranscriptUpdates()

        let transcriber = makeTranscriber(
            source: .me,
            language: "en",
            echoReference: track.reference,
            onEchoVerdict: { verdicts.append($0) },
            transcribe: { _, _ in "Speaker playback that leaked into the microphone." },
            onLine: { line in lines.append(.final(line)) }
        )

        await feed(track.microphone, to: transcriber)
        await transcriber.finish(waitForTranscription: true)

        // The first utterance is what the estimator learns the route from, so it passes through.
        XCTAssertEqual(verdicts.reported.count, 5)
        XCTAssertEqual(verdicts.reported.filter { $0 == .echo }.count, 4)
        XCTAssertEqual(lines.finals.count, 1)
    }

    func testSpeechIsTranscribedWhileTheSystemIsPlaying() async {
        let track = meetingOverSpeakers(bursts: 3)
        let verdicts = Verdicts()
        let lines = TranscriptUpdates()

        // The last burst is the user talking over the playback instead of the room echoing it:
        // just as quiet, but its own voice.
        var microphone = track.microphone
        let ownVoiceStart = microphone.count
        let burst = Int(2.5 * AudioTrackWriter.sampleRate)
        var system = [Float](repeating: 0, count: microphone.count)
        system += voice(seed: 700, count: burst)
        system += [Float](repeating: 0, count: 16_000)
        microphone += voice(seed: 71, count: burst, from: ownVoiceStart).map { $0 * 0.05 }
        microphone += [Float](repeating: 0, count: 16_000)
        track.reference.append(Array(system[ownVoiceStart...]))

        let transcriber = makeTranscriber(
            source: .me,
            language: "en",
            echoReference: track.reference,
            onEchoVerdict: { verdicts.append($0) },
            transcribe: { _, _ in "Something I said while the meeting audio was playing." },
            onLine: { line in lines.append(.final(line)) }
        )

        await feed(microphone, to: transcriber)
        await transcriber.finish(waitForTranscription: true)

        XCTAssertEqual(verdicts.reported.last, .speech)
        let ownVoiceOffset = Double(ownVoiceStart) / AudioTrackWriter.sampleRate
        XCTAssertTrue(
            lines.finals.contains { abs($0.offset - ownVoiceOffset) < 0.5 },
            "Own speech over playback was not transcribed: \(lines.finals.map(\.offset))"
        )
    }

    /// The pause that closes an utterance is longer than the pause between one person finishing
    /// and the other answering, so leakage arrives glued to the front of the reply. The gate has
    /// to trim it instead of judging the pair as one.
    func testLeakageIsTrimmedOffTheFrontOfAReply() async {
        let track = meetingOverSpeakers(bursts: 3)
        let verdicts = Verdicts()
        let lines = TranscriptUpdates()

        var microphone = track.microphone
        let replyStart = microphone.count
        let leak = Int(1.5 * AudioTrackWriter.sampleRate)
        let reply = Int(2.5 * AudioTrackWriter.sampleRate)

        // Playback, then a 400 ms pause — too short to close the utterance — then the reply.
        var system = voice(seed: 500, count: leak)
        system += [Float](repeating: 0, count: reply + 16_000 + 6_400)
        track.reference.append(system)

        var heard = [Float](repeating: 0, count: leak + 6_400)
        for index in Self.acousticDelay..<(leak + Self.acousticDelay) {
            heard[index] = system[index - Self.acousticDelay] * 0.05
        }
        microphone += heard
        microphone += voice(seed: 83, count: reply, from: replyStart).map { $0 * 0.05 }
        microphone += [Float](repeating: 0, count: 16_000)

        let transcriber = makeTranscriber(
            source: .me,
            language: "en",
            echoReference: track.reference,
            onEchoVerdict: { verdicts.append($0) },
            transcribe: { _, _ in "The reply, without the leakage in front of it." },
            onLine: { line in lines.append(.final(line)) }
        )

        await feed(microphone, to: transcriber)
        await transcriber.finish(waitForTranscription: true)

        XCTAssertEqual(verdicts.reported.last, .speech)
        let expectedReplyOffset = Double(replyStart + leak + 6_400) / AudioTrackWriter.sampleRate
        XCTAssertEqual(lines.finals.last?.offset ?? 0, expectedReplyOffset, accuracy: 0.5)
    }

    /// With the gate off there is no reference at all, so nothing is compared and nothing waits
    /// for the system track — the utterance goes straight to recognition.
    func testUtterancesGoStraightToRecognitionWithoutAReference() async {
        let recognized = expectation(description: "Speech was transcribed")
        let verdicts = Verdicts()
        let heard = Self.silence + Self.burst.map { $0 * 0.3 } + Self.silence

        let transcriber = makeTranscriber(
            source: .me,
            language: "en",
            echoReference: nil,
            onEchoVerdict: { verdicts.append($0) },
            transcribe: { _, _ in "Recognized without any echo check." },
            onLine: { _ in recognized.fulfill() }
        )

        let startedAt = Date()
        transcriber.feed(samples(heard))
        await transcriber.finish(waitForTranscription: true)
        await fulfillment(of: [recognized], timeout: 1)

        XCTAssertEqual(verdicts.reported, [])
        // A gated utterance waits up to 0.5 s for the system track; this one must not wait at all.
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.5)
    }

    func testSpeechIsTranscribedWhenTheSystemTrackIsMissing() async {
        let recognized = expectation(description: "Speech was transcribed")
        let heard = Self.silence + Self.burst.map { $0 * 0.3 } + Self.silence
        let verdicts = Verdicts()

        let transcriber = makeTranscriber(
            source: .me,
            language: "en",
            echoReference: EchoReference(),
            onEchoVerdict: { verdicts.append($0) },
            transcribe: { _, _ in "Nothing to compare against." },
            onLine: { _ in recognized.fulfill() }
        )

        transcriber.feed(samples(heard))
        await transcriber.finish(waitForTranscription: true)
        await fulfillment(of: [recognized], timeout: 1)

        XCTAssertEqual(verdicts.reported, [.undecided])
    }

    // MARK: - Helpers

    /// The transcriber reports through a single `onUpdate` stream; several tests below only care
    /// about finished lines, so they go through this wrapper instead of a second initializer.
    private func makeTranscriber(
        source: TranscriptSource,
        language: String?,
        realtimeUpdatesEnabled: Bool = false,
        echoReference: EchoReference? = nil,
        onEchoVerdict: (@MainActor (EchoVerdict) -> Void)? = nil,
        transcribe: @escaping @Sendable ([Float], String?) async -> String?,
        attribute: (@Sendable ([Float], TimeInterval) async -> String?)? = nil,
        onLine: @escaping @MainActor (TranscriptLine) -> Void
    ) -> SourceTranscriber {
        SourceTranscriber(
            source: source,
            language: language,
            realtimeUpdatesEnabled: realtimeUpdatesEnabled,
            echoReference: echoReference,
            onEchoVerdict: onEchoVerdict,
            transcribe: transcribe,
            attribute: attribute,
            onUpdate: { update in
                guard case .final(let line) = update else { return }
                onLine(line)
            }
        )
    }
}
