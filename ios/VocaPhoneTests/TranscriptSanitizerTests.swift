import Testing

/// The expectations here are deliberately the same as the Android client's
/// `TranscriptSanitizerTest`: the two implementations are supposed to produce
/// the same text for the same transcript.
struct TranscriptSanitizerTests {
    @Test func whisperSilenceMarkersNeverReachTheField() {
        #expect(TranscriptSanitizer.clean("[BLANK_AUDIO]") == "")
        #expect(TranscriptSanitizer.clean("  [BLANK_AUDIO]  ") == "")
        #expect(TranscriptSanitizer.clean("[ blank_audio ]") == "")
        #expect(TranscriptSanitizer.clean("[SILENCE]") == "")
        #expect(TranscriptSanitizer.clean("(inaudible)") == "")
    }

    @Test func markersAreStrippedFromAroundRealSpeech() {
        #expect(
            TranscriptSanitizer.clean("[BLANK_AUDIO] Hey, we are using vocaphone app")
                == "Hey, we are using vocaphone app"
        )
        #expect(TranscriptSanitizer.clean("Hello [NOISE] there") == "Hello there")
        #expect(TranscriptSanitizer.clean("[MUSIC] Good morning [APPLAUSE]") == "Good morning")
    }

    @Test func bracketsTheUserDictatedAreLeftAlone() {
        #expect(TranscriptSanitizer.clean("It cost [1,200]") == "It cost [1,200]")
        #expect(TranscriptSanitizer.clean("Ship it (see below)") == "Ship it (see below)")
        #expect(TranscriptSanitizer.clean("Call me (soon)") == "Call me (soon)")
    }

    @Test func lineStructureFromTheWritingStyleSurvives() {
        #expect(
            TranscriptSanitizer.clean("First line\n[NOISE] Second line")
                == "First line\nSecond line"
        )
    }

    @Test func blankInputStaysBlank() {
        #expect(TranscriptSanitizer.clean(nil) == "")
        #expect(TranscriptSanitizer.clean("   ") == "")
    }

    @Test func aRepeatedPhraseCollapsesToOneCopy() {
        #expect(
            TranscriptSanitizer.clean("Thank you. Thank you. Thank you. Thank you.")
                == "Thank you."
        )
        #expect(
            TranscriptSanitizer.clean("Let me know Let me know Let me know Ship it tomorrow")
                == "Let me know Ship it tomorrow"
        )
    }

    @Test func aRepeatedSingleWordKeepsTheEmphasisItMayHaveCarried() {
        #expect(TranscriptSanitizer.clean("no no no no no no") == "no no")
        // Three is within what a person says, so it is left exactly as dictated.
        #expect(TranscriptSanitizer.clean("no no no") == "no no no")
    }

    @Test func ordinaryProseWithRepeatedWordsIsNotCollapsed() {
        let sentence = "I think that that meeting was the one we moved"
        #expect(TranscriptSanitizer.clean(sentence) == sentence)
        let listing = "one two three four five six seven eight"
        #expect(TranscriptSanitizer.clean(listing) == listing)
    }

    @Test func aLoopIsMatchedAcrossThePunctuationThatDiffersBetweenCopies() {
        #expect(
            TranscriptSanitizer.clean("Okay then, okay then. Okay then!") == "Okay then,"
        )
        #expect(TranscriptSanitizer.clean("Okay, okay. Okay! okay,") == "Okay, okay.")
    }
}
