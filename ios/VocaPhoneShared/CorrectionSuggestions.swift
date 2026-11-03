import Foundation

/// A spelling the user fixed after a dictation, offered under Suggested until
/// they add or dismiss it. Mirrors `CorrectionSuggestion` in
/// `CorrectionSuggestions.kt`.
struct CorrectionSuggestion: Codable, Equatable, Identifiable, Sendable {
    var heard: String
    var corrected: String
    /// Times the user made this fix.
    var occurrences: Int
    var lastSeen: Date
    var heardIsWord: Bool
    var namesTerm: Bool

    var id: String { Self.key(heard: heard, corrected: corrected) }

    /// One fix, whatever case the engine heard it in.
    static func key(heard: String, corrected: String) -> String {
        "\(heard.lowercased())→\(corrected)"
    }

    static func encode(_ suggestions: [CorrectionSuggestion]) -> Data? {
        try? JSONEncoder().encode(suggestions)
    }

    /// Unreadable storage is no suggestions.
    static func decode(_ data: Data?) -> [CorrectionSuggestion] {
        guard let data, let decoded = try? JSONDecoder().decode([CorrectionSuggestion].self, from: data) else {
            return []
        }
        return decoded
    }
}

/// What happens to the spellings the keyboard learns (`CorrectionWatch`):
/// suggested, added, or dismissed for good. Pure, so the app's storage stays
/// a thin wrapper. Mirrors `CorrectionSuggestions.kt`.
///
/// VocaMac adds a fixed name the first time, with Undo on screen. A phone has
/// no such moment, so this is more careful: a fix is suggested, and added
/// without asking only once the user has made the same fix
/// `repeatsBeforeAdding` times and it names something
/// (`LearnedCorrection.namesTerm`).
enum CorrectionSuggestions {
    static let capacity = 50
    static let dismissedCapacity = 200
    static let repeatsBeforeAdding = 2

    struct Received: Equatable {
        var suggestions: [CorrectionSuggestion]
        /// Fixes made often enough to add without asking; see `learn`.
        var added: [CorrectionSuggestion]
    }

    /// `suggestions` with `found` counted in. A dismissed fix, or one the
    /// lists already make (`isListed`), is skipped; one seen before moves to
    /// the top with its count raised, and comes out in `added` once it is
    /// due. The newest `capacity` are kept.
    static func receive(
        _ found: [LearnedCorrection],
        into suggestions: [CorrectionSuggestion],
        dismissed: [String],
        now: Date,
        isListed: (_ heard: String, _ corrected: String) -> Bool
    ) -> Received {
        var list = suggestions
        var added: [CorrectionSuggestion] = []
        let dismissedKeys = Set(dismissed)
        for correction in found {
            let key = CorrectionSuggestion.key(heard: correction.heard, corrected: correction.corrected)
            if dismissedKeys.contains(key) || isListed(correction.heard, correction.corrected) { continue }
            var seenBefore = 0
            if let index = list.firstIndex(where: { $0.id == key }) {
                seenBefore = list[index].occurrences
                list.remove(at: index)
            }
            let suggestion = CorrectionSuggestion(
                heard: correction.heard,
                corrected: correction.corrected,
                occurrences: seenBefore + 1,
                lastSeen: now,
                heardIsWord: correction.heardIsWord,
                namesTerm: correction.namesTerm
            )
            if suggestion.namesTerm, suggestion.occurrences >= repeatsBeforeAdding {
                added.append(suggestion)
            } else {
                list.insert(suggestion, at: 0)
            }
        }
        return Received(suggestions: Array(list.prefix(capacity)), added: added)
    }

    /// What adding a fix changes: the replacements, and a word for the
    /// vocabulary.
    struct Learned: Equatable {
        var replacements: [WordReplacement]
        var term: String
    }

    /// Adding `suggestion`: its corrected spelling becomes a custom word, so
    /// close spellings are fixed and the engines listen for it. When the
    /// engine heard different letters, or several words for one, it also
    /// becomes a replacement — unless what was heard is one ordinary word:
    /// fixing "cloud" to "Claude" once must not rewrite every cloud.
    static func learn(_ suggestion: CorrectionSuggestion, replacements: [WordReplacement]) -> Learned {
        let sameLetters = VocabularyCorrection.key(suggestion.heard) == VocabularyCorrection.key(suggestion.corrected)
        let joinsWords = suggestion.heard.trimmingCharacters(in: .whitespaces).contains(" ")
        let replaces = !suggestion.heardIsWord && (!sameLetters || joinsWords)
        let updated = replaces
            ? WordReplacements.adding(heard: suggestion.heard, written: suggestion.corrected, to: replacements)
            : replacements
        return Learned(replacements: updated, term: suggestion.corrected)
    }

    /// Whether the lists already make this fix: the word is a custom word, or
    /// a replacement writes it from what was heard.
    static func isListed(
        heard: String, corrected: String, replacements: [WordReplacement], vocabulary: [String]
    ) -> Bool {
        if vocabulary.contains(corrected) { return true }
        let lowered = heard.lowercased()
        return replacements.contains { row in
            row.written == corrected && row.heardForms.contains { $0.lowercased() == lowered }
        }
    }

    /// `dismissed` with `key` added, newest last, the oldest dropped past
    /// `dismissedCapacity`.
    static func dismissing(_ key: String, from dismissed: [String]) -> [String] {
        var keys = dismissed.filter { $0 != key }
        keys.append(key)
        return Array(keys.suffix(dismissedCapacity))
    }

    /// `vocabulary` (the stored custom-words text) with `term` added on its
    /// own line; a differently cased copy gives way, since the fix is the
    /// spelling wanted. Unchanged when the term is already there.
    static func vocabulary(_ vocabulary: String, adding term: String) -> String {
        let word = term.trimmingCharacters(in: .whitespacesAndNewlines)
        let terms = CustomVocabulary.terms(vocabulary)
        guard !word.isEmpty, !terms.contains(word) else { return vocabulary }
        let lowered = word.lowercased()
        guard terms.contains(where: { $0.lowercased() == lowered }) else {
            let trimmed = vocabulary.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? word : trimmed + "\n" + word
        }
        var kept = terms.filter { $0.lowercased() != lowered }
        kept.append(word)
        return kept.joined(separator: "\n")
    }
}
