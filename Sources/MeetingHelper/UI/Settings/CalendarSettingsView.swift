import SwiftUI

struct CalendarSettingsView: View {
    @EnvironmentObject private var controller: AppController

    var body: some View {
        Form {
            Section {
                accessContent

                Text("""
                    Meeting Helper reads the calendars macOS already syncs, so a recording takes the name \
                    of the event it belongs to and keeps that event's list of invited people. Add the work \
                    Google account and the personal one under System Settings > Internet Accounts with \
                    Calendars turned on. The app signs in to nothing itself and never writes to a calendar.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("Calendar", systemImage: "calendar")
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var accessContent: some View {
        switch controller.calendar.access {
        case .notDetermined:
            Button("Connect Calendar…") { controller.requestCalendarAccess() }
        case .granted:
            LabeledContent("Accounts") {
                Text(calendarAccountSummary)
                    .multilineTextAlignment(.trailing)
            }

            if controller.calendar.availableCalendars.isEmpty {
                Text("No calendars found.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Use events from")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(controller.calendar.availableCalendars) { calendar in
                    Toggle(isOn: calendarSelectionBinding(for: calendar.id)) {
                        SettingRowLabel(title: calendar.title, description: calendar.accountTitle)
                    }
                }
                if enabledCalendarCount == 0 {
                    Text("No calendar events will be used for meeting names or participants.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Button("Add or remove accounts…") { CalendarService.openAccountSettings() }
        case .denied:
            LabeledContent("Access") {
                Label("Denied", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.orange)
            }
            Button("Open Privacy Settings…") { CalendarService.openPrivacySettings() }
        }
    }

    private var calendarAccountSummary: String {
        let titles = controller.calendar.accountTitles
        return titles.isEmpty ? "None with calendars" : titles.joined(separator: ", ")
    }

    private var enabledCalendarCount: Int {
        controller.calendar.availableCalendars.count { calendar in
            !controller.settings.excludedCalendarIDs.contains(calendar.id)
        }
    }

    private func calendarSelectionBinding(for calendarID: String) -> Binding<Bool> {
        Binding(
            get: { !controller.settings.excludedCalendarIDs.contains(calendarID) },
            set: { isEnabled in
                var excluded = controller.settings.excludedCalendarIDs
                if isEnabled {
                    excluded.remove(calendarID)
                } else {
                    excluded.insert(calendarID)
                }
                controller.settings.excludedCalendarIDs = excluded
            }
        )
    }
}
