# How Meeting Helper Works

This document describes the implementation behind meeting detection, audio capture, speaker
attribution, and transcription. For installation and usage, see the [README](../README.md).

## Settings

Settings open with ⌘, in a window of their own, separate from the meetings window. A sidebar splits
them into six screens under two headings: **Configure** holds *General*, *Recording*,
*Transcription* and *Live Transcript*, **Data** holds *Calendar* and *iCloud*. The sidebar cannot be
collapsed, since it is the only way between screens. The rest of this document refers to a setting
by its screen, as in **Settings > Recording**.

Each screen is a grouped `Form` of one or two labeled sections, and each row carries its own
explanation: the title and the sentence describing it sit together on the leading edge, with the
toggle, picker or button on the trailing edge, so the control is never separated from the text it
belongs to. `SettingRowLabel` builds that pair and is the only piece shared between the screens; a
caution that has to stand out — the any-application detection mode, a calendar selection that
excludes everything — stays a colored line of its own instead.

## Meeting detection

Meeting Helper combines four signals, from precise to general.

| Layer | Signal | What it covers |
|---|---|---|
| Meeting process | Presence of `us.zoom.CptHost` | Zoom, native client |
| Process audio activity | `kAudioProcessPropertyIsRunningInput` over a bundle ID family | The browser is holding the microphone |
| Window title | Accessibility API | Distinguishes a meeting tab from other tabs and provides the meeting title |
| General input activity | `kAudioProcessPropertyIsRunningInput` for an application process | Optional selected-app and any-app modes |
| Process output activity | `kAudioProcessPropertyIsRunningOutput` over a bundle ID family | Picks the conferencing app when several applications hold the microphone |

Zoom spawns the `CptHost` helper process for the duration of a conference and terminates it when the
user leaves. This gives the app a precise start and end signal, unlike general microphone activity,
which also occurs during dictation and audio checks.

`CptHost` must be polled. It is an agent (`LSUIElement`), and `NSWorkspace` does not post
`didLaunchApplicationNotification` or `didTerminateApplicationNotification` for agents. They appear
in `runningApplications`, but no lifecycle notifications arrive for them. A live test confirmed that
leaving a conference produced a notification for `us.zoom.xos` but not for `us.zoom.CptHost`.

Browser meetings do not have an equivalent helper process. Meeting Helper therefore requires both
microphone activity and a window that one of the `BrowserMeetingService` entries claims. Without
Accessibility access, browser meeting detection is unavailable, while Zoom detection continues to
work.

**Settings > Recording** offers three detection modes. **Recognized meetings** is the default and
uses only the Zoom and browser signals above. **Selected apps using the microphone** also starts a
recording when one of the chosen application bundle ID families has an active input stream. **Any
app using the microphone** accepts every identifiable application except the configured exclusions.
The app process is always excluded because Meeting Helper itself opens the microphone after
recording starts. Both general modes persist the bundle ID and latest display name of every
identifiable application observed with an active input stream, including applications that are not
selected or are currently excluded. The add and exclude menus offer this history alongside the full
Applications folder picker.

General microphone activity must remain present for two consecutive two-second polls before a
recording starts. The same application must then be absent for three consecutive polls before it
stops. The asymmetric debounce ignores short microphone tests and prevents an audio route change
from splitting one call into several recordings. When several applications hold the microphone,
the detector keeps tracking the application that caused the start; another active application does
not keep that recording alive.

A meeting found this way has no service name to show, so the display name of the application that
held the microphone is saved in `meeting.json` and the meeting header names it — `Microphone app:
Telegram` rather than `Microphone app` alone. The recognized services and manual recordings do not
store the field, because their kind already names the source, and recordings saved before the field
existed keep showing the kind alone.

Which of several applications holding the microphone gets the recording is decided by output
activity: a conference plays the other participants for its whole duration, while a microphone filter
such as Krisp holds the input and never plays anything. Scoping the output tap to a filter records a
system track that contains nothing but its header, so a playing application always wins. Bundle ID
order used to make this choice on its own, which handed a call to whichever application happened to
sort first; it now only breaks the remaining ties, and keeps the choice the same from one poll to the
next.

The application already accumulating positive polls is kept when a second one joins the microphone,
so a filter starting a moment after the meeting app does not restart the countdown. It is given up as
soon as a playing application appears, because a conferencing app can open its output stream shortly
after it takes the microphone. Output activity is only a condition for starting: once a recording
runs, the tracked application holding the microphone is all that keeps it alive, and a stream that
closes mid-call does not end the meeting.

An application selected in **Settings > Recording** is stored by bundle ID rather than display name.
Helper processes are mapped back to their outer `.app` bundle when possible, and every matching Core
Audio process is included in the process-scoped output tap. Processes that cannot be mapped to an
application are ignored in the any-app mode so a Core Audio daemon cannot create a permanent false
meeting. The precise Zoom and recognized-browser paths run before general microphone detection, so
they keep their better titles and known audio bundle families when both signals are available.

Each service is described by a title test and the host of its installed PWA:

| Service | Window title | PWA host |
|---|---|---|
| Google Meet | Names Google Meet, or carries a meeting code such as `abc-defg-hij` | `meet.google.com` |
| Ktalk | Ends with the client's own app name, which it emits untranslated in every locale | `ktalk.ru` and any subdomain of it, such as an organization's `example.ktalk.ru` |

The Ktalk web client builds the document title as either its app name alone or
`<page> — <app name>`, so that name is the only stable marker a title carries. It is anchored to the
end of the title rather than searched for anywhere inside it, because as a bare substring the name
also occurs inside unrelated words, and such a tab would then claim a browser that is holding the
microphone for a real meeting elsewhere.

A PWA window has no title to read: Chrome exposes neither `AXTitle` nor `AXDocument` for one. Its
bundle records the URL it was installed from, so the host taken from `CrAppModeShortcutURL`
identifies the service, while the Accessibility API only confirms that a real window exists.
Subdomains match the configured host, which is what covers a Ktalk instance of an individual
organization.

Stopping a recording drains the transcription backlog and writes the mixdown, which can take a
minute on a long meeting. A meeting detected in that window is remembered and started once the
previous session is gone. Dropping it instead would lose it for good: the detector has already
recorded it as the current meeting and never reports the same start twice. The remembered meeting is
started only if the detector still reports it as running, so a short call that begins and ends inside
that window is not recorded after the fact.

## Audio capture and storage

The microphone goes through an `AVAudioEngine` tap. When the input device changes, the engine is
restarted automatically and gaps longer than one second are padded with silence to keep the track
on the shared timeline. Automatically detected meetings use a Core Audio process tap
(`AudioHardwareCreateProcessTap`, macOS 14.4+) scoped to the detected app, so unrelated audio is not
included. Manual recordings use a global system audio tap and include all system output.

A tap scoped to an application that never plays reports no error of its own: Core Audio starts it and
keeps it alive, the track keeps its bare header, and the meeting is saved without a system track. When
a started tap has delivered nothing fifteen seconds later, the name of the tapped source is written to
the log at error level, which is a level `log show` keeps on disk. A tap on an application that is
playing delivers buffers straight away, silent ones included, so the wait is only there to cover a
source that starts late.

A saved recording can contain the following files. Both audio tracks are normalized to 16 kHz mono
and written separately:

```text
~/Library/Application Support/MeetingHelper/Meetings/<uuid>/
    meeting.json     metadata, including the transcription model identifier
    mic.wav          my voice
    system.wav       the other participants' voices
    mix.m4a          mixdown for playback
    transcript.json  lines with timecodes and roles
```

When the app is asked to quit during a recording, it delays termination until capture has stopped,
the transcription backlog has drained, and the meeting files have been finalized.

### Playback

A saved meeting plays back from `mix.m4a`. Every transcript line carries its offset from the start
of the recording, and merging rewrites those offsets onto the merged timeline, so a line always
points at the same moment of the mixdown. Clicking a line plays the recording from the moment that
line was said, whether playback was already running or not.

The click has to land on the line's speaker, on its timecode, or on the space around the phrase.
The phrase itself is selectable text, which handles its own clicks so that a fragment can still be
selected with the mouse, and no gesture placed above it ever sees them. The live panel is not
clickable at all: a recording that is still running has nothing to play back yet.

### Merging recordings

Several saved recordings can be joined into one meeting. The result is a new meeting with its own
identifier and directory, built by actually concatenating the tracks, so everything downstream —
playback, transcript, synchronization, retention — keeps treating a meeting directory as
self-contained.

The two tracks of a recording rarely have the same length: the process tap attaches once the meeting
app touches audio, and neither source stops on the same buffer. Each recording therefore gets a
*span*, the longer of its two tracks as they are on disk, and both tracks are padded with silence to
fill it before the next recording is appended. `Meeting.duration` is not used for this — it also
counts the wall clock and is almost always longer than either track. Because both tracks of a
segment end up the same length, one shift moves that segment's whole transcript onto the merged
timeline, `Me` and `Others` alike. A recording with no track of a kind contributes silence for its
whole span, which keeps the other track from sliding forward.

Recordings are joined back to back with no gap: the time between two recordings is dropped, so a
merged meeting's `duration` no longer matches the wall-clock interval it covers. When the recordings
overlap in time, the sheet says so and joins them back to back anyway. The moment each part was
actually recorded survives in `Meeting.mergedSegments`, which also carries the offset and length of
every part; merging a merged meeting splices those parts in rather than collapsing them.

Recordings of one meeting normally agree on their kind and transcription model. When they do not,
both raw values are kept, joined with ` + `. A combined kind decodes as `DetectedMeeting.Kind`'s
`unknown` case, which older versions of the app — and the synchronization engine, which fails on
metadata it cannot decode — read without complaint. The transcript format is deliberately left
untouched: `TranscriptSource` has no tolerant decoding, so an added value there would cost a whole
transcript on a Mac running an older version.

The merged recording is assembled in a hidden staging directory, and the mixdown is rebuilt from the
joined tracks rather than joined from the sources' own `mix.m4a` files, whose encoder delay would
drift away from the transcript. The staging directory is moved into place before `meeting.json` is
written, so a synchronization running at the same time skips the directory instead of copying half a
meeting. Only after the merged meeting is saved are the originals removed, and always through
`MeetingStore`, which records the deletion markers the sync folder needs — a directory removed behind
its back would come back at the next reconciliation.

### Folder-based synchronization

The local Application Support directory remains the working library. Recording never writes into a
cloud-backed directory, so a slow or offline sync service cannot interrupt audio capture. After a
meeting is completely saved, the app can mirror its directory into a user-selected folder, normally
one inside iCloud Drive:

```text
<selected folder>/
    Meetings/<uuid>/       complete meeting directories
    DeletedMeetings/       small deletion markers
```

The folder is stored as a macOS bookmark. No app-owned iCloud container or iCloud entitlement is
required; iCloud Drive, Dropbox, or another provider is responsible for moving the ordinary files
between Macs. The app reconciles the folder after a local change, whenever it becomes active, and
every 30 seconds while synchronization is enabled.

The retention setting is disabled by default and supports the newest 10, 30, 50, or all meetings.
The limit is applied to the union of valid local and remote meeting metadata. Older remote copies
are removed from the sync folder, while local copies are retained. A meeting present on only the
remote side is downloaded when it belongs to the retained set.

Meeting UUIDs prevent independently recorded meetings from colliding. If the same meeting changes
on two Macs, the newer side wins, where "newer" is the most recent modification date among the files
in the directory rather than the metadata alone — a transcript can change while `meeting.json` stays
exactly as it was. The winning side is then mirrored file by file: only files whose size or
modification date differ are copied, and files the source no longer has are removed. A meeting
directory is mostly audio that never changes once the recording is saved, so editing a title
transfers a few hundred bytes instead of the whole recording. Each file is staged on the destination
volume and installed in one step, so no file is ever observed half written.
If a previous pass stopped between files, equal directory dates do not hide the partial copy: the
next pass compares file names and restores missing files from the complete side. If each side has a
different subset, their files are merged without deleting either subset.
Meeting kinds written by newer app versions are preserved and shown as "Other" when the current
version does not recognize them. A UUID directory without metadata is treated as an interrupted copy
and repaired when the complete meeting exists on the other side. Unreadable or inconsistent metadata
still fails the synchronization pass instead of being skipped with an up-to-date status. An
in-progress local recording without metadata is ignored until it is completely saved.
App-initiated deletion creates a permanent marker before removing the synchronized copy; this keeps
an offline Mac from uploading an old local copy again later. Turning synchronization off stops
reconciliation but deliberately leaves the current contents of the selected folder unchanged.

Reconciliation runs on a private serial queue rather than on Swift's cooperative thread pool. The
copies can block for minutes on a cold iCloud folder, and that pool holds only a handful of threads
shared with transcription. The queue being serial is also what keeps a recorded deletion from
interleaving with a reconciliation already in progress.

This feature is synchronization, not an independent backup. The selected provider must have enough
space for the audio files, and manually editing or deleting files inside the sync folder can bypass
the app's conflict and deletion rules. A live two-Mac test is still required for every supported
provider because download timing and placeholder behavior are controlled by that provider.

Separate tracks provide the initial attribution without diarization: microphone speech is labelled
"Me", and the meeting app's audio is labelled "Others". Speaker playback can leak into the
microphone, so two additional stages refine that attribution.

### Echo gate

The echo gate runs before recognition. Because both tracks share a timeline, each microphone
utterance can be compared against what the app was playing at that moment. Leakage is that playback
attenuated by the room, so once the acoustic delay is known it still matches the system track sample
for sample, while two people talking at once never do.

The app measures that delay from the recording itself, over the first few utterances with audible
playback. After that it labels each 300 ms of an utterance as silence, leakage or speech. An
utterance that is half leakage does not reach Whisper at all; one that merely begins or ends with
leakage — the far end's last words, picked up before the reply starts — has that part trimmed off
and keeps the rest. Level plays no part in the decision, so speech is kept however quiet it is.

With headphones, without a system track, or before the delay has been measured, the gate does not
fire. The recording window shows how many utterances it has compared and filtered. It can be
disabled in **Settings > Transcription**, which removes the reference buffer and the wait of up to
half a second for the system track to catch up. Thresholds and calibration measurements are
documented in [echo-gate-calibration.md](../knowledge/echo-gate-calibration.md).

### Transcript deduplication

Transcript deduplication runs after recognition. It compares near-simultaneous lines from the two
tracks and keeps the cleaner system-audio copy when both contain the same speech. It catches leakage
that passed the echo gate, while the echo gate handles cases where the two tracks produce different
words for the same speech. Deduplication is enabled by default and can be disabled in
**Settings > Transcription**.

### Hiding your own speech

The live transcript can leave the microphone lines out and show only the other participants. This
affects the display alone: the microphone is still captured, recognized, and written to the saved
transcript, so switching the lines back on brings the hidden ones with it.

Unlike the other transcript options, this switch is read every time the live views redraw instead of
being captured when the recording starts, which is what lets it be flipped mid-call. It is available
in **Settings > Live Transcript**, in the header of the recording window, and in the floating panel
header, where the eye icon next to "Me" also shows the current state.

## Transcription

Transcription uses Core ML through either WhisperKit or FluidAudio. **Settings > Transcription**
offers Whisper large-v3 turbo (~1.5 GB, the default), full Whisper large-v3 (~3 GB, the most
accurate and the slowest), and multilingual Parakeet TDT v3 (~600 MB). Both Whisper variants come
from the `argmaxinc/whisperkit-coreml` repository and share the same code path; their model files
are stored under:

```text
~/Library/Application Support/MeetingHelper/Models
```

Parakeet uses FluidAudio's model cache under `~/Library/Application Support/FluidAudio/Models`.
Both backends process complete audio buffers, so an energy-based VAD with an adaptive threshold
divides each track into utterances. An utterance closes after 0.8 seconds of silence or is forced
closed after 25 seconds. Each track has its own transcriber, and both use a shared actor that owns
the selected model.

Optional real-time updates recognize an expanding, overlapping audio snapshot every two seconds.
Each result updates a preview line in place. After a pause, the full-utterance result replaces the
preview, and only the final line is saved. This mode is disabled by default because it uses more
processing power.

The model selected when recording starts is fixed for that recording and stored with the meeting
metadata. The model picker is disabled until recording stops, and every recognition request verifies
that the captured model is loaded before it runs. The active recording and saved meeting headers show
its short name, and copied transcript text includes it before the timestamped lines. Meetings recorded
by older versions do not have this field and omit the model.

While a recording is active, utterances that arrive before its captured model is ready wait for that
model load instead of being dropped. If the recording stops before the model becomes ready, that
pending transcription work is discarded so stopping does not wait for the download. The model can be
downloaded in advance from **Settings > Transcription**. On later launches, the app loads the local
files and prepares Core ML without contacting the model repository. The interface distinguishes
device optimization from loading the optimized model into memory. Core ML does not expose progress
within device optimization; the first optimization can take 10 minutes or more, while the subsequent
load usually takes a few seconds. macOS caches the optimized model, so later launches are normally
much faster unless the system cache has been evicted.

## Calendar

Calendar integration is optional and read-only. It exists to answer two questions a recording
cannot answer on its own: what the meeting is actually called, and who was invited to it. The
attendee list is also the vocabulary speaker attribution draws on to turn anonymous voices into
names.

### Where the events come from

Events are read through EventKit, from the calendars macOS already syncs. Meeting Helper does not
speak to Google, or to any other calendar service, at all.

The alternative was the Google Calendar API, and it was built first. It requires an OAuth client,
which requires a Google Cloud project, which someone has to create, publish a consent screen for and
keep alive: while the screen stays in testing Google expires the sign-in after seven days, and the
client secret has to live somewhere. All of that is setup a user has to perform before the feature
does anything for them. Going through EventKit moves the entire problem to the system: the account
is added once in **System Settings > Internet Accounts**, where macOS performs the sign-in with its
own credentials, and every calendar it syncs afterwards is readable. The app ends up with no OAuth
client, no client secret, no tokens to store or refresh, and no network code.

What it costs is a dependency on the account being addable to macOS at all — an employer can forbid
it — and on macOS having synced the event already. An invitation accepted a minute ago on a phone
may not be on the Mac yet when the call starts.

Access is requested with `requestFullAccessToEvents`. macOS 14 splits calendar permission into full
and write-only; write-only cannot read anything, so it is treated exactly like a refusal. Both a
refusal and a device policy leave only System Settings as a way out, which is why the settings
screen offers that link instead of asking again — a second request returns the old answer without
showing a prompt.

Neither access nor the list of accounts reports back when it changes. `EKEventStoreChanged` covers
changes made while the app runs, and everything is re-read whenever the app becomes active, which
covers the rest. `EKEventStore` holds on to its sources until told otherwise, so `reset()` is what
makes an account added a moment ago visible.

### Reading events

Every calendar the account offers is enabled by default. **Settings > Calendar** stores the EventKit
identifiers of calendars the user disables, so newly discovered calendars remain enabled without
rewriting the preference. Only enabled calendars are queried, over a window from one hour back to
three hours ahead of the moment the recording starts. EventKit reads a local database, so this is a
plain query at the moment it is needed rather than a cache kept warm in the background: there is no
round trip worth avoiding, and therefore no window that can go stale.

All-day entries and cancelled events are dropped. An all-day entry spans every meeting of the day,
so keeping them would put a birthday reminder in front of the real event. A participant EventKit
identifies by something other than a `mailto:` URL is dropped too: the address is the identity
everything else keys on. An unrecognized attendee response value decodes as "needs action" rather
than failing the event, so a meeting cannot lose its whole roster over one field.

### Matching a recording to an event

Candidates are limited to events that the recording starts within ten minutes of — people join early
and calls run over. A single candidate in that window is selected even when its title differs from
the meeting window, because calendar metadata is the preferred source.

When multiple events are candidates, events with invited attendees are preferred over events that
contain only the current user or no attendees at all. If several candidates have invited attendees,
the one the current user accepted is preferred. If these rules do not identify exactly one event,
the match is ambiguous, so the recording keeps the window title and no participant list. An empty
calendar title also falls back to the window title while retaining the event's participant list.
Matching runs once, as the recording starts, so a title the user types afterwards is never at risk
of being overwritten.

The same event invited to both a work and a personal account arrives twice. Duplicates are collapsed
by `iCalUID` together with the start time, keeping the copy from the calendar where the invitation
was accepted. The start time is part of the key because every occurrence of a recurring series
carries the identifier of the series, and a four-hour window can hold two of them.

### What is stored

A matched event is copied into `meeting.json` as a snapshot — event id, title, organizer, the
calendar it came from, and the attendee list with each person's response — rather than referenced.
The event can be edited or deleted afterwards, and the recording still has to say who was in the
room at the time. The field is optional, so meetings recorded before calendar support decode
unchanged.

An older build of the app that saves a title edit over a newer `meeting.json` drops this field, the
same way it drops a meeting kind it does not recognize.

## Speaker attribution

Optional, on by default with the live transcript, and applied to the system track only. The
microphone is the account owner by definition, so asking a speaker model to confirm that would be
waste and would add a way to get it wrong.

### Where a voice comes from

Attribution reuses the utterances the VAD already cuts. Once a phrase has been recognized — and only
then, so a hallucination on near-silence cannot invent a voice nobody hears again — the same samples
go to FluidAudio's `wespeaker_v2` embedding model, and the resulting 256-dimensional vector is
matched against the voices heard so far. A match yields that voice's id; no match creates a new one.

The match uses a cosine-distance threshold tighter than the diarizer's own default (0.65 rather than
the 0.84 it would apply unprompted). The bias is deliberate, because the two ways of being wrong are
not equally costly: a voice split across two ids is put right in one click by naming both, but two
people merged under a single id cannot be separated afterward. So the threshold leans toward creating
a new voice over folding two together.

The embedding model reads a fixed ten-second window (160 000 samples at 16 kHz), so longer
utterances are cut to their first ten seconds before being handed over. By then the VAD has already
closed on 0.8 seconds of silence, which makes a single speaker within that window very likely.
Shorter audio is repeat-padded by the model itself. The true duration is passed along rather than
the padded one: below a second the speaker database will match an existing voice but refuses to
invent one, which is the right treatment for a half-second interjection.

Real-time previews are not attributed. They revisit the same audio every two seconds, so one
embedding per preview would be both waste and a flickering label. A line therefore gains its name at
the moment it finalizes, and reads as "Others" until then.

### Naming from the invitation

The calendar supplies names, not voices — there is no embedding for a person until somebody has said
who they are. What the invitation buys is narrower and still worth having:

- **A one-on-one names itself.** An event with exactly one other person on it makes the first voice
  on the system track almost certainly them, and it is named without a model saying so.
- **A short candidate list.** Stored voice profiles are seeded into the speaker database filtered to
  the people actually invited. Comparing against five voices instead of every voice ever heard is
  both cheaper and far harder to get wrong.
- **A closed pick list.** Naming a voice by hand is a choice among the attendees rather than free
  text, which keeps a person spelled the same way across meetings.

The one-on-one shortcut deliberately stops at the first voice. Anybody can join a scheduled call
uninvited, and handing that second voice the invited person's name would be a claim nothing supports
— so it stays "Speaker 2". If the uninvited person happened to speak first and took the name,
pointing the invited person at the voice that is really theirs takes the name off the other one in
the same step, rather than producing two people with one name.

### What is stored

Voices are numbered from one within a recording, and a transcript line carries only that id. The
names live in the meeting's own `speakers` table, so naming a voice is one edit and every line of
that voice follows. Both fields are optional, so meetings recorded before attribution decode
unchanged, and a line whose voice is missing from the table falls back to "Others".

Merging two recordings qualifies every voice id with the recording it came from. Each recording
numbers its voices independently, so "1" in two of them stands for two different people, and
collapsing them would claim a resemblance nothing has measured.

Naming a voice during a live recording also stores it, in a single local file:

```text
~/Library/Application Support/MeetingHelper/speakers.json
```

Each profile is an address, a display name and one embedding. A voice embedding is biometric data,
so the file sits beside the meeting library rather than inside it — the folder sync copies meeting
directories, and this must never travel with them. **Settings > Live Transcript** shows how many
voices are known and offers to forget all of them.

Renaming a voice on a saved meeting is possible too, but it only relabels that transcript. Teaching
a voice needs its embedding, and those exist only for as long as the recording that heard them.

### What it will not do

- Overlapping speech gets one label. The utterance is one embedding, and two voices in it produce a
  single answer.
- A speaker change *inside* one utterance is invisible. The VAD closes on 0.8 seconds of silence,
  and two people alternating faster than that land in the same utterance.
- Several people in one conference room, arriving through one microphone, will not reliably separate.
- The two models (`pyannote_segmentation` and `wespeaker_v2`, from
  `FluidInference/speaker-diarization-coreml`) are downloaded on first use in the background.
  Utterances that arrive before they are ready simply carry no voice; nothing waits and nothing is
  reported, because losing a name is far cheaper than losing the line.

## Permission handling

The app is intentionally not sandboxed because process-scoped audio taps and the Accessibility API
are unavailable under App Sandbox.

Local builds use an Apple Development identity configured in the ignored
`Config/LocalSigning.xcconfig` file. A stable signing identity is required because macOS privacy
permissions are tied to the app's designated code requirement; ad-hoc signatures change whenever
the executable changes and therefore invalidate previously granted access.

System audio access has no public API for checking its state. Process bundle IDs remain visible
without permission, and `AudioHardwareCreateProcessTap` returns `noErr` when access is denied while
delivering silence. Meeting Helper reads the state through the TCC SPI. As a fallback,
`RecordingSession` shows a warning when the tap remains near-silent for 20 seconds.

Besides the microphone, system audio recording and Accessibility, the app requests calendar access —
optionally, and only when the Calendar screen in Settings asks for it. It holds no Apple Events
entitlement and nothing in the code reaches for one.

Calendar access needs two things beyond the call itself, and missing either produces the same
silence. `NSCalendarsFullAccessUsageDescription` is the text the prompt shows. The
`com.apple.security.personal-information.calendars` entitlement is what allows the prompt to appear
at all: it reads like a sandbox entitlement, but the hardened runtime requires it too, and without
it TCC refuses to prompt and `requestFullAccessToEvents` returns as though nothing had been asked —
no error, no alert, no change of state. The refusal is visible only in `tccd`'s log, as *service
kTCCServiceCalendar requires entitlement com.apple.security.personal-information.calendars*.

When a meeting starts without microphone access, the detector keeps its state instead of clearing
it. Clearing would let the two-second poll re-fire the start immediately, raising the same alert
once per poll for the whole meeting; keeping it means the failure is reported once, and recording
can be started by hand after the permission is granted.

## Logging and privacy

Recordings, transcripts and metadata never leave the machine unless a sync folder is configured.
Nothing in the app contacts a network service, the calendar included: EventKit reads a local
database, and the syncing is the system's business.

Calendar access does put more personal data into the library. Granting it means the names and
addresses of the people invited to a meeting are written into `meeting.json`, and therefore into the
sync folder as well when synchronization is on. Revoking access in System Settings stops new
recordings from collecting it; the attendee lists already saved with past meetings are left alone.

Speaker attribution adds a second kind of personal data, and a more sensitive one: a voice embedding
identifies a person the way a fingerprint does. Those are written only when a voice is named by
hand, only to `speakers.json`, and never into a meeting directory — which is what keeps them out of
the sync folder. Nothing uploads them and no model leaves the machine to produce them.

Meeting titles, transcript text, and the names and addresses of participants are user data and are
logged with `privacy: .private`, so they appear as `<private>` in `log show` and Console. Only
non-identifying values — the meeting kind, permission states, audio formats, error descriptions —
are logged as `.public`, which is what makes a missed meeting debuggable after the fact without
exposing what was said or who was there.
