import Testing

/// The order of the three steps is the whole point of the funnel, and each
/// wrong order produces text that looks like a different bug.
struct DictatedTranscriptTests {
    /// Digits after styling. The styler capitalizes the first *letter* of a
    /// sentence, so a sentence that already began with "20" would have it skip
    /// past the number and capitalize the word after it.
    @Test func stylingHappensBeforeDigits() {
        #expect(
            DictatedTranscript.finished(
                "twenty people came",
                style: .formal,
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
                numbersAsDigits: true
            ) == "5 copies please."
        )
    }

    /// A gateway has already applied the session's writing style, so that route
    /// passes `nil` and the styler never runs twice.
    @Test func anAlreadyStyledTranscriptIsNotStyledAgain() {
        let styled = "Hello there."
        #expect(DictatedTranscript.finished(styled, numbersAsDigits: false) == styled)
        // The same text through the local route would lose its full stop to the
        // casual style — which is exactly what must not happen twice.
        #expect(
            DictatedTranscript.finished(styled, style: .casual, numbersAsDigits: false)
                == "Hello there"
        )
    }

    /// Off is off: the words the model returned are the words that get inserted.
    @Test func numbersStayWordsWhenThePreferenceIsOff() {
        #expect(
            DictatedTranscript.finished("six pm at office", numbersAsDigits: false)
                == "six pm at office"
        )
        #expect(
            DictatedTranscript.finished("six pm at office", numbersAsDigits: true)
                == "6 pm at office"
        )
    }

    @Test func nothingInMeansNothingOut() {
        #expect(DictatedTranscript.finished(nil, numbersAsDigits: true).isEmpty)
        #expect(DictatedTranscript.finished("   ", style: .formal, numbersAsDigits: true).isEmpty)
    }
}
