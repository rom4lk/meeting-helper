import Foundation

enum SourceTranscriptionUpdate: Sendable {
    case preview(TranscriptLine)
    case final(TranscriptLine)
    case removePreview(UUID)
}

/// Turns a continuous 16 kHz mono stream into transcript lines.
///
/// Whisper is not a streaming model, so we cut the stream into utterances with a simple energy
/// VAD and transcribe each utterance on its own. One instance per track.
///
/// `feed` is called from the track writer's queue and every mutable field below is touched only
/// on `queue`, so instances are safe to hand to a capture callback.
final class SourceTranscriber: @unchecked Sendable {
    /// 100 ms at `AudioTrackWriter.sampleRate`, the unit the VAD works in.
    static let frameSize = 1_600

    private enum Constants {
        static let sampleRate: Double = AudioTrackWriter.sampleRate
        static let frameSize = SourceTranscriber.frameSize
        static let preRollFrames = 3                    // 300 ms kept before speech onset
        static let silenceFramesToClose = 8             // 800 ms of silence ends an utterance
        static let minSpeechFrames = 4                  // shorter bursts are noise
        static let maxUtteranceFrames = 250             // hard cut at 25 s
        static let previewIntervalFrames = 20           // refresh the active phrase every 2 s
        /// Below this a frame is silence, wherever that is judged: here when opening an
        /// utterance, and in `VoicedSpan` when the speaker model asks what part of one is speech.
        static let absoluteThreshold = VoicedSpan.silenceThreshold
        static let noiseMultiplier: Float = 3.5
        /// How long an utterance waits for the system track to reach it before giving up.
        static let referenceWaitLimit: TimeInterval = 0.5
        static let referencePollInterval: UInt64 = 50_000_000
        /// Windows an utterance contributes to the delay estimate.
        static let delayObservationsPerUtterance = 4
        /// Share of an utterance's audible windows that has to be leakage before the whole thing
        /// is treated as leakage. Measured over labelled recordings: leaked phrases land above
        /// 60 %, speech over playback below 10 %.
        static let leakageShare = 0.5
    }

    private let source: TranscriptSource
    private let transcribe: @Sendable ([Float], String?) async -> String?
    /// Names the voice in a finished utterance. Only the system track has one: the microphone is
    /// always the account owner, and asking a speaker model to confirm that would be waste.
    ///
    /// It is handed the spoken stretch of the utterance and the speech in it, not the padded whole
    /// the recognizer sees — see `VoicedSpan` for why the difference matters.
    private let attribute: (@Sendable ([Float], TimeInterval) async -> String?)?
    private let onUpdate: @MainActor (SourceTranscriptionUpdate) -> Void
    private let queue: DispatchQueue
    private let realtimeUpdatesEnabled: Bool
    private let echoReference: EchoReference?
    /// Reports every echo-gate decision so the recording UI can show that the gate is working.
    private let onEchoVerdict: (@MainActor (EchoVerdict) -> Void)?
    /// Learns the route's acoustic delay from the utterances that pass through, so the gate can
    /// line the two tracks up. Shared across utterances, hence its own lock.
    private let delayEstimator = EchoDelayEstimator()

    private var language: String?

    private var inbox: [Float] = []
    private var preRoll: [[Float]] = []
    private var pending: [Float] = []
    private var inUtterance = false
    private var speechFrames = 0
    private var silenceFrames = 0
    private var utteranceStartFrame = 0
    private var framesSeen = 0
    private var noiseFloor: Float = 0.002
    private var utteranceID: UUID?
    private var lastPreviewFrameCount = 0
    private var previewGeneration = 0
    private var activePreviewGeneration: Int?
    private var activePreviewTask: Task<Void, Never>?
    /// In-flight transcription tasks, only ever touched on `queue`. Each one drops its own entry
    /// when it finishes, so a long meeting does not accumulate a handle per utterance.
    private var tasks: [Int: Task<Void, Never>] = [:]
    private var nextTaskID = 0

    init(
        source: TranscriptSource,
        language: String?,
        realtimeUpdatesEnabled: Bool,
        echoReference: EchoReference? = nil,
        onEchoVerdict: (@MainActor (EchoVerdict) -> Void)? = nil,
        transcribe: @escaping @Sendable ([Float], String?) async -> String?,
        attribute: (@Sendable ([Float], TimeInterval) async -> String?)? = nil,
        onUpdate: @escaping @MainActor (SourceTranscriptionUpdate) -> Void
    ) {
        self.source = source
        self.transcribe = transcribe
        self.attribute = attribute
        self.language = language
        self.realtimeUpdatesEnabled = realtimeUpdatesEnabled
        self.echoReference = echoReference
        self.onEchoVerdict = onEchoVerdict
        self.onUpdate = onUpdate
        self.queue = DispatchQueue(label: "com.kovalev.MeetingHelper.vad.\(source.rawValue)", qos: .utility)
    }

    convenience init(
        source: TranscriptSource,
        engine: any SpeechTranscribing,
        model: String,
        language: String?,
        realtimeUpdatesEnabled: Bool,
        echoReference: EchoReference? = nil,
        onEchoVerdict: (@MainActor (EchoVerdict) -> Void)? = nil,
        attribute: (@Sendable ([Float], TimeInterval) async -> String?)? = nil,
        onUpdate: @escaping @MainActor (SourceTranscriptionUpdate) -> Void
    ) {
        self.init(
            source: source,
            language: language,
            realtimeUpdatesEnabled: realtimeUpdatesEnabled,
            echoReference: echoReference,
            onEchoVerdict: onEchoVerdict,
            transcribe: { samples, language in
                await engine.transcribe(samples, language: language, model: model)
            },
            attribute: attribute,
            onUpdate: onUpdate
        )
    }

    func feed(_ samples: [Float]) {
        queue.async { [weak self] in
            guard let self else { return }
            self.inbox.append(contentsOf: samples)
            while self.inbox.count >= Constants.frameSize {
                let frame = Array(self.inbox.prefix(Constants.frameSize))
                self.inbox.removeFirst(Constants.frameSize)
                self.consume(frame)
            }
        }
    }

    /// Flushes whatever is still buffered and, when recognition is ready, waits for every
    /// in-flight transcription so the saved transcript is complete. If the model is still
    /// loading, pending work is discarded so stopping a recording does not wait for the model.
    func finish(waitForTranscription: Bool) async {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else { return continuation.resume() }

                guard waitForTranscription else {
                    self.activePreviewTask?.cancel()
                    self.activePreviewTask = nil
                    self.activePreviewGeneration = nil
                    self.inbox.removeAll()
                    self.pending.removeAll()
                    self.preRoll.removeAll()
                    self.utteranceID = nil
                    self.tasks.values.forEach { $0.cancel() }
                    self.tasks.removeAll()
                    return continuation.resume()
                }

                if !self.inbox.isEmpty {
                    self.pending.append(contentsOf: self.inbox)
                    self.inbox.removeAll()
                }
                self.closeUtterance(force: true)
                continuation.resume()
            }
        }

        let pending = queue.sync { Array(tasks.values) }
        for task in pending {
            await task.value
        }
    }

    /// Runs a transcription task and forgets the handle once it completes.
    private func track(_ body: @escaping @Sendable () async -> Void) {
        let id = nextTaskID
        nextTaskID += 1
        tasks[id] = Task { [weak self, queue] in
            await body()
            guard let self else { return }
            queue.async { self.tasks[id] = nil }
        }
    }

    private func consume(_ frame: [Float]) {
        framesSeen += 1

        let energy = rootMeanSquare(frame)
        // Track the quietest recent level as the noise floor so the threshold follows the room.
        if energy < noiseFloor {
            noiseFloor = noiseFloor * 0.9 + energy * 0.1
        } else {
            noiseFloor = noiseFloor * 0.995 + energy * 0.005
        }

        let threshold = max(Constants.absoluteThreshold, noiseFloor * Constants.noiseMultiplier)
        let isSpeech = energy > threshold

        if inUtterance {
            pending.append(contentsOf: frame)
            if isSpeech {
                speechFrames += 1
                silenceFrames = 0
            } else {
                silenceFrames += 1
            }

            let frameCount = pending.count / Constants.frameSize
            if silenceFrames >= Constants.silenceFramesToClose || frameCount >= Constants.maxUtteranceFrames {
                closeUtterance(force: false)
            } else {
                startPreviewIfNeeded()
            }
        } else {
            preRoll.append(frame)
            if preRoll.count > Constants.preRollFrames {
                preRoll.removeFirst()
            }

            guard isSpeech else { return }

            inUtterance = true
            utteranceID = UUID()
            utteranceStartFrame = framesSeen - preRoll.count
            pending = preRoll.flatMap { $0 }
            preRoll.removeAll()
            speechFrames = 1
            silenceFrames = 0
            lastPreviewFrameCount = 0
        }
    }

    private func closeUtterance(force: Bool) {
        let previewTask = activePreviewTask
        previewTask?.cancel()
        activePreviewTask = nil
        activePreviewGeneration = nil

        defer {
            inUtterance = false
            utteranceID = nil
            pending.removeAll()
            preRoll.removeAll()
            speechFrames = 0
            silenceFrames = 0
            lastPreviewFrameCount = 0
        }

        guard inUtterance, let utteranceID else { return }
        guard force || speechFrames >= Constants.minSpeechFrames else {
            schedulePreviewRemoval(utteranceID, after: previewTask)
            return
        }
        guard speechFrames > 0, !pending.isEmpty else {
            schedulePreviewRemoval(utteranceID, after: previewTask)
            return
        }

        let samples = pending
        let offset = Double(utteranceStartFrame) * Double(Constants.frameSize) / Constants.sampleRate
        let source = self.source
        let language = self.language

        track { [transcribe, attribute, onUpdate, onEchoVerdict, echoReference, delayEstimator] in
            if let previewTask {
                await previewTask.value
            }
            guard !Task.isCancelled else { return }

            var samples = samples
            var offset = offset
            if let echoReference {
                let decision = await Self.decide(
                    samples: samples,
                    at: offset,
                    reference: echoReference,
                    delayEstimator: delayEstimator,
                    learning: true
                )
                await onEchoVerdict?(decision.verdict)
                if decision.verdict == .echo {
                    Log.audio.info("Dropped speaker leakage at \(offset, privacy: .public) s")
                    await onUpdate(.removePreview(utteranceID))
                    return
                }
                offset += Double(decision.kept.lowerBound) / Constants.sampleRate
                samples = Array(samples[decision.kept])
            }

            guard let text = await transcribe(samples, language) else {
                await onUpdate(.removePreview(utteranceID))
                return
            }
            guard !Task.isCancelled else { return }

            // Naming the voice comes after recognition, so a phrase that never becomes a line does
            // not invent a speaker. A hallucination on near-silence would otherwise leave behind a
            // voice nobody ever hears again.
            var speakerID: String?
            if let attribute {
                let span = VoicedSpan.of(samples)
                if !span.isEmpty {
                    speakerID = await attribute(Array(samples[span.range]), span.duration)
                }
            }

            let line = TranscriptLine(
                id: utteranceID,
                source: source,
                offset: offset,
                text: text,
                speakerID: speakerID
            )
            await onUpdate(.final(line))
        }
    }

    /// Recognizes an expanding snapshot of the active utterance. Every snapshot overlaps the
    /// previous one, letting Whisper revise the preview as more context arrives.
    private func startPreviewIfNeeded() {
        guard realtimeUpdatesEnabled, inUtterance, activePreviewTask == nil,
              let utteranceID
        else { return }

        let frameCount = pending.count / Constants.frameSize
        guard frameCount >= lastPreviewFrameCount + Constants.previewIntervalFrames else { return }

        let samples = pending
        let offset = Double(utteranceStartFrame) * Double(Constants.frameSize) / Constants.sampleRate
        let source = self.source
        let language = self.language
        let queue = self.queue

        lastPreviewFrameCount = frameCount
        previewGeneration += 1
        let generation = previewGeneration
        activePreviewGeneration = generation

        let task = Task { [weak self, transcribe, onUpdate, echoReference, delayEstimator] in
            var samples = samples
            var offset = offset
            if let echoReference {
                // Previews revisit the same audio every couple of seconds, so they only read the
                // delay estimate — feeding it here would count one window many times over.
                let decision = await Self.decide(
                    samples: samples,
                    at: offset,
                    reference: echoReference,
                    delayEstimator: delayEstimator,
                    learning: false
                )
                guard !Task.isCancelled else {
                    queue.async { [weak self] in self?.previewDidFinish(generation) }
                    return
                }
                if decision.verdict == .echo {
                    await onUpdate(.removePreview(utteranceID))
                    queue.async { [weak self] in self?.previewDidFinish(generation) }
                    return
                }
                offset += Double(decision.kept.lowerBound) / Constants.sampleRate
                samples = Array(samples[decision.kept])
            }

            if let text = await transcribe(samples, language), !Task.isCancelled {
                let line = TranscriptLine(id: utteranceID, source: source, offset: offset, text: text)
                await onUpdate(.preview(line))
            }
            queue.async { [weak self] in self?.previewDidFinish(generation) }
        }
        activePreviewTask = task
    }

    private func previewDidFinish(_ generation: Int) {
        guard activePreviewGeneration == generation else { return }
        activePreviewTask = nil
        activePreviewGeneration = nil
        startPreviewIfNeeded()
    }

    private func schedulePreviewRemoval(_ id: UUID, after previewTask: Task<Void, Never>?) {
        track { [onUpdate] in
            if let previewTask {
                await previewTask.value
            }
            guard !Task.isCancelled else { return }
            await onUpdate(.removePreview(id))
        }
    }

    /// What the gate concluded about one utterance, and which part of it is worth recognizing.
    private struct EchoDecision {
        var verdict: EchoVerdict
        /// The stretch to keep, in samples from the start of the utterance.
        var kept: Range<Int>
    }

    /// Waits for the system track to reach the end of the utterance, lines the two up at the
    /// route's delay, and asks the gate.
    ///
    /// Everything short of a confident echo verdict passes through — no reference, a window that
    /// scrolled out of the buffer, coverage that never arrives, a delay not yet measured.
    /// Transcript deduplication is the second net, and dropping real speech is the worse failure.
    private static func decide(
        samples: [Float],
        at offset: TimeInterval,
        reference: EchoReference,
        delayEstimator: EchoDelayEstimator,
        learning: Bool
    ) async -> EchoDecision {
        let whole = EchoDecision(verdict: .undecided, kept: 0..<samples.count)
        guard samples.count >= EchoGate.minimumSamples, reference.hasData else { return whole }

        // The reference has to start far enough ahead of the utterance for every delay to be
        // tried, and reach past its end by the alignment slack at either side.
        let lead = Double(EchoDelayEstimator.maximumDelay + EchoGate.alignmentSpan)
            / Constants.sampleRate
        let start = offset - lead
        guard start >= 0 else { return whole }

        let end = offset + Double(samples.count + EchoGate.alignmentSpan) / Constants.sampleRate
        let deadline = Date().addingTimeInterval(Constants.referenceWaitLimit)
        while reference.coveredUntil < end {
            guard Date() < deadline else { return whole }
            try? await Task.sleep(nanoseconds: Constants.referencePollInterval)
        }

        guard let window = reference.window(
            startingAt: start,
            sampleCount: samples.count + EchoDelayEstimator.maximumDelay + 2 * EchoGate.alignmentSpan
        ) else { return whole }

        if learning {
            observeDelay(samples: samples, window: window, estimator: delayEstimator)
        }
        guard let delay = delayEstimator.delay else { return whole }

        // Slide the reference forward by the delay, so both spans describe the same moment of the
        // meeting as the microphone heard it, with the slack the gate refines within.
        let origin = EchoDelayEstimator.maximumDelay - delay
        let aligned = Array(window[origin..<(origin + samples.count + 2 * EchoGate.alignmentSpan)])

        let windows = classify(microphone: samples, reference: aligned)
        let audible = windows.filter { $0 != .undecided }.count
        guard audible > 0 else { return whole }

        // Judging the utterance by one correlation over the whole of it lets its length dilute the
        // answer: a leaked phrase carries the pause around it, and a long one outweighs its own
        // evidence. Counting the windows that are leakage does not care how long the rest is.
        let leakage = windows.filter { $0 == .echo }.count
        let kept = keptRange(windows, count: samples.count)
        guard Double(leakage) < Constants.leakageShare * Double(audible), !kept.isEmpty else {
            return EchoDecision(verdict: .echo, kept: 0..<samples.count)
        }

        return EchoDecision(verdict: .speech, kept: kept)
    }

    /// Feeds the head of the utterance to the delay estimator, a few windows at a time. One window
    /// per utterance would take most of a meeting to converge; the whole utterance would let a
    /// single long one dominate.
    private static func observeDelay(
        samples: [Float],
        window: [Float],
        estimator: EchoDelayEstimator
    ) {
        let available = samples.count / EchoDelayEstimator.windowSamples
        for index in 0..<min(Constants.delayObservationsPerUtterance, available) {
            let lower = index * EchoDelayEstimator.windowSamples
            // `window` leads the utterance by the alignment slack as well, which the estimator
            // does not expect — it searches the delay itself.
            let referenceLower = lower + EchoGate.alignmentSpan
            estimator.observe(
                microphone: Array(samples[lower..<(lower + EchoDelayEstimator.windowSamples)]),
                reference: Array(
                    window[referenceLower..<(referenceLower + EchoDelayEstimator.referenceSamples)]
                )
            )
        }
    }

    private static func isEcho(
        _ range: Range<Int>,
        microphone: [Float],
        reference: [Float]
    ) -> Bool {
        EchoGate.isEcho(
            microphone: Array(microphone[range]),
            reference: Array(
                reference[range.lowerBound..<(range.upperBound + 2 * EchoGate.alignmentSpan)]
            )
        )
    }

    /// Trims leakage off the ends of an utterance.
    ///
    /// It takes 800 ms of silence to close an utterance, which is longer than the pause between
    /// one person finishing and the other answering. Without this, the far end's last words arrive
    /// glued to the front of the reply and the whole thing is judged — and attributed — as one.
    /// Walks the utterance in overlapping windows and labels each one.
    ///
    /// Silence gets its own answer rather than counting as speech. Every utterance ends in the
    /// 800 ms of it the VAD needs to close, and a wholly leaked one would survive on that alone.
    private static func classify(microphone: [Float], reference: [Float]) -> [EchoVerdict] {
        let window = EchoGate.minimumSamples
        guard microphone.count >= window else { return [] }

        return stride(from: 0, through: microphone.count - window, by: Constants.frameSize)
            .map { start in
                let range = start..<(start + window)
                guard rootMeanSquare(microphone[range]) > Constants.absoluteThreshold else {
                    return .undecided
                }
                return isEcho(range, microphone: microphone, reference: reference) ? .echo : .speech
            }
    }

    /// Trims leakage off the ends of an utterance, keeping everything from its first spoken window
    /// to its last.
    ///
    /// It takes 800 ms of silence to close an utterance, which is longer than the pause between one
    /// person finishing and the other answering. Without this, the far end's last words arrive glued
    /// to the front of the reply and the whole thing is attributed as one. Ends without leakage are
    /// left alone, so an ordinary utterance keeps the run-up the VAD deliberately captured.
    private static func keptRange(_ windows: [EchoVerdict], count: Int) -> Range<Int> {
        let step = Constants.frameSize

        var first = 0
        var leadingLeakage = false
        while first < windows.count, windows[first] != .speech {
            leadingLeakage = leadingLeakage || windows[first] == .echo
            first += 1
        }
        guard first < windows.count else { return 0..<0 }

        var last = windows.count - 1
        var trailingLeakage = false
        while last > first, windows[last] != .speech {
            trailingLeakage = trailingLeakage || windows[last] == .echo
            last -= 1
        }

        let lower = leadingLeakage ? first * step : 0
        let upper = trailingLeakage ? min(count, last * step + EchoGate.minimumSamples) : count
        return lower < upper ? lower..<upper : 0..<0
    }
}
