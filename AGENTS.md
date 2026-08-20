# AGENTS.md

## Language

Everything in this repository is written in English: code, comments, identifiers, commit messages,
documentation, and **all user-facing strings** — window and menu titles, buttons, labels, error
messages, placeholders, and the `NS*UsageDescription` entries in [project.yml](project.yml) and
[Resources/Info.plist](Resources/Info.plist). The app interface is English-only; there is no
localization and no Russian UI.

One exception: the hallucination filter in
[Sources/MeetingHelper/Transcription/TranscriptionEngine.swift](Sources/MeetingHelper/Transcription/TranscriptionEngine.swift)
holds verbatim Whisper output in the languages the model produces it in. Those strings are data
being matched against — never translate them.

Transcript content is whatever the meeting participants said, in whatever language they said it —
that is user data, not interface text.

## Commands

The Xcode project is generated, not committed. Regenerate it after adding, moving, or deleting a
source file:

```bash
xcodegen generate
```

`project.yml` lists whole directories (`Sources/MeetingHelper`, `Tests/…`) as sources, so new files
are picked up by regenerating — there is no project file to edit by hand.

Build, restart, and launch the app in one step (this is the normal edit-run loop):

```bash
./run.sh
```

Add `--release` for the Release configuration. `run.sh` regenerates the project, builds into
`.build`, kills the running copy, and reopens the new one.

Build without launching:

```bash
xcodebuild -project MeetingHelper.xcodeproj -scheme MeetingHelper -configuration Debug -destination 'platform=macOS' -derivedDataPath .build build
```

Run the unit tests:

```bash
xcodebuild -project MeetingHelper.xcodeproj -scheme MeetingHelper -destination 'platform=macOS' -derivedDataPath .build test
```

Run one test class or one test case:

```bash
xcodebuild -project MeetingHelper.xcodeproj -scheme MeetingHelper -destination 'platform=macOS' -derivedDataPath .build test -only-testing:MeetingHelperTests/MeetingStoreTests/testSavedMeetingSurvivesAReload
```

UI tests are deliberately excluded from the `MeetingHelper` scheme; they run under the
`MeetingHelperUITests` scheme, launch the real app, and drive it through
`--ui-testing-…` launch arguments handled in `AppController.bootstrap()`.

Every build — tests included — needs `Config/LocalSigning.xcconfig` with a `DEVELOPMENT_TEAM`
(copy `Config/LocalSigning.xcconfig.example`). A pre-build script fails the build without it.

## Build constraints that are not negotiable

- **The app must be code signed with a stable identity.** macOS TCC ties microphone, system audio,
  Accessibility, and Calendar grants to the code requirement; ad-hoc signing changes it on every
  rebuild and re-prompts for everything. `project.yml` fails the build on `CODE_SIGNING_ALLOWED=NO`,
  a missing team, or `CODE_SIGN_IDENTITY = -`.
- **The app is not sandboxed, on purpose.** Core Audio process taps
  (`AudioHardwareCreateProcessTap`) and the Accessibility API used to read meeting window titles are
  both unavailable inside the App Sandbox.
- **`project.yml` owns `Resources/Info.plist` and the entitlements**; `xcodegen generate` rewrites
  them, so edits made only in the plist are lost.
- Dependencies are pinned to exact versions: WhisperKit via `argmaxinc/argmax-oss-swift`, and
  `FluidInference/FluidAudio` for Parakeet and the speaker models.

## Architecture

A single `@MainActor` object graph hangs off `AppController` (`App/AppController.swift`), which
`MeetingHelperApp` creates once and injects as an `EnvironmentObject`. It owns `AppSettings`,
`MeetingStore`, `MeetingDetector`, `CalendarService`, `SpeakerProfileStore`,
`ICloudMeetingSyncCoordinator`, the shared `TranscriptionEngine` actor, the floating panel, and the
global hotkeys. Nested `ObservableObject`s do not propagate through SwiftUI on their own, so
`AppController` re-publishes each one's `objectWillChange` — a new nested observable needs the same
wiring or its changes will not redraw anything.

The recording pipeline, in the order data flows:

1. **Detection** (`Detection/`). `MeetingDetector` polls every two seconds and combines four
   signals: the Zoom `CptHost` helper process, per-process Core Audio input/output activity, and
   Accessibility window titles (or PWA install URLs) for browser services. It debounces
   asymmetrically — two polls to start, three to stop — and calls back into `AppController` through
   `onStart`/`onStop`.
2. **Capture** (`Audio/`). One `RecordingSession` per meeting owns two independent sources:
   `MicrophoneCapture` (an `AVAudioEngine` tap, restarted and silence-padded across device changes)
   and `SystemAudioTap` (process-scoped for detected meetings, global for manual recordings).
   `AudioTrackWriter` puts both on one shared timeline at 16 kHz mono — every later stage (echo
   gate, transcript offsets, merging, playback seeking) depends on that shared timeline.
3. **Transcription** (`Transcription/`). Each track gets its own `SourceTranscriber`, which runs an
   energy VAD, cuts utterances, and funnels them through the single `TranscriptionEngine` actor that
   owns the loaded model. Audio-thread classes are `@unchecked Sendable` with explicit locking and
   hand results back through `@MainActor` closures.
4. **Refinement.** `EchoGate` + `EchoDelayEstimator` + `EchoReference` drop or trim microphone
   utterances that are speaker leakage, *before* recognition; `TranscriptDeduplicator` catches what
   got through, *after* recognition. `SpeakerAttributor` (an actor) embeds finalized system-track
   utterances and assigns voice ids that `SpeakerRoster` maps to names.
5. **Storage** (`Storage/`). `MeetingStore` writes each meeting as a self-contained directory under
   `~/Library/Application Support/MeetingHelper/Meetings/<uuid>/` (`meeting.json`, `mic.wav`,
   `system.wav`, `mix.m4a`, `transcript.json`). Merging and folder sync both assume that
   self-containment. `ICloudMeetingSync` mirrors finished directories into a user-chosen folder on
   its own serial queue — recording never writes into a cloud-backed directory.

`Calendar/` is read-only EventKit: `CalendarEventMatcher` picks an event once, as the recording
starts, and a snapshot is copied into `meeting.json` rather than referenced. Nothing in the app
talks to a network service.

### Conventions worth knowing

- **`meeting.json` and `transcript.json` are a compatibility surface.** Meetings recorded by older
  versions must keep decoding, and newer values must survive a round trip through an older build —
  hence the optional fields everywhere and `DetectedMeeting.Kind`'s tolerant `unknown` case. The
  transcript format has no tolerant decoding by design; adding a `TranscriptSource` value would cost
  a whole transcript on an older Mac.
- **Logging privacy is load-bearing.** Use the `Log` categories in `Support/Log.swift`. Meeting
  titles, transcript text, participant names, and addresses are logged `privacy: .private`; only
  non-identifying values (kinds, permission states, formats, error descriptions) are `.public`.
- Tests are XCTest and inject a temporary root (`MeetingStore(root:)`, `TemporaryProfileStore`)
  rather than touching the real library. Pure logic — matching, merging, gating, formatting — is
  split into testable types away from the capture and UI classes; keep new logic on that side of the
  line.
- Speaker embeddings are biometric data: they live only in
  `~/Library/Application Support/MeetingHelper/speakers.json` and must never be written into a
  meeting directory, which is what keeps them out of the sync folder.

## Documentation

Update the documentation whenever a change affects application behavior, architecture, setup,
permissions, supported meeting apps, configuration, or known limitations. Keep `README.md` concise
and user-focused, and put implementation details in the relevant file under `docs/` or `knowledge/`.
Documentation updates must be part of the same change as the code they describe.

`docs/how-it-works.md` is the implementation reference and is expected to change with the code.
`knowledge/` holds measurement notes explaining why things are the way they are — read
`acoustic-echo-cancellation.md` before touching microphone capture (it records why macOS AEC was
removed rather than fixed) and `echo-gate-calibration.md` before changing any echo threshold.
