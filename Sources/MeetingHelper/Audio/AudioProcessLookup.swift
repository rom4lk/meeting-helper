import AudioToolbox
import Foundation

/// Finds Core Audio process objects belonging to an app family.
///
/// Matching is done on a bundle identifier *prefix* on purpose: a browser plays its audio from
/// helper processes (`com.google.Chrome.helper`) and Zoom spreads audio across `us.zoom.xos`
/// and its meeting helpers, so tapping only the main bundle identifier would miss the audio.
enum AudioProcessLookup {
    struct Match {
        let objectID: AudioObjectID
        let bundleID: String
        let pid: pid_t

        /// `true` when this process belongs to one of the bundle ID families.
        func belongs(toAnyOf prefixes: [String]) -> Bool {
            prefixes.contains { AudioProcessLookup.bundleID(bundleID, belongsTo: $0) }
        }
    }

    static func matches(prefixes: [String]) -> [Match] {
        allMatches().filter { $0.belongs(toAnyOf: prefixes) }
    }

    static func activeInputMatches() -> [Match] {
        allMatches().filter { $0.objectID.isRunningInput }
    }

    /// Every process currently playing audio. Read once per poll and matched against several
    /// bundle ID families, which is cheaper than walking the process list for each of them.
    static func playingOutputMatches() -> [Match] {
        allMatches().filter { $0.objectID.isRunningOutput }
    }

    /// `true` when any process of the family holds the microphone. This is the signal that
    /// tells "a browser tab is in a call" apart from "a browser tab is playing a video".
    static func isCapturingInput(prefixes: [String]) -> Bool {
        matches(prefixes: prefixes).contains { $0.objectID.isRunningInput }
    }

    static func bundleID(_ bundleID: String, belongsTo prefix: String) -> Bool {
        bundleID == prefix || bundleID.hasPrefix(prefix + ".")
    }

    private static func allMatches() -> [Match] {
        guard let objectIDs = try? AudioObjectID.readProcessList() else { return [] }

        return objectIDs.compactMap { objectID in
            guard let bundleID = objectID.processBundleID,
                  let pid = objectID.processPID
            else { return nil }

            return Match(objectID: objectID, bundleID: bundleID, pid: pid)
        }
    }
}
