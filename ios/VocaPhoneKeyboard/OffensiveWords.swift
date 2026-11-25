import Foundation

/// Words the keyboard never offers: slurs never, swear words only when the
/// user turned on "Suggest swear words" (off by default, as on Apple's
/// keyboard and for the App Store's 4+ rating).
///
/// The list is `assets/keyboard/never-suggest.tsv`, shared with the Android
/// keyboard so both refuse the same words (`never-suggest.LICENSE`: LDNOOBW,
/// CC BY 4.0). Checked wherever a suggestion is looked up — completions,
/// guesses, predictions, swipe readings and the word autocorrect would apply —
/// never on what the user typed: a blocked word typed in full is left alone,
/// not corrected away. The user's own words (custom vocabulary, learned words,
/// text replacements) are never filtered.
struct OffensiveWords: Sendable, Equatable {
    private var slurs: Set<String> = []
    private var swears: Set<String> = []
    /// Two-word expressions, as "first second": the second word is blocked
    /// only right after the first, never alone.
    private var slurPairs: Set<String> = []
    private var swearPairs: Set<String> = []

    static let empty = OffensiveWords()

    var isEmpty: Bool { slurs.isEmpty && swears.isEmpty && slurPairs.isEmpty && swearPairs.isEmpty }

    /// Rows for every layout (`*`) and for English, the only language this
    /// keyboard suggests in.
    static func parse(_ text: String, layouts: Set<String> = ["*", "en"]) -> OffensiveWords {
        var words = OffensiveWords()
        for line in text.split(whereSeparator: \.isNewline) {
            guard !line.hasPrefix("#") else { continue }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 3, layouts.contains(String(fields[0])) else { continue }
            let entry = fields[2].lowercased().trimmingCharacters(in: .whitespaces)
            guard !entry.isEmpty else { continue }
            let isPair = entry.contains(" ")
            switch (fields[1], isPair) {
            case ("slur", false): words.slurs.insert(entry)
            case ("slur", true): words.slurPairs.insert(entry)
            case ("swear", false): words.swears.insert(entry)
            case ("swear", true): words.swearPairs.insert(entry)
            default: continue
            }
        }
        return words
    }

    static func load(from bundle: Bundle) -> OffensiveWords {
        guard let url = bundle.url(forResource: "never-suggest", withExtension: "tsv"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return .empty }
        return parse(text)
    }

    /// Whether `word` may not be offered, after `previous` (the word before it,
    /// for two-word expressions). A multi-word suggestion is checked whole.
    func blocks(_ word: String, after previous: String? = nil, allowSwears: Bool) -> Bool {
        let lowered = Self.normalized(word)
        guard !lowered.isEmpty else { return false }
        if lowered.contains(" ") {
            let parts = lowered.split(separator: " ").map(String.init)
            if slurPairs.contains(lowered) || (!allowSwears && swearPairs.contains(lowered)) { return true }
            return parts.contains { blocks($0, allowSwears: allowSwears) }
        }
        if slurs.contains(lowered) || (!allowSwears && swears.contains(lowered)) { return true }
        guard let previous else { return false }
        let pair = Self.normalized(previous) + " " + lowered
        return slurPairs.contains(pair) || (!allowSwears && swearPairs.contains(pair))
    }

    func filter(_ words: [String], after previous: String? = nil, allowSwears: Bool) -> [String] {
        guard !isEmpty else { return words }
        return words.filter { !blocks($0, after: previous, allowSwears: allowSwears) }
    }

    /// Curly apostrophes read as straight ones, so "don’t"-style spellings
    /// match the list's.
    private static func normalized(_ word: String) -> String {
        word.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .trimmingCharacters(in: .whitespaces)
    }
}
