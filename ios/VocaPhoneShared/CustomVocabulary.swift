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
        whisperPrompt(raw, maximumTokens: nil) { _ in 0 }
    }

    /// The prompt WhisperKit is given: the same list, cut to `maximumTokens`
    /// as `tokenCount` counts them.
    ///
    /// Characters are the wrong unit on this platform. WhisperKit's decoder has
    /// a 224-token context shared between the prompt and the transcript, keeps
    /// only the *last* 111 prompt tokens, and feeds every one of them through
    /// the decoder a token at a time before the first word of the window, on
    /// every window and every retry. Names are expensive: a 560-character list
    /// was 206 tokens, so the first half of it — the terms the user wrote
    /// first — was silently dropped while the rest cost 111 decoder passes and
    /// half the room the transcript had. Cutting here, at a term boundary and
    /// from the end, keeps the terms the user put first and pays for a few
    /// dozen passes instead. `VocabularyCorrection` still applies the whole
    /// list to the text afterwards, on every route.
    static func whisperPrompt(
        _ raw: String?,
        maximumTokens: Int?,
        tokenCount: (String) -> Int
    ) -> String {
        let terms = terms(raw)
        guard !terms.isEmpty else { return "" }
        var prompt = ""
        for term in terms {
            let separator = prompt.isEmpty ? "" : ", "
            let candidate = prompt + separator + term
            if candidate.count > maximumPromptCharacters { break }
            if let maximumTokens, tokenCount(candidate + ".") > maximumTokens { break }
            prompt = candidate
        }
        return prompt.isEmpty ? "" : prompt + "."
    }

    /// The prompt budget on iOS, in tokens: room for a dozen or so names, and
    /// a fraction of a second of decoder passes rather than the better part of
    /// two seconds.
    static let whisperKitPromptTokens = 48
}
