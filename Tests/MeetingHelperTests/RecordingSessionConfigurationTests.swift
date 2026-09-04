import XCTest
@testable import MeetingHelper

@MainActor
final class RecordingSessionConfigurationTests: XCTestCase {
    func testModelIsCapturedWhenTheRecordingSessionIsCreated() {
        let suiteName = "RecordingSessionConfigurationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        let initialModel = AppSettings.availableModels[0].id
        let replacementModel = AppSettings.availableModels[1].id
        settings.liveTranscriptEnabled = true
        settings.model = initialModel

        let session = RecordingSession(
            detected: DetectedMeeting(
                kind: .manual,
                title: "Model capture test",
                audioPrefixes: [],
                detectedAt: Date()
            ),
            settings: settings,
            engine: TranscriptionEngine(),
            profileStore: SpeakerProfileStore(url: .temporaryProfileStore())
        )
        settings.model = replacementModel

        XCTAssertEqual(session.transcriptionModel, initialModel)
    }

    func testMicrophoneOnlySettingIsCapturedWhenTheRecordingSessionIsCreated() {
        let suiteName = "RecordingSessionConfigurationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        settings.recordSystemAudio = false

        let session = Self.makeSession(settings: settings)
        settings.recordSystemAudio = true

        XCTAssertFalse(session.systemAudioEnabled)
        XCTAssertEqual(session.systemState, .off)
    }

    func testSwitchingSystemAudioOffBeforeStartingLeavesTheTrackOff() {
        let suiteName = "RecordingSessionConfigurationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)

        let session = Self.makeSession(settings: settings)
        XCTAssertTrue(session.systemAudioEnabled)
        XCTAssertEqual(session.systemState, .pending)

        session.setSystemAudioEnabled(false)

        XCTAssertFalse(session.systemAudioEnabled)
        XCTAssertEqual(session.systemState, .off)
        XCTAssertTrue(settings.recordSystemAudio, "The switch changes the recording, not the setting")
    }

    private static func makeSession(settings: AppSettings) -> RecordingSession {
        RecordingSession(
            detected: DetectedMeeting(
                kind: .manual,
                title: "Microphone only test",
                audioPrefixes: [],
                detectedAt: Date()
            ),
            settings: settings,
            engine: TranscriptionEngine(),
            profileStore: SpeakerProfileStore(url: .temporaryProfileStore())
        )
    }
}
