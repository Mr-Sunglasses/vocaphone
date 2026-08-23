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
