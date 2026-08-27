import Foundation

/// Drops utterances that are nothing but a non-lexical backchannel — the sounds a listener makes
/// to show they are still there: "Mm-hmm.", "Um...", "Э-э".
///
/// They are noise twice over. In the transcript they bury the phrases that carry the meeting; in
/// speaker attribution a two-second "mm-hmm", often spoken over somebody else, embeds badly and
/// founds a phantom voice of its own. Filtering happens where hallucinations are filtered — before
/// the phrase becomes a line, so neither problem starts.
///
/// Real short answers are deliberately not here: "Да.", "No.", "Okay." answer questions.
enum FillerFilter {
    /// Normalized spellings, matched against the whole utterance only. Like the hallucination
    /// list, these are model output being matched against, not interface text — the Cyrillic
    /// entries must stay Cyrillic.
    private static let fillers: Set<String> = [
        // English / generic Latin
        "hm", "m", "mhm", "hmhm", "um", "uh", "uhum", "uhuh", "er", "erm",
        "ah", "oh", "ugh", "aw",
        // Russian
        "м", "мгм", "хм", "э", "эм", "угу",
    ]

    /// Whether a recognised phrase is only a filler.
    static func isFiller(_ text: String) -> Bool {
        // Numbers are content — "3-5%, 2%." is somebody reading figures out loud.
        guard !text.contains(where: \.isNumber) else { return false }
        let normalized = normalize(text)
        // A phrase with no letters at all — "-", "..." — asserts nothing either.
        if normalized.isEmpty { return true }
        return fillers.contains(normalized)
    }

    /// Whisper spells the same sound a dozen ways: "Mm-hmm.", "Mm.", "Ummm,", "Uh-huh." Lowercase
    /// it, keep only the letters, and collapse each run of one letter — "mmhmm" and "m-hm" both
    /// become "mhm", "ummm" becomes "um".
    private static func normalize(_ text: String) -> String {
        var result = ""
        var previous: Character?
        for character in text.lowercased() where character.isLetter {
            if character != previous { result.append(character) }
            previous = character
        }
        return result
    }
}
