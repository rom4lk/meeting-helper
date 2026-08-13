import SwiftUI

/// One screen of the settings window. The sidebar groups these; the detail pane shows one at a time.
private enum SettingsCategory: Hashable {
    case general
    case recording
    case transcription
    case liveTranscript
    case calendar
    case iCloud

    var title: String {
        switch self {
        case .general: return "General"
        case .recording: return "Recording"
        case .transcription: return "Transcription"
        case .liveTranscript: return "Live Transcript"
        case .calendar: return "Calendar"
        case .iCloud: return "iCloud"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .recording: return "record.circle"
        case .transcription: return "waveform"
        case .liveTranscript: return "text.bubble"
        case .calendar: return "calendar"
        case .iCloud: return "icloud"
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var controller: AppController
    @State private var category: SettingsCategory = .general

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            sidebar
        } detail: {
            detail
        }
        .frame(minWidth: 700, idealWidth: 760, minHeight: 460, idealHeight: 560)
        .onAppear {
            controller.refreshPermissions()
            controller.refreshModelState()
        }
    }

    // Note: do not add `.navigationSplitViewColumnWidth` here — see the same warning in RootView.
    private var sidebar: some View {
        List(selection: $category) {
            Section {
                row(.general)
                row(.recording)
                row(.transcription)
                row(.liveTranscript)
            } header: {
                Text("Configure")
            }

            Section {
                row(.calendar)
                row(.iCloud)
            } header: {
                Text("Data")
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 180, idealWidth: 196, maxWidth: 220)
        // The sidebar is the only way between screens, so it must not be collapsible.
        .toolbar(removing: .sidebarToggle)
    }

    private func row(_ category: SettingsCategory) -> some View {
        Label(category.title, systemImage: category.systemImage)
            .tag(category)
    }

    @ViewBuilder
    private var detail: some View {
        switch category {
        case .general: GeneralSettingsView()
        case .recording: RecordingSettingsView()
        case .transcription: TranscriptionSettingsView()
        case .liveTranscript: LiveTranscriptSettingsView()
        case .calendar: CalendarSettingsView()
        case .iCloud: ICloudSettingsView()
        }
    }
}
