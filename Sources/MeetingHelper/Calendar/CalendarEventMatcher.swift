import Foundation

/// Decides which calendar event a detected meeting is.
///
/// Time defines which events are candidates. When several overlap, an invitation with other
/// attendees is preferred, followed by one the current user accepted.
///
/// Everything here is a pure function of its arguments so the decisions stay testable without a
/// network or a running meeting.
enum CalendarEventMatcher {
    struct Match {
        let event: CalendarEvent
    }

    /// How far outside an event a meeting can start and still belong to it. People join early and
    /// calls run over.
    static let tolerance: TimeInterval = 10 * 60

    /// The events close enough to the recording start to be considered.
    static func candidates(
        for meeting: DetectedMeeting,
        in events: [CalendarEvent]
    ) -> [CalendarEvent] {
        deduplicate(events).filter { isWithinTolerance(meeting.detectedAt, of: $0) }
    }

    /// The best unambiguous event, or `nil` when the calendar cannot identify one.
    ///
    /// A single event in the time window is enough. Among multiple events, prefer the only one
    /// with invited attendees. If several have attendees, prefer the only one the user accepted.
    static func bestMatch(for meeting: DetectedMeeting, in events: [CalendarEvent]) -> Match? {
        let candidates = candidates(for: meeting, in: events)
        guard let first = candidates.first else { return nil }
        guard candidates.count > 1 else { return Match(event: first) }

        let withInvitedAttendees = candidates.filter { event in
            event.attendees.contains { !$0.isSelf }
        }
        guard let firstWithAttendees = withInvitedAttendees.first else { return nil }
        guard withInvitedAttendees.count > 1 else { return Match(event: firstWithAttendees) }

        let accepted = withInvitedAttendees.filter { event in
            event.attendees.contains { $0.isSelf && $0.responseStatus == .accepted }
        }
        guard accepted.count == 1, let acceptedEvent = accepted.first else { return nil }
        return Match(event: acceptedEvent)
    }

    private static func isWithinTolerance(_ moment: Date, of event: CalendarEvent) -> Bool {
        moment >= event.start.addingTimeInterval(-tolerance)
            && moment <= event.end.addingTimeInterval(tolerance)
    }

    // MARK: - Deduplication

    /// The same event invited to both a work and a personal account arrives twice. Keep one copy,
    /// preferring the account where the user accepted it — that is the one whose roster reflects
    /// the meeting they are actually in.
    static func deduplicate(_ events: [CalendarEvent]) -> [CalendarEvent] {
        var best: [String: CalendarEvent] = [:]

        for event in events {
            guard let existing = best[event.occurrenceKey] else {
                best[event.occurrenceKey] = event
                continue
            }
            if rank(event) > rank(existing) {
                best[event.occurrenceKey] = event
            }
        }

        return best.values.sorted { $0.start < $1.start }
    }

    private static func rank(_ event: CalendarEvent) -> Int {
        guard let response = event.attendees.first(where: \.isSelf)?.responseStatus else { return 0 }
        switch response {
        case .accepted: return 3
        case .tentative: return 2
        case .needsAction: return 1
        case .declined: return 0
        }
    }
}
