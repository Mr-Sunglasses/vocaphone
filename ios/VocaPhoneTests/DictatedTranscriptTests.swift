import Testing

/// The order of the four steps is the whole point of the funnel, and each wrong
/// order produces text that looks like a different bug.
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
                numbersAsDigits: true
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
                numbersAsDigits: true
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
                numbersAsDigits: false
            ) == "What time is it?"
        )
        // Without repair the styler sees no question and closes the sentence
        // with the full stop it is contractually allowed to add.
        #expect(
            DictatedTranscript.finished(
                "um what time is it",
                style: .formal,
                repairSpeech: false,
                numbersAsDigits: false
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
                numbersAsDigits: false
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
                numbersAsDigits: false
            ) == styled
        )
        // The same text through the local route would lose its full stop to the
        // casual style — which is exactly what must not happen twice.
        #expect(
            DictatedTranscript.finished(
                styled,
                style: .casual,
                repairSpeech: false,
                numbersAsDigits: false
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
                numbersAsDigits: false
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
                numbersAsDigits: false
            ) == "six pm at office"
        )
        #expect(
            DictatedTranscript.finished(
                "six pm at office",
                style: .casual,
                styledUpstream: true,
                repairSpeech: false,
                numbersAsDigits: true
            ) == "6 pm at office"
        )
    }

    @Test func nothingInMeansNothingOut() {
        #expect(
            DictatedTranscript.finished(
                nil,
                style: .casual,
                styledUpstream: true,
                repairSpeech: true,
                numbersAsDigits: true
            ).isEmpty
        )
        #expect(
            DictatedTranscript.finished(
                "   ",
                style: .formal,
                repairSpeech: true,
                numbersAsDigits: true
            ).isEmpty
        )
    }
}
