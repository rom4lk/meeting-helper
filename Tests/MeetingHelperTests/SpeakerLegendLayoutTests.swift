import SwiftUI
import XCTest
@testable import MeetingHelper

/// The legend used to set a minimum width of its own: a meeting with a dozen voices named after
/// email addresses made the detail pane wider than the window, which pushed the sidebar off screen
/// and clipped the header on both sides.
@MainActor
final class SpeakerLegendLayoutTests: XCTestCase {

    func testALongRosterDoesNotWidenTheWindow() {
        let attendees = [CalendarAttendee(email: "ivan@example.com", displayName: "Ivan Petrov")]
        let speakers = (1...12).map { ordinal in
            MeetingSpeaker(
                id: "speaker-\(ordinal)",
                ordinal: ordinal,
                name: "somebody.with.a.long.address\(ordinal)@example.com"
            )
        }

        let legend = SpeakerLegend(speakers: speakers, attendees: attendees) { _, _ in }
        let host = NSHostingView(rootView: legend)
        host.sizingOptions = [.minSize]
        host.translatesAutoresizingMaskIntoConstraints = false
        NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 60)).addSubview(host)
        host.layoutSubtreeIfNeeded()

        XCTAssertLessThan(host.fittingSize.width, 200)
    }
}
