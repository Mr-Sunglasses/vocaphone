import Testing

/// The order of the five steps is the whole point of the funnel, and each wrong
/// order produces text that looks like a different bug.
///
/// Every test that is not about spoken emoji switches it off, so a phrase that
/// happens to end in the trigger word cannot change an unrelated assertion.
struct DictatedTranscriptTests {
    /// Digits after styling. The styler capitalizes the first *letter* of a
    /// sentence, so a sentence that already began with "20" would have it skip
    /// past the number and capitalize the word after it.
    @Test func stylingHappensBeforeDigits() {
        #expect(
            DictatedTranscript.finished(
                "twenty people came",
                style: .formal,
                repairSpeech: false,
                numbersAsDigits: true,
                spokenEmoji: false
            ) == "20 people came."
        )
    }

    /// Sanitizing first, because a model's own annotations are not something to
    /// capitalize and punctuate into looking like speech.
    @Test func markersAreRemovedBeforeAnythingElse() {
        #expect(
            DictatedTranscript.finished(
                "[BLANK_AUDIO] five copies please",
                style: .formal,
                repairSpeech: false,
                numbersAsDigits: true,
                spokenEmoji: false
            ) == "5 copies please."
        )
    }

    /// Repair before styling, because repair is what puts the sentence
    /// boundaries there. Styling capitalizes and terminates *around* a
    /// boundary and cannot find one that is missing.
    @Test func repairHappensBeforeStyling() {
        #expect(
            DictatedTranscript.finished(
                "um what time is it",
                style: .formal,
                repairSpeech: true,
                numbersAsDigits: false,
                spokenEmoji: false
            ) == "What time is it?"
        )
        // Without repair the styler sees no question and closes the sentence
        // with the full stop it is contractually allowed to add.
        #expect(
            DictatedTranscript.finished(
                "um what time is it",
                style: .formal,
                repairSpeech: false,
                numbersAsDigits: false,
                spokenEmoji: false
            ) == "Um what time is it."
        )
    }

    /// Raw promises the model's own output, so the one stage that changes words
    /// never runs for it however the preference is set.
    @Test func rawIsNeverRepaired() {
        #expect(
            DictatedTranscript.finished(
                "um so we we should ship it",
                style: .raw,
                repairSpeech: true,
                numbersAsDigits: false,
                spokenEmoji: false
            ) == "um so we we should ship it"
        )
    }

    /// A gateway has already applied the session's writing style, so that route
    /// says so and the styler never runs twice.
    @Test func anAlreadyStyledTranscriptIsNotStyledAgain() {
        let styled = "Hello there."
        #expect(
            DictatedTranscript.finished(
                styled,
                style: .casual,
                styledUpstream: true,
                repairSpeech: false,
                numbersAsDigits: false,
                spokenEmoji: false
            ) == styled
        )
        // The same text through the local route would lose its full stop to the
        // casual style — which is exactly what must not happen twice.
        #expect(
            DictatedTranscript.finished(
                styled,
                style: .casual,
                repairSpeech: false,
                numbersAsDigits: false,
                spokenEmoji: false
            ) == "Hello there"
        )
    }

    /// The gateway does not repair, so this route still does — and because the
    /// text arrives cased, a sentence repair creates is cased to match.
    @Test func anAlreadyStyledTranscriptIsStillRepaired() {
        #expect(
            DictatedTranscript.finished(
                "We shipped it on Friday um anyway the tests are green",
                style: .casual,
                styledUpstream: true,
                repairSpeech: true,
                numbersAsDigits: false,
                spokenEmoji: false
            ) == "We shipped it on Friday. Anyway, the tests are green"
        )
    }

    /// Off is off: the words the model returned are the words that get inserted.
    @Test func numbersStayWordsWhenThePreferenceIsOff() {
        #expect(
            DictatedTranscript.finished(
                "six pm at office",
                style: .casual,
                styledUpstream: true,
                repairSpeech: false,
                numbersAsDigits: false,
                spokenEmoji: false
            ) == "six pm at office"
        )
        #expect(
            DictatedTranscript.finished(
                "six pm at office",
                style: .casual,
                styledUpstream: true,
                repairSpeech: false,
                numbersAsDigits: true,
                spokenEmoji: false
            ) == "6 pm at office"
        )
    }

    /// Expansion runs after styling and digits, and the expansion text is
    /// literal — it must come out exactly as the user wrote it even when
    /// styling would otherwise flatten or capitalize the words around it.
    @Test func snippetExpansionIsNotRewrittenByStyling() {
        let snippets = [Snippet(trigger: "sig", expansion: "kanishk@example.com")]
        #expect(
            DictatedTranscript.finished(
                "reach me at sig",
                style: .formal,
                repairSpeech: false,
                numbersAsDigits: false,
                spokenEmoji: false,
                snippets: snippets
            ) == "Reach me at kanishk@example.com."
        )
    }

    /// Trigger matching is case-insensitive, so a style that flattens or
    /// capitalizes the source text before expansion runs still finds it.
    @Test func snippetTriggerMatchesRegardlessOfStyledCasing() {
        let snippets = [Snippet(trigger: "brb", expansion: "be right back")]
        #expect(
            DictatedTranscript.finished(
                "BRB everyone",
                style: .formal,
                repairSpeech: false,
                numbersAsDigits: false,
                spokenEmoji: false,
                snippets: snippets
            ) == "be right back everyone."
        )
    }

    /// Emoji before digits. The table's keys are words: once "hundred" has
    /// become "100" there is no key left to look up, and the trigger word would
    /// be typed out.
    @Test func emojiHappensBeforeDigits() {
        #expect(
            DictatedTranscript.finished(
                "that was hundred emoji",
                style: .casual,
                repairSpeech: false,
                numbersAsDigits: true,
                spokenEmoji: true
            ) == "That was 💯"
        )
    }

    /// Emoji after styling, so the styler still sees "emoji" as an ordinary
    /// word and closes the sentence around it. The mark it added survives the
    /// substitution because only the words are replaced.
    @Test func stylingHappensBeforeEmoji() {
        #expect(
            DictatedTranscript.finished(
                "i'm so sad crying emoji",
                style: .formal,
                repairSpeech: false,
                numbersAsDigits: false,
                spokenEmoji: true
            ) == "I'm so sad 😭"
        )
    }

    /// Raw promises the model's own output, and a glyph is not a word the model
    /// returned — so this stage is skipped for it exactly as repair is.
    @Test func rawNeverGetsSpokenEmoji() {
        #expect(
            DictatedTranscript.finished(
                "i'm so sad crying emoji",
                style: .raw,
                repairSpeech: true,
                numbersAsDigits: false,
                spokenEmoji: true
            ) == "i'm so sad crying emoji"
        )
    }

    /// The switch is what makes the stage honest: off, the words are typed out.
    @Test func spokenEmojiCanBeTurnedOff() {
        #expect(
            DictatedTranscript.finished(
                "i'm so sad crying emoji",
                style: .casual,
                repairSpeech: false,
                numbersAsDigits: false,
                spokenEmoji: false
            ) == "I'm so sad crying emoji"
        )
    }

    /// Three of the same emoji dictated in a row survive the two stages that
    /// collapse repetition before this one gets to see it.
    ///
    /// The sanitizer treats a phrase said three times as a model stuck in a
    /// loop, and repair treats it as a false start. Both are right about
    /// ordinary speech and both were wrong here — and because they run at
    /// stages 1 and 2, the emoji stage never saw the copies to convert them.
    /// Tested through the funnel because that is the only place it goes wrong.
    @Test func repeatedEmojiSurviveTheStagesThatCollapseRepetition() {
        for repair in [true, false] {
            #expect(
                DictatedTranscript.finished(
                    "crying emoji crying emoji crying emoji",
                    style: .formal,
                    repairSpeech: repair,
                    numbersAsDigits: false,
                    spokenEmoji: true
                ) == "😭 😭 😭"
            )
            // Four, and with the commas a speech model writes the pauses down as.
            #expect(
                DictatedTranscript.finished(
                    "fire emoji, fire emoji, fire emoji, fire emoji",
                    style: .formal,
                    repairSpeech: repair,
                    numbersAsDigits: false,
                    spokenEmoji: true
                ) == "🔥 🔥 🔥 🔥"
            )
        }
    }

    /// The exemption above must not disarm the loop protection it sits inside.
    @Test func ordinaryRepetitionStillCollapses() {
        #expect(
            DictatedTranscript.finished(
                "thank you thank you thank you thank you",
                style: .formal,
                repairSpeech: false,
                numbersAsDigits: false,
                spokenEmoji: true
            ) == "Thank you."
        )
    }

    @Test func nothingInMeansNothingOut() {
        #expect(
            DictatedTranscript.finished(
                nil,
                style: .casual,
                styledUpstream: true,
                repairSpeech: true,
                numbersAsDigits: true,
                spokenEmoji: false
            ).isEmpty
        )
        #expect(
            DictatedTranscript.finished(
                "   ",
                style: .formal,
                repairSpeech: true,
                numbersAsDigits: true,
                spokenEmoji: false
            ).isEmpty
        )
    }
}
