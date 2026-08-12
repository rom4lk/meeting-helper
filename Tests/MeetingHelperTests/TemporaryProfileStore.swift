import Foundation

extension URL {
    /// A voice profile file of its own for one test, so nothing here can read or overwrite the
    /// profiles belonging to whoever is running the suite.
    static func temporaryProfileStore() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingHelperTests", isDirectory: true)
            .appendingPathComponent("\(UUID().uuidString).json")
    }
}
