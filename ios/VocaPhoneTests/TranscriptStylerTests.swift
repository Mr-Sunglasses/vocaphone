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

    @Test func localStylingKeepsProtectedSpansIntact() {
        #expect(
            TranscriptStyler.apply(
                "Email John@Example.com at 3:30.",
                style: .veryCasual
            ) == "email John@Example.com at 3:30"
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
