import AppKit
import Combine
import Foundation

struct DetectedMeeting: Equatable {
    enum Kind: Codable, Hashable {
        case zoom
        case googleMeet
        case ktalk
        case microphoneApp
        case manual
        case unknown(String)

        var rawValue: String {
            switch self {
            case .zoom: return "zoom"
            case .googleMeet: return "googleMeet"
            case .ktalk: return "ktalk"
            case .microphoneApp: return "microphoneApp"
            case .manual: return "manual"
            case .unknown(let rawValue): return rawValue
            }
        }

        init(rawValue: String) {
            switch rawValue {
            case "zoom": self = .zoom
            case "googleMeet": self = .googleMeet
            case "ktalk": self = .ktalk
            case "microphoneApp": self = .microphoneApp
            case "manual": self = .manual
            default: self = .unknown(rawValue)
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            self.init(rawValue: try container.decode(String.self))
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }

        var displayName: String {
            switch self {
            case .zoom: return "Zoom"
            case .googleMeet: return "Google Meet"
            case .ktalk: return "Ktalk"
            case .microphoneApp: return "Microphone app"
            case .manual: return "Manual"
            case .unknown: return "Other"
            }
        }

        /// Kinds that live in a browser tab and share the browser detection path.
        var isBrowserMeeting: Bool {
            self == .googleMeet || self == .ktalk
        }
    }

    let kind: Kind
    let title: String
    /// Bundle identifier prefixes whose audio output belongs to this meeting.
    let audioPrefixes: [String]
    let detectedAt: Date
    /// The application whose input stream triggered generic microphone detection.
    let triggerBundleID: String?
    /// A user-facing name for a generically detected audio source.
    let audioSourceName: String?

    init(
        kind: Kind,
        title: String,
        audioPrefixes: [String],
        detectedAt: Date,
        triggerBundleID: String? = nil,
        audioSourceName: String? = nil
    ) {
        self.kind = kind
        self.title = title
        self.audioPrefixes = audioPrefixes
        self.detectedAt = detectedAt
        self.triggerBundleID = triggerBundleID
        self.audioSourceName = audioSourceName
    }

    var capturesAllSystemAudio: Bool {
        kind == .manual
    }

    var audioSourceDisplayName: String {
        guard !capturesAllSystemAudio else { return "All system audio" }
        if let audioSourceName { return audioSourceName }

        let apps = [MeetingApp.zoom] + MeetingApp.browsers
        return apps.first { $0.audioBundleIDPrefixes == audioPrefixes }?.displayName
            ?? kind.displayName
    }
}

struct MicrophoneActivityTracker {
    enum Transition: Equatable {
        case start(String)
        case stop
    }

    private(set) var currentBundleID: String?
    private var startCandidateBundleID: String?
    private var positiveTicks = 0
    private var negativeTicks = 0

    let startTicks: Int
    let stopTicks: Int

    init(startTicks: Int = 2, stopTicks: Int = 3) {
        self.startTicks = startTicks
        self.stopTicks = stopTicks
    }

    mutating func update(activeBundleIDs: Set<String>) -> Transition? {
        if let currentBundleID {
            if activeBundleIDs.contains(currentBundleID) {
                negativeTicks = 0
                return nil
            }

            negativeTicks += 1
            guard negativeTicks >= stopTicks else { return nil }
            reset()
            return .stop
        }

        guard !activeBundleIDs.isEmpty else {
            startCandidateBundleID = nil
            positiveTicks = 0
            return nil
        }

        let candidate = startCandidateBundleID.flatMap { activeBundleIDs.contains($0) ? $0 : nil }
            ?? activeBundleIDs.sorted().first!
        if candidate == startCandidateBundleID {
            positiveTicks += 1
        } else {
            startCandidateBundleID = candidate
            positiveTicks = 1
        }

        guard positiveTicks >= startTicks else { return nil }
        currentBundleID = candidate
        startCandidateBundleID = nil
        positiveTicks = 0
        negativeTicks = 0
        return .start(candidate)
    }

    mutating func reset() {
        currentBundleID = nil
        startCandidateBundleID = nil
        positiveTicks = 0
        negativeTicks = 0
    }
}

/// A conferencing service that runs inside a browser tab.
///
/// Such a service has no process of its own, so it is recognised by the title of the browser
/// window, or — for an installed PWA window, which exposes no title — by the host its bundle was
/// created from.
struct BrowserMeetingService {
    let kind: DetectedMeeting.Kind
    /// Matched against a raw window title, browser name suffix included.
    let matchesTitle: @MainActor (String) -> Bool
    /// Host recorded in the PWA bundle. Subdomains match too: Ktalk gives every organisation its
    /// own one, and Meet is reached through a single host that has none in use.
    let pwaHost: String

    static let all: [BrowserMeetingService] = [
        BrowserMeetingService(
            kind: .googleMeet,
            matchesTitle: MeetingDetector.looksLikeGoogleMeet,
            pwaHost: "meet.google.com"
        ),
        BrowserMeetingService(
            kind: .ktalk,
            matchesTitle: MeetingDetector.looksLikeKtalk,
            pwaHost: "ktalk.ru"
        )
    ]

    func matches(pwaHost host: String) -> Bool {
        host.localizedCaseInsensitiveCompare(pwaHost) == .orderedSame
            || host.lowercased().hasSuffix("." + pwaHost.lowercased())
    }
}

/// Watches the system for meetings that have actually *started*.
///
/// Zoom is detected by its meeting helper process `us.zoom.CptHost`, which the client spawns on
/// join and kills on leave. That is a far sharper signal than "some app opened the microphone" —
/// it fires the moment the meeting begins, and never fires for the Zoom main window.
///
/// `CptHost` is an agent (`LSUIElement`), and `NSWorkspace` does not post launch or terminate
/// notifications for agents — it only reports them in `runningApplications`. So everything here
/// is driven by one poll.
///
/// Browser meetings have no such process, so there we combine two weaker signals: the browser
/// holding the microphone, and a window that one of the `BrowserMeetingService` entries claims.
/// Optional broader modes use the same Core Audio input signal for selected applications, or for
/// every identifiable application except an exclusion list.
@MainActor
final class MeetingDetector: ObservableObject {
    static let zoomMeetingBundleID = "us.zoom.CptHost"

    @Published private(set) var current: DetectedMeeting?
    @Published var autoDetectionEnabled = true {
        didSet { autoDetectionEnabled ? startWatching() : stopWatching() }
    }

    var detectionMode = AppSettings.DetectionMode.recognizedMeetings {
        didSet { microphoneActivity.reset() }
    }
    var selectedMicrophoneAppBundleIDs: Set<String> = [] {
        didSet { microphoneActivity.reset() }
    }
    var excludedMicrophoneAppBundleIDs: Set<String> = [] {
        didSet { microphoneActivity.reset() }
    }

    var onStart: ((DetectedMeeting) -> Void)?
    var onStop: (() -> Void)?

    private var pollTimer: Timer?
    private var browserPositiveTicks = 0
    private var browserNegativeTicks = 0

    private let browserStartTicks = 2
    private let browserStopTicks = 3
    private var microphoneActivity = MicrophoneActivityTracker()

    func startWatching() {
        guard pollTimer == nil else { return }

        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer

        poll()
        // `notice` and above is what `log show` keeps on disk, so these three transitions stay
        // visible after the fact — `info` is dropped and cannot be used to debug a missed meeting.
        Log.detection.notice("Detector started")
    }

    func stopWatching() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func poll() {
        pollZoom()
        pollBrowsers()
        pollMicrophoneApps()
    }

    /// Called when the user starts a recording by hand or via the global hotkey.
    func beginManual(title: String) {
        guard current == nil else { return }
        begin(DetectedMeeting(
            kind: .manual,
            title: title,
            audioPrefixes: [],
            detectedAt: Date()
        ))
    }

    /// Called when the user stops a recording by hand — clears the state so a later automatic
    /// detection can fire again.
    func clearCurrent() {
        guard current != nil else { return }
        current = nil
        browserPositiveTicks = 0
        browserNegativeTicks = 0
        microphoneActivity.reset()
    }

    // MARK: - General microphone activity

    private struct ActiveMicrophoneApp {
        let bundleID: String
        let displayName: String
        let audioPrefixes: [String]
    }

    private func pollMicrophoneApps() {
        guard detectionMode != .recognizedMeetings else {
            microphoneActivity.reset()
            return
        }
        guard current == nil || current?.kind == .microphoneApp else {
            microphoneActivity.reset()
            return
        }

        let activeApps = activeMicrophoneApps()
        let appsByBundleID = Dictionary(uniqueKeysWithValues: activeApps.map { ($0.bundleID, $0) })
        let transition = microphoneActivity.update(activeBundleIDs: Set(appsByBundleID.keys))

        switch transition {
        case .start(let bundleID):
            guard current == nil, let app = appsByBundleID[bundleID] else {
                microphoneActivity.reset()
                return
            }
            begin(DetectedMeeting(
                kind: .microphoneApp,
                title: "\(app.displayName) call",
                audioPrefixes: app.audioPrefixes,
                detectedAt: Date(),
                triggerBundleID: app.bundleID,
                audioSourceName: app.displayName
            ))
        case .stop:
            guard current?.kind == .microphoneApp else { return }
            end()
        case nil:
            break
        }
    }

    private func activeMicrophoneApps() -> [ActiveMicrophoneApp] {
        let ownBundleID = Bundle.main.bundleIdentifier ?? "com.kovalev.MeetingHelper"
        var appsByBundleID: [String: ActiveMicrophoneApp] = [:]

        for match in AudioProcessLookup.activeInputMatches() {
            guard !AudioProcessLookup.bundleID(match.bundleID, belongsTo: ownBundleID) else { continue }

            let resolved = resolveApplication(for: match)
            if let resolved,
               AudioProcessLookup.bundleID(resolved.bundleID, belongsTo: ownBundleID) {
                continue
            }

            let app: ActiveMicrophoneApp
            switch detectionMode {
            case .recognizedMeetings:
                continue
            case .selectedMicrophoneApps:
                guard let selectedBundleID = selectedMicrophoneAppBundleIDs.first(where: { bundleID in
                    AudioProcessLookup.bundleID(match.bundleID, belongsTo: bundleID)
                        || resolved.map { AudioProcessLookup.bundleID($0.bundleID, belongsTo: bundleID) } == true
                }) else { continue }

                app = ActiveMicrophoneApp(
                    bundleID: selectedBundleID,
                    displayName: applicationName(forBundleID: selectedBundleID)
                        ?? resolved?.displayName
                        ?? selectedBundleID,
                    audioPrefixes: audioPrefixes(
                        forBundleID: selectedBundleID,
                        including: match.bundleID
                    )
                )
            case .anyMicrophoneApp:
                guard let resolved else { continue }
                guard !excludedMicrophoneAppBundleIDs.contains(where: { bundleID in
                    AudioProcessLookup.bundleID(match.bundleID, belongsTo: bundleID)
                        || AudioProcessLookup.bundleID(resolved.bundleID, belongsTo: bundleID)
                }) else { continue }
                app = resolved
            }

            if let existing = appsByBundleID[app.bundleID] {
                let additionalPrefixes = app.audioPrefixes.filter { !existing.audioPrefixes.contains($0) }
                appsByBundleID[app.bundleID] = ActiveMicrophoneApp(
                    bundleID: existing.bundleID,
                    displayName: existing.displayName,
                    audioPrefixes: existing.audioPrefixes + additionalPrefixes
                )
            } else {
                appsByBundleID[app.bundleID] = app
            }
        }

        return Array(appsByBundleID.values)
    }

    private func resolveApplication(for match: AudioProcessLookup.Match) -> ActiveMicrophoneApp? {
        if let knownApp = ([MeetingApp.zoom] + MeetingApp.browsers).first(where: { app in
            app.audioBundleIDPrefixes.contains { prefix in
                AudioProcessLookup.bundleID(match.bundleID, belongsTo: prefix)
            }
        }) {
            return ActiveMicrophoneApp(
                bundleID: knownApp.mainBundleID,
                displayName: knownApp.displayName,
                audioPrefixes: knownApp.audioBundleIDPrefixes
            )
        }

        guard let runningApplication = NSRunningApplication(processIdentifier: match.pid) else { return nil }
        let bundle = outermostApplicationBundle(startingAt: runningApplication.bundleURL)
            ?? runningApplication.bundleIdentifier
                .flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
                .flatMap(Bundle.init(url:))
        guard let bundle, let bundleID = bundle.bundleIdentifier else { return nil }
        let displayName = bundleDisplayName(bundle)
            ?? runningApplication.localizedName
            ?? bundleID

        return ActiveMicrophoneApp(
            bundleID: bundleID,
            displayName: displayName,
            audioPrefixes: audioPrefixes(forBundleID: bundleID, including: match.bundleID)
        )
    }

    private func audioPrefixes(forBundleID bundleID: String, including observedBundleID: String? = nil) -> [String] {
        let knownApps = [MeetingApp.zoom] + MeetingApp.browsers
        var prefixes = knownApps.first(where: { $0.mainBundleID == bundleID })?.audioBundleIDPrefixes
            ?? [bundleID]
        if let observedBundleID,
           !prefixes.contains(where: { AudioProcessLookup.bundleID(observedBundleID, belongsTo: $0) }) {
            prefixes.append(observedBundleID)
        }
        return prefixes
    }

    private func applicationName(forBundleID bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return bundleDisplayName(Bundle(url: url))
    }

    private func outermostApplicationBundle(startingAt bundleURL: URL?) -> Bundle? {
        guard var url = bundleURL else { return nil }
        var outermostBundle: Bundle?

        while url.path != "/" {
            if url.pathExtension.localizedCaseInsensitiveCompare("app") == .orderedSame,
               let bundle = Bundle(url: url) {
                outermostBundle = bundle
            }
            url.deleteLastPathComponent()
        }

        return outermostBundle
    }

    private func bundleDisplayName(_ bundle: Bundle?) -> String? {
        guard let bundle else { return nil }
        return (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
    }

    // MARK: - Zoom

    private var isZoomMeetingRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.zoomMeetingBundleID).isEmpty
    }

    private func pollZoom() {
        if isZoomMeetingRunning {
            guard current == nil else { return }
            begin(zoomMeeting())
        } else {
            guard current?.kind == .zoom else { return }
            end()
        }
    }

    private func zoomMeeting() -> DetectedMeeting {
        DetectedMeeting(
            kind: .zoom,
            title: zoomTitle() ?? "Zoom meeting",
            audioPrefixes: MeetingApp.zoom.audioBundleIDPrefixes,
            detectedAt: Date()
        )
    }

    private func zoomTitle() -> String? {
        let ignored: Set<String> = ["Zoom", "Zoom Workplace", "zoom.us"]
        let titles = WindowTitles.titles(forBundleID: MeetingApp.zoom.mainBundleID)
            + WindowTitles.titles(forBundleID: Self.zoomMeetingBundleID)

        return titles.first { !ignored.contains($0) && !$0.hasPrefix("Zoom Workplace —") }
    }

    // MARK: - Browser meetings

    private func pollBrowsers() {
        guard current == nil || current?.kind.isBrowserMeeting == true else { return }

        var detected: DetectedMeeting?

        search: for browser in MeetingApp.browsers {
            guard AudioProcessLookup.isCapturingInput(prefixes: browser.audioBundleIDPrefixes) else { continue }

            for app in browser.runningApplications {
                for service in BrowserMeetingService.all {
                    guard let title = meetingTitle(for: app, service: service) else { continue }

                    detected = DetectedMeeting(
                        kind: service.kind,
                        title: Self.cleanMeetTitle(title),
                        audioPrefixes: browser.audioBundleIDPrefixes,
                        detectedAt: Date()
                    )
                    break search
                }
            }
        }

        if let detected {
            browserNegativeTicks = 0
            browserPositiveTicks += 1
            if current == nil, browserPositiveTicks >= browserStartTicks {
                begin(detected)
            }
        } else {
            browserPositiveTicks = 0
            guard current?.kind.isBrowserMeeting == true else { return }
            browserNegativeTicks += 1
            if browserNegativeTicks >= browserStopTicks {
                end()
            }
        }
    }

    private func meetingTitle(for app: NSRunningApplication, service: BrowserMeetingService) -> String? {
        let titles = WindowTitles.titles(forPID: app.processIdentifier)
        if let title = titles.first(where: service.matchesTitle) {
            return title
        }

        // Chrome PWA windows expose neither AXTitle nor AXDocument. Their bundle records the
        // installed app URL, so use that as the identity signal while AX confirms a real window.
        guard current?.kind == service.kind || app.isActive else { return nil }
        guard WindowTitles.hasWindows(forPID: app.processIdentifier) else { return nil }
        guard let bundleURL = app.bundleURL,
              let shortcutURL = Bundle(url: bundleURL)?.object(forInfoDictionaryKey: "CrAppModeShortcutURL") as? String,
              let host = URL(string: shortcutURL)?.host,
              service.matches(pwaHost: host)
        else { return nil }

        return app.localizedName ?? service.kind.displayName
    }

    /// Google Meet window titles look like `Meet — abc-defg-hij` or `<name> - Google Meet`.
    static func looksLikeGoogleMeet(_ title: String) -> Bool {
        if title.localizedCaseInsensitiveContains("Google Meet") { return true }
        guard title.localizedCaseInsensitiveContains("Meet") else { return false }
        return title.range(of: "[a-z]{3}-[a-z]{4}-[a-z]{3}", options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The Ktalk web client builds every document title as either its own app name alone or
    /// `<page> — <app name>`, and it ships that name untranslated in all of its locales, so the
    /// name is the only stable marker a title carries. It is a string read from a page and matched
    /// against, not interface text — it must stay as the client emits it.
    ///
    /// The name is anchored to the end of the title rather than searched for anywhere in it: as a
    /// bare substring it also occurs inside unrelated Russian words, and an unrelated tab could
    /// then claim a browser that holds the microphone for a real meeting.
    static func looksLikeKtalk(_ title: String) -> Bool {
        let cleaned = cleanMeetTitle(title)
        if cleaned.localizedCaseInsensitiveCompare(ktalkAppName) == .orderedSame { return true }
        return titleSeparators.contains { cleaned.hasSuffix(" \($0) \(ktalkAppName)") }
    }

    private static let ktalkAppName = "Толк"

    /// Separators seen between a title and the name appended after it. Which one appears varies by
    /// browser, by macOS version and — for Ktalk — by what the web client itself emits.
    private static let titleSeparators = ["-", "—", "–"]

    /// Browsers append their own name to the window title; strip it so the meeting keeps the
    /// tab's name.
    ///
    /// The separator differs per browser and per macOS version, and some titles carry invisible
    /// characters — Edge has been seen emitting a zero-width space inside its own name — so the
    /// title is normalised before matching rather than compared against handwritten literals.
    static func cleanMeetTitle(_ title: String) -> String {
        let normalized = title.unicodeScalars
            .filter { !Self.invisibleScalars.contains($0) }
            .reduce(into: "") { $0.unicodeScalars.append($1) }

        for name in MeetingApp.browsers.map(\.displayName) {
            for separator in titleSeparators {
                let suffix = " \(separator) \(name)"
                if normalized.hasSuffix(suffix) {
                    return String(normalized.dropLast(suffix.count))
                        .trimmingCharacters(in: .whitespaces)
                }
            }
        }
        return normalized.trimmingCharacters(in: .whitespaces)
    }

    /// Zero-width space, non-joiner, joiner and BOM: present in real window titles, invisible in
    /// source, and enough to break a literal comparison.
    private static let invisibleScalars: Set<Unicode.Scalar> = ["\u{200B}", "\u{200C}", "\u{200D}", "\u{FEFF}"]

    // MARK: - Transitions

    private func begin(_ meeting: DetectedMeeting) {
        guard current == nil else { return }
        current = meeting
        browserPositiveTicks = 0
        browserNegativeTicks = 0
        if meeting.kind != .microphoneApp {
            microphoneActivity.reset()
        }
        // The kind stays public so a missed meeting can still be debugged from `log show`; the
        // title is user data and must not be written to the system log in the clear.
        Log.detection.notice("Meeting started: \(meeting.kind.rawValue, privacy: .public) — \(meeting.title, privacy: .private)")
        onStart?(meeting)
    }

    private func end() {
        guard current != nil else { return }
        current = nil
        browserPositiveTicks = 0
        browserNegativeTicks = 0
        microphoneActivity.reset()
        Log.detection.notice("Meeting ended")
        onStop?()
    }
}
