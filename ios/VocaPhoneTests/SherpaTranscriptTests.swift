import Testing

/// Mirrors the Android client's `SherpaTranscriptTest`.
struct SherpaTranscriptTests {
    @Test func senseVoiceLanguageTagsBecomeCodes() {
        #expect(SherpaTranscript.languageCode("<|en|>") == "en")
        #expect(SherpaTranscript.languageCode("<|zh|>") == "zh")
        #expect(SherpaTranscript.languageCode("<|yue|>") == "yue")
        #expect(SherpaTranscript.languageCode(" <|JA|> ") == "ja")
        // A family that reports nothing is the common case, not an error.
        #expect(SherpaTranscript.languageCode("") == "")
        #expect(SherpaTranscript.languageCode(nil) == "")
    }

    @Test func anythingNotShapedLikeALanguageCodeIsDiscarded() {
        // Better no code than a wrong one: an unrecognized code would choose
        // punctuation with more confidence than the text-sniffing fallback.
        #expect(SherpaTranscript.languageCode("<|nospeech|>") == "")
        #expect(SherpaTranscript.languageCode("<|withitn|>") == "")
        #expect(SherpaTranscript.languageCode("<|0|>") == "")
        #expect(SherpaTranscript.languageCode("hello there") == "")
    }

    @Test func theFirstReportedLanguageSurvivesTheMerge() {
        let first = SherpaTranscript(text: "你好", language: "zh")
        let second = SherpaTranscript(text: "世界", language: "")
        #expect(first.appending(second, deduplicateOverlap: false).language == "zh")
        // A chunk that reported nothing does not erase what came before, and a
        // later report fills in for an earlier silence.
        #expect(second.appending(first, deduplicateOverlap: false).language == "zh")
    }

    @Test func mergingStillJoinsTheTextItAlwaysDid() {
        let merged = SherpaTranscript(text: "hello there", language: "en")
            .appending(SherpaTranscript(text: "there world"), deduplicateOverlap: true)
        #expect(merged.text == "hello there world")
    }
}
