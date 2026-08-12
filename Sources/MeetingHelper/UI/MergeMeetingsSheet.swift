import SwiftUI

/// Picks the recordings to join into one meeting.
///
/// The recording the merge was started from stays selected: it is what gives the sheet its
/// starting point, and unticking it would leave nothing to merge with.
struct MergeMeetingsSheet: View {
    @EnvironmentObject private var controller: AppController
    @Environment(\.dismiss) private var dismiss

    let anchor: Meeting
    let onMerge: (UUID) -> Void

    @State private var selectedIDs: Set<UUID>
    @State private var title: String
    @State private var deletesOriginals = true

    init(anchor: Meeting, onMerge: @escaping (UUID) -> Void) {
        self.anchor = anchor
        self.onMerge = onMerge
        _selectedIDs = State(initialValue: [anchor.id])
        _title = State(initialValue: anchor.title)
    }

    private var selected: [Meeting] {
        controller.store.meetings
            .filter { selectedIDs.contains($0.id) }
            .sorted { $0.startedAt < $1.startedAt }
    }

    /// The largest stretch two consecutive recordings share. They are joined back to back anyway,
    /// so this is a warning rather than an obstacle.
    private var overlap: TimeInterval? {
        let overlaps = zip(selected, selected.dropFirst()).map { earlier, later in
            earlier.startedAt.addingTimeInterval(earlier.duration).timeIntervalSince(later.startedAt)
        }
        guard let longest = overlaps.max(), longest > 0 else { return nil }
        return longest
    }

    private var estimatedDuration: TimeInterval {
        selected.reduce(0) { $0 + $1.duration }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Merge Recordings")
                    .font(.title2.weight(.semibold))
                Text("The recordings are joined back to back, oldest first. The time between them is not kept.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            List {
                ForEach(controller.store.meetings) { meeting in
                    row(for: meeting)
                }
            }
            .frame(height: 220)
            .accessibilityIdentifier("merge-candidates-list")

            if let overlap {
                Label(
                    "These recordings overlap by \(overlap.clockString). They will still be joined back to back.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                TextField("Merged title", text: $title)
                    .textFieldStyle(.roundedBorder)
                Text("\(selected.count) recordings, about \(estimatedDuration.clockString)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Toggle("Delete original recordings", isOn: $deletesOriginals)
                .accessibilityIdentifier("merge-deletes-originals")

            HStack {
                if controller.isMerging {
                    ProgressView().controlSize(.small)
                    Text("Joining recordings…").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Merge", action: merge)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.count < 2)
                    .accessibilityIdentifier("merge-confirm-button")
            }
            .disabled(controller.isMerging)
        }
        .padding(20)
        .frame(width: 540)
    }

    private func row(for meeting: Meeting) -> some View {
        Toggle(isOn: Binding(
            get: { selectedIDs.contains(meeting.id) },
            set: { isSelected in
                if isSelected {
                    selectedIDs.insert(meeting.id)
                } else {
                    selectedIDs.remove(meeting.id)
                }
            }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.title).lineLimit(1)
                HStack(spacing: 6) {
                    Text(meeting.startedAt.formatted(date: .abbreviated, time: .shortened))
                    Text(meeting.formattedDuration).monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.checkbox)
        .disabled(meeting.id == anchor.id || controller.isMerging)
    }

    private func merge() {
        let meetings = selected
        let mergedTitle = title
        let deletesOriginals = self.deletesOriginals

        Task {
            let id = await controller.mergeMeetings(
                meetings,
                title: mergedTitle,
                deletesOriginals: deletesOriginals
            )
            if let id { onMerge(id) }
            dismiss()
        }
    }
}
