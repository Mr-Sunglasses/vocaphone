import Foundation

/// Words a speech model is unlikely to know: names, places, project code names,
/// the jargon of whatever the user actually does.
///
/// Whisper takes a prompt that conditions the decoder, and Qwen3-ASR takes
/// hotwords, which is where a user can teach a model a spelling without
/// retraining anything (`RecognitionHints` builds both). Either is a bias and
/// not a rule — the model may still write "Kanishk" as "Kanish" — so this
/// exists to improve the odds, not to guarantee a spelling.
///
/// The stored text is shared with the Android client's `CustomVocabulary`, so
/// the parsing rules have to match: split on newlines and commas, keep phrases
/// with spaces in them intact.
enum CustomVocabulary {

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
}
