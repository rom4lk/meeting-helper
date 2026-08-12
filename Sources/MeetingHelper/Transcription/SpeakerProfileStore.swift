import Foundation

/// A voice the app has been told the name of, so the same person is recognized at the next meeting.
struct SpeakerProfile: Codable, Hashable, Identifiable {
    /// The invited person's calendar address. Names are spelled differently from one invitation to
    /// the next; the address is what stays the same.
    let email: String
    var name: String
    /// The diarizer's 256-dimensional speaker embedding.
    var embedding: [Float]
    var updatedAt: Date

    var id: String { email }
}

/// The voices the app can recognize, kept in one local file.
///
/// A voice embedding is biometric data, so this file sits beside the meeting library rather than
/// inside it. The iCloud sync copies meeting directories, and it must never carry these.
@MainActor
final class SpeakerProfileStore: ObservableObject {
    @Published private(set) var profiles: [SpeakerProfile] = []

    private let url: URL

    static let defaultURL: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MeetingHelper", isDirectory: true)
        .appendingPathComponent("speakers.json")

    init(url: URL = SpeakerProfileStore.defaultURL) {
        self.url = url

        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode([SpeakerProfile].self, from: data)
        else { return }
        profiles = stored
    }

    /// The profiles worth comparing a meeting's voices against: the people actually invited to it.
    ///
    /// Matching against every voice ever heard would trade a missing name for a wrong one. A
    /// handful of candidates from the invitation is both cheaper and far harder to get wrong.
    func profiles(for attendees: [CalendarAttendee]) -> [SpeakerProfile] {
        let invited = Set(attendees.map { $0.email.lowercased() })
        return profiles.filter { invited.contains($0.email.lowercased()) }
    }

    func remember(email: String, name: String, embedding: [Float]) {
        guard !email.isEmpty, !embedding.isEmpty else { return }

        let profile = SpeakerProfile(
            email: email,
            name: name,
            embedding: embedding,
            updatedAt: Date()
        )
        if let index = profiles.firstIndex(where: {
            $0.email.caseInsensitiveCompare(email) == .orderedSame
        }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        save()
    }

    func removeAll() {
        guard !profiles.isEmpty else { return }
        profiles.removeAll()
        save()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(profiles).write(to: url, options: .atomic)
        } catch {
            Log.speakers.error("Could not save voice profiles: \(error, privacy: .public)")
        }
    }
}
