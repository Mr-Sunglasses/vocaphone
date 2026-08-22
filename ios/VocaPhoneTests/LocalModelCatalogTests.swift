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
        // Detecting the language is not the same as covering every language:
        // Parakeet v3 decides for itself, and knows exactly 25.
        let parakeet = LocalModelCatalog.descriptor(for: "parakeet-tdt-0.6b-v3")
        #expect(parakeet?.detectsLanguageAutomatically == true)
        #expect(parakeet?.languageCodes.count == 25)
        #expect(parakeet?.languageCodes.contains("ru") == true)
        #expect(parakeet?.languageCodes.contains("hi") == false)
        // SenseVoice takes a language on its sherpa config, so a pick reaches
        // the decoder rather than only the punctuation.
        let senseVoice = LocalModelCatalog.descriptor(for: "sense-voice")
        #expect(senseVoice?.detectsLanguageAutomatically == false)
        #expect(senseVoice?.languageCodes == ["zh", "en", "ja", "ko", "yue"])
        #expect(LocalModelCatalog.descriptor(for: "dolphin-base-ctc")?.languageCodes.contains("hi") == true)
    }

    /// The point of declaring Parakeet's coverage: every one of its 25 languages
    /// has to be a row the user can actually reach.
    @Test func everyLanguageAModelCoversHasAPickerEntry() {
        let picker = LocalModelLanguages.picker
        let parakeet = LocalModelCatalog.descriptor(for: "parakeet-tdt-0.6b-v3")
        #expect(parakeet?.languageCodes.count == 25)
        for model in LocalModelCatalog.all {
            #expect(
                model.languageCodes.isSubset(of: picker),
                "\(model.id) covers codes the picker cannot show: \(model.languageCodes.subtracting(picker))"
            )
        }
    }

    /// Cantonese is language 100. Offering it on a Whisper build that stops at
    /// 99 would not fail, it would silently decode against the wrong token.
    @Test func cantoneseIsOfferedOnlyWhereItDecodes() {
        let small = LocalModelCatalog.descriptor(for: "openai_whisper-small")
        #expect(small?.selectableLanguageCodes.contains("yue") == false)
        #expect(small?.selectableLanguageCodes.contains("hi") == true)
        let largeV3 = LocalModelCatalog.all.first { $0.id.contains("large-v3") }
        #expect(largeV3?.selectableLanguageCodes.isEmpty == true)
        #expect(
            LocalModelCatalog.descriptor(for: "sense-voice")?
                .selectableLanguageCodes.contains("yue") == true
        )
    }

    /// The lead pick follows the phone's language, and Parakeet leads wherever
    /// the memory holds it rather than a tiny model the phone does not need.
    @Test func recommendationLeadsWithParakeetThenFallsBackByMemory() {
        #expect(
            LocalModelCatalog.recommended(deviceMemoryGB: 4, language: "en").id
                == "parakeet-tdt-0.6b-v2-en"
        )
        #expect(
            LocalModelCatalog.recommended(deviceMemoryGB: 3, language: "en").id
                == "moonshine-base-en"
        )
        #expect(
            LocalModelCatalog.recommended(deviceMemoryGB: 2, language: "en").id
                == "moonshine-tiny-en"
        )
    }

    /// The list is what makes a 670 MB default acceptable: someone on cellular
    /// can see a small answer to the same question without going hunting through
    /// the catalog.
    @Test func picksCoverAccuracyBreadthAndASmallDownload() {
        let english = LocalModelCatalog.recommendations(deviceMemoryGB: 8, language: "en")
        #expect(english.map(\.role) == [.english, .multilingual, .compact])
        #expect(english[0].model.id == "parakeet-tdt-0.6b-v2-en")
        #expect(english[1].model.id == "parakeet-tdt-0.6b-v3")
        #expect(english[2].model.sizeBytes < english[0].model.sizeBytes)

        // A regional language leads with its own specialist and still sees the
        // multilingual and English answers next to it.
        let russian = LocalModelCatalog.recommendations(deviceMemoryGB: 8, language: "ru")
        #expect(russian[0].role == .regional)
        #expect(russian[0].model.id == "giga-am-ctc-ru")
        #expect(russian[1].model.id == "parakeet-tdt-0.6b-v3")
        #expect(russian.count >= 3)
    }

    @Test func everyPickFitsTheDeviceAndCoversItsLanguage() {
        for language in ["en", "de", "hi", "zh", "yue", "ja", "ru", "it"] {
            for memory in [2, 3, 4, 8] {
                let picks = LocalModelCatalog.recommendations(
                    deviceMemoryGB: memory, language: language
                )
                #expect(!picks.isEmpty, "no picks for \(language) on \(memory) GB")
                #expect(Set(picks.map(\.model.id)).count == picks.count)
                for pick in picks {
                    #expect(
                        memory >= pick.model.minimumRamGB,
                        "\(pick.model.id) does not fit \(memory) GB"
                    )
                }
                // The lead pick covers the phone's language whenever anything
                // that fits does. A 2 GB iPhone has no Italian model at all,
                // and offering the English one is better than offering nothing.
                let anyCovers = LocalModelCatalog.all.contains {
                    memory >= $0.minimumRamGB && $0.covers(language)
                }
                #expect(
                    picks[0].model.covers(language) || !anyCovers,
                    "\(picks[0].model.id) leads for \(language) on \(memory) GB"
                )
            }
        }
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
