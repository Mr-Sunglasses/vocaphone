import Testing

struct TranscriptStylerTests {
    @Test func localStylesMatchGatewayExamples() {
        let source = "hello there. how are you"
        #expect(TranscriptStyler.apply(source, style: .raw) == source)
        #expect(TranscriptStyler.apply(source, style: .clean) == "hello there. how are you.")
        #expect(TranscriptStyler.apply(source, style: .formal) == "Hello there. How are you.")
        #expect(TranscriptStyler.apply(source, style: .casual) == "Hello there. How are you")
        #expect(TranscriptStyler.apply(source, style: .veryCasual) == "hello there, how are you")
        #expect(TranscriptStyler.apply(source, style: .excited) == "Hello there! How are you!")
    }

    @Test func automaticLanguageRecognizesUnpunctuatedDandaScripts() {
        let hindi = "मैं कल बाजार जाऊंगा"
        #expect(TranscriptStyler.apply(hindi, style: .formal, language: "hi") == "मैं कल बाजार जाऊंगा।")
        #expect(TranscriptStyler.apply(hindi, style: .formal, language: "auto") == "मैं कल बाजार जाऊंगा।")
        #expect(TranscriptStyler.apply("আমি কাল যাব", style: .formal, language: "auto") == "আমি কাল যাব।")
        #expect(TranscriptStyler.apply("ਮੈਂ ਕੱਲ੍ਹ ਜਾਵਾਂਗਾ", style: .formal, language: "auto") == "ਮੈਂ ਕੱਲ੍ਹ ਜਾਵਾਂਗਾ।")
    }

    @Test func hindiNormalizesSentenceDotsWithoutTouchingProtectedDotsOrEllipses() {
        #expect(
            TranscriptStyler.apply(
                "मूल्य 22.5 है. U.S. टीम example.com देखें... ठीक है.",
                style: .formal,
                language: "auto"
            ) == "मूल्य 22.5 है। U.S. टीम example.com देखें... ठीक है।"
        )
    }

    @Test func cleanAndFormalFlattenMidSentenceTitleCase() {
        let titled = "Hello There. The Keyboard Is Ready"
        #expect(TranscriptStyler.apply(titled, style: .clean) == "hello there. the keyboard is ready.")
        #expect(TranscriptStyler.apply(titled, style: .formal) == "Hello there. The keyboard is ready.")
        #expect(TranscriptStyler.apply(titled, style: .casual) == "Hello there. The keyboard is ready")
    }

    @Test func parakeetTitleCaseAndChunkJoinsFlattenUnderFormal() {
        #expect(
            TranscriptStyler.apply("I Think We Should Go To The Store", style: .formal)
                == "I think we should go to the store."
        )
        #expect(
            TranscriptStyler.apply("Hello there How are you today", style: .formal)
                == "Hello there how are you today."
        )
        #expect(
            TranscriptStyler.apply("Yes, It's Ready Now", style: .formal)
                == "Yes, it's ready now."
        )
    }

    @Test func flatteningKeepsMixedCaseNamesAcronymsAndPronounI() {
        let source = "I use VocaPhone and GraphQL at NASA today"
        #expect(TranscriptStyler.apply(source, style: .clean) == "I use VocaPhone and GraphQL at NASA today.")
        #expect(TranscriptStyler.apply(source, style: .formal) == "I use VocaPhone and GraphQL at NASA today.")
        #expect(TranscriptStyler.apply("i went home", style: .clean) == "I went home.")
    }

    /// A capital in an otherwise ordinary sentence is a name someone said,
    /// not Title Case the model invented.
    @Test func namesSurviveInAnOrdinarySentence() {
        let source = "I met Sarah in Paris on Monday"
        for style in [WritingStyle.clean, .formal] {
            #expect(TranscriptStyler.apply(source, style: style) == "I met Sarah in Paris on Monday.")
        }
        #expect(TranscriptStyler.apply(source, style: .casual) == "I met Sarah in Paris on Monday")
        #expect(TranscriptStyler.apply(source, style: .excited) == "I met Sarah in Paris on Monday!")
        // Four capitals in seven words is a sentence full of names, not a
        // Title-Cased one.
        #expect(
            TranscriptStyler.apply("Meet Sarah and John in Paris on Monday", style: .formal)
                == "Meet Sarah and John in Paris on Monday."
        )
        #expect(TranscriptStyler.apply("Call Sarah", style: .clean) == "Call Sarah.")
        #expect(TranscriptStyler.apply("Ich habe Hunger", style: .formal) == "Ich habe Hunger.")
    }

    /// A function word a chunk join capitalized is flattened, but not inside
    /// what looks like a multi-word name.
    @Test func multiWordNamesKeepTheirFunctionWords() {
        #expect(
            TranscriptStyler.apply("we flew to the Bank Of America office", style: .formal)
                == "We flew to the Bank Of America office."
        )
        #expect(
            TranscriptStyler.apply("I moved to The Hague last year", style: .formal)
                == "I moved to The Hague last year."
        )
        #expect(
            TranscriptStyler.apply("Sarah said It was fine", style: .formal)
                == "Sarah said it was fine."
        )
    }

    /// The whole-sentence pathology is decided per sentence, so a Title-Cased
    /// sentence does not cost the next one its names.
    @Test func titleCaseIsJudgedPerSentence() {
        #expect(
            TranscriptStyler.apply("The Meeting Is At Noon. Ask Sarah about it", style: .formal)
                == "The meeting is at noon. Ask Sarah about it."
        )
        #expect(TranscriptStyler.apply("Do It Now", style: .formal) == "Do it now.")
        #expect(TranscriptStyler.apply("Ate A Lot Of Pizza Today", style: .formal) == "Ate a lot of pizza today.")
    }

    /// A short all-Title-Case sentence is the model's only when nothing in it
    /// could be a name, and a capitalized opening word can be the first half
    /// of one.
    @Test func shortAndOpeningNamesKeepTheirCapitals() {
        #expect(TranscriptStyler.apply("Visit The Hague", style: .formal) == "Visit The Hague.")
        #expect(
            TranscriptStyler.apply("Doctor Who is on tonight", style: .formal)
                == "Doctor Who is on tonight."
        )
        // Nothing here could be a name, so the model's Title Case still goes.
        #expect(TranscriptStyler.apply("Call Him", style: .formal) == "Call him.")
        // An opening interjection is not half a name: the capital after it is
        // a chunk join's.
        #expect(
            TranscriptStyler.apply("Okay So we start at noon", style: .formal)
                == "Okay so we start at noon."
        )
    }

    @Test func longAllCapsIsStillFlattened() {
        #expect(TranscriptStyler.apply("this is REALLY good", style: .formal) == "This is really good.")
    }

    @Test func localStylingKeepsProtectedSpansIntact() {
        #expect(
            TranscriptStyler.apply(
                "Email John@Example.com at 3:30.",
                style: .veryCasual
            ) == "email John@Example.com at 3:30"
        )
        #expect(
            TranscriptStyler.apply(
                "Email John@Example.com at 3:30.",
                style: .formal
            ) == "Email John@Example.com at 3:30."
        )
    }

    @Test func localStylingUsesLanguagePunctuation() {
        #expect(
            TranscriptStyler.apply(
                "家に帰りました。ジョンが電話してきました。",
                style: .excited,
                language: "ja"
            ) == "家に帰りました！ジョンが電話してきました！"
        )
        #expect(
            TranscriptStyler.apply(
                "मैं कल बाजार जाऊंगा",
                style: .formal,
                language: "hi"
            ) == "मैं कल बाजार जाऊंगा।"
        )
    }
}
