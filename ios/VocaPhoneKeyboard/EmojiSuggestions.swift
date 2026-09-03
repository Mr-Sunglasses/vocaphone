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
///
/// The table itself is ``EmojiTable``, in `VocaPhoneShared`, because
/// ``SpokenEmoji`` reads it too and runs in the app target. Only the loading
/// moved; what stays here is the strip's own policy about the table.
enum EmojiSuggestions {
    /// The shortest word worth matching. Two letters are mostly initials,
    /// particles and typos.
    static let minimumLength = EmojiTable.minimumLength

    static func glyph(for word: String) -> String? {
        EmojiTable.glyph(forKey: word.lowercased())
    }

    static let triggers: [String: String] = EmojiTable.triggers

    static func parse(_ text: String) -> [String: String] { EmojiTable.parse(text) }
}
