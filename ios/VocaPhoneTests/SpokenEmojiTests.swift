import Testing

/// The rules that stop "emoji" being eaten out of ordinary sentences. Each one
/// exists because the obvious implementation gets it wrong.
struct SpokenEmojiTests {
    @Test func aDescriptorAndTheTriggerBecomeTheGlyph() {
        #expect(SpokenEmoji.glyphs(in: "I'm so sad crying emoji") == "I'm so sad 😭")
    }

    /// The worked example from the plan, and the case that proves repeats need
    /// no special handling: two triggers are two independent matches.
    @Test func repeatedTriggersEachConvert() {
        #expect(
            SpokenEmoji.glyphs(in: "I'm so sad crying emoji crying emoji")
                == "I'm so sad 😭 😭"
        )
    }

    /// Keys are the descriptor with its spaces removed, so a multi-word
    /// descriptor resolves without the table having to store the spacing.
    @Test func multiWordDescriptorsResolve() {
        #expect(SpokenEmoji.glyphs(in: "nice work thumbs up emoji") == "nice work 👍")
        #expect(SpokenEmoji.glyphs(in: "shrug emoji") == "🤷")
    }

    /// The spoken forms added to `tools/emoji-suggestion-overrides.tsv` when
    /// this shipped. The generated names cover most of the catalog, but these
    /// are how people say them out loud, and without them the table answered
    /// with the words instead of the glyph.
    @Test func spokenPhrasingsResolve() {
        #expect(SpokenEmoji.glyphs(in: "heart eyes emoji") == "😍")
        #expect(SpokenEmoji.glyphs(in: "praying hands emoji") == "🙏")
        #expect(SpokenEmoji.glyphs(in: "tears of joy emoji") == "😂")
        #expect(SpokenEmoji.glyphs(in: "check mark emoji") == "✅")
    }

    /// The longest phrase wins. "loudly crying" and "crying" are both keys, and
    /// stopping at the first match would leave the word "loudly" behind.
    @Test func theLongestPhraseWins() {
        #expect(SpokenEmoji.glyphs(in: "loudly crying emoji") == "😭")
    }

    /// Three emoji dictated in a row: the pauses arrive as commas, and
    /// substituting each phrase in place would leave them stranded between the
    /// glyphs. A run of emoji is a run, not a list.
    @Test func punctuationBetweenTwoGlyphsCollapses() {
        #expect(
            SpokenEmoji.glyphs(in: "Crying emoji, crying emoji, crying emoji.")
                == "😭 😭 😭."
        )
        // A longer pause is written down as a full stop, and "😭. 😭." is no
        // more something a person types than "😭, 😭".
        #expect(SpokenEmoji.glyphs(in: "Crying emoji. Fire emoji.") == "😭 🔥.")
        // Already a plain space: nothing to collapse, nothing changed.
        #expect(SpokenEmoji.glyphs(in: "crying emoji crying emoji") == "😭 😭")
    }

    /// The collapse must not reach past the run. Punctuation that belongs to
    /// the sentence around the emoji stays exactly where the styler put it.
    @Test func punctuationOutsideTheRunIsUntouched() {
        #expect(SpokenEmoji.glyphs(in: "fire emoji, then home") == "🔥, then home")
        #expect(
            SpokenEmoji.glyphs(in: "I'm sad crying emoji, but fire emoji, then home")
                == "I'm sad 😭, but 🔥, then home"
        )
        // Words between two glyphs are not punctuation, so nothing collapses.
        #expect(SpokenEmoji.glyphs(in: "crying emoji and fire emoji") == "😭 and 🔥")
    }

    /// A trigger with nothing it recognizes in front of it is left exactly as
    /// spoken. This is the case the feature is judged on: it must never guess.
    @Test func anUnmatchedTriggerIsLeftAlone() {
        #expect(SpokenEmoji.glyphs(in: "Send me the emoji.") == "Send me the emoji.")
        #expect(SpokenEmoji.glyphs(in: "emoji") == "emoji")
        // "emoji" is not itself a key, so a trigger cannot match its neighbour.
        #expect(SpokenEmoji.glyphs(in: "emoji emoji") == "emoji emoji")
    }

    @Test func theTriggerMayBePluralized() {
        #expect(SpokenEmoji.glyphs(in: "add fire emojis") == "add 🔥")
    }

    /// Styling has already run, so the trigger arrives carrying whatever mark
    /// the style put on it. Only the words are replaced, which leaves the mark
    /// and the spacing exactly where the styler left them.
    @Test func punctuationTheStylerAttachedSurvives() {
        #expect(SpokenEmoji.glyphs(in: "I'm so sad crying emoji.") == "I'm so sad 😭.")
        #expect(SpokenEmoji.glyphs(in: "That was fun party emoji!") == "That was fun 🎉!")
        #expect(SpokenEmoji.glyphs(in: "fire emoji, then home") == "🔥, then home")
    }

    /// Formal capitalizes a sentence start, so a descriptor can arrive
    /// capitalized. Matching is case-insensitive.
    @Test func aCapitalizedDescriptorStillMatches() {
        #expect(SpokenEmoji.glyphs(in: "Crying emoji. That was rough.") == "😭. That was rough.")
    }

    /// Only a space or a hyphen joins a descriptor to its trigger. A comma is a
    /// clause boundary, and reading through it would take a word out of the
    /// sentence before.
    @Test func punctuationInsideThePhraseEndsIt() {
        #expect(SpokenEmoji.glyphs(in: "I was crying, emoji") == "I was crying, emoji")
    }

    /// Masked before the walk, so a descriptor cannot be taken out of an
    /// address. The dot makes this a hostname, not a trigger.
    @Test func addressesAreNotEaten() {
        #expect(SpokenEmoji.glyphs(in: "see crying emoji.com") == "see crying emoji.com")
        #expect(
            SpokenEmoji.glyphs(in: "mail fire emoji@example.com")
                == "mail fire emoji@example.com"
        )
    }

    /// Nothing about a transcript in another script matches an English table,
    /// which is the whole language policy: untouched beats partially mangled.
    @Test func otherLanguagesPassThrough() {
        #expect(SpokenEmoji.glyphs(in: "मैं बहुत खुश हूँ।") == "मैं बहुत खुश हूँ।")
    }

    @Test func textWithNoTriggerIsReturnedUnchanged() {
        #expect(SpokenEmoji.glyphs(in: "just an ordinary sentence") == "just an ordinary sentence")
        #expect(SpokenEmoji.glyphs(in: "") == "")
    }

    /// The lookback is bounded by the table's own widest key rather than a
    /// guessed word count, so the bound cannot drift from the data.
    @Test func theTableSuppliesItsOwnLookbackBound() {
        #expect(EmojiTable.widestKeyLength > 0)
        #expect(EmojiTable.triggers["loudlycrying"] == "😭")
        #expect(EmojiTable.triggers["emoji"] == nil)
    }

    /// The single-byte pre-check must be invisible. It skips text with no "j"
    /// in it, so the cases that matter are the ones that still have to work
    /// after passing it — and the ones it correctly lets through.
    @Test func theFastPathChangesNothing() {
        // No "j" anywhere: skipped, and identical either way.
        let untouched = "no trigger anywhere in this sentence at all"
        #expect(SpokenEmoji.glyphs(in: untouched) == untouched)
        // A "j" from an ordinary word, no trigger: falls through to the full
        // walk, which declines it.
        #expect(SpokenEmoji.glyphs(in: "just a jar of jam") == "just a jar of jam")
        // "emojify" carries the "j" and the substring, so the pre-check passes
        // it; the word-boundary rule is what correctly declines it.
        #expect(SpokenEmoji.glyphs(in: "fire emojify") == "fire emojify")
        // Upper case has to survive the byte fold, or a shouted trigger is lost.
        #expect(SpokenEmoji.glyphs(in: "Fire EMOJI now") == "🔥 now")
    }
}
