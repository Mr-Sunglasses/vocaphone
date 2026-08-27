import Foundation

/// The emoji offered for a word as it is typed: "lol" offers 😂, "flamingo" 🦩.
///
/// Not a lookup into ``EmojiCatalog``. The catalog's keywords exist to answer a
/// deliberate search in the emoji panel. Matched against ordinary prose they
/// answer "the" with 🤣, "and" with 🫢, "is" with the flag of Iceland, "dog"
/// with 💩 and "clock" with 🏫 — because a keyword match says a word appears
/// somewhere in an emoji's description, not that the emoji is what the word
/// means.
///
/// The strip table is `assets/keyboard/emoji/suggestions.tsv`, generated from
/// Unicode names, CLDR spoken names, and a short curated override list. Function
/// words stay off it: "good", "yes", "no", "time", "work", "day", "code",
/// "check", "key". Distinctive names cover most of the catalog; `lol` and
/// `dog` → 🐶 are overrides because Unicode does not call them that.
///
/// Exact whole words only. A prefix match would put an emoji on the strip
/// while the user is still two letters into a different word.
enum EmojiSuggestions {
    /// The shortest word worth matching. Two letters are mostly initials,
    /// particles and typos.
    static let minimumLength = 2

    static func glyph(for word: String) -> String? {
        let key = word.lowercased()
        guard key.count >= minimumLength else { return nil }
        return triggers[key]
    }

    static let triggers: [String: String] = load()

    static func parse(_ text: String) -> [String: String] {
        var table: [String: String] = [:]
        table.reserveCapacity(4_000)
        for line in text.split(whereSeparator: \.isNewline) {
            if line.isEmpty || line.first == "#" { continue }
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let word = parts[0].lowercased()
            let glyph = String(parts[1])
            guard !word.isEmpty, !glyph.isEmpty, table[word] == nil else { continue }
            table[word] = glyph
        }
        return table
    }

    private static func load() -> [String: String] {
        for url in candidateURLs() {
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                let parsed = parse(text)
                if !parsed.isEmpty { return parsed }
            }
        }
        return [:]
    }

    private static func candidateURLs() -> [URL] {
        var urls: [URL] = []
        let bundles = [Bundle(for: EmojiSuggestionsAnchor.self), .main]
        for bundle in bundles {
            if let url = bundle.url(forResource: "suggestions", withExtension: "tsv") {
                urls.append(url)
            }
            if let url = bundle.url(forResource: "emoji/suggestions", withExtension: "tsv") {
                urls.append(url)
            }
        }
        // Unit tests compile this file into a bundle that does not embed the
        // shared keyboard assets. The repository copy is the same file the
        // keyboard ships, and `#filePath` is how `EmojiCatalogTests` finds it.
        urls.append(
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("assets/keyboard/emoji/suggestions.tsv")
        )
        return urls
    }
}

/// `Bundle(for:)` needs a class. The enum above is not one.
private final class EmojiSuggestionsAnchor: NSObject {}
