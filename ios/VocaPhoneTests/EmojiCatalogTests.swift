import Foundation
import Testing

/// The emoji catalog, shared with the Android keyboard — one `catalog.tsv` at
/// `assets/keyboard/emoji/`, so the two platforms cannot drift into offering
/// different emoji or different search results.
struct EmojiCatalogTests {
    private static let fixture = EmojiCatalog.parse(
        """
        😀\tsmileys\tgrinning face smile happy
        ❤️\tsymbols\tred heart love
        💔\tsymbols\tbroken heart brokenhearted
        🐻\tanimals\tbear face
        malformed line
        🚫\tnotacategory\tprohibited
        """
    )

    @Test func wellFormedLinesParseAndTheRestAreSkipped() {
        #expect(Self.fixture.entries.count == 4)
        #expect(Self.fixture.entries.first?.glyph == "😀")
        #expect(Self.fixture.entries.first?.category == .smileys)
    }

    /// A keyboard that refuses to appear because one row of a data file is
    /// malformed is a worse outcome than a keyboard missing one emoji.
    @Test func anUnknownCategoryIsSkippedRatherThanFatal() {
        #expect(!Self.fixture.entries.contains { $0.glyph == "🚫" })
    }

    @Test func categoriesSelectTheirOwnEntries() {
        #expect(Self.fixture.entries(in: .symbols).count == 2)
        #expect(Self.fixture.entries(in: .animals).map(\.glyph) == ["🐻"])
        // Recents is populated by use, never by the catalog.
        #expect(Self.fixture.entries(in: .recents).isEmpty)
    }

    /// Someone typing "hear" wants "heart" before "brokenhearted": a whole-word
    /// prefix beats a match buried inside another word.
    @Test func searchPutsWholeWordPrefixesFirst() {
        let results = Self.fixture.search("heart").map(\.glyph)
        #expect(results.first == "❤️")
        #expect(results.contains("💔"))
    }

    @Test func searchIsCaseInsensitiveAndTrimmed() {
        #expect(Self.fixture.search("  BEAR ").map(\.glyph) == ["🐻"])
        #expect(Self.fixture.search("").isEmpty)
        #expect(Self.fixture.search("nothing at all").isEmpty)
    }

    @Test func everyBrowsableCategoryHasALabelAndAnIcon() {
        for category in EmojiCategory.allCases {
            #expect(!category.label.isEmpty)
            #expect(!category.icon.isEmpty)
        }
        #expect(!EmojiCategory.browsable.contains(.recents))
    }

    /// The shared file lists each tone as an emoji of its own. The grid shows
    /// one of each and offers the rest on a long press — a grid of every tone
    /// was 1,875 extra cells, and each drawn cell costs the extension memory it
    /// never gets back.
    private static let toned = EmojiCatalog.parse(
        """
        👍\tpeople\tthumbs up
        👍🏻\tpeople\tthumbs up light skin tone
        👍🏼\tpeople\tthumbs up medium-light skin tone
        👍🏽\tpeople\tthumbs up medium skin tone
        👍🏾\tpeople\tthumbs up medium-dark skin tone
        👍🏿\tpeople\tthumbs up dark skin tone
        🏌️‍♂️\tactivities\tman golfing
        🏌🏻‍♂️\tactivities\tman golfing light skin tone
        🏌🏼‍♂️\tactivities\tman golfing medium-light skin tone
        🏌🏽‍♂️\tactivities\tman golfing medium skin tone
        🏌🏾‍♂️\tactivities\tman golfing medium-dark skin tone
        🏌🏿‍♂️\tactivities\tman golfing dark skin tone
        🧑‍🤝‍🧑\tpeople\tpeople holding hands
        🧑🏻‍🤝‍🧑🏿\tpeople\tpeople holding hands light skin tone dark skin tone
        """
    )

    @Test func tonesStayOutOfTheGrid() {
        #expect(Self.toned.entries.map(\.glyph) == ["👍", "🏌️‍♂️", "🧑‍🤝‍🧑", "🧑🏻‍🤝‍🧑🏿"])
    }

    /// A pair in two tones has no long-press row to be found in, so it keeps
    /// its cell — and search finds it even when the untoned pair matches too.
    @Test func aMixedTonePairKeepsItsCell() {
        #expect(Self.toned.entries(in: .people).map(\.glyph).contains("🧑🏻‍🤝‍🧑🏿"))
        #expect(Self.toned.search("holding hands").map(\.glyph) == ["🧑‍🤝‍🧑", "🧑🏻‍🤝‍🧑🏿"])
    }

    @Test func aLongPressOffersEveryUniformTone() {
        #expect(Self.toned.toneVariants(of: "👍") == ["👍", "👍🏻", "👍🏼", "👍🏽", "👍🏾", "👍🏿"])
        // Unicode drops the variation selector after a modifier; the row must
        // still find the toned forms of a glyph that carries one.
        #expect(Self.toned.toneVariants(of: "🏌️‍♂️").count == 6)
        #expect(Self.toned.toneVariants(of: "🏌🏽‍♂️").first == "🏌️‍♂️")
        // A recent emoji already in a tone opens the same row.
        #expect(Self.toned.toneVariants(of: "👍🏾") == Self.toned.toneVariants(of: "👍"))
        // Two people in two different tones is not a row of six.
        #expect(Self.toned.toneVariants(of: "🧑‍🤝‍🧑").isEmpty)
        #expect(Self.toned.toneVariants(of: "🧑🏻‍🤝‍🧑🏿").isEmpty)
        #expect(Self.toned.toneVariants(of: "🐻").isEmpty)
    }

    /// An emoji the file does not list still gets its tones from Unicode.
    @Test func aSingleScalarOutsideTheFileStillHasTones() {
        #expect(EmojiCatalog.empty.toneVariants(of: "👋").count == 6)
    }

    @Test func searchOffersTheDefaultAndReachesTonesOnlyWhenAsked() {
        #expect(Self.toned.search("thumbs").map(\.glyph) == ["👍"])
        // Nothing untoned matches "dark", so the toned forms are the results —
        // one per emoji, with the rest a long press away.
        let dark = Self.toned.search("dark").map(\.glyph)
        #expect(dark.contains("🧑🏻‍🤝‍🧑🏿"))
        #expect(dark.filter { EmojiSkinTones.key(of: $0) == "👍" } == ["👍🏿"])
        #expect(Self.toned.search("medium-dark").map(\.glyph).contains("👍🏾"))
        #expect(Self.toned.search("medium skin").map(\.glyph).contains("👍🏽"))
    }

    /// The real file, which both platforms read. Tolerant assertions: this
    /// checks the format and the wiring, not Unicode's contents.
    @Test func theSharedCatalogParses() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("assets/keyboard/emoji/catalog.tsv")
        let text = try String(contentsOf: root, encoding: .utf8)
        let catalog = EmojiCatalog.parse(text)

        #expect(catalog.entries.count > 1_000)
        // The grid holds no tone a long press offers; mixed pairs keep a cell.
        #expect(!catalog.entries.contains { EmojiSkinTones.modifiers(in: $0.glyph).count == 1 })
        #expect(catalog.entries.count < 2_200)
        #expect(catalog.toneVariants(of: "👍").count == 6)
        #expect(catalog.toneVariants(of: "🧑‍💻").count == 6)
        // The real file has both the uniform pairs and the mixed ones: a mixed
        // pair must not open the uniform row.
        #expect(catalog.toneVariants(of: "🧑‍🤝‍🧑").count == 6)
        #expect(catalog.toneVariants(of: "🧑🏻‍🤝‍🧑🏿").isEmpty)
        // Every browsable category has something in it, or its tab would open
        // onto an empty grid.
        for category in EmojiCategory.browsable {
            #expect(
                !catalog.entries(in: category).isEmpty,
                "\(category.label) has no emoji"
            )
        }
        #expect(!catalog.search("heart").isEmpty)
        // Concatenated Unicode names, so a search for the name people type
        // still hits — "thumbs up" was already there as two words.
        #expect(catalog.search("thumbsup").map(\.glyph).contains("👍"))
        #expect(catalog.search("hotdog").map(\.glyph).contains("🌭"))
        #expect(catalog.search("trex").map(\.glyph).contains("🦖"))
    }
}
