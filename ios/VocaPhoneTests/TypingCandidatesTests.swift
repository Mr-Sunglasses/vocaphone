import Testing

/// Ranking and the autocorrect rules.
///
/// Every autocorrect rule gets a test written so that **deleting the rule
/// fails it**. An autocorrect that fires wrongly is worse than none: it
/// takes a word the user typed deliberately and replaces it after they have
/// stopped looking, and they find out later, in someone else's message.
struct TypingCandidatesTests {
    private static func context(
        composition: String,
        origin: WordComposer.Origin = .typed,
        guesses: [String] = [],
        completions: [String] = [],
        listCompletions: [String] = [],
        lexicon: [String] = [],
        custom: [String] = [],
        learned: [String] = [],
        predictions: [String] = [],
        preceding: String? = nil,
        isKnownToChecker: Bool = false,
        isInWordList: Bool = false,
        asserted: Set<String> = [],
        suggestions: Bool = true,
        autocorrect: Bool = true,
        prediction: Bool = true,
        allowed: Bool = true,
        followers: [String] = [],
        expansion: String? = nil,
        isMidWord: Bool = false
    ) -> TypingCandidates.Context {
        var context = TypingCandidates.Context()
        context.composition = composition
        context.origin = origin
        context.systemGuesses = guesses
        context.systemCompletions = completions
        context.listCompletions = listCompletions
        context.lexiconEntries = lexicon
        context.customWords = custom
        context.learnedWords = learned
        context.predictions = predictions
        context.precedingWord = preceding
        context.isKnownToChecker = isKnownToChecker
        context.isInWordList = isInWordList
        context.assertedWords = asserted
        context.suggestionsEnabled = suggestions
        context.autocorrectEnabled = autocorrect
        context.predictionEnabled = prediction
        context.allowsTypingIntelligence = allowed
        context.contextualFollowers = followers
        context.lexiconExpansion = expansion
        context.isMidWord = isMidWord
        return context
    }

    // MARK: - The touch model

    /// The corrections a spell checker will never make, because nothing is
    /// misspelled. Every one of these is blocked by a rule that is individually
    /// right — too short, already a word, case-only — and every one of them is
    /// something the system keyboard fixes.
    @Test func theCuratedShortWordsAreCorrected() {
        let expected = [
            "i": "I",
            "im": "I'm",
            "ive": "I've",
            "dont": "don't",
            "cant": "can't",
            "youre": "you're",
            "thats": "that's",
        ]
        for (typed, replacement) in expected {
            #expect(
                TypingCandidates.autocorrection(
                    Self.context(composition: typed, isKnownToChecker: true, isInWordList: true)
                ) == replacement,
                "\(typed) should become \(replacement)"
            )
        }
    }

    /// Someone shouting has still chosen their letters. The curated table must
    /// not rewrite a contraction typed with caps lock on, for the same reason
    /// "WIP" is not a misspelling of "wip".
    @Test func aShoutedContractionIsNotRewritten() {
        for token in ["DONT", "CANT", "IM", "YOURE"] {
            #expect(
                TypingCandidates.autocorrection(
                    Self.context(composition: token, isKnownToChecker: true)
                ) == nil,
                "\(token) should stand"
            )
        }
    }

    /// A text replacement is an instruction the user configured, so it expands
    /// whatever case it is typed in. This is the deliberate split from the rule
    /// above.
    @Test func aShoutedShortcutStillExpands() {
        #expect(
            TypingCandidates.autocorrection(
                Self.context(
                    composition: "OMW",
                    isKnownToChecker: true,
                    expansion: "On my way!"
                )
            ) == "On my way!"
        )
    }

    /// The words deliberately left out, because only grammar could tell them
    /// apart and a keyboard has none.
    @Test func ambiguousContractionsAreLeftAlone() {
        for token in ["its", "were", "well", "hell", "shell", "wed"] {
            #expect(
                TypingCandidates.autocorrection(
                    Self.context(composition: token, isKnownToChecker: true)
                ) == nil,
                "\(token) should stand"
            )
        }
    }

    /// The user's own assertion outranks the table. Someone who put "im" back
    /// once has answered the question.
    @Test func anAssertedShortWordIsNotCorrected() {
        #expect(
            TypingCandidates.autocorrection(
                Self.context(composition: "im", asserted: ["im"])
            ) == nil
        )
    }

    /// A text replacement is an instruction, not a guess: the user told Settings
    /// what "omw" means. It used to reach the strip as a chip and stop there, so
    /// the expansion only happened if they noticed and tapped it.
    @Test func aTextReplacementExpandsOnItsOwn() {
        #expect(
            TypingCandidates.autocorrection(
                Self.context(
                    composition: "omw",
                    isKnownToChecker: true,
                    expansion: "On my way!"
                )
            ) == "On my way!"
        )
    }

    /// The bug from the recording: typing "world" produced "World".
    ///
    /// `UILexicon` is not only the shortcuts someone typed into Settings — it
    /// also carries Contacts names and system proper nouns as a lowercase
    /// `userInput` mapped to a properly-cased `documentText`. Applying those on
    /// an exact match silently capitalised any ordinary word that happened to be
    /// in the user's address book, mid-sentence, with no way to predict which.
    @Test func aLexiconEntryNeverAppliesAMereCapitalization() {
        #expect(
            TypingCandidates.autocorrection(
                Self.context(
                    composition: "world",
                    isKnownToChecker: true,
                    expansion: "World"
                )
            ) == nil
        )
        // The words from the original report, for the same reason.
        for (typed, cased) in [("are", "Are"), ("the", "The"), ("hello", "Hello")] {
            #expect(
                TypingCandidates.autocorrection(
                    Self.context(composition: typed, isKnownToChecker: true, expansion: cased)
                ) == nil,
                "\(typed) must not be capitalised into \(cased)"
            )
        }
    }

    /// A genuine expansion still applies on its own — that is what the lexicon
    /// is handed to keyboards for.
    @Test func aGenuineExpansionStillApplies() {
        #expect(
            TypingCandidates.autocorrection(
                Self.context(
                    composition: "omw",
                    isKnownToChecker: true,
                    expansion: "On my way!"
                )
            ) == "On my way!"
        )
        // A case change *plus* a real edit is an expansion, not a capitalization.
        #expect(
            TypingCandidates.autocorrection(
                Self.context(
                    composition: "kp",
                    isKnownToChecker: true,
                    expansion: "Kanishk"
                )
            ) == "Kanishk"
        )
    }

    /// The curated table keeps its case-only power, because every entry in it is
    /// a word whose capital is unambiguous. This is the line between the two.
    @Test func theCuratedTableStillCapitalisesI() {
        #expect(
            TypingCandidates.autocorrection(
                Self.context(composition: "i", isKnownToChecker: true, isInWordList: true)
            ) == "I"
        )
    }

    /// A replacement carrying its own capitalization is a substitution, not a
    /// spelling of the typed word. Caps lock must not shout it.
    @Test func anExpansionKeepsItsOwnCapitalization() {
        #expect(
            TypingCandidates.matchingCase(of: "OMW", applyingTo: "On my way!") == "On my way!"
        )
        #expect(TypingCandidates.matchingCase(of: "i", applyingTo: "I") == "I")
        // An ordinary correction still follows the typed word's case.
        #expect(TypingCandidates.matchingCase(of: "Teh", applyingTo: "the") == "The")
    }

    /// Nothing may be replaced when the cursor is inside a longer word: the
    /// composition is a prefix of something the keyboard can only see half of,
    /// and rewriting it corrupts a word the user never finished.
    @Test func nothingIsCorrectedInTheMiddleOfAWord() {
        #expect(
            TypingCandidates.autocorrection(
                Self.context(composition: "teh", guesses: ["the"], isMidWord: true)
            ) == nil
        )
    }

    /// The preceding word is evidence the checker never had. Two guesses the
    /// same distance away, and the bigram says which one the sentence wants.
    @Test func contextBreaksATieTheCheckerCannot() {
        #expect(
            TypingCandidates.autocorrection(
                Self.context(
                    composition: "hend",
                    guesses: ["hand", "bend"],
                    preceding: "please",
                    followers: ["hand"]
                )
            ) == "hand"
        )
    }

    /// Proximity settles a contest the dictionary rates equally; it never
    /// manufactures a winner where there genuinely is not one.
    @Test func proximityBreaksTiesWithoutCreatingThem() {
        // Adjacent keys cost less than a letter from the other side of the
        // keyboard: "w" is beside "e", "p" is not.
        #expect(KeyProximity.areAdjacent("w", "e"))
        #expect(!KeyProximity.areAdjacent("q", "p"))
        #expect(
            KeyProximity.substitutionCost(typed: "w", intended: "e")
                < KeyProximity.substitutionCost(typed: "q", intended: "p")
        )
        // Still no correction when both readings are one plain edit away.
        #expect(
            TypingCandidates.autocorrection(
                Self.context(composition: "hend", guesses: ["hand", "bend"])
            ) == nil
        )
        // But a runner-up needing strictly more edits still loses, which is the
        // rule proximity weighting must not have taken away.
        #expect(
            TypingCandidates.autocorrection(
                Self.context(composition: "hend", guesses: ["hand", "blend"])
            ) == "hand"
        )
    }

    // MARK: - Autocorrect rules

    @Test func anObviousTypoIsCorrected() {
        #expect(
            TypingCandidates.autocorrection(
                Self.context(composition: "teh", guesses: ["the", "tech"])
            ) == "the"
        )
    }

    @Test func correctionRequiresBothSwitches() {
        #expect(
            TypingCandidates.autocorrection(
                Self.context(composition: "teh", guesses: ["the"], autocorrect: false)
            ) == nil
        )
        #expect(
            TypingCandidates.autocorrection(
                Self.context(composition: "teh", guesses: ["the"], suggestions: false)
            ) == nil
        )
    }

    @Test func aSensitiveFieldIsNeverCorrected() {
        #expect(
            TypingCandidates.autocorrection(
                Self.context(composition: "teh", guesses: ["the"], allowed: false)
            ) == nil
        )
    }

    /// A dictated word came from a model that already had its say; a swipe word
    /// and a tapped suggestion were both chosen from something visible.
    @Test func onlyTypedWordsAreCorrected() {
        for origin in [WordComposer.Origin.dictated, .suggestion, .swipe] {
            #expect(
                TypingCandidates.autocorrection(
                    Self.context(composition: "teh", origin: origin, guesses: ["the"])
                ) == nil
            )
        }
    }

    /// The shorter the word, the more words sit within one edit of it — and
    /// two-letter words are nearly always deliberate.
    @Test func veryShortWordsAreLeftAlone() {
        #expect(
            TypingCandidates.autocorrection(
                Self.context(composition: "te", guesses: ["the"])
            ) == nil
        )
    }

    @Test func aWordAnySourceRecognisesIsLeftAlone() {
        #expect(
            TypingCandidates.autocorrection(
                Self.context(composition: "hte", guesses: ["the"], isKnownToChecker: true)
            ) == nil
        )
        #expect(
            TypingCandidates.autocorrection(
                Self.context(composition: "hte", guesses: ["the"], isInWordList: true)
            ) == nil
        )
        #expect(
            TypingCandidates.autocorrection(
                Self.context(composition: "kanishk", guesses: ["banish"], custom: ["kanishk"])
            ) == nil
        )
        #expect(
            TypingCandidates.autocorrection(
                Self.context(composition: "vocaphone", guesses: ["megaphone"], learned: ["vocaphone"])
            ) == nil
        )
    }

    /// A word the user put back once must not be taken away again. This is the
    /// behaviour people rely on without knowing its name.
    @Test func anAssertedWordIsNeverCorrectedAgain() {
        #expect(
            TypingCandidates.autocorrection(
                Self.context(composition: "teh", guesses: ["the"], asserted: ["teh"])
            ) == nil
        )
    }

    /// Identifiers, handles, paths and code are not misspellings.
    @Test func tokensThatAreNotWordsAreLeftAlone() {
        for token in ["abc123", "user@host", "src/main", "snake_case", "#tag"] {
            #expect(
                TypingCandidates.autocorrection(
                    Self.context(composition: token, guesses: ["something"])
                ) == nil,
                "\(token) should not be corrected"
            )
        }
    }

    @Test func acronymsStand() {
        #expect(
            TypingCandidates.autocorrection(
                Self.context(composition: "WIP", guesses: ["wip", "whip"])
            ) == nil
        )
    }

    /// Two equally good guesses means the checker does not know either, and
    /// picking one is a coin toss played with the user's sentence.
    @Test func aTiedGuessIsNotAppliedWithoutAMargin() {
        // Both one edit away: no margin, no correction.
        #expect(
            TypingCandidates.autocorrection(
                Self.context(composition: "hend", guesses: ["hand", "bend"])
            ) == nil
        )
        // The runner-up is further away, so the best one wins.
        #expect(
            TypingCandidates.autocorrection(
                Self.context(composition: "hend", guesses: ["hand", "blend"])
            ) == "hand"
        )
    }

    @Test func aDistantGuessIsNotATypo() {
        #expect(
            TypingCandidates.autocorrection(
                Self.context(composition: "zqx", guesses: ["through"])
            ) == nil
        )
    }

    /// Capitalization is the shift key's job. An autocorrect that only changes
    /// case is the keyboard fighting the user's own capitalization.
    @Test func aCaseOnlyDifferenceIsNotACorrection() {
        #expect(
            TypingCandidates.autocorrection(
                Self.context(composition: "iphone", guesses: ["iPhone"])
            ) == nil
        )
    }

    @Test func noGuessMeansNoCorrection() {
        #expect(
            TypingCandidates.autocorrection(Self.context(composition: "qwrtp")) == nil
        )
    }

    // MARK: - Strip

    /// The literal is only worth a slot when something is about to replace it.
    /// Echoing the user's own word back on every keystroke would spend a third
    /// of the strip saying nothing.
    @Test func theLiteralAppearsOnlyWhenACorrectionIsPending() {
        let correcting = TypingCandidates.strip(
            Self.context(composition: "teh", guesses: ["the", "tech"])
        )
        #expect(correcting.candidates.first?.kind == .literal)
        #expect(correcting.candidates.first?.text == "teh")
        #expect(correcting.autocorrection == "the")

        let completing = TypingCandidates.strip(
            Self.context(composition: "hel", completions: ["hello", "help"], isKnownToChecker: true)
        )
        let showsLiteral = completing.candidates.contains { $0.kind == .literal }
        #expect(!showsLiteral)
        #expect(completing.autocorrection == nil)
    }

    /// Exactly one chip is emphasised, and only when a boundary key really would
    /// apply it. An emphasised chip that space does not apply is a lie the user
    /// only catches after losing a word.
    @Test func emphasisMeansSpaceWillApplyIt() {
        let correcting = TypingCandidates.strip(
            Self.context(composition: "teh", guesses: ["the", "tech"])
        )
        #expect(correcting.candidates.filter(\.isEmphasised).count == 1)
        #expect(correcting.candidates.first(where: \.isEmphasised)?.text == "the")

        let completing = TypingCandidates.strip(
            Self.context(composition: "hel", completions: ["hello"], isKnownToChecker: true)
        )
        let anyEmphasised = completing.candidates.contains(where: \.isEmphasised)
        #expect(!anyEmphasised)
    }

    @Test func theStripNeverShowsMoreThanThreeChips() {
        let strip = TypingCandidates.strip(
            Self.context(
                composition: "teh",
                guesses: ["the", "tech", "ten"],
                completions: ["tehran"],
                listCompletions: ["tehsil"]
            )
        )
        #expect(strip.candidates.count <= TypingCandidates.slotCount)
    }

    @Test func theSameWordIsNeverShownTwice() {
        let strip = TypingCandidates.strip(
            Self.context(
                composition: "hel",
                completions: ["hello", "Hello"],
                listCompletions: ["hello"],
                learned: ["hello"],
                isKnownToChecker: true
            )
        )
        let texts = strip.candidates.map { $0.text.lowercased() }
        #expect(Set(texts).count == texts.count)
    }

    @Test func theTypedWordIsNeverOfferedBackAsASuggestion() {
        let ranked = TypingCandidates.rankedSuggestions(
            Self.context(composition: "hello", completions: ["hello", "hellos"])
        )
        let echoesTypedWord = ranked.contains { $0.caseInsensitiveCompare("hello") == .orderedSame }
        #expect(!echoesTypedWord)
    }

    /// Someone who taught the app their surname should not have to scroll past
    /// the dictionary to find it.
    @Test func personalSourcesOutrankTheSystemList() {
        let ranked = TypingCandidates.rankedSuggestions(
            Self.context(
                composition: "kan",
                completions: ["kangaroo"],
                lexicon: ["Kanishk"],
                custom: ["Kandinsky"],
                learned: ["kanban"]
            )
        )
        #expect(ranked.first == "Kanishk")
        #expect(ranked.firstIndex(of: "kangaroo")! > ranked.firstIndex(of: "kanban")!)
    }

    /// A longer version of what is already typed is nearly always closer to
    /// intent than a different word.
    @Test func completionsOutrankCorrections() {
        let ranked = TypingCandidates.rankedSuggestions(
            Self.context(composition: "hel", guesses: ["heel"], completions: ["hello"])
        )
        #expect(ranked.firstIndex(of: "hello")! < ranked.firstIndex(of: "heel")!)
    }

    // MARK: - Prediction

    @Test func predictionsFillTheStripAfterAWord() {
        let strip = TypingCandidates.strip(
            Self.context(composition: "", predictions: ["you", "the", "it"], preceding: "see")
        )
        #expect(strip.candidates.map(\.text) == ["you", "the", "it"])
        let allPredictions = strip.candidates.allSatisfy { $0.kind == .prediction }
        #expect(allPredictions)
        #expect(strip.autocorrection == nil)
    }

    @Test func predictionRespectsItsSwitch() {
        #expect(
            TypingCandidates.strip(
                Self.context(composition: "", predictions: ["you"], prediction: false)
            ).isEmpty
        )
    }

    // MARK: - Off switches

    @Test func everythingIsSilentWhenSuggestionsAreOffOrTheFieldIsSensitive() {
        #expect(
            TypingCandidates.strip(
                Self.context(composition: "teh", guesses: ["the"], suggestions: false)
            ).isEmpty
        )
        #expect(
            TypingCandidates.strip(
                Self.context(composition: "teh", guesses: ["the"], allowed: false)
            ).isEmpty
        )
    }

    // MARK: - Helpers

    @Test func editDistanceCountsATranspositionAsOne() {
        #expect(TypingCandidates.editDistance("teh", "the", maximum: 2) == 1)
        #expect(TypingCandidates.editDistance("abc", "abc", maximum: 2) == 0)
        #expect(TypingCandidates.editDistance("", "abc", maximum: 2) == 3)
        #expect(TypingCandidates.editDistance("abc", "", maximum: 2) == 3)
        // Bounded: anything past the maximum only has to be "too far".
        #expect(TypingCandidates.editDistance("abc", "xyzzy", maximum: 2) > 2)
    }

    @Test func replacementsInheritTheTypedWordsCase() {
        #expect(TypingCandidates.matchingCase(of: "Teh", applyingTo: "the") == "The")
        #expect(TypingCandidates.matchingCase(of: "TEH", applyingTo: "the") == "THE")
        #expect(TypingCandidates.matchingCase(of: "teh", applyingTo: "the") == "the")
    }
}
// MARK: - Emoji

/// The emoji chip is an extra, not a competitor. The three word slots are what
/// the strip is for, and spending one on decoration is a bad trade even when
/// the emoji is right.
@Suite struct EmojiCandidateTests {
    private func context(_ composition: String, emoji: String?) -> TypingCandidates.Context {
        var context = TypingCandidates.Context()
        context.composition = composition
        context.emojiSuggestion = emoji
        context.isKnownToChecker = true
        context.isInWordList = true
        return context
    }

    @Test func theEmojiIsAppendedAfterTheWordCandidates() {
        var ctx = context("lol", emoji: "😂")
        ctx.listCompletions = ["lolly", "lollipop"]
        let strip = TypingCandidates.strip(ctx)
        #expect(strip.candidates.last?.kind == .emoji)
        #expect(strip.candidates.last?.text == "😂")
        // Every word candidate that would have been shown is still shown.
        let words = strip.candidates.filter { $0.kind != .emoji }
        #expect(words.count == 2)
        #expect(words.allSatisfy { $0.text != "😂" })
    }

    @Test func aWordWithNoEmojiIsUnchanged() {
        let strip = TypingCandidates.strip(context("ship", emoji: nil))
        #expect(!strip.candidates.contains { $0.kind == .emoji })
    }

    @Test func theSettingRemovesTheChipEntirely() {
        var ctx = context("lol", emoji: "😂")
        ctx.emojiEnabled = false
        #expect(!TypingCandidates.strip(ctx).candidates.contains { $0.kind == .emoji })
    }

    /// Nothing is being typed, so there is no word for an emoji to stand for.
    /// The prediction row is about the *next* word.
    @Test func predictionsNeverCarryAnEmoji() {
        var ctx = context("", emoji: "😂")
        ctx.predictions = ["the", "a"]
        #expect(!TypingCandidates.strip(ctx).candidates.contains { $0.kind == .emoji })
    }

    /// A word with a curated emoji is never autocorrected away.
    ///
    /// Most triggers are informal and absent from the shipped word list, so
    /// without this the keyboard offers 😱 for "omg" and then replaces it with
    /// a dictionary word on the next space — disagreeing with itself, in a way
    /// the user only discovers after sending the message.
    @Test func aWordWithAnEmojiIsNotCorrectedAway() {
        var ctx = context("omg", emoji: "😱")
        ctx.isKnownToChecker = false
        ctx.isInWordList = false
        ctx.systemGuesses = ["org"]
        #expect(TypingCandidates.autocorrection(ctx) == nil)
        #expect(TypingCandidates.strip(ctx).autocorrection == nil)
        // The literal chip exists to warn about a pending replacement, so with
        // nothing pending it does not take a slot either.
        #expect(!TypingCandidates.strip(ctx).candidates.contains { $0.kind == .literal })
    }

    /// The exemption is the *word*, not the setting. Turning the chip off stops
    /// a chip being drawn; it does not make "omg" a typo again.
    @Test func theExemptionSurvivesTheSettingBeingOff() {
        var ctx = context("omg", emoji: "😱")
        ctx.emojiEnabled = false
        ctx.isKnownToChecker = false
        ctx.isInWordList = false
        ctx.systemGuesses = ["org"]
        #expect(TypingCandidates.autocorrection(ctx) == nil)
    }

    /// And a genuine typo that happens to be near a trigger is still corrected.
    @Test func aTypoWithNoEmojiIsStillCorrected() {
        var ctx = context("teh", emoji: nil)
        ctx.isKnownToChecker = false
        ctx.isInWordList = false
        ctx.systemGuesses = ["the"]
        #expect(TypingCandidates.autocorrection(ctx) == "the")
    }

    /// The strip is off entirely in a password or code field, and the emoji
    /// must not be the one thing that survives that.
    @Test func aFieldThatRefusesIntelligenceGetsNoEmoji() {
        var ctx = context("lol", emoji: "😂")
        ctx.allowsTypingIntelligence = false
        #expect(TypingCandidates.strip(ctx).candidates.isEmpty)
    }
}

/// A revert deletes a fixed number of characters and types the original in
/// their place, which is only meaningful where the replacement actually is.
struct AppliedCorrectionArmingTests {
    private static let correction = TypingEngine.AppliedCorrection(
        typed: "teh",
        replacement: "the",
        boundary: " "
    )

    /// Immediately after the correction, with it still in front of the cursor.
    @Test func aCorrectionInFrontOfTheCursorIsArmed() {
        #expect(Self.correction.isArmed(documentBefore: "the "))
        #expect(Self.correction.isArmed(documentBefore: "I saw the "))
    }

    /// The cursor has moved on. Reverting here would delete four characters of
    /// unrelated text and insert a word from a paragraph ago.
    @Test func aCorrectionTheCursorHasLeftIsNotArmed() {
        #expect(!Self.correction.isArmed(documentBefore: "the quick brown fox"))
        #expect(!Self.correction.isArmed(documentBefore: "somewhere else entirely"))
        #expect(!Self.correction.isArmed(documentBefore: ""))
    }

    /// The host declining to answer is not permission to delete on faith.
    @Test func anUnansweredContextIsNotArmed() {
        #expect(!Self.correction.isArmed(documentBefore: nil))
    }

    /// The boundary counts. "the" alone is a word the user typed, not the
    /// correction plus the space that applied it.
    @Test func theBoundaryIsPartOfWhatMustStillBeThere() {
        #expect(!Self.correction.isArmed(documentBefore: "the"))
        let punctuated = TypingEngine.AppliedCorrection(
            typed: "teh",
            replacement: "the",
            boundary: "."
        )
        #expect(punctuated.isArmed(documentBefore: "the."))
        #expect(!punctuated.isArmed(documentBefore: "the "))
    }
}
