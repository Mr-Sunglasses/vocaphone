import Testing

/// The table is the feature. Matching is three lines; what decides whether the
/// strip reads as clever or as broken is which words are in it — slang,
/// obvious associations, and the distinctive Unicode name of almost every
/// emoji, but never ordinary prose.
struct EmojiSuggestionsTests {
    @Test func theWordsPeopleExpectAreOffered() {
        #expect(EmojiSuggestions.glyph(for: "lol") == "😂")
        #expect(EmojiSuggestions.glyph(for: "pizza") == "🍕")
        #expect(EmojiSuggestions.glyph(for: "birthday") == "🎂")
        #expect(EmojiSuggestions.glyph(for: "thanks") == "🙏")
        #expect(EmojiSuggestions.glyph(for: "fire") == "🔥")
        #expect(EmojiSuggestions.glyph(for: "flamingo") == "🦩")
        #expect(EmojiSuggestions.glyph(for: "saxophone") == "🎷")
        #expect(EmojiSuggestions.glyph(for: "thumbsup") == "👍")
        #expect(EmojiSuggestions.glyph(for: "trex") == "🦖")
        #expect(EmojiSuggestions.glyph(for: "laugh") == "😂")
    }

    /// Case is not part of the word. "LOL" is the same trigger as "lol".
    @Test func matchingIgnoresCase() {
        #expect(EmojiSuggestions.glyph(for: "LOL") == "😂")
        #expect(EmojiSuggestions.glyph(for: "Pizza") == "🍕")
    }

    /// Whole words only. A prefix match would put an emoji on the strip while
    /// the user is still two letters into a different word — "car" offering 🚗
    /// to someone typing "carefully".
    @Test func onlyWholeWordsMatch() {
        #expect(EmojiSuggestions.glyph(for: "lolly") == nil)
        #expect(EmojiSuggestions.glyph(for: "carefully") == nil)
        #expect(EmojiSuggestions.glyph(for: "car") == "🚗")
        #expect(EmojiSuggestions.glyph(for: "l") == nil)
        #expect(EmojiSuggestions.glyph(for: "") == nil)
    }

    /// The failure mode that would make this unusable. A keyword lookup into
    /// the emoji catalog answers every one of these — "the" with 🤣, "is" with
    /// a flag — because appearing in a description is not the same as being
    /// what the word means.
    @Test func ordinaryProseGetsNothing() {
        for word in [
            "the", "and", "is", "was", "of", "to", "it", "that", "this", "with",
            "have", "from", "they", "there", "about", "would", "should",
            // Excluded on purpose: common in sentences that have nothing to do
            // with the emoji they would otherwise attract.
            "good", "yes", "no", "time", "work", "day", "code", "check", "key",
        ] {
            #expect(EmojiSuggestions.glyph(for: word) == nil, "\(word) should offer nothing")
        }
    }

    /// Every entry has to be a single glyph the strip can draw. A stray word or
    /// an empty value would render as a chip with text in it.
    @Test func everyEntryIsOneEmojiForOneLowercaseWord() {
        for (word, glyph) in EmojiSuggestions.triggers {
            #expect(word == word.lowercased(), "\(word) is not lowercased")
            #expect(word.count >= EmojiSuggestions.minimumLength)
            // `allSatisfy` is rethrowing too, so it is answered here rather
            // than inside the macro.
            let isPlainWord = word.allSatisfy(\.isLetter)
            #expect(isPlainWord, "\(word) is not a plain word")
            #expect(!glyph.isEmpty)
            // One grapheme, so the chip is a glyph rather than a phrase. Flags
            // and skin-tone variants are single graphemes too, which is the
            // point of counting characters rather than scalars.
            #expect(glyph.count == 1, "\(word) maps to \(glyph.count) characters")
            // Answered outside the macro: `contains(where:)` is rethrowing, and
            // `#expect` will not take a call it thinks can throw.
            let carriesAnEmojiScalar = glyph.unicodeScalars.contains { $0.properties.isEmoji }
            #expect(carriesAnEmojiScalar, "\(word) maps to something that is not an emoji")
        }
    }

    /// Distinctive Unicode names are generated; the curated list is only the
    /// slang and the cases where the obvious glyph is not the literal name.
    @Test func distinctiveNamesAreOffered() {
        #expect(EmojiSuggestions.glyph(for: "cactus") == "🌵")
        #expect(EmojiSuggestions.glyph(for: "penguin") == "🐧")
        #expect(EmojiSuggestions.glyph(for: "unicorn") == "🦄")
        #expect(EmojiSuggestions.glyph(for: "abacus") == "🧮")
        #expect(EmojiSuggestions.glyph(for: "dragon") == "🐉")
        #expect(EmojiSuggestions.glyph(for: "hotdog") == "🌭")
    }

    /// Most of the catalog is reachable by typing a name. The uncovered rest
    /// are long phrases and ambiguous generics (`face`, `person` sequences).
    @Test func theTableCoversMostNamedEmoji() {
        #expect(EmojiSuggestions.triggers.count > 2_000)
        let glyphs = Set(EmojiSuggestions.triggers.values)
        #expect(glyphs.count > 1_500)
    }
}
