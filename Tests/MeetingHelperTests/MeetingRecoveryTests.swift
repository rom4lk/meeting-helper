import AVFoundation
import XCTest
@testable import MeetingHelper

@MainActor
final class MeetingRecoveryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
    }

    func testOrphanedDirectoryWithAudioBecomesARecoveredMeeting() throws {
        let id = UUID()
        try MeetingLibrary.createDirectory(for: id, in: root)
        try writeTone(seconds: 3, to: MeetingLibrary.micTrackURL(for: id, in: root))

        let store = MeetingStore(root: root)
        store.recoverOrphanedRecordings()

        let meeting = try XCTUnwrap(store.meetings.first { $0.id == id })
        XCTAssertEqual(meeting.title, "Recovered recording")
        XCTAssertEqual(meeting.duration, 3, accuracy: 0.01)
        XCTAssertTrue(meeting.hasMicTrack)
        XCTAssertFalse(meeting.hasSystemTrack)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: MeetingLibrary.metadataURL(for: id, in: root).path
        ))
    }

    func testRecoveredMeetingSurvivesAReload() throws {
        let id = UUID()
        try MeetingLibrary.createDirectory(for: id, in: root)
        try writeTone(seconds: 2, to: MeetingLibrary.systemTrackURL(for: id, in: root))

        MeetingStore(root: root).recoverOrphanedRecordings()

        let reopened = MeetingStore(root: root)
        let meeting = try XCTUnwrap(reopened.meetings.first { $0.id == id })
        XCTAssertTrue(meeting.hasSystemTrack)
        XCTAssertFalse(meeting.hasMicTrack)
        XCTAssertEqual(meeting.kind.displayName, "Other")
    }

    func testDurationComesFromTheLongerTrack() throws {
        let id = UUID()
        try MeetingLibrary.createDirectory(for: id, in: root)
        try writeTone(seconds: 1, to: MeetingLibrary.micTrackURL(for: id, in: root))
        try writeTone(seconds: 4, to: MeetingLibrary.systemTrackURL(for: id, in: root))

        let store = MeetingStore(root: root)
        store.recoverOrphanedRecordings()

        let meeting = try XCTUnwrap(store.meetings.first { $0.id == id })
        XCTAssertEqual(meeting.duration, 4, accuracy: 0.01)
        XCTAssertTrue(meeting.hasMicTrack)
        XCTAssertTrue(meeting.hasSystemTrack)
    }

    func testDirectoryWithoutAudioIsNotRecovered() throws {
        let id = UUID()
        try MeetingLibrary.createDirectory(for: id, in: root)

        let store = MeetingStore(root: root)
        store.recoverOrphanedRecordings()

        XCTAssertTrue(store.meetings.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: MeetingLibrary.metadataURL(for: id, in: root).path
        ))
    }

    func testExcludedDirectoryIsLeftForSynchronizationToRepair() throws {
        let id = UUID()
        try MeetingLibrary.createDirectory(for: id, in: root)
        try writeTone(seconds: 3, to: MeetingLibrary.micTrackURL(for: id, in: root))

        let store = MeetingStore(root: root)
        store.recoverOrphanedRecordings(excluding: [id])

        XCTAssertTrue(store.meetings.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: MeetingLibrary.metadataURL(for: id, in: root).path
        ))
    }

    func testSavedMeetingIsNotTouchedByRecovery() throws {
        let store = MeetingStore(root: root)
        let meeting = Meeting(title: "Weekly sync", kind: .zoom, duration: 42)
        try store.save(meeting)
        try writeTone(seconds: 3, to: MeetingLibrary.micTrackURL(for: meeting.id, in: root))

        store.recoverOrphanedRecordings()

        XCTAssertEqual(store.meetings.map(\.title), ["Weekly sync"])
        XCTAssertEqual(store.meetings.first?.duration, 42)
    }

    func testRemoteMeetingIDsReadsTheSyncFolderLayout() throws {
        let syncFolder = root.appendingPathComponent("Sync", isDirectory: true)
        let remoteID = UUID()
        try FileManager.default.createDirectory(
            at: syncFolder
                .appendingPathComponent("Meetings", isDirectory: true)
                .appendingPathComponent(remoteID.uuidString, isDirectory: true),
            withIntermediateDirectories: true
        )

        XCTAssertEqual(ICloudMeetingSyncEngine.remoteMeetingIDs(inSyncFolder: syncFolder), [remoteID])
        XCTAssertTrue(ICloudMeetingSyncEngine.remoteMeetingIDs(
            inSyncFolder: root.appendingPathComponent("Missing", isDirectory: true)
        ).isEmpty)
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
}
