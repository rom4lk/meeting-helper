import SwiftUI

struct GeneralSettingsView: View {
    @EnvironmentObject private var controller: AppController

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    permissionControl(granted: controller.microphoneGranted) {
                        controller.requestMicrophonePermission()
                    }
                } label: {
                    SettingRowLabel(
                        title: "Microphone",
                        description: "Records your voice during the meeting."
                    )
                }

                LabeledContent {
                    permissionControl(granted: controller.systemAudioPermission == .authorized) {
                        controller.requestSystemAudioPermission()
                    }
                } label: {
                    SettingRowLabel(
                        title: "System audio",
                        description: "Records the other participants' voices from the meeting app's audio stream."
                    )
                }

                LabeledContent {
                    permissionControl(granted: controller.accessibilityGranted) {
                        controller.requestAccessibilityPermission()
                    }
                } label: {
                    SettingRowLabel(
                        title: "Accessibility",
                        description: "Reads meeting window titles, which names the recording and finds browser meetings."
                    )
                }
            } header: {
                Label("Permissions", systemImage: "lock.shield")
            }

            Section {
                LabeledContent("Start/stop recording", value: "⌥⌘R")
                LabeledContent("Show/hide the panel", value: "⌥⌘T")
            } header: {
                Label("Shortcuts", systemImage: "keyboard")
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func permissionControl(granted: Bool, handler: @escaping () -> Void) -> some View {
        if granted {
            Label("Granted", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .labelStyle(.titleAndIcon)
        } else {
            Button("Grant", action: handler)
        }
    }
}
