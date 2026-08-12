import SwiftUI

/// Shared transcript renderer for the detail view and the floating panel.
struct TranscriptView: View {
    let lines: [TranscriptLine]
    /// The voices heard on the "Others" track. Lines carry only an id; this is what turns it into
    /// a name, so renaming a voice updates every one of its lines at once.
    var speakers: [MeetingSpeaker] = []
    var compact = false
    var autoScroll = false

    private let bottomAnchorID = "transcript-bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: compact ? 6 : 10) {
                    ForEach(lines) { line in
                        TranscriptRow(line: line, speaker: speaker(for: line), compact: compact)
                            .id(line.id)
                    }

                    Color.clear
                        .frame(height: compact ? 10 : 16)
                        .id(bottomAnchorID)
                }
                .padding([.top, .horizontal], compact ? 10 : 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: lines.last) { _, line in
                guard autoScroll, line != nil else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                }
            }
        }
    }

    private func speaker(for line: TranscriptLine) -> MeetingSpeaker? {
        guard let speakerID = line.speakerID else { return nil }
        return speakers.first { $0.id == speakerID }
    }
}

private struct TranscriptRow: View {
    let line: TranscriptLine
    /// The voice this line was attributed to, when it was. A line without one keeps saying
    /// "Others": an unattributed phrase is not the same claim as an unnamed voice.
    let speaker: MeetingSpeaker?
    let compact: Bool

    private var color: Color {
        if line.source == .me { return .accentColor }
        guard let speaker else { return .secondary }
        return SpeakerPalette.color(forOrdinal: speaker.ordinal)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(speaker?.displayName ?? line.source.title)
                    .font(.system(size: compact ? 10 : 11, weight: .semibold))
                    .foregroundStyle(color)
                Text(line.timestamp)
                    .font(.system(size: compact ? 10 : 11).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Text(line.text)
                .font(.system(size: compact ? 12 : 13))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
