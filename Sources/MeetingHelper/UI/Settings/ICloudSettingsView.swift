import SwiftUI

struct ICloudSettingsView: View {
    @EnvironmentObject private var controller: AppController

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    syncFolderControl
                } label: {
                    SettingRowLabel(
                        title: "Sync folder",
                        description: "Choose a folder in iCloud Drive to synchronize complete recordings, transcripts, and meeting details. Turning sync off leaves existing copies in the folder."
                    )
                }

                Picker(selection: Binding(
                    get: { controller.settings.iCloudSyncLimit },
                    set: { controller.setICloudSyncLimit($0) }
                )) {
                    ForEach(AppSettings.ICloudSyncLimit.allCases) { limit in
                        Text(limit.displayName).tag(limit)
                    }
                } label: {
                    SettingRowLabel(
                        title: "Keep synchronized",
                        description: "Older meetings stay on this Mac when the limit is reached."
                    )
                }
                .pickerStyle(.menu)

                if controller.settings.iCloudSyncLimit != .disabled {
                    LabeledContent {
                        syncStatus
                    } label: {
                        SettingRowLabel(title: "Status")
                    }
                }
            } header: {
                Label("iCloud", systemImage: "icloud")
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var syncFolderControl: some View {
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
    private var syncStatus: some View {
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
}
