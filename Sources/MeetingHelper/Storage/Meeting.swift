import Foundation

struct Meeting: Identifiable, Codable, Hashable {
    static let deletionConfirmationThreshold: TimeInterval = 5 * 60

    let id: UUID
    var title: String
    var kind: DetectedMeeting.Kind
    var startedAt: Date
    var duration: TimeInterval
    var hasMicTrack: Bool
    var hasSystemTrack: Bool
    var transcriptionModel: String?
    /// The calendar event this recording was matched to, if there was one. Optional both because
    /// most manual recordings have none and because meetings recorded before calendar support
    /// exists must keep decoding.
    var calendar: MeetingCalendarInfo?
    /// The distinct voices heard on the "Others" track, and what each is called. `nil` when speaker
    /// attribution was off, and for meetings recorded before it existed.
    var speakers: [MeetingSpeaker]?
    /// The recordings this meeting was merged from, in the order they were joined. `nil` for an
    /// ordinary recording, and for meetings saved before merging existed.
    var mergedSegments: [MergedMeetingSegment]?

    init(
        id: UUID = UUID(),
        title: String,
        kind: DetectedMeeting.Kind,
        startedAt: Date = Date(),
        duration: TimeInterval = 0,
        hasMicTrack: Bool = false,
        hasSystemTrack: Bool = false,
        transcriptionModel: String? = nil,
        calendar: MeetingCalendarInfo? = nil,
        speakers: [MeetingSpeaker]? = nil,
        mergedSegments: [MergedMeetingSegment]? = nil
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.startedAt = startedAt
        self.duration = duration
        self.hasMicTrack = hasMicTrack
        self.hasSystemTrack = hasSystemTrack
        self.transcriptionModel = transcriptionModel
        self.calendar = calendar
        self.speakers = speakers
        self.mergedSegments = mergedSegments
    }

    var formattedDuration: String { duration.clockString }

    var requiresDeletionConfirmation: Bool {
        duration > Self.deletionConfirmationThreshold
    }

    func shouldBeSaved(minimumDuration: TimeInterval) -> Bool {
        duration >= minimumDuration
    }

    /// What the detail view calls this meeting's kind.
    ///
    /// A merge of recordings with different kinds stores their raw values joined together, which
    /// `Kind` decodes as `.unknown` and would otherwise show as a flat "Other".
    var kindDisplayName: String {
        guard let mergedSegments, !mergedSegments.isEmpty else { return kind.displayName }

        var names: [String] = []
        for segment in mergedSegments where !names.contains(segment.kind.displayName) {
            names.append(segment.kind.displayName)
        }
        return names.joined(separator: " + ")
    }
}

/// One recording that went into a merged meeting.
///
/// The merged timeline joins the recordings back to back and drops the gaps between them, so this
/// is the only place where the moment each part was actually recorded survives.
struct MergedMeetingSegment: Codable, Hashable {
    let sourceID: UUID
    let title: String
    let kind: DetectedMeeting.Kind
    let startedAt: Date
    /// Seconds from the start of the merged recording.
    let offset: TimeInterval
    let duration: TimeInterval
}

/// On-disk layout. One directory per meeting keeps everything inspectable with Finder and
/// makes a partially written recording survivable — a crash costs at most the last buffer.
/// The library root is a parameter with a default rather than a constant so that tests can run
/// against a temporary directory instead of the user's real recordings.
enum MeetingLibrary {
    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeetingHelper", isDirectory: true)
            .appendingPathComponent("Meetings", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    static func directory(for id: UUID, in root: URL = root) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    @discardableResult
    static func createDirectory(for id: UUID, in root: URL = root) throws -> URL {
        let url = directory(for: id, in: root)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func metadataURL(for id: UUID, in root: URL = root) -> URL {
        directory(for: id, in: root).appendingPathComponent("meeting.json")
    }

    static func transcriptURL(for id: UUID, in root: URL = root) -> URL {
        directory(for: id, in: root).appendingPathComponent("transcript.json")
    }

    static func micTrackURL(for id: UUID, in root: URL = root) -> URL {
        directory(for: id, in: root).appendingPathComponent("mic.wav")
    }

    static func systemTrackURL(for id: UUID, in root: URL = root) -> URL {
        directory(for: id, in: root).appendingPathComponent("system.wav")
    }

    static func mixdownURL(for id: UUID, in root: URL = root) -> URL {
        directory(for: id, in: root).appendingPathComponent("mix.m4a")
    }
}
