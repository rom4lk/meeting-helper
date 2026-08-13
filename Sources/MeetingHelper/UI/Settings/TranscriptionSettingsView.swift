import SwiftUI

struct TranscriptionSettingsView: View {
    @EnvironmentObject private var controller: AppController

    var body: some View {
        Form {
            Section {
                Text("The language and model are fixed for the whole recording. Model selection is available again after the recording stops.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker(selection: Binding(
                    get: { controller.settings.language },
                    set: { controller.settings.language = $0 }
                )) {
                    ForEach(AppSettings.Language.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                } label: {
                    SettingRowLabel(title: "Language")
                }

                Picker(selection: Binding(
                    get: { controller.settings.model },
                    set: { controller.selectModel($0) }
                )) {
                    ForEach(AppSettings.availableModels, id: \.id) { model in
                        Text(model.name).tag(model.id)
                    }
                } label: {
                    SettingRowLabel(title: "Model")
                }
                .disabled(controller.isRecording)

                LabeledContent {
                    modelControl
                } label: {
                    SettingRowLabel(
                        title: "Model files",
                        description: "Downloaded models are prepared in the background when the app starts, so speech recognition is ready before a meeting begins."
                    )
                }
            } header: {
                Label("Speech recognition", systemImage: "waveform")
            }

            Section {
                Toggle(isOn: Binding(
                    get: { controller.settings.echoGateEnabled },
                    set: { controller.settings.echoGateEnabled = $0 }
                )) {
                    SettingRowLabel(
                        title: "Filter out speaker leakage before recognition",
                        description: "Compares each microphone phrase against the system audio, skips the ones that are only playback leaking back in, and trims leaked words off the start of a reply. A phrase waits up to half a second for the system track before it is recognized; turn this off to send the microphone straight to recognition. Takes effect when the next recording starts."
                    )
                }

                Toggle(isOn: Binding(
                    get: { controller.settings.transcriptDeduplicationEnabled },
                    set: { controller.settings.transcriptDeduplicationEnabled = $0 }
                )) {
                    SettingRowLabel(
                        title: "Remove duplicate transcript lines",
                        description: "Removes near-simultaneous matching lines captured from both microphone and system audio. Takes effect when the next recording starts."
                    )
                }
            } header: {
                Label("Cleanup", systemImage: "wand.and.sparkles")
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var modelControl: some View {
        switch controller.modelState {
        case .missing:
            Button("Download") { controller.downloadModel() }
        case .downloading(let progress):
            HStack(spacing: 8) {
                if let progress {
                    ProgressView(value: progress).frame(width: 120)
                    Text(progress.formatted(.percent.precision(.fractionLength(0))))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                    Text("Starting download…").foregroundStyle(.secondary)
                }
            }
        case .preparing(let stage):
            VStack(alignment: .trailing, spacing: 3) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(stage.statusText).foregroundStyle(.secondary)
                }
                Text(stage.detailText)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.trailing)
            }
        case .installed:
            Label("Downloaded", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .labelStyle(.titleAndIcon)
        case .failed(let message):
            HStack(spacing: 8) {
                Text(message)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                Button("Retry") { controller.downloadModel() }
            }
        }
    }
}
