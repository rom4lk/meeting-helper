import SwiftUI

struct SettingsView: View {
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
            Section("Detection") {
                Toggle("Start recording automatically when a meeting begins", isOn: Binding(
                    get: { controller.settings.autoDetectionEnabled },
                    set: {
                        controller.settings.autoDetectionEnabled = $0
                        controller.detector.autoDetectionEnabled = $0
                    }
                ))

                Picker("Detection mode", selection: Binding(
                    get: { controller.settings.detectionMode },
                    set: { controller.setDetectionMode($0) }
                )) {
                    ForEach(AppSettings.DetectionMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .disabled(!controller.settings.autoDetectionEnabled || controller.isRecording)

                switch controller.settings.detectionMode {
                case .recognizedMeetings:
                    Text("Zoom is detected by its meeting helper process, Google Meet and Ktalk by the browser microphone and tab title.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .selectedMicrophoneApps:
                    microphoneApplicationList(
                        bundleIDs: controller.settings.selectedMicrophoneAppBundleIDs,
                        emptyText: "No applications selected. Recognized Zoom, Google Meet, and Ktalk meetings are still detected.",
                        addLabel: "Add Applications…",
                        addAction: controller.chooseSelectedMicrophoneApplications,
                        addObservedAction: controller.addSelectedMicrophoneApplication,
                        removeAction: controller.removeSelectedMicrophoneApplication
                    )
                    Text("Recording starts after a selected application uses the microphone continuously for two checks and stops after three checks without microphone activity.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
            }

            Section("Recording") {
                Picker("Minimum duration", selection: Binding(
                    get: { controller.settings.minimumRecordingDuration },
                    set: { controller.settings.minimumRecordingDuration = $0 }
                )) {
                    ForEach(AppSettings.minimumRecordingDurations, id: \.self) { duration in
                        Text(Self.recordingDurationLabels[duration] ?? "\(duration) seconds")
                            .tag(duration)
                    }
                }
                .pickerStyle(.menu)

                Text("Recordings shorter than this are deleted without saving audio or a transcript.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("iCloud") {
                LabeledContent("Sync folder") { iCloudSyncFolderControl }

                Picker("Keep synchronized", selection: Binding(
                    get: { controller.settings.iCloudSyncLimit },
                    set: { controller.setICloudSyncLimit($0) }
                )) {
                    ForEach(AppSettings.ICloudSyncLimit.allCases) { limit in
                        Text(limit.displayName).tag(limit)
                    }
                }
                .pickerStyle(.menu)

                if controller.settings.iCloudSyncLimit != .disabled {
                    LabeledContent("Status") { iCloudSyncStatus }
                }

                Text("Choose a folder in iCloud Drive to synchronize complete recordings, transcripts, and meeting details. Older meetings stay on this Mac when the limit is reached. Turning sync off leaves existing copies in the folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Transcript") {
                Toggle("Live transcript", isOn: Binding(
                    get: { controller.settings.liveTranscriptEnabled },
                    set: { controller.setLiveTranscriptEnabled($0) }
                ))

                Toggle("Show my speech in the live transcript", isOn: Binding(
                    get: { controller.settings.liveTranscriptShowsMySpeech },
                    set: { controller.settings.liveTranscriptShowsMySpeech = $0 }
                ))
                .disabled(!controller.settings.liveTranscriptEnabled)

                Text("Leaves the microphone lines out of the live transcript and the floating panel, which keeps only the other participants on screen. Audio and the saved transcript are unaffected, and the switch can be flipped during a recording from the recording window or the floating panel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Update transcript while people are speaking", isOn: Binding(
                    get: { controller.settings.realtimeTranscriptEnabled },
                    set: { controller.settings.realtimeTranscriptEnabled = $0 }
                ))
                .disabled(!controller.settings.liveTranscriptEnabled)

                Text("Recognizes the active phrase every two seconds and replaces the preview with a final result after a pause. Uses more processing power and takes effect when the next recording starts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Show the floating panel on start", isOn: Binding(
                    get: { controller.settings.showPanelOnStart },
                    set: { controller.settings.showPanelOnStart = $0 }
                ))
                .disabled(!controller.settings.liveTranscriptEnabled)

                Toggle("Filter out speaker leakage before recognition", isOn: Binding(
                    get: { controller.settings.echoGateEnabled },
                    set: { controller.settings.echoGateEnabled = $0 }
                ))

                Text("Compares each microphone phrase against the system audio, skips the ones that are only playback leaking back in, and trims leaked words off the start of a reply. A phrase waits up to half a second for the system track before it is recognized; turn this off to send the microphone straight to recognition. Takes effect when the next recording starts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Remove duplicate transcript lines", isOn: Binding(
                    get: { controller.settings.transcriptDeduplicationEnabled },
                    set: { controller.settings.transcriptDeduplicationEnabled = $0 }
                ))

                Text("Removes near-simultaneous matching lines captured from both microphone and system audio. Takes effect when the next recording starts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("The language and model are fixed for the whole recording. Model selection is available again after the recording stops.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Language", selection: Binding(
                    get: { controller.settings.language },
                    set: { controller.settings.language = $0 }
                )) {
                    ForEach(AppSettings.Language.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }

                Picker("Model", selection: Binding(
                    get: { controller.settings.model },
                    set: { controller.selectModel($0) }
                )) {
                    ForEach(AppSettings.availableModels, id: \.id) { model in
                        Text(model.name).tag(model.id)
                    }
                }
                .disabled(controller.isRecording)

                LabeledContent("Model files") { modelControl }

                Text("Downloaded models are prepared in the background when the app starts, so speech recognition is ready before a meeting begins.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Calendar") {
                calendarSection
            }

            Section("Shortcuts") {
                LabeledContent("Start/stop recording", value: "⌥⌘R")
                LabeledContent("Show/hide the panel", value: "⌥⌘T")
            }

            Section("Permissions") {
                LabeledContent("Microphone") {
                    permissionControl(granted: controller.microphoneGranted) {
                        controller.requestMicrophonePermission()
                    }
                }
                LabeledContent("System audio") {
                    permissionControl(granted: controller.systemAudioPermission == .authorized) {
                        controller.requestSystemAudioPermission()
                    }
                }
                LabeledContent("Accessibility") {
                    permissionControl(granted: controller.accessibilityGranted) {
                        controller.requestAccessibilityPermission()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .onAppear {
            controller.refreshPermissions()
            controller.refreshModelState()
        }
    }

    @ViewBuilder
    private var calendarSection: some View {
        switch controller.calendar.access {
        case .notDetermined:
            Button("Connect Calendar…") { controller.requestCalendarAccess() }
        case .granted:
            LabeledContent("Accounts") {
                Text(calendarAccountSummary)
                    .multilineTextAlignment(.trailing)
            }
            Button("Add or remove accounts…") { CalendarService.openAccountSettings() }
        case .denied:
            LabeledContent("Access") {
                Label("Denied", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.orange)
            }
            Button("Open Privacy Settings…") { CalendarService.openPrivacySettings() }
        }

        Text("""
            Meeting Helper reads the calendars macOS already syncs, so a recording takes the name \
            of the event it belongs to and keeps that event's list of invited people. Add the work \
            Google account and the personal one under System Settings > Internet Accounts with \
            Calendars turned on. The app signs in to nothing itself and never writes to a calendar.
            """)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var calendarAccountSummary: String {
        let titles = controller.calendar.accountTitles
        return titles.isEmpty ? "None with calendars" : titles.joined(separator: ", ")
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

    @ViewBuilder
    private var iCloudSyncFolderControl: some View {
        if let folderURL = controller.settings.iCloudSyncFolderURL {
            HStack(spacing: 8) {
                Text(folderURL.lastPathComponent)
                    .lineLimit(1)
                    .help(folderURL.path)
                Button("Change…") { controller.chooseICloudSyncFolder() }
                Button {
                    controller.clearICloudSyncFolder()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .help("Stop using this folder")
            }
        } else {
            Button("Choose…") { controller.chooseICloudSyncFolder() }
        }
    }

    @ViewBuilder
    private var iCloudSyncStatus: some View {
        switch controller.iCloudSync.status {
        case .disabled:
            Text("Off").foregroundStyle(.secondary)
        case .folderNotSelected:
            Label("Choose a folder", systemImage: "folder.badge.questionmark")
                .foregroundStyle(.orange)
                .labelStyle(.titleAndIcon)
        case .syncing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Syncing…").foregroundStyle(.secondary)
            }
        case .upToDate:
            Label("Up to date", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .labelStyle(.titleAndIcon)
        case .unavailable:
            Label("Sync folder unavailable", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .labelStyle(.titleAndIcon)
        case .failed(let message):
            Label("Sync failed", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .labelStyle(.titleAndIcon)
                .help(message)
        }
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
