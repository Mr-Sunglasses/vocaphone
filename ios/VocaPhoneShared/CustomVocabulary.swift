import Foundation

/// Words a speech model is unlikely to know: names, places, project code names,
/// the jargon of whatever the user actually does.
///
/// Whisper takes a prompt that conditions the decoder, which is the one place a
/// user can teach it a spelling without retraining anything. The prompt is a
/// bias and not a rule — the model may still write "Kanishk" as "Kanish" — so
/// this exists to improve the odds, not to guarantee a spelling.
///
/// The stored text is shared with the Android client's `CustomVocabulary`, so
/// the parsing rules have to match: split on newlines and commas, keep phrases
/// with spaces in them intact.
enum CustomVocabulary {

    /// The prompt competes with the audio for the decoder's context window, and
    /// a long one measurably degrades transcription of everything the user did
    /// say. Whisper truncates past its own limit anyway; stopping well short of
    /// it keeps the context spent on speech.
    private static let maximumPromptCharacters = 640

    /// Long enough for "Ministry of Electronics and Information Technology".
    private static let maximumTermCharacters = 64

    /// Distinct terms in the order the user wrote them.
    ///
    /// Splitting on newlines and commas but not spaces is what lets "Claude
    /// Code" stay one phrase. Duplicates are compared case-insensitively while
    /// the first spelling is the one kept, because the whole point of the list
    /// is that the user's capitalization is the correct one.
    static func terms(_ raw: String?) -> [String] {
        guard let raw, !raw.isEmpty else { return [] }
        var seen = Set<String>()
        return raw
            .split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { part in
                String(part.prefix(maximumTermCharacters))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// The prompt text WhisperKit tokenizes into decoder prompt tokens, and the
    /// `initial_prompt` whisper.cpp takes on the other platform.
    ///
    /// A bare comma-separated list is what OpenAI documents for vocabulary
    /// biasing, and it reads to the decoder as a plausible run of text in the
    /// same domain as the speech. Truncation stops at a term boundary: half a
    /// name is worse than no name, because it biases toward a spelling nobody
    /// wants.
    static func whisperPrompt(_ raw: String?) -> String {
        let terms = terms(raw)
        guard !terms.isEmpty else { return "" }
        var prompt = ""
        for term in terms {
            let separator = prompt.isEmpty ? "" : ", "
            if prompt.count + separator.count + term.count > maximumPromptCharacters { break }
            prompt += separator + term
        }
        return prompt.isEmpty ? "" : prompt + "."
    }
}
