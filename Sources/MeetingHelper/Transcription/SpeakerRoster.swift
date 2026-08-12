import Foundation

/// One voice heard on the "Others" track of a meeting.
///
/// The name lives here rather than on every transcript line, so naming a voice is a single edit and
/// every line carrying that id follows.
struct MeetingSpeaker: Codable, Hashable, Identifiable {
    /// What `TranscriptLine.speakerID` holds. Local to the meeting: the diarizer numbers the voices
    /// it hears from one and starts over at the next recording.
    let id: String
    /// Position in the order the voices were first heard, and what an unnamed one is called.
    let ordinal: Int
    /// `nil` until the voice is recognized from a stored profile, taken from a one-on-one
    /// invitation, or named by hand.
    var name: String?
    /// The invited person this voice was tied to, when there is one. This is the identity a voice
    /// profile is stored under; `name` is only what it is displayed as.
    var attendeeEmail: String?

    var displayName: String { name ?? "Speaker \(ordinal)" }
}

/// Which voices a recording has heard, and what each of them is called.
///
/// Naming from the invitation is deliberately narrow. A scheduled one-on-one has exactly one other
/// person on it, so the first voice on the "Others" track is almost certainly them. But anybody can
/// join a call uninvited, and that second voice must not inherit the name — so the shortcut applies
/// to the first voice only and never moves afterwards. Correcting it stays one click away, and
/// giving a voice somebody's name takes that name off whichever voice held it before.
struct SpeakerRoster: Equatable {
    private(set) var speakers: [MeetingSpeaker] = []
    /// Everybody on the invitation except the account owner, who is not on this track.
    let attendees: [CalendarAttendee]

    init(attendees: [CalendarAttendee] = [], speakers: [MeetingSpeaker] = []) {
        self.attendees = attendees
        self.speakers = speakers
    }

    func speaker(id: String) -> MeetingSpeaker? {
        speakers.first { $0.id == id }
    }

    func displayName(forSpeaker id: String) -> String? {
        speaker(id: id)?.displayName
    }

    /// Registers a voice the diarizer reported, naming it when there is a safe way to.
    ///
    /// - Parameter email: the address of the stored profile the voice was recognized as, when the
    ///   diarizer matched one.
    @discardableResult
    mutating func note(_ id: String, recognizedAs email: String? = nil) -> MeetingSpeaker {
        if let existing = speaker(id: id) { return existing }

        var speaker = MeetingSpeaker(id: id, ordinal: speakers.count + 1)
        if let recognized = email.flatMap(attendee(withEmail:)) {
            speaker.name = recognized.name
            speaker.attendeeEmail = recognized.email
        } else if speakers.isEmpty, attendees.count == 1 {
            speaker.name = attendees[0].name
            speaker.attendeeEmail = attendees[0].email
        }

        speakers.append(speaker)
        return speaker
    }

    /// Ties a voice to somebody on the invitation, or clears its name when `attendee` is `nil`.
    ///
    /// One person cannot be two voices at once, so the attendee is taken off any other voice first.
    /// That is what makes a wrong one-on-one guess repairable in a single step: naming the voice
    /// that really is the invited person leaves the uninvited one unnamed rather than duplicated.
    mutating func assign(_ attendee: CalendarAttendee?, to id: String) {
        guard let index = speakers.firstIndex(where: { $0.id == id }) else { return }

        if let attendee {
            for other in speakers.indices where speakers[other].attendeeEmail == attendee.email {
                speakers[other].name = nil
                speakers[other].attendeeEmail = nil
            }
        }

        speakers[index].name = attendee?.name
        speakers[index].attendeeEmail = attendee?.email
    }

    private func attendee(withEmail email: String) -> CalendarAttendee? {
        attendees.first { $0.email.caseInsensitiveCompare(email) == .orderedSame }
    }
}
