import Testing

/// The rules that stop "emoji" being eaten out of ordinary sentences. Each one
/// exists because the obvious implementation gets it wrong.
struct SpokenEmojiTests {
    @Test func aDescriptorAndTheTriggerBecomeTheGlyph() {
        #expect(SpokenEmoji.glyphs(in: "crying emoji") == "😭")
    }

    /// The worked example from the plan, and the case that proves repeats need
    /// no special handling: two triggers are two independent matches.
    @Test func repeatedTriggersEachConvert() {
        #expect(SpokenEmoji.glyphs(in: "crying emoji crying emoji") == "😭 😭")
    }

    /// Keys are the descriptor with its spaces removed, so a multi-word
    /// descriptor resolves without the table having to store the spacing.
    @Test func multiWordDescriptorsResolve() {
        #expect(SpokenEmoji.glyphs(in: "thumbs up emoji") == "👍")
        #expect(SpokenEmoji.glyphs(in: "shrug emoji") == "🤷")
    }

    /// Prose glued to the descriptor is not part of the name. The whole span
    /// before the trigger has to be the key; a leftover prefix means decline.
    @Test func proseBeforeADescriptorIsNotConsumed() {
        #expect(
            SpokenEmoji.glyphs(in: "I'm so sad crying emoji")
                == "I'm so sad crying emoji"
        )
        #expect(
            SpokenEmoji.glyphs(in: "nice work thumbs up emoji")
                == "nice work thumbs up emoji"
        )
        // A comma ends the phrase, so the descriptor stands alone.
        #expect(SpokenEmoji.glyphs(in: "I'm so sad, crying emoji") == "I'm so sad, 😭")
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

    /// The whole multi-word name converts, not a short suffix of it.
    /// "loudly crying" and "crying" are both keys; taking only "crying" would
    /// leave "loudly" stranded in front of the glyph.
    @Test func theFullMultiWordNameConverts() {
        #expect(SpokenEmoji.glyphs(in: "loudly crying emoji") == "😭")
    }

    /// Three emoji dictated in a row: the pauses arrive as commas, and
    /// substituting each phrase in place would leave them stranded between the
    /// glyphs. A run of emoji is a run, not a list.
    @Test func punctuationBetweenTwoGlyphsCollapses() {
        #expect(
            SpokenEmoji.glyphs(in: "Crying emoji, crying emoji, crying emoji.")
                == "😭 😭 😭"
        )
        #expect(SpokenEmoji.glyphs(in: "Crying emoji. Fire emoji.") == "😭 🔥")
        #expect(SpokenEmoji.glyphs(in: "crying emoji crying emoji") == "😭 😭")
    }

    /// The collapse must not reach past the run. Punctuation that belongs to
    /// the sentence around the emoji stays exactly where the styler put it.
    @Test func punctuationOutsideTheRunIsUntouched() {
        #expect(SpokenEmoji.glyphs(in: "fire emoji, then home") == "🔥, then home")
        // "but fire" is not a key, so the second phrase declines rather than
        // taking the "fire" suffix and leaving "but" stranded.
        #expect(
            SpokenEmoji.glyphs(in: "I'm sad, crying emoji, but fire emoji, then home")
                == "I'm sad, 😭, but fire emoji, then home"
        )
        // A sentence break gives the second descriptor its own span.
        #expect(
            SpokenEmoji.glyphs(in: "I'm sad, crying emoji. Fire emoji, then home")
                == "I'm sad, 😭 🔥, then home"
        )
        // Leading name-stop words stay; "and" is not eaten into the second glyph.
        #expect(SpokenEmoji.glyphs(in: "crying emoji and fire emoji") == "😭 and 🔥")
    }

    /// A partial match must never leave the rest of what was said in front of
    /// the glyph. Exact multi-word keys convert fully; phrases that are not
    /// keys must not fall back to a proper suffix.
    @Test func longerPhrasesDoNotStrandTheirLeadingWords() {
        #expect(SpokenEmoji.glyphs(in: "one hundred emoji") == "💯")
        #expect(SpokenEmoji.glyphs(in: "face with tears of joy emoji") == "😂")
        #expect(SpokenEmoji.glyphs(in: "rolling on the floor laughing emoji") == "🤣")
        #expect(SpokenEmoji.glyphs(in: "crying face emoji") == "😢")
        #expect(SpokenEmoji.glyphs(in: "thumbs up sign emoji") == "👍")
    }

    /// Full-descriptor-or-decline: CLDR-style names that hit a key once
    /// name-stop words are dropped convert as a whole; near-miss phrases that
    /// only share a suffix with a key are left unchanged.
    @Test func cldrNamesConvertFullyOrNotAtAll() {
        #expect(SpokenEmoji.glyphs(in: "smiling face with heart eyes emoji") == "😍")
        #expect(SpokenEmoji.glyphs(in: "pile of poo emoji") == "💩")
        #expect(SpokenEmoji.glyphs(in: "face with rolling eyes emoji") == "🙄")
        #expect(SpokenEmoji.glyphs(in: "smiling face with sunglasses emoji") == "😎")
        #expect(SpokenEmoji.glyphs(in: "heart on fire emoji") == "❤️‍🔥")
        #expect(SpokenEmoji.glyphs(in: "couple with heart emoji") == "💑")

        for phrase in [
            "I love you emoji",
            "see no evil emoji",
            "person running emoji",
        ] {
            #expect(SpokenEmoji.glyphs(in: phrase) == phrase)
        }
    }

    /// Property-style: table keys spoken as themselves before "emoji" convert
    /// with no leftover prefix. Spaced multi-word forms from overrides and
    /// CLDR joins do the same.
    @Test func tableKeysConvertWithNoLeftoverPrefix() {
        var checked = 0
        for (key, glyph) in EmojiTable.triggers {
            if key.count < EmojiTable.minimumLength { continue }
            if key == "korea" { continue } // spoken blocklist; covered below
            #expect(SpokenEmoji.glyphs(in: "\(key) emoji") == glyph)
            checked += 1
            if checked >= 200 { break }
        }
        #expect(checked >= 200)

        let spaced: [(String, String)] = [
            ("heart eyes", "😍"),
            ("loudly crying", "😭"),
            ("one hundred", "💯"),
            ("thumbs up", "👍"),
            ("face with tears of joy", "😂"),
            ("rolling on the floor laughing", "🤣"),
        ]
        for (phrase, glyph) in spaced {
            #expect(SpokenEmoji.glyphs(in: "\(phrase) emoji") == glyph)
        }
    }

    /// `korea` in the strip table is 🇰🇵. Spoken path refuses the bare word;
    /// southkorea / northkorea still convert.
    @Test func koreaAloneDoesNotBecomeTheDPRKFlag() {
        #expect(SpokenEmoji.glyphs(in: "korea emoji") == "korea emoji")
        #expect(SpokenEmoji.glyphs(in: "southkorea emoji") == "🇰🇷")
        #expect(SpokenEmoji.glyphs(in: "northkorea emoji") == "🇰🇵")
        // Strip table is unchanged: the blocklist is spoken-only.
        #expect(EmojiTable.triggers["korea"] == "🇰🇵")
    }

    /// Digits are descriptors too. A speech model writes someone saying
    /// "hundred" as "100" about as often as it writes the word, and 💯 is the
    /// emoji people reach for most by number.
    @Test func digitsCanBeDescriptors() {
        #expect(SpokenEmoji.glyphs(in: "100 emoji") == "💯")
        #expect(SpokenEmoji.glyphs(in: "a hundred emoji") == "💯")
        #expect(SpokenEmoji.glyphs(in: "one hundred emoji") == "💯")
        #expect(SpokenEmoji.glyphs(in: "I need 20 emoji") == "I need 20 emoji")
        #expect(SpokenEmoji.glyphs(in: "3 crying emoji") == "3 crying emoji")
        #expect(SpokenEmoji.glyphs(in: "3, crying emoji") == "3, 😭")
    }

    /// Allowing digits made a masked span's own index look like a word, so a
    /// price or a URL could have offered its placeholder as a descriptor. These
    /// are the shapes ``ProtectedSpans`` masks; every one keeps its span and
    /// still converts the descriptor that follows it.
    @Test func maskedSpansAreNotDescriptors() {
        #expect(SpokenEmoji.glyphs(in: "it cost 3.50 crying emoji") == "it cost 3.50 😭")
        #expect(SpokenEmoji.glyphs(in: "meet at 10:30 crying emoji") == "meet at 10:30 😭")
        #expect(SpokenEmoji.glyphs(in: "the 1st crying emoji") == "the 1st 😭")
        #expect(
            SpokenEmoji.glyphs(in: "read https://example.com/a fire emoji")
                == "read https://example.com/a 🔥"
        )
    }

    /// The descriptors are English, but nothing else has to be. A transcript in
    /// another language keeps every word of its own and still converts an
    /// English phrase the speaker chose to say — which is what code-switching
    /// dictation actually sounds like.
    @Test func onlyTheDescriptorHasToBeEnglish() {
        #expect(
            SpokenEmoji.glyphs(in: "मैं बहुत उदास हूँ crying emoji", language: "hi")
                == "मैं बहुत उदास हूँ 😭"
        )
        #expect(
            SpokenEmoji.glyphs(in: "とても悲しい crying emoji", language: "ja")
                == "とても悲しい 😭"
        )
        #expect(
            SpokenEmoji.glyphs(in: "estoy muy triste llorando emoji", language: "es")
                == "estoy muy triste llorando emoji"
        )
    }

    /// A trigger with nothing it recognizes in front of it is left exactly as
    /// spoken. This is the case the feature is judged on: it must never guess.
    @Test func anUnmatchedTriggerIsLeftAlone() {
        #expect(SpokenEmoji.glyphs(in: "Send me the emoji.") == "Send me the emoji.")
        #expect(SpokenEmoji.glyphs(in: "emoji") == "emoji")
        #expect(SpokenEmoji.glyphs(in: "emoji emoji") == "emoji emoji")
    }

    @Test func theTriggerMayBePluralized() {
        #expect(SpokenEmoji.glyphs(in: "fire emojis") == "🔥")
    }

    /// Styling has already run, so the trigger arrives carrying whatever mark
    /// the style put on it. Only the words are replaced, which leaves the mark
    /// and the spacing exactly where the styler left them.
    @Test func punctuationTheStylerAttachedSurvives() {
        #expect(SpokenEmoji.glyphs(in: "party emoji!") == "🎉!")
        #expect(SpokenEmoji.glyphs(in: "fire emoji, then home") == "🔥, then home")
        #expect(SpokenEmoji.glyphs(in: "Crying emoji. That was rough.") == "😭. That was rough.")
    }

    /// The styler ended the sentence while the last word was still "emoji". An
    /// emoji is the end: nobody writes "I'm so sad 😭." or "💯."
    @Test func aTrailingTerminatorAfterAGlyphGoes() {
        #expect(SpokenEmoji.glyphs(in: "I'm so sad, crying emoji.") == "I'm so sad, 😭")
        #expect(SpokenEmoji.glyphs(in: "Hundred emoji.") == "💯")
        #expect(
            SpokenEmoji.glyphs(in: "Crying emoji is how I feel.")
                == "😭 is how I feel."
        )
    }

    /// A full stop is structure and goes; "!" and "?" carry meaning that was in
    /// what the user said, exactly as the casual writing style already argues.
    @Test func meaningfulTerminatorsAfterAGlyphStay() {
        #expect(SpokenEmoji.glyphs(in: "Crying emoji!") == "😭!")
        #expect(SpokenEmoji.glyphs(in: "Crying emoji?") == "😭?")
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
        let untouched = "no trigger anywhere in this sentence at all"
        #expect(SpokenEmoji.glyphs(in: untouched) == untouched)
        #expect(SpokenEmoji.glyphs(in: "just a jar of jam") == "just a jar of jam")
        #expect(SpokenEmoji.glyphs(in: "fire emojify") == "fire emojify")
        #expect(SpokenEmoji.glyphs(in: "Fire EMOJI now") == "🔥 now")
    }
}
