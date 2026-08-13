import SwiftUI

struct LiveTranscriptSettingsView: View {
    @EnvironmentObject private var controller: AppController

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { controller.settings.liveTranscriptEnabled },
                    set: { controller.setLiveTranscriptEnabled($0) }
                )) {
                    SettingRowLabel(
                        title: "Live transcript",
                        description: "Recognizes speech while the recording runs instead of only after it stops."
                    )
                }

                Toggle(isOn: Binding(
                    get: { controller.settings.liveTranscriptShowsMySpeech },
                    set: { controller.settings.liveTranscriptShowsMySpeech = $0 }
                )) {
                    SettingRowLabel(
                        title: "Show my speech in the live transcript",
                        description: "Leaves the microphone lines out of the live transcript and the floating panel, which keeps only the other participants on screen. Audio and the saved transcript are unaffected, and the switch can be flipped during a recording from the recording window or the floating panel."
                    )
                }
                .disabled(!controller.settings.liveTranscriptEnabled)

                Toggle(isOn: Binding(
                    get: { controller.settings.realtimeTranscriptEnabled },
                    set: { controller.settings.realtimeTranscriptEnabled = $0 }
                )) {
                    SettingRowLabel(
                        title: "Update transcript while people are speaking",
                        description: "Recognizes the active phrase every two seconds and replaces the preview with a final result after a pause. Uses more processing power and takes effect when the next recording starts."
                    )
                }
                .disabled(!controller.settings.liveTranscriptEnabled)

                Toggle(isOn: Binding(
                    get: { controller.settings.showPanelOnStart },
                    set: { controller.settings.showPanelOnStart = $0 }
                )) {
                    SettingRowLabel(
                        title: "Show the floating panel on start",
                        description: "Opens the transcript panel over the meeting as soon as a recording begins. ⌥⌘T shows and hides it at any time."
                    )
                }
                .disabled(!controller.settings.liveTranscriptEnabled)
            } header: {
                Label("Live transcript", systemImage: "text.bubble")
            }

            Section {
                Toggle(isOn: Binding(
                    get: { controller.settings.speakerAttributionEnabled },
                    set: { controller.settings.speakerAttributionEnabled = $0 }
                )) {
                    SettingRowLabel(
                        title: "Tell the other participants apart",
                        description: "Groups the system audio by voice, so each line says who spoke rather than just \"Others\". A meeting with one other person on the invitation names that voice on its own; anywhere else the voices start as \"Speaker 1\", \"Speaker 2\" and are named from the recording window. Downloads two small models the first time and takes effect when the next recording starts."
                    )
                }
                .disabled(!controller.settings.liveTranscriptEnabled)

                if !controller.speakerProfiles.profiles.isEmpty {
                    LabeledContent {
                        HStack(spacing: 8) {
                            Text(knownVoicesSummary)
                            Button("Forget all") { controller.speakerProfiles.removeAll() }
                        }
                    } label: {
                        SettingRowLabel(
                            title: "Known voices",
                            description: "Naming a voice during a recording stores it locally so the same person is recognized at their next meeting. These recordings of a voice never leave this Mac and are not part of the iCloud sync."
                        )
                    }
                }
            } header: {
                Label("Speakers", systemImage: "person.2.wave.2")
            }
        }
        .formStyle(.grouped)
    }

    private var knownVoicesSummary: String {
        let count = controller.speakerProfiles.profiles.count
        return count == 1 ? "1 person" : "\(count) people"
    }
}
