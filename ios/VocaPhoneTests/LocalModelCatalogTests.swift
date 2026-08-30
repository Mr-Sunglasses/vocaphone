import Testing

struct LocalModelCatalogTests {
    @Test func sherpaModelsAreAvailableAlongsideWhisperKit() {
        let sherpa = LocalModelCatalog.all.filter { $0.engine == .sherpaOnnx }
        #expect(sherpa.count == 9)
        #expect(sherpa.allSatisfy { $0.repository != nil && $0.revision != nil })
        #expect(sherpa.allSatisfy { $0.sherpaFamily != nil })
    }

    @Test func sherpaLanguageContractsMatchTheirFamilies() {
        #expect(LocalModelCatalog.descriptor(for: "canary-180m-flash")?.languageCodes == ["en", "de", "es", "fr"])
        #expect(LocalModelCatalog.descriptor(for: "giga-am-ctc-v3-ru")?.languageCodes == ["ru"])
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
        #expect(LocalModelCatalog.descriptor(for: "dolphin-small-ctc")?.languageCodes.contains("hi") == true)
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
        let small = LocalModelCatalog.descriptor(for: "openai_whisper-small_216MB")
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
        // Below Parakeet's budget, Canary rather than the Moonshine builds this
        // used to reach: 207 MB at 7.12 average WER against Moonshine Base's
        // 287 MB at 10.07, and it needs only 2 GB.
        #expect(
            LocalModelCatalog.recommended(deviceMemoryGB: 3, language: "en").id
                == "canary-180m-flash"
        )
        #expect(
            LocalModelCatalog.recommended(deviceMemoryGB: 2, language: "en").id
                == "canary-180m-flash"
        )
    }

    @Test func guidanceReturnsOnePlainLanguageMatch() {
        let result = LocalModelCatalog.guidance(
            deviceMemoryGB: 4,
            intent: ModelGuidanceIntent(language: "en")
        )

        #expect(result.confidence == .goodDefault)
        #expect(result.intent.language == "en")
        #expect(result.model?.id == "parakeet-tdt-0.6b-v2-en")
        #expect(result.reason.contains("English"))
    }

    @Test func guidancePriorityChangesTheDownloadTradeoff() {
        let balanced = LocalModelCatalog.guidance(
            deviceMemoryGB: 8,
            intent: ModelGuidanceIntent(language: "en", priority: .balanced)
        )
        let lighter = LocalModelCatalog.guidance(
            deviceMemoryGB: 8,
            intent: ModelGuidanceIntent(language: "en", priority: .lighter)
        )
        let smallest = LocalModelCatalog.all
            .filter { $0.minimumRamGB <= 8 && $0.covers("en") }
            .min { $0.sizeBytes < $1.sizeBytes }

        #expect(lighter.model?.id == smallest?.id)
        #expect(lighter.reason.contains("smallest"))
        #expect(balanced.model != nil)

    }

    /// The reason this option exists at all. "Best accuracy" was replaced
    /// because it returned the balanced match on every language and every
    /// memory size, which is a control that does nothing.
    @Test func multilingualIsADifferentAnswerWhereverAWiderModelFits() {
        var differed = 0
        for language in ["en", "ru", "de", "ja", "zh"] {
            for memory in [8, 4, 3] {
                let balanced = LocalModelCatalog.guidance(
                    deviceMemoryGB: memory,
                    intent: ModelGuidanceIntent(language: language, priority: .balanced)
                ).model
                let wide = LocalModelCatalog.guidance(
                    deviceMemoryGB: memory,
                    intent: ModelGuidanceIntent(language: language, priority: .multilingual)
                ).model

                #expect(wide != nil, "no multilingual match for \(language) at \(memory)GB")
                #expect(wide?.covers(language) == true, "\(language) pick cannot transcribe it")
                #expect(wide?.englishOnly == false, "\(language) got an English-only model")
                #expect((wide?.minimumRamGB ?? .max) <= memory, "\(language) pick does not fit")
                if wide?.id != balanced?.id { differed += 1 }
            }
        }
        // The option has to actually earn its place on ordinary iPhones.
        #expect(differed >= 10, "multilingual never differed from balanced")
    }




    @Test func guidanceAutomaticLanguageUsesThePhoneLanguage() {
        let result = LocalModelCatalog.guidance(
            deviceMemoryGB: 8,
            intent: ModelGuidanceIntent(language: "auto", priority: .balanced)
        )

        #expect(result.intent.language == LocalModelCatalog.deviceLanguage)
        #expect(result.model?.covers(result.intent.language) == true)
    }

    @Test func guidanceReportsNoMatchWhenNothingFits() {
        let result = LocalModelCatalog.guidance(
            deviceMemoryGB: 1,
            intent: ModelGuidanceIntent(language: "en")
        )

        #expect(result.confidence == .noMatch)
        #expect(result.model == nil)
        #expect(result.reason.contains("English"))
    }

    @Test func guidanceDoesNotMislabelAnUnlistedPhoneLanguageAsAutomatic() {
        let result = LocalModelCatalog.guidance(
            deviceMemoryGB: 8,
            intent: ModelGuidanceIntent(language: "af", priority: .balanced)
        )

        #expect(result.intent.language == "af")
        #expect(!result.languageName.isEmpty)
        #expect(result.languageName != TranscriptionLanguage.automatic.displayName)
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
        #expect(russian[0].model.id == "giga-am-ctc-v3-ru")
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
