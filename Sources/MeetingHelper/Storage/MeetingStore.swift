import Foundation

@MainActor
final class MeetingStore: ObservableObject {
    enum LibraryChange {
        case updated
        case deleted(UUID)
    }

    @Published private(set) var meetings: [Meeting] = []

    var onLibraryChange: ((LibraryChange) -> Void)?

    /// Injectable so tests run against a temporary directory instead of the real library.
    private let root: URL

    /// Where this store keeps its meetings, for the operations that work on the library as a whole.
    var libraryRoot: URL { root }

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init(root: URL = MeetingLibrary.root) {
        self.root = root
        reload()
    }

    func reload() {
        let directories = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        meetings = directories
            .compactMap { directory -> Meeting? in
                let url = directory.appendingPathComponent("meeting.json")
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(Meeting.self, from: data)
            }
            .sorted { $0.startedAt > $1.startedAt }
    }

    func save(_ meeting: Meeting) throws {
        try MeetingLibrary.createDirectory(for: meeting.id, in: root)
        let data = try encoder.encode(meeting)
        try data.write(to: MeetingLibrary.metadataURL(for: meeting.id, in: root), options: .atomic)

        if let index = meetings.firstIndex(where: { $0.id == meeting.id }) {
            meetings[index] = meeting
        } else {
            meetings.insert(meeting, at: 0)
            meetings.sort { $0.startedAt > $1.startedAt }
        }
        onLibraryChange?(.updated)
    }

    func delete(_ meeting: Meeting) {
        let wasSaved = meetings.contains { $0.id == meeting.id }
        try? FileManager.default.removeItem(at: MeetingLibrary.directory(for: meeting.id, in: root))
        meetings.removeAll { $0.id == meeting.id }
        if wasSaved {
            onLibraryChange?(.deleted(meeting.id))
        }
    }

    func saveTranscript(_ lines: [TranscriptLine], for id: UUID) throws {
        try MeetingLibrary.createDirectory(for: id, in: root)
        let data = try encoder.encode(lines)
        try data.write(to: MeetingLibrary.transcriptURL(for: id, in: root), options: .atomic)
        if meetings.contains(where: { $0.id == id }) {
            onLibraryChange?(.updated)
        }
    }

    func transcript(for id: UUID) -> [TranscriptLine] {
        guard let data = try? Data(contentsOf: MeetingLibrary.transcriptURL(for: id, in: root)),
              let lines = try? decoder.decode([TranscriptLine].self, from: data)
        else { return [] }
        return lines
    }

    // MARK: - Orphan recovery

    /// Adopts meeting directories that hold audio but no `meeting.json`.
    ///
    /// Such a directory is left behind when the app crashed mid-recording, or when saving the
    /// metadata failed with the audio already on disk — a full disk being the likely cause.
    /// Without metadata the directory is invisible: `reload` skips it, synchronization ignores
    /// it, and nothing ever deletes it, so the audio would sit unreachable forever.
    ///
    /// `excludedIDs` names directories that may be interrupted sync downloads. Those are left
    /// alone: reconciliation repairs them from the complete remote copy, and adopting one here
    /// would overwrite the real metadata with a reconstruction.
    ///
    /// Called once at launch, before any recording can start — a live recording's directory
    /// also has no metadata yet and must not be adopted from under it.
    func recoverOrphanedRecordings(excluding excludedIDs: Set<UUID> = []) {
        let fileManager = FileManager.default
        let directories = (try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        var recoveredIDs: [UUID] = []
        for directory in directories {
            guard let id = UUID(uuidString: directory.lastPathComponent),
                  !excludedIDs.contains(id),
                  !fileManager.fileExists(atPath: MeetingLibrary.metadataURL(for: id, in: root).path)
            else { continue }

            let micURL = MeetingLibrary.micTrackURL(for: id, in: root)
            let systemURL = MeetingLibrary.systemTrackURL(for: id, in: root)
            let micFrames = TrackConcatenation.frameCount(at: micURL)
            let systemFrames = TrackConcatenation.frameCount(at: systemURL)
            let frames = max(micFrames, systemFrames)
            // A directory with no readable audio holds nothing worth presenting as a meeting.
            guard frames > 0 else { continue }

            let meeting = Meeting(
                id: id,
                title: "Recovered recording",
                kind: .unknown("recovered"),
                startedAt: recordingStart(of: directory, micURL: micURL, systemURL: systemURL),
                duration: Double(frames) / AudioTrackWriter.sampleRate,
                hasMicTrack: micFrames > 0,
                hasSystemTrack: systemFrames > 0
            )
            do {
                try save(meeting)
                recoveredIDs.append(id)
                Log.store.notice(
                    "Recovered an orphaned recording of \(meeting.duration, privacy: .public) seconds"
                )
            } catch {
                Log.store.error("Cannot recover an orphaned recording: \(error, privacy: .public)")
            }
        }

        rebuildMissingMixdowns(for: recoveredIDs)
    }

    /// The track files are created as the recording starts, so their creation date is when it
    /// began — unlike the modification date, which advances with every buffer written.
    private func recordingStart(of directory: URL, micURL: URL, systemURL: URL) -> Date {
        let candidates = [micURL, systemURL, directory].compactMap { url in
            (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
        }
        return candidates.min() ?? Date()
    }

    /// A recording that never reached its normal stop has no `mix.m4a`. Build it from the
    /// recovered tracks in the background, so the meeting can be played back and not only listed.
    private func rebuildMissingMixdowns(for ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let root = self.root
        Task.detached(priority: .utility) {
            for id in ids {
                let mixURL = MeetingLibrary.mixdownURL(for: id, in: root)
                guard !FileManager.default.fileExists(atPath: mixURL.path) else { continue }
                _ = Mixdown.create(
                    micURL: MeetingLibrary.micTrackURL(for: id, in: root),
                    systemURL: MeetingLibrary.systemTrackURL(for: id, in: root),
                    outputURL: mixURL
                )
            }
        }
    }
}
