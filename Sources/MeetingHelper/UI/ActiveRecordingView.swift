import SwiftUI

struct ActiveRecordingView: View {
    @EnvironmentObject private var controller: AppController
    @ObservedObject var session: RecordingSession

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            let lines = session.visibleLines
            if lines.isEmpty {
                status
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TranscriptView(lines: lines, speakers: session.roster.speakers, autoScroll: true)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Circle()
                    .fill(.red)
                    .frame(width: 10, height: 10)

                TextField("Meeting title", text: $session.title)
                    .textFieldStyle(.plain)
                    .font(.title2.weight(.semibold))

                Spacer()

                Text(session.elapsed.clockString)
                    .font(.title3.monospacedDigit())
                    .foregroundStyle(.secondary)

                Button(session.systemAudioEnabled ? "Microphone only" : "Record system audio") {
                    session.setSystemAudioEnabled(!session.systemAudioEnabled)
                }
                .disabled(controller.isStopping)
                .help("Starts or stops capturing the other participants for this recording only. The default for new recordings is in Settings > Recording.")

                Button(controller.settings.liveTranscriptShowsMySpeech ? "Hide my speech" : "Show my speech") {
                    controller.settings.liveTranscriptShowsMySpeech.toggle()
                }
                .help("Hides or shows the microphone lines in the live transcript and in the floating panel. The saved transcript always keeps them.")

                Button(controller.isPanelVisible ? "Hide panel" : "Show panel") {
                    controller.togglePanel()
                }

                Button("Stop") {
                    controller.stopRecording()
                }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(controller.isStopping)
            }

            HStack(spacing: 20) {
                LevelMeter(title: "Microphone", level: session.micLevel, isActive: session.micState == .capturing)
                LevelMeter(title: "System audio", level: session.systemLevel, isActive: session.systemState == .capturing)
            }

            HStack(spacing: 20) {
                Label("Microphone: \(session.microphoneDeviceName)", systemImage: "mic")
                if session.systemAudioEnabled {
                    Label("Audio source: \(session.systemAudioSourceName)", systemImage: "speaker.wave.2")
                } else {
                    Label("Audio source: microphone only", systemImage: "speaker.slash")
                }
                if let model = session.transcriptionModel {
                    Label(
                        "Transcription: \(AppSettings.displayName(forModel: model))",
                        systemImage: "waveform"
                    )
                }
                echoGate
                if let calendar = session.calendar {
                    CalendarParticipantsLabel(info: calendar)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            // Naming a voice is only possible here, while the recording still holds its embeddings.
            // Doing it now is also what teaches the app to recognize that person next time.
            SpeakerLegend(
                speakers: session.roster.speakers,
                attendees: session.roster.attendees,
                assign: { attendee, id in session.assign(attendee, toSpeaker: id) }
            )

            if session.systemSilent {
                HStack {
                    if controller.systemAudioPermission == .denied {
                        Label("System audio access is disabled.", systemImage: "exclamationmark.triangle.fill")
                        Button("Open Settings") { SystemAudioPermission.openSystemSettings() }
                            .buttonStyle(.link)
                    } else {
                        Label("No system audio detected yet. This is normal while the meeting is quiet.", systemImage: "waveform.slash")
                    }
                }
                .font(.caption)
                .foregroundStyle(.orange)
            }

            if case .unavailable(let message) = session.systemState {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if case .unavailable(let message) = session.micState {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(20)
    }

    /// Live state of the echo gate: whether it is comparing anything at all, how much speaker
    /// leakage it has kept out of the transcript, and a highlight right after it fires.
    private var echoGate: some View {
        Label(echoGateText, systemImage: echoGateIcon)
            .foregroundStyle(session.echoGateFiring ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
            .help("Speaker playback that leaks into the microphone is recognized before recognition and left out of the transcript. With headphones there is nothing to filter. Switchable in Settings; the switch takes effect on the next recording.")
    }

    private var echoGateIcon: String {
        guard session.echoGateEnabled, session.systemAudioEnabled else { return "waveform.slash" }
        return session.echoGateFiltered > 0 ? "waveform.badge.minus" : "waveform"
    }

    private var echoGateText: String {
        guard session.echoGateEnabled else { return "Echo gate: off" }
        // Without a system track there is no playback to leak into the microphone, so the gate
        // has nothing to compare against.
        guard session.systemAudioEnabled else { return "Echo gate: idle, microphone only" }
        guard session.echoGateChecked > 0 else { return "Echo gate: standing by" }
        guard session.echoGateFiltered > 0 else {
            return "Echo gate: nothing to filter (\(session.echoGateChecked) checked)"
        }
        return "Echo gate: filtered \(session.echoGateFiltered) of \(session.echoGateChecked)"
    }

    @ViewBuilder
    private var status: some View {
        VStack(spacing: 8) {
            switch session.transcriptionState {
            case .downloading(let progress):
                if let progress {
                    ProgressView(value: progress).frame(width: 180)
                    Text("Downloading the speech recognition model — \(progress.formatted(.percent.precision(.fractionLength(0))))")
                } else {
                    ProgressView().controlSize(.small)
                    Text("Starting the speech recognition model download…")
                }
            case .preparing(let stage):
                ProgressView().controlSize(.small)
                Text(stage.statusText)
                Text(stage.detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .running:
                Image(systemName: "waveform").font(.largeTitle).foregroundStyle(.tertiary)
                Text("Listening. Lines will show up here a couple of seconds after the first phrase.")
            case .disabled:
                Image(systemName: "waveform.slash").font(.largeTitle).foregroundStyle(.tertiary)
                Text("Live transcript is off. Audio is still being recorded.")
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
                Text("Recognition unavailable: \(message)")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 420)
        .padding()
    }
}
