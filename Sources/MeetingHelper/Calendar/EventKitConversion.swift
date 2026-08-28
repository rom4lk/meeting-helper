import EventKit
import Foundation

extension CalendarEvent {
    /// Reads one EventKit event, or refuses it.
    ///
    /// All-day entries and cancelled ones are dropped: neither can be the call that is being
    /// recorded, and an all-day entry spans every meeting of the day, so keeping them would put a
    /// birthday reminder in front of the real event.
    init?(_ event: EKEvent) {
        guard !event.isAllDay, event.status != .canceled else { return nil }
        guard let identifier = event.eventIdentifier,
              let start = event.startDate,
              let end = event.endDate
        else { return nil }

        let organizerEmail = event.organizer.flatMap { CalendarAttendee.emailAddress(inParticipantURL: $0.url) }

        self.init(
            id: identifier,
            iCalUID: event.calendarItemExternalIdentifier ?? identifier,
            calendarTitle: event.calendar?.title ?? "",
            title: event.title ?? "",
            start: start,
            end: end,
            organizerEmail: organizerEmail,
            attendees: (event.attendees ?? []).compactMap {
                CalendarAttendee($0, organizerEmail: organizerEmail)
            }
        )
    }
}

extension CalendarAttendee {
    /// An attendee without a readable address is skipped: the address is the identity everything
    /// else keys on, and a participant that carries none — a resource with an odd URL — is of no
    /// use for naming a voice later.
    init?(_ participant: EKParticipant, organizerEmail: String?) {
        guard Self.isPerson(participant.participantType) else { return nil }
        guard let email = Self.emailAddress(inParticipantURL: participant.url) else { return nil }

        self.init(
            email: email,
            displayName: participant.name,
            responseStatus: ResponseStatus(participant.participantStatus),
            isSelf: participant.isCurrentUser,
            isOrganizer: organizerEmail?.caseInsensitiveCompare(email) == .orderedSame
        )
    }

    /// A booked room or a projector is invited the way a person is, answers the invitation, and
    /// often has a mailbox of its own — but no voice will ever be theirs, so they are not part of
    /// the roster the recording is named from.
    static func isPerson(_ type: EKParticipantType) -> Bool {
        switch type {
        case .room, .resource: return false
        default: return true
        }
    }

    /// EventKit identifies a participant by URL, which for a person is `mailto:someone@example.com`.
    static func emailAddress(inParticipantURL url: URL) -> String? {
        guard url.scheme?.lowercased() == "mailto" else { return nil }

        let specifier = String(url.absoluteString.dropFirst("mailto:".count))
        let address = specifier.split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
        let decoded = (address.removingPercentEncoding ?? address)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return decoded.contains("@") ? decoded : nil
    }
}

extension CalendarAttendee.ResponseStatus {
    /// EventKit has more states than an invitation really has. The ones that say nothing about
    /// whether the person is coming — delegated, in process, unknown — read as no answer yet.
    init(_ status: EKParticipantStatus) {
        switch status {
        case .accepted: self = .accepted
        case .declined: self = .declined
        case .tentative: self = .tentative
        default: self = .needsAction
        }
    }
}
