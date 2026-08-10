import Testing

struct LocalModelCatalogTests {
    @Test func sherpaModelsAreAvailableAlongsideWhisperKit() {
        let sherpa = LocalModelCatalog.all.filter { $0.engine == .sherpaOnnx }
        #expect(sherpa.count == 12)
        #expect(sherpa.allSatisfy { $0.repository != nil && $0.revision != nil })
        #expect(sherpa.allSatisfy { $0.sherpaFamily != nil })
    }

    @Test func sherpaLanguageContractsMatchTheirFamilies() {
        #expect(LocalModelCatalog.descriptor(for: "canary-180m-flash")?.languageCodes == ["en", "de", "es", "fr"])
        #expect(LocalModelCatalog.descriptor(for: "fast-conformer-ctc-4-lang")?.languageCodes == ["en", "de", "es", "fr"])
        #expect(LocalModelCatalog.descriptor(for: "giga-am-ctc-ru")?.languageCodes == ["ru"])
        #expect(LocalModelCatalog.descriptor(for: "parakeet-tdt-0.6b-v3")?.detectsLanguageAutomatically == true)
        #expect(LocalModelCatalog.descriptor(for: "sense-voice")?.detectsLanguageAutomatically == true)
    }

    @Test func longAudioStreamingUsesBoundedWindows() {
        let samples = [Float](
            repeating: 0.05,
            count: SherpaLongAudio.sampleRate * 30
        )
        let split = SherpaLongAudio.nextStreamingSplit(samples)

        #expect(split?.endExclusive == SherpaLongAudio.sampleRate * 10)
        #expect(split?.nextStart == SherpaLongAudio.sampleRate * 9 + SherpaLongAudio.sampleRate / 2)
        #expect(!SherpaLongAudio.isEffectivelySilent(samples))
        #expect(SherpaLongAudio.isEffectivelySilent([Float](repeating: 0, count: 16_000)))
    }

    @Test func transcriptMergerSeparatesNonOverlappingChunks() {
        #expect(
            SherpaTranscriptMerger.append(
                existing: "first chunk",
                next: "second chunk",
                deduplicateOverlap: false
            ) == "first chunk second chunk"
        )
        #expect(
            SherpaTranscriptMerger.append(
                existing: "hello there",
                next: "there friend"
            ) == "hello there friend"
        )
    }
}
