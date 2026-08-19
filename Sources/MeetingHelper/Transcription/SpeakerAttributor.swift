import FluidAudio
import Foundation

/// Recognizes which voice a stretch of the "Others" track belongs to.
///
/// Owns the diarizer's models and its speaker database. Both are mutable and neither is `Sendable`,
/// hence the actor. One instance per recording: the numbering it hands out is local to the meeting,
/// and the voices it picks up during one call must not leak into the next.
actor SpeakerAttributor {
    /// The embedding model reads a fixed ten-second window — 160 000 samples at 16 kHz. Anything
    /// past that is ignored by the model, so an utterance is cut here rather than silently
    /// truncated somewhere inside CoreML.
    static let maximumSamples = 160_000

    /// Maximum cosine distance at which an utterance is treated as an already-heard voice rather
    /// than a new one. Deliberately tighter than what the diarizer would use on its own (0.84, via
    /// its `clusteringThreshold * 1.2`), because the trade-off here is asymmetric: a voice wrongly
    /// split across two ids is repaired in one click by naming both, but two people merged under one
    /// id cannot be separated at all. So we bias toward splitting. The single knob to tune — lower
    /// it if similar voices still merge, raise it if one person keeps fragmenting.
    static let matchThreshold: Float = 0.65

    /// Ids given to seeded profiles. They are deliberately not numbers: the diarizer numbers the
    /// voices it discovers itself from one upwards, and a shared id space would collide.
    private static let knownIDPrefix = "known-"

    struct Assignment: Sendable {
        let id: String
        /// The address of the stored profile this voice was recognized as, when one matched.
        let profileEmail: String?
    }

    private var diarizer: DiarizerManager?
    /// Which seeded id belongs to which stored profile. The diarizer's own `Speaker.name` is not
    /// used for this — it names the clusters it invents too, and the two must not be confused.
    private var profileEmails: [String: String] = [:]
    private var preparation: Task<Void, Never>?

    /// Downloads the models if needed, then seeds the voices of the people on the invitation.
    ///
    /// Failure is not fatal and not reported: the recording goes on without attribution, and the
    /// transcript keeps saying "Others" as it always did.
    func prepare(with profiles: [SpeakerProfile]) {
        guard diarizer == nil, preparation == nil else { return }

        preparation = Task {
            do {
                let models = try await DiarizerModels.downloadIfNeeded()
                let manager = DiarizerManager()
                manager.initialize(models: models)
                install(manager, seeding: profiles)
                Log.speakers.notice("Speaker attribution ready with \(profiles.count) known voices")
            } catch {
                Log.speakers.error("Speaker attribution unavailable: \(error, privacy: .public)")
            }
        }
    }

    /// Names the voice heard in one utterance, creating a new one when it matches nobody so far.
    ///
    /// Returns `nil` while the models are still loading, and for audio the embedding model refuses.
    /// The caller treats that as an unattributed line rather than an error — losing a name is a far
    /// smaller cost than losing the line.
    func assign(_ samples: [Float], duration: TimeInterval) -> Assignment? {
        guard let diarizer else { return nil }

        let window = samples.count > Self.maximumSamples
            ? Array(samples[0..<Self.maximumSamples])
            : samples
        guard let embedding = try? diarizer.extractSpeakerEmbedding(from: window),
              diarizer.validateEmbedding(embedding)
        else { return nil }

        // The true duration is passed rather than the padded window's: below a second the speaker
        // model will match an existing voice but refuses to invent one, which is the behaviour a
        // half-second interjection deserves.
        guard let speaker = diarizer.speakerManager.assignSpeaker(
            embedding,
            speechDuration: Float(duration),
            speakerThreshold: Self.matchThreshold
        ) else { return nil }

        return Assignment(id: speaker.id, profileEmail: profileEmails[speaker.id])
    }

    /// The voice's embedding as it stands, for storing it as a profile once it has a name.
    func embedding(forSpeaker id: String) -> [Float]? {
        diarizer?.speakerManager.getSpeaker(for: id)?.currentEmbedding
    }

    private func install(_ manager: DiarizerManager, seeding profiles: [SpeakerProfile]) {
        let known = profiles.enumerated().map { index, profile in
            Speaker(
                id: "\(Self.knownIDPrefix)\(index + 1)",
                name: profile.name,
                currentEmbedding: profile.embedding,
                isPermanent: true
            )
        }
        manager.initializeKnownSpeakers(known)

        profileEmails = Dictionary(
            uniqueKeysWithValues: zip(known.map(\.id), profiles.map(\.email))
        )
        diarizer = manager
    }
}
