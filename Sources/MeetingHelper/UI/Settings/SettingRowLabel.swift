import SwiftUI

/// Title with its explanation directly underneath, so a Toggle, Picker or button on the trailing
/// edge always sits next to the text it belongs to instead of a caption paragraph below the row.
struct SettingRowLabel: View {
    let title: String
    var description: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if let description {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
