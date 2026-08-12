import XCTest
@testable import MeetingHelper

@MainActor
final class TranscriptTextFormatterTests: XCTestCase {
    private let lines = [
        TranscriptLine(source: .me, offset: 1.5, text: "Can you hear me?"),
        TranscriptLine(source: .others, offset: 3, text: "Loud and clear.")
    ]

    func testIncludesTheTranscriptionModel() {
        XCTAssertEqual(
            TranscriptTextFormatter.string(
                from: lines,
                transcriptionModel: "openai_whisper-large-v3"
            ),
            """
            Transcription model: Whisper large-v3

            [00:01] Me: Can you hear me?
            [00:03] Others: Loud and clear.
            """
        )
    }

    func testLegacyMeetingWithoutAModelKeepsTheExistingFormat() {
        XCTAssertEqual(
            TranscriptTextFormatter.string(from: lines, transcriptionModel: nil),
            """
            [00:01] Me: Can you hear me?
            [00:03] Others: Loud and clear.
            """
        )
    }

    func testAttributedLinesAreNamedAfterTheirVoice() {
        let attributed = [
            TranscriptLine(source: .me, offset: 1.5, text: "Can you hear me?"),
            TranscriptLine(source: .others, offset: 3, text: "Loud and clear.", speakerID: "1"),
            TranscriptLine(source: .others, offset: 5, text: "Same here.", speakerID: "2")
        ]

        XCTAssertEqual(
            TranscriptTextFormatter.string(
                from: attributed,
                speakers: [
                    MeetingSpeaker(id: "1", ordinal: 1, name: "Ivan Petrov"),
                    MeetingSpeaker(id: "2", ordinal: 2)
                ],
                transcriptionModel: nil
            ),
            """
            [00:01] Me: Can you hear me?
            [00:03] Ivan Petrov: Loud and clear.
            [00:05] Speaker 2: Same here.
            """
        )
    }

    /// A line attributed in a meeting whose speaker table did not survive still has to read
    /// sensibly rather than print a bare cluster id.
    func testALineWhoseVoiceIsUnknownFallsBackToTheTrackName() {
        XCTAssertEqual(
            TranscriptTextFormatter.string(
                from: [TranscriptLine(source: .others, offset: 3, text: "Hello.", speakerID: "7")],
                transcriptionModel: nil
            ),
            "[00:03] Others: Hello."
        )
    }
}
