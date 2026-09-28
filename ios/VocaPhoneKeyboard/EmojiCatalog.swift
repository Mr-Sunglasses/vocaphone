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
///
/// The shared file lists every skin tone as an emoji of its own, which is how
/// the Android panel offers them. This panel offers tones on a long press, as
/// the system keyboard does, so a toned form that a long-press row reaches is
/// held apart from the grid. That is a memory rule as much as a layout one:
/// every glyph drawn at panel size leaves about 50 KB in a Core Text cache that
/// is never given back, and People alone was 2,261 cells, 1,875 of them tones.
/// Scrolling it once cost more than a keyboard extension is allowed to use.
///
/// A pair in two different tones has no row to live in — the row is one tone
/// across — so it keeps its own cell, where it always was.
struct EmojiCatalog: Sendable {
    /// What the grid shows: each emoji in its default tone, plus the toned
    /// forms no long-press row offers.
    let entries: [EmojiEntry]
    /// Toned entries a long-press row offers. Search reaches these only when
    /// the default did not match, which is how "dark skin" still finds 👍🏿.
    private let toned: [EmojiEntry]
    /// Keyed by ``EmojiSkinTones/key(of:)``: the default glyph, then one
    /// variant per tone, lightest first.
    private let tones: [String: [String]]

    static let empty = EmojiCatalog(entries: [])

    init(entries: [EmojiEntry]) {
        var defaults: [String: String] = [:]
        var uniform: [String: [Int: String]] = [:]
        for entry in entries {
            let modifiers = EmojiSkinTones.modifiers(in: entry.glyph)
            let key = EmojiSkinTones.key(of: entry.glyph)
            guard let first = modifiers.first else {
                defaults[key] = defaults[key] ?? entry.glyph
                continue
            }
            if modifiers.allSatisfy({ $0 == first }),
               let index = EmojiSkinTones.modifiers.firstIndex(of: first)
            {
                uniform[key, default: [:]][index] = entry.glyph
            }
        }
        var tones: [String: [String]] = [:]
        for (key, found) in uniform {
            guard let base = defaults[key],
                  found.count == EmojiSkinTones.modifiers.count
            else { continue }
            tones[key] = [base] + found.keys.sorted().compactMap { found[$0] }
        }
        var shown: [EmojiEntry] = []
        var toned: [EmojiEntry] = []
        for entry in entries {
            if !EmojiSkinTones.modifiers(in: entry.glyph).isEmpty,
               tones[EmojiSkinTones.key(of: entry.glyph)]?.contains(entry.glyph) == true
            {
                toned.append(entry)
            } else {
                shown.append(entry)
            }
        }
        self.entries = shown
        self.toned = toned
        self.tones = tones
    }

    var isEmpty: Bool { entries.isEmpty }

    func entries(in category: EmojiCategory) -> [EmojiEntry] {
        entries.filter { $0.category == category }
    }

    /// The long-press row for `glyph`, default first, or an empty array when it
    /// has no tones. The catalog's own sequences first, so a person with an
    /// occupation gets the forms Unicode defines rather than a guess; the
    /// single-scalar rule covers an emoji the file does not list.
    ///
    /// A pair in two different tones has no row: the row is one tone across,
    /// and offering it from 🧑🏻‍🤝‍🧑🏿 would offer everything but what was pressed.
    func toneVariants(of glyph: String) -> [String] {
        guard let row = tones[EmojiSkinTones.key(of: glyph)] else {
            return EmojiSkinTones.variants(of: glyph)
        }
        let toned = !EmojiSkinTones.modifiers(in: glyph).isEmpty
        return !toned || row.contains(glyph) ? row : []
    }

    /// Local search over the CLDR annotations.
    ///
    /// Prefix matches on a whole keyword first — someone typing "hear" wants
    /// "heart" before "brokenhearted" — then anything else containing the query.
    /// A toned emoji is a result only when its default did not already match:
    /// "thumbs" is one thumbs up with a long press, not six of them.
    func search(_ query: String, limit: Int = 90) -> [EmojiEntry] {
        let needle = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !needle.isEmpty else { return [] }
        var leading: [EmojiEntry] = []
        var trailing: [EmojiEntry] = []
        var matchedKeys: Set<String> = []
        @discardableResult
        func consider(_ entry: EmojiEntry) -> Bool {
            guard entry.keywords.contains(needle) else { return false }
            if entry.keywords.split(separator: " ").contains(where: { $0.hasPrefix(needle) }) {
                leading.append(entry)
            } else {
                trailing.append(entry)
            }
            return true
        }
        for entry in entries {
            consider(entry)
            if leading.count >= limit { break }
        }
        for entry in leading + trailing {
            matchedKeys.insert(EmojiSkinTones.key(of: entry.glyph))
        }
        // One toned form per emoji, the long press holding the others — and
        // the most specific one: "dark skin" also matches "medium-dark skin",
        // and the shorter annotation is the tone that was asked for.
        var bestToned: [String: EmojiEntry] = [:]
        var order: [String] = []
        for entry in toned where entry.keywords.contains(needle) {
            let key = EmojiSkinTones.key(of: entry.glyph)
            guard !matchedKeys.contains(key) else { continue }
            if let current = bestToned[key] {
                if entry.keywords.count < current.keywords.count { bestToned[key] = entry }
            } else {
                bestToned[key] = entry
                order.append(key)
            }
        }
        for key in order where leading.count < limit {
            if let entry = bestToned[key] { consider(entry) }
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

    /// The tone modifiers in `glyph`, in order. Two for a pair of people.
    static func modifiers(in glyph: String) -> [Unicode.Scalar] {
        glyph.unicodeScalars.filter { modifiers.contains($0) }
    }

    /// What a glyph and each of its toned forms have in common: the glyph
    /// without tones or variation selectors. Unicode drops the selector after a
    /// modifier, so "🏌️‍♂️" and "🏌🏽‍♂️" only agree once both are gone.
    static func key(of glyph: String) -> String {
        String(String.UnicodeScalarView(
            glyph.unicodeScalars.filter { !modifiers.contains($0) && $0 != "\u{FE0F}" }
        ))
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
