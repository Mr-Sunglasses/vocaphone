import Foundation

protocol SnippetExpanding {
    func expand(in text: String, using snippets: [Snippet]) -> String
}

/// Expands every snippet trigger found in a finished transcript, in one pass.
///
/// One combined regex rather than looping snippet-by-snippet, so an expansion
/// that happens to contain another trigger is never itself re-expanded — a
/// second pass would see it as ordinary dictated text.
final class SnippetExpander: SnippetExpanding {
    func expand(in text: String, using snippets: [Snippet]) -> String {
        guard let (ordered, matches) = Self.matches(in: text, using: snippets) else { return text }

        var result = text
        // Reverse order, so replacing a later match never invalidates the
        // range of a match still waiting to be replaced.
        for match in matches.reversed() {
            guard let groupIndex = Self.matchedGroup(match), groupIndex - 1 < ordered.count,
                  let range = Range(match.range, in: result)
            else { continue }
            result.replaceSubrange(range, with: ordered[groupIndex - 1].expansion)
        }
        return result
    }

    /// Where the triggers `expand` would replace sit in `text`, found by the
    /// same pattern in the same single pass. For an earlier stage that must
    /// leave them exactly as they are.
    static func triggerRanges(in text: String, using snippets: [Snippet]) -> [Range<String.Index>] {
        guard let (_, matches) = matches(in: text, using: snippets) else { return [] }
        return matches.compactMap { Range($0.range, in: text) }
    }

    private static func matches(
        in text: String,
        using snippets: [Snippet]
    ) -> (ordered: [Snippet], matches: [NSTextCheckingResult])? {
        // A blank expansion is skipped rather than applied: the settings screen
        // will not save one, and a stored one would quietly delete its trigger
        // from every transcript, which is never what an empty field meant.
        let candidates = snippets.compactMap { snippet -> Snippet? in
            let trigger = snippet.trigger.trimmingCharacters(in: .whitespacesAndNewlines)
            let expansion = snippet.expansion.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trigger.isEmpty, !expansion.isEmpty else { return nil }
            var trimmed = snippet
            trimmed.trigger = trigger
            return trimmed
        }
        guard !candidates.isEmpty else { return nil }

        // Longest first, so "good morning team" wins over "good morning"
        // rather than the shorter trigger firing on a substring of it.
        let ordered = candidates.sorted { $0.trigger.count > $1.trigger.count }

        let pattern = ordered.map { "(\(Self.boundaryPattern(for: $0.trigger)))" }.joined(separator: "|")
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return nil }

        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return nil }
        return (ordered, matches)
    }

    private static func matchedGroup(_ match: NSTextCheckingResult) -> Int? {
        for index in 1..<match.numberOfRanges where match.range(at: index).location != NSNotFound {
            return index
        }
        return nil
    }

    /// A trigger that starts or ends on a letter, digit, or underscore is
    /// bounded by ``word`` spelled out rather than by `\b`, so this matches
    /// the Android expander character for character — `\b` resolves against
    /// each engine's own idea of a word character, and the two do not agree.
    /// A trigger that starts or ends on punctuation — "->", ")))" — has no
    /// word character to bound, and `\b` would never fire beside it anyway;
    /// a non-whitespace lookaround matches it at either edge of the string as
    /// well as between words.
    private static func boundaryPattern(for trigger: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: trigger)
        let left = isWordCharacter(trigger.first) ? "(?<!\(Self.word))" : "(?<!\\S)"
        let right = isWordCharacter(trigger.last) ? "(?!\(Self.word))" : "(?!\\S)"
        return left + escaped + right
    }

    /// Letters and digits in any script, plus the underscore.
    private static let word = "[\\p{L}\\p{N}_]"

    private static func isWordCharacter(_ character: Character?) -> Bool {
        guard let character else { return false }
        return character.isLetter || character.isNumber || character == "_"
    }
}
