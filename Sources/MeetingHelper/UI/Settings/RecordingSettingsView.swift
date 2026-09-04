import SwiftUI

struct RecordingSettingsView: View {
    private static let recordingDurationLabels = [
        5: "5 seconds",
        10: "10 seconds",
        30: "30 seconds",
        60: "1 minute",
        300: "5 minutes"
    ]

    @EnvironmentObject private var controller: AppController

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { controller.settings.autoDetectionEnabled },
                    set: {
                        controller.settings.autoDetectionEnabled = $0
                        controller.detector.autoDetectionEnabled = $0
                    }
                )) {
                    SettingRowLabel(
                        title: "Start recording automatically when a meeting begins",
                        description: "Watches for meetings and starts a recording without you pressing anything."
                    )
                }

                Picker(selection: Binding(
                    get: { controller.settings.detectionMode },
                    set: { controller.setDetectionMode($0) }
                )) {
                    ForEach(AppSettings.DetectionMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                } label: {
                    SettingRowLabel(title: "Detection mode", description: detectionModeDescription)
                }
                .pickerStyle(.menu)
                .disabled(!controller.settings.autoDetectionEnabled || controller.isRecording)

                switch controller.settings.detectionMode {
                case .recognizedMeetings:
                    EmptyView()
                case .selectedMicrophoneApps:
                    microphoneApplicationList(
                        bundleIDs: controller.settings.selectedMicrophoneAppBundleIDs,
                        emptyText: "No applications selected. Recognized Zoom, Google Meet, and Ktalk meetings are still detected.",
                        addLabel: "Add Applications…",
                        addAction: controller.chooseSelectedMicrophoneApplications,
                        addObservedAction: controller.addSelectedMicrophoneApplication,
                        removeAction: controller.removeSelectedMicrophoneApplication
                    )
                case .anyMicrophoneApp:
                    microphoneApplicationList(
                        bundleIDs: controller.settings.excludedMicrophoneAppBundleIDs,
                        emptyText: "No applications excluded.",
                        addLabel: "Exclude Applications…",
                        addAction: controller.chooseExcludedMicrophoneApplications,
                        addObservedAction: controller.addExcludedMicrophoneApplication,
                        removeAction: controller.removeExcludedMicrophoneApplication
                    )
                    Text("Any application using the microphone can start a recording unless it is excluded. This can include dictation, voice messages, and microphone tests.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if controller.isRecording {
                    Text("Detection settings cannot be changed during a recording.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Label("Automatic detection", systemImage: "dot.radiowaves.left.and.right")
            }

            Section {
                Toggle(isOn: Binding(
                    get: { controller.settings.recordSystemAudio },
                    set: { controller.settings.recordSystemAudio = $0 }
                )) {
                    SettingRowLabel(
                        title: "Record system audio",
                        description: "Off records the microphone alone: the other participants are neither captured nor transcribed. This is the default for new recordings and can be changed during a call."
                    )
                }
            } header: {
                Label("Audio sources", systemImage: "speaker.wave.2")
            }

            Section {
                Picker(selection: Binding(
                    get: { controller.settings.minimumRecordingDuration },
                    set: { controller.settings.minimumRecordingDuration = $0 }
                )) {
                    ForEach(AppSettings.minimumRecordingDurations, id: \.self) { duration in
                        Text(Self.recordingDurationLabels[duration] ?? "\(duration) seconds")
                            .tag(duration)
                    }
                } label: {
                    SettingRowLabel(
                        title: "Minimum duration",
                        description: "Recordings shorter than this are deleted without saving audio or a transcript."
                    )
                }
                .pickerStyle(.menu)
            } header: {
                Label("Saved recordings", systemImage: "tray.and.arrow.down")
            }
        }
        .formStyle(.grouped)
    }

    /// `nil` for the mode whose explanation is the caution below the exclusion list, which has to
    /// stand out rather than read as an ordinary description.
    private var detectionModeDescription: String? {
        switch controller.settings.detectionMode {
        case .recognizedMeetings:
            return "Zoom is detected by its meeting helper process, Google Meet and Ktalk by the browser microphone and tab title."
        case .selectedMicrophoneApps:
            return "Recording starts after a selected application uses the microphone continuously for two checks and stops after three checks without microphone activity."
        case .anyMicrophoneApp:
            return nil
        }
    }

    @ViewBuilder
    private func microphoneApplicationList(
        bundleIDs: Set<String>,
        emptyText: String,
        addLabel: String,
        addAction: @escaping () -> Void,
        addObservedAction: @escaping (String) -> Void,
        removeAction: @escaping (String) -> Void
    ) -> some View {
        if bundleIDs.isEmpty {
            Text(emptyText)
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ForEach(bundleIDs.sorted(by: applicationSort), id: \.self) { bundleID in
                HStack {
                    Text(controller.applicationDisplayName(forBundleID: bundleID))
                    Spacer()
                    Button {
                        removeAction(bundleID)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove \(controller.applicationDisplayName(forBundleID: bundleID))")
                    .disabled(controller.isRecording)
                }
            }
        }

        let availableObservedApplications = controller.settings.observedMicrophoneApplications
            .map { MicrophoneApplication(bundleID: $0.key, displayName: $0.value) }
            .filter { !bundleIDs.contains($0.bundleID) }
            .sorted { left, right in
                left.displayName.localizedCaseInsensitiveCompare(right.displayName) == .orderedAscending
            }

        Menu(addLabel) {
            if availableObservedApplications.isEmpty {
                Text("No observed applications")
            } else {
                Section("Previously used the microphone") {
                    ForEach(availableObservedApplications) { application in
                        Button(application.displayName) {
                            addObservedAction(application.bundleID)
                        }
                    }
                }
            }

            Divider()
            Button("Choose from Applications…", action: addAction)
        }
            .disabled(controller.isRecording)
    }

    private func applicationSort(_ left: String, _ right: String) -> Bool {
        controller.applicationDisplayName(forBundleID: left).localizedCaseInsensitiveCompare(
            controller.applicationDisplayName(forBundleID: right)
        ) == .orderedAscending
    }
}
