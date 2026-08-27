import SwiftUI

/// Colours for the voices on the "Others" track.
///
/// The account owner keeps the accent colour, so these start after it and stay away from red and
/// green, which read as status rather than identity.
enum SpeakerPalette {
    static let colors: [Color] = [.teal, .purple, .orange, .pink, .indigo, .brown]

    static func color(forOrdinal ordinal: Int) -> Color {
        colors[max(0, ordinal - 1) % colors.count]
    }
}

/// The voices a recording has heard, and the control for saying who they are.
///
/// One chip per voice rather than a menu on every line: naming is something done once per person,
/// and a picker on each phrase would be both noise and a much easier way to misclick.
struct SpeakerLegend: View {
    let speakers: [MeetingSpeaker]
    let attendees: [CalendarAttendee]
    /// `nil` when the voices cannot be renamed, which is how a meeting with no invitation to pick
    /// names from is shown.
    var assign: ((CalendarAttendee?, String) -> Void)?

    var body: some View {
        if !speakers.isEmpty {
            // The strip scrolls because the chips must not decide how wide the window has to be.
            // A meeting with a dozen voices, each named after an email address, is wider than the
            // screen, and a row that refuses to compress pushes the sidebar out of the window.
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    Image(systemName: "person.wave.2")
                        .foregroundStyle(.tertiary)

                    ForEach(speakers) { speaker in
                        chip(for: speaker)
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
            .fixedSize(horizontal: false, vertical: true)
            .font(.caption)
        }
    }

    @ViewBuilder
    private func chip(for speaker: MeetingSpeaker) -> some View {
        if let assign, !attendees.isEmpty {
            Menu {
                ForEach(attendees) { attendee in
                    Button(attendee.name) { assign(attendee, speaker.id) }
                }
                Divider()
                Button("Not on the invitation") { assign(nil, speaker.id) }
            } label: {
                label(for: speaker)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Say which of the invited people this voice is.")
        } else {
            label(for: speaker)
        }
    }

    private func label(for speaker: MeetingSpeaker) -> some View {
        Text(speaker.displayName)
            .foregroundStyle(SpeakerPalette.color(forOrdinal: speaker.ordinal))
    }
}
