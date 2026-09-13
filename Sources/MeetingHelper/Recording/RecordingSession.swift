import AVFoundation
import Foundation

/// A recording in progress: two capture sources, two files, two transcribers.
@MainActor
final class RecordingSession: ObservableObject {
    enum TrackState: Equatable {
        case pending
        case capturing
        /// Not being captured on purpose: this recording is microphone only.
        case off
        case unavailable(String)
    }

    enum TranscriptionState: Equatable {
        case disabled
        case downloading(Double?)
        case preparing(ModelPreparationStage)
        case running
        case failed(String)
    }

    let meetingID = UUID()
    let detected: DetectedMeeting
    let transcriptionModel: String?

    @Published var title: String
    @Published private(set) var startedAt = Date()
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var systemLevel: Float = 0
    @Published private(set) var microphoneDeviceName = "Unknown microphone"
    @Published private(set) var micState: TrackState = .pending
    @Published private(set) var systemState: TrackState = .pending
    /// Whether this recording captures the other participants. Seeded from the setting and
    /// switchable while the recording runs; the setting itself is left alone.
    @Published private(set) var systemAudioEnabled: Bool
    @Published private(set) var transcriptionState: TranscriptionState = .disabled
    @Published private(set) var lines: [TranscriptLine] = []
    /// The tap is active, but no audible system audio has been detected yet. This can mean that
    /// the meeting is quiet or, when permission is denied, that Core Audio is delivering silence.
    @Published private(set) var systemSilent = false
    /// Microphone utterances the echo gate was able to compare against the system track, and how
    /// many of those it recognized as speaker leakage. Utterances it could not judge count as
    /// neither: they pass through unchecked.
    @Published private(set) var echoGateChecked = 0
    @Published private(set) var echoGateFiltered = 0
    /// True for a few seconds after each drop, so the indicator visibly reacts.
    @Published private(set) var echoGateFiring = false
    /// The calendar event this recording was matched to, set once as the recording starts.
    @Published private(set) var calendar: MeetingCalendarInfo?
    /// The distinct voices heard so far on the system track, and what they are called.
    @Published private(set) var roster = SpeakerRoster()

    private var lastEchoDropAt: Date?
    private var systemPeak: Float = 0
    private var captureStartedAtUptime: TimeInterval = 0
    /// When the system track was last switched on. The silence warning is counted from here, so
    /// re-enabling capture mid-recording does not raise it immediately.
    private var systemAudioStartedAt = Date()

    private let settings: AppSettings
    private let engine: TranscriptionEngine
    private let profileStore: SpeakerProfileStore
    private let transcriptDeduplicationEnabled: Bool
    private let realtimeTranscriptEnabled: Bool
    /// `nil` when speaker attribution is off, or when there is no live transcript for it to label.
    private let attributor: SpeakerAttributor?
    private var previewLineIDs: Set<UUID> = []

    private let microphone = MicrophoneCapture()
    /// The system track's loudness, used to recognize speaker leakage in the microphone.
    /// `nil` when the echo gate is off, which takes the whole check out of the path: nothing is
    /// buffered and no utterance ever waits for the system track before reaching Whisper.
    private let echoReference: EchoReference?
    private var systemTap: SystemAudioTap?
    private var micWriter: AudioTrackWriter?
    private var systemWriter: AudioTrackWriter?
    private var micTranscriber: SourceTranscriber?
    private var systemTranscriber: SourceTranscriber?

    private var uiTimer: Timer?
    private var systemRetryTimer: Timer?
    private var systemRetriesLeft = 15
    /// Set by `stop()`. The system tap attaches asynchronously, and an attachment that lands
    /// after the recording stopped has to be torn down instead of installed.
    private var isCaptureStopped = false
    /// When the tap attached, which can be seconds into the recording: the meeting app has to show
    /// up in Core Audio's process list first.
    private var systemTapAttachedAt: Date?
    private var reportedEmptySystemTap = false
    /// Attachment attempts are numbered and run one at a time. Switching system audio off and back
    /// on while one is still running would otherwise leave two attachments racing for the same
    /// track: both would find capture enabled when they land, and both could open their own writer
    /// on `system.wav`, truncating it and splitting the stream the transcriber reads.
    private var systemAttachmentGeneration = 0
    private var systemAttachmentInFlight = false
    /// Set when capture is switched on while an attachment from an earlier switch is still
    /// running. The one that lands starts the fresh attachment, so the request is not lost.
    private var systemAttachmentPending = false

    /// How long a started tap may stay empty before it is written to the log. A tap on an app that
    /// is playing delivers buffers immediately, silent ones included.
    private static let emptySystemTapReportDelay: TimeInterval = 15

    init(
        detected: DetectedMeeting,
        settings: AppSettings,
        engine: TranscriptionEngine,
        profileStore: SpeakerProfileStore
    ) {
        self.detected = detected
        self.settings = settings
        self.engine = engine
        self.profileStore = profileStore
        self.transcriptDeduplicationEnabled = settings.transcriptDeduplicationEnabled
        self.realtimeTranscriptEnabled = settings.realtimeTranscriptEnabled
        self.echoReference = settings.echoGateEnabled ? EchoReference() : nil
        self.transcriptionModel = settings.liveTranscriptEnabled ? settings.model : nil
        self.attributor = settings.liveTranscriptEnabled && settings.speakerAttributionEnabled
            ? SpeakerAttributor()
            : nil
        self.title = detected.title
        self.systemAudioEnabled = settings.recordSystemAudio
        self.systemState = settings.recordSystemAudio ? .pending : .off
    }

    /// Adopts a confidently matched calendar event, including its title and attendee list.
    ///
    /// Called before `start`, so the voices of the people on the invitation are already known when
    /// the first utterance arrives.
    func apply(_ match: CalendarEventMatcher.Match) {
        let info = MeetingCalendarInfo(event: match.event)
        calendar = info
        roster = SpeakerRoster(attendees: info.otherAttendees)
        let calendarTitle = match.event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !calendarTitle.isEmpty {
            title = calendarTitle
        }
    }

    /// Ties a voice to somebody on the invitation, or clears its name when `attendee` is `nil`.
    ///
    /// Naming a voice while the recording runs is also what teaches it: the embeddings only exist
    /// for as long as the session does, so this is the moment the person becomes recognizable at
    /// their next meeting.
    func assign(_ attendee: CalendarAttendee?, toSpeaker id: String) {
        roster.assign(attendee, to: id)

        guard let attendee, let attributor else { return }
        Task { [attributor, profileStore] in
            guard let embedding = await attributor.embedding(forSpeaker: id) else { return }
            profileStore.remember(
                email: attendee.email,
                name: attendee.name,
                embedding: embedding
            )
        }
    }

    // MARK: - Lifecycle

    func start() {
        startedAt = Date()
        captureStartedAtUptime = ProcessInfo.processInfo.systemUptime

        do {
            _ = try MeetingLibrary.createDirectory(for: meetingID)
        } catch {
            Log.audio.error("Cannot create meeting directory: \(error, privacy: .public)")
        }

        prepareSpeakerAttribution()
        startTranscription()
        startMicrophone()
        systemAudioStartedAt = startedAt
        if systemAudioEnabled {
            startSystemAudio()
        }

        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        uiTimer = timer
    }

    /// Stops every capture, finishes any ready transcription backlog and returns the saved meeting.
    func stop() async -> Meeting {
        isCaptureStopped = true
        uiTimer?.invalidate()
        uiTimer = nil
        systemRetryTimer?.invalidate()
        systemRetryTimer = nil

        microphone.stop()
        systemTap?.stop()
        systemTap = nil

        micWriter?.finish()
        systemWriter?.finish()

        // Read before the transcription backlog is drained: capture has already stopped, and
        // draining can take minutes on a long meeting. Counting that as recorded time would save
        // a duration the audio does not have, and with it mislead the minimum-length filter and
        // the confirmation a long recording asks for before it is deleted.
        let stoppedAt = Date()

        let waitForTranscription = transcriptionState == .running
        await micTranscriber?.finish(waitForTranscription: waitForTranscription)
        await systemTranscriber?.finish(waitForTranscription: waitForTranscription)
        discardAllPreviews()
        micTranscriber = nil
        systemTranscriber = nil

        let micDuration = micWriter?.duration ?? 0
        let systemDuration = systemWriter?.duration ?? 0
        let duration = max(micDuration, systemDuration, stoppedAt.timeIntervalSince(startedAt))

        let hasMic = micDuration > 0
        let hasSystem = systemDuration > 0

        micWriter = nil
        systemWriter = nil

        let id = meetingID
        await Task.detached(priority: .utility) {
            _ = Mixdown.create(
                micURL: hasMic ? MeetingLibrary.micTrackURL(for: id) : nil,
                systemURL: hasSystem ? MeetingLibrary.systemTrackURL(for: id) : nil,
                outputURL: MeetingLibrary.mixdownURL(for: id)
            )
        }.value

        return Meeting(
            id: meetingID,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? detected.title : title,
            kind: detected.kind,
            audioSourceName: detected.audioSourceName,
            startedAt: startedAt,
            duration: duration,
            hasMicTrack: hasMic,
            hasSystemTrack: hasSystem,
            transcriptionModel: transcriptionModel,
            calendar: calendar,
            speakers: roster.speakers.isEmpty ? nil : roster.speakers
        )
    }

    /// Starts or stops capturing the other participants while the recording runs.
    ///
    /// Only this recording is affected; the setting keeps its own value. Switching capture back on
    /// reuses the track's writer, so the pause is padded with silence and the system track stays a
    /// single file on the shared timeline.
    func setSystemAudioEnabled(_ enabled: Bool) {
        guard enabled != systemAudioEnabled, !isCaptureStopped else { return }

        systemAudioEnabled = enabled
        Log.audio.info("System audio capture \(enabled ? "enabled" : "disabled", privacy: .public)")

        guard enabled else {
            systemRetryTimer?.invalidate()
            systemRetryTimer = nil
            // An attachment that is still running was asked for by the capture being switched off
            // here, so its result must not install itself when it lands.
            systemAttachmentGeneration += 1
            systemAttachmentPending = false
            systemTap?.stop()
            systemTap = nil
            systemTapAttachedAt = nil
            systemState = .off
            systemSilent = false
            return
        }

        systemRetriesLeft = 15
        systemState = .pending
        systemPeak = 0
        systemSilent = false
        systemAudioStartedAt = Date()
        reportedEmptySystemTap = false
        startSystemAudio()
    }

    var sortedLines: [TranscriptLine] {
        lines.sorted { $0.offset < $1.offset }
    }

    /// What the live views show. Unlike the other transcript options, this one is read on every
    /// access instead of being captured at init, so hiding or showing the microphone track takes
    /// effect during the recording. Saving uses `sortedLines`, so hidden lines are still stored.
    var visibleLines: [TranscriptLine] {
        guard settings.liveTranscriptShowsMySpeech else {
            return sortedLines.filter { $0.source != .me }
        }
        return sortedLines
    }

    var echoGateEnabled: Bool {
        echoReference != nil
    }

    var systemAudioSourceName: String {
        detected.audioSourceDisplayName
    }

    // MARK: - Sources

    // Capture callbacks run on Core Audio's threads, so they capture the writer and the
    // transcriber directly instead of reaching back through `self`. Those objects are internally
    // synchronised; this session's stored properties are main-actor state and must not be touched
    // from an audio thread.
    private func startMicrophone() {
        refreshMicrophoneDeviceName()

        do {
            let format = try microphone.prepare()
            let transcriber = micTranscriber
            let writer = try AudioTrackWriter(
                url: MeetingLibrary.micTrackURL(for: meetingID),
                sourceFormat: format,
                label: "mic",
                timelineStartUptime: captureStartedAtUptime
            ) { samples in
                transcriber?.feed(samples)
            }
            micWriter = writer

            try microphone.start { buffer in
                writer.append(buffer)
            }

            micState = .capturing
        } catch {
            Log.audio.error("Microphone failed: \(error, privacy: .public)")
            micState = .unavailable(error.localizedDescription)
        }
    }

    private func startSystemAudio() {
        // The retry below fires from a timer, so a switch flipped in between has to be honoured
        // here rather than only at the call sites.
        guard systemAudioEnabled else { return }

        // Core Audio only lists a process once it has touched audio, so right after a meeting
        // starts the conferencing app may not be there yet. Retry once a second for 15 seconds.
        guard attachSystemTap() else {
            guard systemRetriesLeft > 0 else {
                systemState = .unavailable("Could not find the meeting app's audio stream")
                return
            }
            systemRetriesLeft -= 1
            let timer = Timer(timeInterval: 1, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.startSystemAudio() }
            }
            RunLoop.main.add(timer, forMode: .common)
            systemRetryTimer = timer
            return
        }
    }

    private func attachSystemTap() -> Bool {
        // One attachment at a time. The one in flight picks this request up when it lands, which
        // is also what keeps a superseded attachment from being replaced before it has torn itself
        // down.
        guard !systemAttachmentInFlight else {
            systemAttachmentPending = true
            return true
        }

        let scope: SystemAudioTap.Scope
        if detected.capturesAllSystemAudio {
            let ownBundleID = Bundle.main.bundleIdentifier ?? "com.kovalev.MeetingHelper"
            let ownObjectIDs = AudioProcessLookup.matches(prefixes: [ownBundleID]).map(\.objectID)
            scope = .allSystemAudio(excluding: ownObjectIDs)
        } else {
            let objectIDs = AudioProcessLookup.matches(prefixes: detected.audioPrefixes).map(\.objectID)
            guard !objectIDs.isEmpty else { return false }
            scope = .processes(objectIDs)
        }

        let tap = SystemAudioTap(scope: scope)
        let transcriber = systemTranscriber
        let reference = echoReference
        let url = MeetingLibrary.systemTrackURL(for: meetingID)
        let timelineStartUptime = captureStartedAtUptime
        // Capture switched back on: keep writing into the track that is already open, so the
        // recording keeps one system track and the writer pads the pause with silence. A new
        // writer on the same URL would truncate what was recorded before the pause.
        let existingWriter = systemWriter

        systemAttachmentGeneration += 1
        systemAttachmentInFlight = true
        let generation = systemAttachmentGeneration

        // Preparing and starting the tap wait on Core Audio with bounded sleeps that can add up
        // to over a second, so they run off the main thread — the interface must not freeze at
        // the start of every meeting.
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<AudioTrackWriter, Error> = Result {
                try tap.prepare()
                guard let format = tap.format else {
                    throw CoreAudioError("System audio format unavailable")
                }
                let writer = try existingWriter ?? AudioTrackWriter(
                    url: url,
                    sourceFormat: format,
                    label: "system",
                    timelineStartUptime: timelineStartUptime
                ) { samples in
                    reference?.append(samples)
                    transcriber?.feed(samples)
                }
                try tap.start { buffer in
                    writer.append(buffer)
                }
                return writer
            }
            Task { @MainActor in
                self.finishSystemTapAttachment(
                    tap,
                    generation: generation,
                    result: result,
                    reusesWriter: existingWriter != nil
                )
            }
        }
        return true
    }

    /// Lands the asynchronous tap attachment back on the session, or tears it down when the
    /// recording stopped — or system audio was switched off — while the tap was still attaching.
    private func finishSystemTapAttachment(
        _ tap: SystemAudioTap,
        generation: Int,
        result: Result<AudioTrackWriter, Error>,
        reusesWriter: Bool
    ) {
        systemAttachmentInFlight = false
        defer { resumeSystemAudioIfRequested() }

        // Stale once the recording stopped, once capture was switched off, or once a later switch
        // superseded this attempt. In all three the tap is torn down instead of installed.
        let isStale = generation != systemAttachmentGeneration
            || isCaptureStopped
            || !systemAudioEnabled

        switch result {
        case .success(let writer):
            guard !isStale else {
                tap.stop()
                // A reused writer belongs to a track that already holds audio and stays open: it
                // is this session's, `stop()` is closing it and reading its length, and switching
                // capture back on writes into it again. Only a track this attachment opened itself
                // is closed and removed here, which also discards the sliver of audio the tap can
                // deliver between starting and landing.
                guard !reusesWriter else { return }
                writer.finish()
                try? FileManager.default.removeItem(at: MeetingLibrary.systemTrackURL(for: meetingID))
                return
            }
            systemWriter = writer
            systemTap = tap
            systemTapAttachedAt = Date()
        case .failure(let error):
            Log.audio.error("System tap failed: \(error, privacy: .public)")
            tap.stop()
            guard !isStale else { return }
            systemState = .unavailable(error.localizedDescription)
        }
    }

    /// Starts the attachment that was asked for while another one was still running. Nothing to do
    /// when that attachment installed itself: it is the capture the switch asked for.
    private func resumeSystemAudioIfRequested() {
        guard systemAttachmentPending else { return }
        systemAttachmentPending = false
        guard !isCaptureStopped, systemAudioEnabled, systemTap == nil else { return }
        startSystemAudio()
    }

    private func startTranscription() {
        guard let model = transcriptionModel else {
            transcriptionState = .disabled
            return
        }

        let language = settings.language.whisperCode

        micTranscriber = SourceTranscriber(
            source: .me,
            engine: engine,
            model: model,
            language: language,
            realtimeUpdatesEnabled: realtimeTranscriptEnabled,
            echoReference: echoReference,
            onEchoVerdict: { [weak self] verdict in
                self?.receive(verdict)
            }
        ) { [weak self] update in
            self?.receive(update)
        }
        systemTranscriber = SourceTranscriber(
            source: .others,
            engine: engine,
            model: model,
            language: language,
            realtimeUpdatesEnabled: realtimeTranscriptEnabled,
            attribute: attributeHandler()
        ) { [weak self] update in
            self?.receive(update)
        }

        transcriptionState = TranscriptionEngine.isDownloaded(model)
            ? .preparing(TranscriptionEngine.initialPreparationStage(for: model))
            : .downloading(nil)
        Task { [engine] in
            do {
                try await engine.prepare(
                    model: model,
                    onProgress: { [weak self] fraction in
                        Task { @MainActor in
                            self?.transcriptionState = fraction < 1
                                ? .downloading(fraction)
                                : .preparing(TranscriptionEngine.initialPreparationStage(for: model))
                        }
                    },
                    onPreparationStage: { [weak self] stage in
                        Task { @MainActor in
                            self?.transcriptionState = .preparing(stage)
                        }
                    }
                )
                transcriptionState = .running
            } catch {
                transcriptionState = .failed(error.localizedDescription)
            }
        }
    }

    /// Loads the speaker models in the background and seeds them with the voices of the people on
    /// the invitation. Utterances that arrive before it is ready simply carry no voice.
    private func prepareSpeakerAttribution() {
        guard let attributor else { return }

        let profiles = profileStore.profiles(for: roster.attendees)
        Task { await attributor.prepare(with: profiles) }
    }

    private func attributeHandler() -> (@Sendable ([Float], TimeInterval) async -> String?)? {
        guard let attributor else { return nil }

        return { [weak self] samples, duration in
            guard let assignment = await attributor.assign(samples, duration: duration) else {
                return nil
            }
            await self?.note(assignment)
            return assignment.id
        }
    }

    private func note(_ assignment: SpeakerAttributor.Assignment) {
        roster.note(assignment.id, recognizedAs: assignment.profileEmail)
    }

    private func receive(_ update: SourceTranscriptionUpdate) {
        switch update {
        case .preview(let line):
            noteRecognitionRecovered()
            previewLineIDs.insert(line.id)
            if let index = lines.firstIndex(where: { $0.id == line.id }) {
                lines[index] = line
            } else {
                lines.append(line)
            }
        case .final(let line):
            noteRecognitionRecovered()
            previewLineIDs.remove(line.id)
            lines.removeAll { $0.id == line.id }
            if transcriptDeduplicationEnabled {
                TranscriptDeduplicator.insert(line, into: &lines)
            } else {
                lines.append(line)
            }
        case .removePreview(let id):
            previewLineIDs.remove(id)
            lines.removeAll { $0.id == id }
        }
    }

    /// A line can arrive while the state still says `failed`: the engine retries a failed model
    /// load on a cooldown, and seeing output is the only report that the retry succeeded. The
    /// state has to say `running` again so stopping waits for the transcription backlog.
    private func noteRecognitionRecovered() {
        if case .failed = transcriptionState {
            transcriptionState = .running
        }
    }

    private func discardAllPreviews() {
        lines.removeAll { previewLineIDs.contains($0.id) }
        previewLineIDs.removeAll()
    }

    private func receive(_ verdict: EchoVerdict) {
        switch verdict {
        case .echo:
            echoGateChecked += 1
            echoGateFiltered += 1
            lastEchoDropAt = Date()
            echoGateFiring = true
        case .speech:
            echoGateChecked += 1
        case .undecided:
            break
        }
    }

    private func tick() {
        elapsed = Date().timeIntervalSince(startedAt)
        micLevel = micWriter?.level ?? 0
        // The writer keeps its last level after the tap detaches, so a switched-off track has to
        // read as silent rather than freezing the meter at whatever was playing.
        systemLevel = systemAudioEnabled ? (systemWriter?.level ?? 0) : 0
        refreshMicrophoneDeviceName()

        if systemState == .pending, systemTap?.hasDeliveredAudio == true {
            systemState = .capturing
        }
        reportEmptySystemTapIfNeeded()

        systemPeak = max(systemPeak, systemLevel)
        let systemIsAvailable: Bool
        if case .unavailable = systemState {
            systemIsAvailable = false
        } else {
            systemIsAvailable = true
        }
        systemSilent = systemAudioEnabled
            && systemIsAvailable
            && Date().timeIntervalSince(systemAudioStartedAt) > 20
            && systemPeak < 0.0005

        if let lastEchoDropAt, Date().timeIntervalSince(lastEchoDropAt) > 3 {
            echoGateFiring = false
        }
    }

    /// A tap that never delivers a buffer leaves no trace of its own: Core Audio reports no error,
    /// the track keeps its bare header, and the meeting is saved without a system track. That is
    /// what happens when the tap is scoped to an app that holds the microphone without playing
    /// anything, so record which source was tapped — it is the only clue after the fact.
    private func reportEmptySystemTapIfNeeded() {
        guard !reportedEmptySystemTap,
              systemAudioEnabled,
              let systemTapAttachedAt,
              systemTap?.hasDeliveredAudio == false,
              Date().timeIntervalSince(systemTapAttachedAt) > Self.emptySystemTapReportDelay
        else { return }

        reportedEmptySystemTap = true
        Log.audio.error(
            """
            System tap on \(self.systemAudioSourceName, privacy: .public) has delivered no audio in \
            \(Self.emptySystemTapReportDelay, privacy: .public) seconds; that source is most likely \
            capturing the microphone without playing anything
            """
        )
    }

    private func refreshMicrophoneDeviceName() {
        let detectedName = try? AudioObjectID.readDefaultInputDevice().readDeviceName()
        let name = detectedName.flatMap { $0.isEmpty ? nil : $0 } ?? "Unknown microphone"
        guard name != microphoneDeviceName else { return }

        microphoneDeviceName = name
    }
}
