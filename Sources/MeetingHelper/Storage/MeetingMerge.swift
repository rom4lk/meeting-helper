import AVFoundation
import Foundation

/// Joins several recordings into a single meeting.
///
/// The recordings are placed back to back with no gap between them, so the merged timeline is
/// shorter than the wall clock says: the pause between two recordings disappears. Each part keeps
/// the moment it was actually recorded in `Meeting.mergedSegments`.
///
/// Split in two on purpose. `plan` decides what the result looks like and where every part lands
/// on the timeline, which is arithmetic worth testing on its own; `perform` does the file work,
/// which is minutes of I/O and runs off the main actor.
enum MeetingMerge {
    enum Failure: LocalizedError {
        case tooFewMeetings
        case duplicateMeetings
        case emptySources
        case missingDirectory(UUID)
        case unreadableTrack(UUID, track: String)
        case notEnoughDiskSpace(required: Int64)

        var errorDescription: String? {
            switch self {
            case .tooFewMeetings:
                return "Merging needs at least two recordings."
            case .duplicateMeetings:
                return "The same recording cannot be merged with itself."
            case .emptySources:
                return "The selected recordings hold no audio."
            case .missingDirectory(let id):
                return "The recording \(id.uuidString) is no longer in the library."
            case .unreadableTrack(let id, let track):
                return """
                    The \(track) audio of recording \(id.uuidString) is missing or unreadable, \
                    so merging would silently drop it.
                    """
            case .notEnoughDiskSpace(let required):
                let size = ByteCountFormatter.string(fromByteCount: required, countStyle: .file)
                return "Merging needs about \(size) of free disk space."
            }
        }
    }

    /// One source recording and the stretch of the merged timeline it occupies.
    struct PlannedSegment {
        let meeting: Meeting
        let offsetFrames: AVAudioFramePosition
        /// Length of the stretch, the longer of the recording's two tracks. Both tracks are padded
        /// with silence to fill it, which is what keeps the microphone and the system track of the
        /// next segment starting at the same offset.
        let spanFrames: AVAudioFramePosition
        /// `nil` when the recording has no track of this kind, in which case its whole span is
        /// silence.
        let micURL: URL?
        let systemURL: URL?

        var offset: TimeInterval { Double(offsetFrames) / AudioTrackWriter.sampleRate }
        var span: TimeInterval { Double(spanFrames) / AudioTrackWriter.sampleRate }
    }

    struct Plan {
        let meeting: Meeting
        let segments: [PlannedSegment]

        var totalFrames: AVAudioFramePosition {
            segments.reduce(0) { $0 + $1.spanFrames }
        }
    }

    /// Separates the raw values of recordings that disagree on their kind or their model.
    static let valueSeparator = " + "

    // MARK: - Planning

    static func plan(
        merging meetings: [Meeting],
        title: String,
        newID: UUID = UUID(),
        in root: URL = MeetingLibrary.root
    ) throws -> Plan {
        guard meetings.count >= 2 else { throw Failure.tooFewMeetings }
        guard Set(meetings.map(\.id)).count == meetings.count else { throw Failure.duplicateMeetings }

        // Recording order decides the merge order, and the tie-break keeps it reproducible for two
        // recordings that somehow share a start.
        let ordered = meetings.sorted {
            $0.startedAt == $1.startedAt
                ? $0.id.uuidString < $1.id.uuidString
                : $0.startedAt < $1.startedAt
        }

        var segments: [PlannedSegment] = []
        var offsetFrames: AVAudioFramePosition = 0
        for meeting in ordered {
            let directory = MeetingLibrary.directory(for: meeting.id, in: root)
            guard FileManager.default.fileExists(atPath: directory.path) else {
                throw Failure.missingDirectory(meeting.id)
            }

            // The lengths come from the files rather than from `Meeting.duration`, which also
            // counts the wall clock and is therefore almost always longer than either track.
            let micURL = MeetingLibrary.micTrackURL(for: meeting.id, in: root)
            let systemURL = MeetingLibrary.systemTrackURL(for: meeting.id, in: root)
            let micFrames = TrackConcatenation.frameCount(at: micURL)
            let systemFrames = TrackConcatenation.frameCount(at: systemURL)

            // A track the recording says it has but the disk cannot produce would be padded with
            // silence for its whole span, and the merge would look like it worked. That is worth
            // refusing: with the originals deleted afterwards, their mixdown goes with them, and
            // the audio would be gone for good.
            if meeting.hasMicTrack, micFrames <= 0 {
                throw Failure.unreadableTrack(meeting.id, track: "microphone")
            }
            if meeting.hasSystemTrack, systemFrames <= 0 {
                throw Failure.unreadableTrack(meeting.id, track: "system")
            }

            segments.append(PlannedSegment(
                meeting: meeting,
                offsetFrames: offsetFrames,
                spanFrames: max(micFrames, systemFrames),
                micURL: micFrames > 0 ? micURL : nil,
                systemURL: systemFrames > 0 ? systemURL : nil
            ))
            offsetFrames += max(micFrames, systemFrames)
        }

        guard offsetFrames > 0 else { throw Failure.emptySources }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let merged = Meeting(
            id: newID,
            title: trimmedTitle.isEmpty ? ordered[0].title : trimmedTitle,
            kind: combinedKind(of: ordered),
            startedAt: ordered[0].startedAt,
            duration: Double(offsetFrames) / AudioTrackWriter.sampleRate,
            hasMicTrack: segments.contains { $0.micURL != nil },
            hasSystemTrack: segments.contains { $0.systemURL != nil },
            transcriptionModel: combinedTranscriptionModel(of: ordered),
            calendar: ordered.compactMap(\.calendar).first,
            speakers: mergedSpeakers(of: segments),
            mergedSegments: provenance(of: segments)
        )

        return Plan(meeting: merged, segments: segments)
    }

    /// Shifts every source transcript onto the merged timeline.
    static func transcript(
        for plan: Plan,
        transcripts: [UUID: [TranscriptLine]]
    ) -> [TranscriptLine] {
        plan.segments
            .flatMap { segment in
                (transcripts[segment.meeting.id] ?? []).map { line in
                    // A line cannot be allowed past the end of its own segment, or it would land
                    // inside the next one.
                    let offset = min(max(line.offset, 0), segment.span)
                    return TranscriptLine(
                        id: line.id,
                        source: line.source,
                        offset: segment.offset + offset,
                        text: line.text,
                        speakerID: line.speakerID.map { speakerID($0, in: segment.meeting) }
                    )
                }
            }
            .sorted { $0.offset < $1.offset }
    }

    /// Voices are numbered from one inside each recording, so the same id in two of them stands for
    /// two different people. Qualifying every id with the recording it came from keeps them apart.
    /// Collapsing them instead would claim a resemblance nothing has measured.
    private static func speakerID(_ id: String, in meeting: Meeting) -> String {
        "\(meeting.id.uuidString):\(id)"
    }

    private static func mergedSpeakers(of segments: [PlannedSegment]) -> [MeetingSpeaker]? {
        var merged: [MeetingSpeaker] = []
        for segment in segments {
            for speaker in segment.meeting.speakers ?? [] {
                merged.append(MeetingSpeaker(
                    id: speakerID(speaker.id, in: segment.meeting),
                    ordinal: merged.count + 1,
                    name: speaker.name,
                    attendeeEmail: speaker.attendeeEmail
                ))
            }
        }
        return merged.isEmpty ? nil : merged
    }

    /// A merged recording contributes the parts it was made of rather than itself, so merging a
    /// merge keeps naming the original recordings.
    private static func provenance(of segments: [PlannedSegment]) -> [MergedMeetingSegment] {
        segments.flatMap { segment -> [MergedMeetingSegment] in
            guard let inner = segment.meeting.mergedSegments, !inner.isEmpty else {
                return [MergedMeetingSegment(
                    sourceID: segment.meeting.id,
                    title: segment.meeting.title,
                    kind: segment.meeting.kind,
                    startedAt: segment.meeting.startedAt,
                    offset: segment.offset,
                    duration: segment.span
                )]
            }
            return inner.map {
                MergedMeetingSegment(
                    sourceID: $0.sourceID,
                    title: $0.title,
                    kind: $0.kind,
                    startedAt: $0.startedAt,
                    offset: segment.offset + $0.offset,
                    duration: $0.duration
                )
            }
        }
    }

    /// Recordings of one meeting always agree here. When they do not, both values are kept — a
    /// combination decodes as `Kind.unknown`, which older versions of the app read without
    /// complaint.
    private static func combinedKind(of meetings: [Meeting]) -> DetectedMeeting.Kind {
        var rawValues: [String] = []
        for meeting in meetings where !rawValues.contains(meeting.kind.rawValue) {
            rawValues.append(meeting.kind.rawValue)
        }
        return DetectedMeeting.Kind(rawValue: rawValues.joined(separator: valueSeparator))
    }

    private static func combinedTranscriptionModel(of meetings: [Meeting]) -> String? {
        var models: [String] = []
        for meeting in meetings {
            guard let model = meeting.transcriptionModel, !models.contains(model) else { continue }
            models.append(model)
        }
        return models.isEmpty ? nil : models.joined(separator: valueSeparator)
    }

    // MARK: - Writing

    /// Builds the merged recording on disk and installs it in the library.
    ///
    /// Everything is assembled in a hidden staging directory first, so an interrupted merge leaves
    /// no half-written meeting behind — and the installed directory holds no `meeting.json` until
    /// the caller saves one, which is what keeps a concurrent synchronisation from picking up an
    /// incomplete meeting.
    static func perform(_ plan: Plan, in root: URL = MeetingLibrary.root) throws {
        try checkDiskSpace(for: plan, in: root)

        let fileManager = FileManager.default
        let staging = root.appendingPathComponent(".merge-\(plan.meeting.id.uuidString)", isDirectory: true)
        if fileManager.fileExists(atPath: staging.path) {
            try fileManager.removeItem(at: staging)
        }
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)

        var installed = false
        defer { if !installed { try? fileManager.removeItem(at: staging) } }

        let spans = plan.segments.map(\.spanFrames)
        let micURL = staging.appendingPathComponent("mic.wav")
        let systemURL = staging.appendingPathComponent("system.wav")

        if plan.meeting.hasMicTrack {
            try TrackConcatenation.concatenate(
                sources: plan.segments.map(\.micURL),
                spans: spans,
                outputURL: micURL
            )
        }
        if plan.meeting.hasSystemTrack {
            try TrackConcatenation.concatenate(
                sources: plan.segments.map(\.systemURL),
                spans: spans,
                outputURL: systemURL
            )
        }

        // Built from the joined tracks rather than from the sources' own mixdowns: AAC carries an
        // encoder delay, so joining the compressed files would drift away from the transcript.
        Mixdown.create(
            micURL: plan.meeting.hasMicTrack ? micURL : nil,
            systemURL: plan.meeting.hasSystemTrack ? systemURL : nil,
            outputURL: staging.appendingPathComponent("mix.m4a")
        )

        let destination = MeetingLibrary.directory(for: plan.meeting.id, in: root)
        try fileManager.moveItem(at: staging, to: destination)
        installed = true
    }

    /// Both joined tracks are 16-bit mono at 16 kHz, and the compressed mixdown is small next to
    /// them. A fifth on top covers it and the temporary copy the move never makes.
    private static func checkDiskSpace(for plan: Plan, in root: URL) throws {
        let required = Int64(Double(plan.totalFrames) * 2 * 2 * 1.2)
        let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values?.volumeAvailableCapacityForImportantUsage else { return }
        guard available < required else { return }
        throw Failure.notEnoughDiskSpace(required: required)
    }
}
