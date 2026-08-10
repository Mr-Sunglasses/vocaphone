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
