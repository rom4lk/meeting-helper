import AVFoundation
import XCTest
@testable import MeetingHelper

@MainActor
final class MeetingMergeTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingMergeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
    }

    // MARK: - Planning

    /// The span of a recording is the longer of its two tracks, because both are padded to it.
    func testSegmentStartsAfterTheLongerTrackOfThePreviousOne() throws {
        let first = try makeRecording(startedAt: .distantPast, micSeconds: 10, systemSeconds: 7)
        let second = try makeRecording(startedAt: Date(), micSeconds: 5, systemSeconds: 5)

        let plan = try MeetingMerge.plan(merging: [first, second], title: "Joined", in: root)

        XCTAssertEqual(plan.segments[0].offset, 0)
        XCTAssertEqual(plan.segments[1].offset, 10)
        XCTAssertEqual(plan.segments[0].span, 10)
        XCTAssertEqual(plan.meeting.duration, 15)
    }

    func testRecordingsAreJoinedInRecordingOrder() throws {
        let earlier = try makeRecording(
            title: "Earlier",
            startedAt: Date(timeIntervalSince1970: 1_000),
            micSeconds: 2,
            systemSeconds: nil
        )
        let later = try makeRecording(
            title: "Later",
            startedAt: Date(timeIntervalSince1970: 2_000),
            micSeconds: 3,
            systemSeconds: nil
        )

        let plan = try MeetingMerge.plan(merging: [later, earlier], title: "Joined", in: root)

        XCTAssertEqual(plan.segments.map(\.meeting.title), ["Earlier", "Later"])
        XCTAssertEqual(plan.meeting.startedAt, earlier.startedAt)
    }

    func testTranscriptOfTheSecondRecordingIsShiftedOntoTheMergedTimeline() throws {
        let first = try makeRecording(startedAt: .distantPast, micSeconds: 10, systemSeconds: 7)
        let second = try makeRecording(startedAt: Date(), micSeconds: 5, systemSeconds: 5)
        let plan = try MeetingMerge.plan(merging: [first, second], title: "Joined", in: root)

        let lines = MeetingMerge.transcript(for: plan, transcripts: [
            first.id: [
                TranscriptLine(source: .me, offset: 1, text: "First, me"),
                TranscriptLine(source: .others, offset: 6, text: "First, them")
            ],
            second.id: [
                TranscriptLine(source: .others, offset: 2, text: "Second, them")
            ]
        ])

        XCTAssertEqual(lines.map(\.offset), [1, 6, 12])
        XCTAssertEqual(lines.map(\.text), ["First, me", "First, them", "Second, them"])
    }

    /// Both tracks of a segment are padded to the same span, so one shift covers both sources.
    func testBothTrackSourcesAreShiftedByTheSameAmount() throws {
        let first = try makeRecording(startedAt: .distantPast, micSeconds: 10, systemSeconds: 7)
        let second = try makeRecording(startedAt: Date(), micSeconds: 5, systemSeconds: 5)
        let plan = try MeetingMerge.plan(merging: [first, second], title: "Joined", in: root)

        let lines = MeetingMerge.transcript(for: plan, transcripts: [
            second.id: [
                TranscriptLine(source: .me, offset: 3, text: "Me"),
                TranscriptLine(source: .others, offset: 3, text: "Them")
            ]
        ])

        XCTAssertEqual(lines.map(\.offset), [13, 13])
    }

    func testTranscriptLineIsClampedToItsOwnSegment() throws {
        let first = try makeRecording(startedAt: .distantPast, micSeconds: 4, systemSeconds: nil)
        let second = try makeRecording(startedAt: Date(), micSeconds: 4, systemSeconds: nil)
        let plan = try MeetingMerge.plan(merging: [first, second], title: "Joined", in: root)

        let lines = MeetingMerge.transcript(for: plan, transcripts: [
            first.id: [TranscriptLine(source: .me, offset: 9, text: "Past the end")]
        ])

        XCTAssertEqual(lines.map(\.offset), [4])
    }

    // MARK: - Metadata

    func testMatchingKindAndModelSurviveTheMerge() throws {
        let first = try makeRecording(
            kind: .zoom,
            startedAt: .distantPast,
            micSeconds: 1,
            systemSeconds: nil,
            transcriptionModel: "openai_whisper-large-v3"
        )
        let second = try makeRecording(
            kind: .zoom,
            startedAt: Date(),
            micSeconds: 1,
            systemSeconds: nil,
            transcriptionModel: "openai_whisper-large-v3"
        )

        let plan = try MeetingMerge.plan(merging: [first, second], title: "Joined", in: root)

        XCTAssertEqual(plan.meeting.kind, .zoom)
        XCTAssertEqual(plan.meeting.transcriptionModel, "openai_whisper-large-v3")
    }

    func testDifferingKindAndModelAreCombined() throws {
        let first = try makeRecording(
            kind: .zoom,
            startedAt: .distantPast,
            micSeconds: 1,
            systemSeconds: nil,
            transcriptionModel: "openai_whisper-large-v3"
        )
        let second = try makeRecording(
            kind: .manual,
            startedAt: Date(),
            micSeconds: 1,
            systemSeconds: nil,
            transcriptionModel: nil
        )

        let plan = try MeetingMerge.plan(merging: [first, second], title: "Joined", in: root)

        XCTAssertEqual(plan.meeting.kind, .unknown("zoom + manual"))
        XCTAssertEqual(plan.meeting.kindDisplayName, "Zoom + Manual")
        XCTAssertEqual(plan.meeting.transcriptionModel, "openai_whisper-large-v3")
    }

    func testCombinedModelIsNamedPartByPart() {
        let combined = "openai_whisper-large-v3 + openai_whisper-large-v3-v20240930_turbo"

        XCTAssertEqual(
            AppSettings.displayName(forModel: combined),
            "Whisper large-v3 + Whisper large-v3 turbo"
        )
    }

    /// A combined kind must survive a round trip through the library, where older versions of the
    /// app read it as an unknown kind rather than failing.
    func testCombinedKindRoundTripsThroughTheStore() throws {
        let first = try makeRecording(kind: .zoom, startedAt: .distantPast, micSeconds: 1, systemSeconds: nil)
        let second = try makeRecording(kind: .manual, startedAt: Date(), micSeconds: 1, systemSeconds: nil)
        let plan = try MeetingMerge.plan(merging: [first, second], title: "Joined", in: root)
        let store = MeetingStore(root: root)

        try store.save(plan.meeting)

        let reopened = MeetingStore(root: root).meetings.first { $0.id == plan.meeting.id }
        XCTAssertEqual(reopened?.kind, .unknown("zoom + manual"))
        XCTAssertEqual(reopened?.mergedSegments?.map(\.title), [first.title, second.title])
    }

    func testCalendarComesFromTheFirstRecordingThatHasOne() throws {
        let event = CalendarEvent(
            id: "event",
            iCalUID: "ical",
            calendarTitle: "Work",
            title: "Weekly sync",
            start: Date(),
            end: Date(),
            organizerEmail: "lead@example.com",
            attendees: [],
            conferenceURLs: []
        )
        let first = try makeRecording(startedAt: .distantPast, micSeconds: 1, systemSeconds: nil)
        let second = try makeRecording(
            startedAt: Date(),
            micSeconds: 1,
            systemSeconds: nil,
            calendar: MeetingCalendarInfo(event: event)
        )

        let plan = try MeetingMerge.plan(merging: [first, second], title: "Joined", in: root)

        XCTAssertEqual(plan.meeting.calendar?.title, "Weekly sync")
    }

    func testMergingAMergeKeepsTheOriginalRecordings() throws {
        let alreadyMerged = try makeRecording(
            title: "Already merged",
            startedAt: .distantPast,
            micSeconds: 6,
            systemSeconds: nil,
            mergedSegments: [
                MergedMeetingSegment(
                    sourceID: UUID(),
                    title: "Part one",
                    kind: .zoom,
                    startedAt: Date(timeIntervalSince1970: 1_000),
                    offset: 0,
                    duration: 2
                ),
                MergedMeetingSegment(
                    sourceID: UUID(),
                    title: "Part two",
                    kind: .zoom,
                    startedAt: Date(timeIntervalSince1970: 2_000),
                    offset: 2,
                    duration: 4
                )
            ]
        )
        let third = try makeRecording(title: "Part three", startedAt: Date(), micSeconds: 3, systemSeconds: nil)

        let plan = try MeetingMerge.plan(merging: [alreadyMerged, third], title: "Joined", in: root)

        let segments = try XCTUnwrap(plan.meeting.mergedSegments)
        XCTAssertEqual(segments.map(\.title), ["Part one", "Part two", "Part three"])
        XCTAssertEqual(segments.map(\.offset), [0, 2, 6])
    }

    // MARK: - Refusals

    func testRefusesASingleRecording() throws {
        let only = try makeRecording(startedAt: Date(), micSeconds: 1, systemSeconds: nil)

        XCTAssertThrowsError(try MeetingMerge.plan(merging: [only], title: "Joined", in: root))
    }

    func testRefusesTheSameRecordingTwice() throws {
        let meeting = try makeRecording(startedAt: Date(), micSeconds: 1, systemSeconds: nil)

        XCTAssertThrowsError(
            try MeetingMerge.plan(merging: [meeting, meeting], title: "Joined", in: root)
        )
    }

    func testRefusesARecordingThatLeftTheLibrary() throws {
        let present = try makeRecording(startedAt: .distantPast, micSeconds: 1, systemSeconds: nil)
        let absent = Meeting(title: "Gone", kind: .manual, startedAt: Date())

        XCTAssertThrowsError(
            try MeetingMerge.plan(merging: [present, absent], title: "Joined", in: root)
        )
    }

    func testRefusesRecordingsWithoutAnyAudio() throws {
        let first = try makeRecording(startedAt: .distantPast, micSeconds: nil, systemSeconds: nil)
        let second = try makeRecording(startedAt: Date(), micSeconds: nil, systemSeconds: nil)

        XCTAssertThrowsError(
            try MeetingMerge.plan(merging: [first, second], title: "Joined", in: root)
        )
    }

    // MARK: - Writing

    func testJoinedTracksShareOneLength() throws {
        let first = try makeRecording(startedAt: .distantPast, micSeconds: 10, systemSeconds: 7)
        let second = try makeRecording(startedAt: Date(), micSeconds: 5, systemSeconds: nil)
        let plan = try MeetingMerge.plan(merging: [first, second], title: "Joined", in: root)

        try MeetingMerge.perform(plan, in: root)

        let directory = MeetingLibrary.directory(for: plan.meeting.id, in: root)
        XCTAssertEqual(try duration(of: directory.appendingPathComponent("mic.wav")), 15, accuracy: 0.001)
        XCTAssertEqual(try duration(of: directory.appendingPathComponent("system.wav")), 15, accuracy: 0.001)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("mix.m4a").path
        ))
    }

    func testMissingTrackBecomesSilenceForItsWholeSpan() throws {
        let first = try makeRecording(startedAt: .distantPast, micSeconds: 4, systemSeconds: 4)
        let second = try makeRecording(startedAt: Date(), micSeconds: 4, systemSeconds: nil)
        let plan = try MeetingMerge.plan(merging: [first, second], title: "Joined", in: root)

        try MeetingMerge.perform(plan, in: root)

        let system = MeetingLibrary.systemTrackURL(for: plan.meeting.id, in: root)
        XCTAssertGreaterThan(try peakAmplitude(of: system, from: 0, to: 4), 0.1)
        XCTAssertEqual(try peakAmplitude(of: system, from: 4, to: 8), 0, accuracy: 0.0001)
    }

    func testTrackThatNoRecordingHasIsNotWritten() throws {
        let first = try makeRecording(startedAt: .distantPast, micSeconds: nil, systemSeconds: 3)
        let second = try makeRecording(startedAt: Date(), micSeconds: nil, systemSeconds: 3)
        let plan = try MeetingMerge.plan(merging: [first, second], title: "Joined", in: root)

        try MeetingMerge.perform(plan, in: root)

        XCTAssertFalse(plan.meeting.hasMicTrack)
        XCTAssertTrue(plan.meeting.hasSystemTrack)
        let directory = MeetingLibrary.directory(for: plan.meeting.id, in: root)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("mic.wav").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("mix.m4a").path
        ))
    }

    func testStagingDirectoryDoesNotSurviveTheMerge() throws {
        let first = try makeRecording(startedAt: .distantPast, micSeconds: 2, systemSeconds: nil)
        let second = try makeRecording(startedAt: Date(), micSeconds: 2, systemSeconds: nil)
        let plan = try MeetingMerge.plan(merging: [first, second], title: "Joined", in: root)

        try MeetingMerge.perform(plan, in: root)

        let leftovers = try FileManager.default
            .contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix(".merge-") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    /// The merged meeting has to be on disk before the originals go, and the originals have to go
    /// through the store — a directory removed behind its back leaves no tombstone for the
    /// synchronised copies.
    func testLibraryKeepsOnlyTheResultWhenTheOriginalsAreDeleted() throws {
        let first = try makeRecording(startedAt: .distantPast, micSeconds: 2, systemSeconds: nil)
        let second = try makeRecording(startedAt: Date(), micSeconds: 2, systemSeconds: nil)
        let store = MeetingStore(root: root)
        try store.save(first)
        try store.save(second)
        var deletedIDs: [UUID] = []
        store.onLibraryChange = { change in
            if case .deleted(let id) = change { deletedIDs.append(id) }
        }

        let plan = try MeetingMerge.plan(merging: [first, second], title: "Joined", in: root)
        try MeetingMerge.perform(plan, in: root)
        try store.save(plan.meeting)
        try store.saveTranscript(
            MeetingMerge.transcript(for: plan, transcripts: [:]),
            for: plan.meeting.id
        )
        store.delete(first)
        store.delete(second)

        XCTAssertEqual(store.meetings.map(\.id), [plan.meeting.id])
        XCTAssertEqual(Set(deletedIDs), [first.id, second.id])
        XCTAssertEqual(MeetingStore(root: root).meetings.map(\.title), ["Joined"])
    }

    // MARK: - Helpers

    private func makeRecording(
        title: String = "Recording",
        kind: DetectedMeeting.Kind = .zoom,
        startedAt: Date,
        micSeconds: Double?,
        systemSeconds: Double?,
        transcriptionModel: String? = nil,
        calendar: MeetingCalendarInfo? = nil,
        mergedSegments: [MergedMeetingSegment]? = nil
    ) throws -> Meeting {
        let id = UUID()
        try MeetingLibrary.createDirectory(for: id, in: root)
        if let micSeconds {
            try writeTone(seconds: micSeconds, to: MeetingLibrary.micTrackURL(for: id, in: root))
        }
        if let systemSeconds {
            try writeTone(seconds: systemSeconds, to: MeetingLibrary.systemTrackURL(for: id, in: root))
        }

        return Meeting(
            id: id,
            title: title,
            kind: kind,
            startedAt: startedAt,
            duration: max(micSeconds ?? 0, systemSeconds ?? 0),
            hasMicTrack: micSeconds != nil,
            hasSystemTrack: systemSeconds != nil,
            transcriptionModel: transcriptionModel,
            calendar: calendar,
            mergedSegments: mergedSegments
        )
    }

    private func writeTone(seconds: Double, to url: URL) throws {
        let format = AudioTrackWriter.targetFormat
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        let frames = AVAudioFrameCount(seconds * format.sampleRate)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<Int(frames) {
            channel[index] = 0.5 * sin(2 * .pi * 220 * Float(index) / Float(format.sampleRate))
        }
        try file.write(from: buffer)
    }

    private func duration(of url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }

    private func peakAmplitude(of url: URL, from start: Double, to end: Double) throws -> Float {
        let file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        file.framePosition = AVAudioFramePosition(start * rate)
        let frames = AVAudioFrameCount((end - start) * rate)
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)
        )
        try file.read(into: buffer, frameCount: frames)

        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        var peak: Float = 0
        for index in 0..<Int(buffer.frameLength) {
            peak = max(peak, abs(channel[index]))
        }
        return peak
    }
}
