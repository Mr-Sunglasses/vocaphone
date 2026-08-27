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
