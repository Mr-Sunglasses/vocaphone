import Foundation

/// The emoji categories, in the order the panel shows them.
///
/// The same identifiers the Android keyboard uses, because both read the same
/// `catalog.tsv` — one file at `assets/keyboard/emoji/`, so the two platforms
/// cannot drift into offering different emoji.
enum EmojiCategory: String, CaseIterable, Identifiable, Sendable {
    case recents
    case smileys
    case people
    case animals
    case food
    case travel
    case activities
    case objects
    case symbols
    case flags

    var id: String { rawValue }

    var label: String {
        switch self {
        case .recents: "Recents"
        case .smileys: "Smileys"
        case .people: "People"
        case .animals: "Animals"
        case .food: "Food"
        case .travel: "Travel"
        case .activities: "Activities"
        case .objects: "Objects"
        case .symbols: "Symbols"
        case .flags: "Flags"
        }
    }

    /// The glyph on the category tab. Emoji rather than SF Symbols, because the
    /// tab bar of an emoji panel is the one place emoji *are* the vocabulary.
    var icon: String {
        switch self {
        case .recents: "🕒"
        case .smileys: "😀"
        case .people: "👋"
        case .animals: "🐻"
        case .food: "🍔"
        case .travel: "✈️"
        case .activities: "⚽"
        case .objects: "💡"
        case .symbols: "🔣"
        case .flags: "🚩"
        }
    }

    /// Everything with entries in the catalog. Recents is populated by use.
    static var browsable: [EmojiCategory] { allCases.filter { $0 != .recents } }
}

struct EmojiEntry: Equatable, Sendable {
    let glyph: String
    let category: EmojiCategory
    /// The CLDR annotation words, which is what search matches against — no
    /// network, no service, just the names Unicode publishes.
    let keywords: String
}

/// The shipped emoji list, and the search over it.
struct EmojiCatalog: Sendable {
    let entries: [EmojiEntry]

    static let empty = EmojiCatalog(entries: [])

    var isEmpty: Bool { entries.isEmpty }

    func entries(in category: EmojiCategory) -> [EmojiEntry] {
        entries.filter { $0.category == category }
    }

    /// Local search over the CLDR annotations.
    ///
    /// Prefix matches on a whole keyword first — someone typing "hear" wants
    /// "heart" before "brokenhearted" — then anything else containing the query.
    func search(_ query: String, limit: Int = 90) -> [EmojiEntry] {
        let needle = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !needle.isEmpty else { return [] }
        var leading: [EmojiEntry] = []
        var trailing: [EmojiEntry] = []
        for entry in entries {
            guard entry.keywords.contains(needle) else { continue }
            if entry.keywords.split(separator: " ").contains(where: { $0.hasPrefix(needle) }) {
                leading.append(entry)
            } else {
                trailing.append(entry)
            }
            if leading.count >= limit { break }
        }
        return Array((leading + trailing).prefix(limit))
    }

    // MARK: - Loading

    /// Glyph, category, keywords — one tab-separated line each. Malformed lines
    /// are skipped rather than failing the load: a keyboard that refuses to
    /// appear because one row of a data file is wrong is a worse outcome than a
    /// keyboard missing one emoji.
    static func parse(_ text: String) -> EmojiCatalog {
        var entries: [EmojiEntry] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3,
                  !parts[0].isEmpty,
                  let category = EmojiCategory(rawValue: String(parts[1]))
            else { continue }
            entries.append(
                EmojiEntry(
                    glyph: String(parts[0]),
                    category: category,
                    keywords: String(parts[2]).lowercased()
                )
            )
        }
        return EmojiCatalog(entries: entries)
    }

    static func load(from bundle: Bundle) -> EmojiCatalog {
        guard let url = bundle.url(forResource: "catalog", withExtension: "tsv")
            ?? bundle.url(forResource: "emoji/catalog", withExtension: "tsv"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return .empty }
        return parse(text)
    }
}

/// The five skin tones an emoji can be asked for, and which emoji can be asked.
///
/// Long-pressing a hand or a face on the system keyboard offers these, and a
/// panel without them quietly excludes most of its users from the emoji they
/// actually send. The eligibility test is Unicode's own — `isEmojiModifierBase`
/// is the property that exists to answer exactly this question — rather than a
/// hand-kept list that would go stale with every emoji release.
enum EmojiSkinTones {
    /// Light to dark, the order every keyboard shows them in.
    static let modifiers: [Unicode.Scalar] = [
        "\u{1F3FB}", "\u{1F3FC}", "\u{1F3FD}", "\u{1F3FE}", "\u{1F3FF}",
    ]

    /// The glyph with its skin tone stripped, so a recent emoji already in a
    /// tone still finds its own variants.
    static func base(of glyph: String) -> String {
        String(String.UnicodeScalarView(
            glyph.unicodeScalars.filter { !modifiers.contains($0) }
        ))
    }

    /// The tone variants of `glyph`, default first, or an empty array when the
    /// emoji has no tones.
    ///
    /// Only single-base emoji are offered. A ZWJ sequence — a family, a couple,
    /// a person with an occupation — takes a modifier on each of its people,
    /// and a row that changed only the first one would produce a glyph the user
    /// did not ask for and cannot easily undo.
    static func variants(of glyph: String) -> [String] {
        let stripped = base(of: glyph)
        var scalars = Array(stripped.unicodeScalars)
        // A trailing variation selector is presentation, not content.
        if scalars.last == "\u{FE0F}" { scalars.removeLast() }
        guard scalars.count == 1,
              let scalar = scalars.first,
              scalar.properties.isEmojiModifierBase
        else { return [] }
        return [stripped] + modifiers.map { modifier in
            var toned = String.UnicodeScalarView()
            toned.append(scalar)
            toned.append(modifier)
            return String(toned)
        }
    }

    static func hasVariants(of glyph: String) -> Bool {
        !variants(of: glyph).isEmpty
    }
}

/// The emoji this user reaches for, most recent first.
///
/// In the App Group so they survive the keyboard being torn down — which iOS
/// does constantly — and capped, because a recents row is a shortcut and a
/// shortcut with two hundred entries is just the catalog again.
enum EmojiRecents {
    static let key = "recentEmoji"
    static let limit = 30

    static var glyphs: [String] {
        KeyboardPreferences.defaults?.stringArray(forKey: key) ?? []
    }

    static func note(_ glyph: String) {
        var recents = glyphs.filter { $0 != glyph }
        recents.insert(glyph, at: 0)
        KeyboardPreferences.defaults?.set(Array(recents.prefix(limit)), forKey: key)
    }

    static func clear() {
        KeyboardPreferences.defaults?.removeObject(forKey: key)
    }
}
