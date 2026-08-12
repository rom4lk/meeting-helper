import Foundation

enum TranscriptTextFormatter {
    @MainActor
    static func string(
        from lines: [TranscriptLine],
        speakers: [MeetingSpeaker] = [],
        transcriptionModel: String?
    ) -> String {
        let names = Dictionary(
            speakers.map { ($0.id, $0.displayName) },
            uniquingKeysWith: { first, _ in first }
        )
        let transcript = lines
            .map { line in
                let who = line.speakerID.flatMap { names[$0] } ?? line.source.title
                return "[\(line.timestamp)] \(who): \(line.text)"
            }
            .joined(separator: "\n")

        guard let transcriptionModel else { return transcript }

        let modelName = AppSettings.displayName(forModel: transcriptionModel)
        return "Transcription model: \(modelName)\n\n\(transcript)"
    }
}
