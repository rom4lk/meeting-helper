import Foundation

enum TranscriptSource: String, Codable, CaseIterable {
    /// Captured from the microphone.
    case me
    /// Captured from the meeting app's audio output.
    case others

    var title: String {
        switch self {
        case .me: return "Me"
        case .others: return "Others"
        }
    }
}

struct TranscriptLine: Identifiable, Codable, Hashable {
    let id: UUID
    let source: TranscriptSource
    /// Seconds from the start of the recording.
    let offset: TimeInterval
    let text: String
    /// Which voice on the "Others" track said this, as `MeetingSpeaker.id`. Only an identifier: the
    /// name it stands for lives on the meeting, so renaming a voice does not rewrite the transcript.
    ///
    /// `nil` for microphone lines, which are always the account owner, for a preview, and whenever
    /// attribution is off or has nothing to say.
    let speakerID: String?

    init(
        id: UUID = UUID(),
        source: TranscriptSource,
        offset: TimeInterval,
        text: String,
        speakerID: String? = nil
    ) {
        self.id = id
        self.source = source
        self.offset = offset
        self.text = text
        self.speakerID = speakerID
    }

    var timestamp: String { offset.clockString }
}
