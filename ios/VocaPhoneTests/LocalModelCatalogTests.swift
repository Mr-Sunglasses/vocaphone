import Testing

struct LocalModelCatalogTests {
    @Test func omnilingualIsAnOptionalGreedyModelWithExplicitCoverage() throws {
        let model = try #require(LocalModelCatalog.descriptor(for: "omnilingual-300m-ctc"))
        #expect(model.covers("ar"))
        #expect(model.covers("sw"))
        #expect(model.covers("hi"))
        #expect(model.detectsLanguageAutomatically)
        #expect(model.sherpaFamily?.acceptsLanguage == false)
        #expect(model.sherpaFamily?.supportsBeamSearch == false)
        #expect(model.translationTargets.isEmpty)
        #expect(!model.supportsCustomVocabulary)
        #expect(model.minimumRamGB == 6)
        #expect(model.maker == .meta)
        #expect(!LocalModelCatalog.accuracyRanking(for: "hi").contains(model.id))
    }

    @Test func sherpaModelsAreAvailableAlongsideWhisperKit() {
        let sherpa = LocalModelCatalog.all.filter { $0.engine == .sherpaOnnx }
        #expect(sherpa.count == 12)
        #expect(sherpa.allSatisfy { $0.repository != nil && $0.revision != nil })
        #expect(sherpa.allSatisfy { $0.sherpaFamily != nil })
    }

    @Test func sherpaLanguageContractsMatchTheirFamilies() {
        #expect(LocalModelCatalog.descriptor(for: "canary-180m-flash")?.languageCodes == ["en", "de", "es", "fr"])
        #expect(LocalModelCatalog.descriptor(for: "giga-am-v3-ru")?.languageCodes == ["ru"])
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
        // The 132 MB Parakeet 110M fits a 2 GB phone as well, so it is the
        // English answer everywhere the 0.6B does not fit.
        #expect(
            LocalModelCatalog.recommended(deviceMemoryGB: 3, language: "en").id
                == "parakeet-tdt-ctc-110m-en"
        )
        #expect(
            LocalModelCatalog.recommended(deviceMemoryGB: 2, language: "en").id
                == "parakeet-tdt-ctc-110m-en"
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
        // The smallest model built for English, not the smallest that lists
        // it: Paraformer is smaller, but it is a Mandarin model.
        let smallest = LocalModelCatalog.all
            .filter {
                $0.minimumRamGB <= 8 && $0.covers("en")
                    && !LocalModelCatalog.isIncidental($0, for: "en")
            }
            .min { $0.sizeBytes < $1.sizeBytes }

        #expect(lighter.model?.id == smallest?.id)
        #expect(lighter.model?.id == "parakeet-tdt-ctc-110m-en")
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
        #expect(russian[0].model.id == "giga-am-v3-ru")
        #expect(russian[1].model.id == "parakeet-tdt-0.6b-v3")
        #expect(russian.count >= 3)
    }

    /// Two keyboards, one card in first place. It has to be the one that can
    /// hear both of them — the Russian specialist used to lead here, and it
    /// does not transcribe a word of the English keyboard sitting next to it.
    @Test func twoKeyboardLanguagesLeadWithTheModelThatCoversBoth() {
        let spoken = LocalModelCatalog.spokenLanguages(
            device: "en",
            keyboards: ["en-US", "ru-RU"]
        )
        #expect(spoken == ["en", "ru"])
        let picks = LocalModelCatalog.recommendations(deviceMemoryGB: 8, languages: spoken)
        #expect(picks[0].role == .multilingual)
        #expect(picks[0].model.covers("en"))
        #expect(picks[0].model.covers("ru"))
        // The specialists stay, as alternates rather than as the answer.
        #expect(picks.contains { $0.model.id == "giga-am-v3-ru" })
        #expect(picks.contains { $0.model.id == "parakeet-tdt-0.6b-v2-en" })
    }

    /// One keyboard language still leads with its specialist: there is nothing
    /// for a multilingual model to cover that the specialist does not.
    @Test func aSingleKeyboardLanguageStillLeadsWithItsSpecialist() {
        let spoken = LocalModelCatalog.spokenLanguages(device: "en", keyboards: ["ru-RU"])
        #expect(spoken == ["ru"])
        let picks = LocalModelCatalog.recommendations(deviceMemoryGB: 8, languages: spoken)
        #expect(picks[0].role == .regional)
        #expect(picks[0].model.id == "giga-am-v3-ru")
    }

    @Test func everyEnabledKeyboardLanguageIsInTheSpokenList() {
        let spoken = LocalModelCatalog.spokenLanguages(
            device: "en",
            keyboards: ["en-US", "zh-Hans", "ja", "ko", "ru-RU"]
        )
        #expect(spoken == ["en", "zh", "ja", "ko", "ru"])
        let picks = LocalModelCatalog.recommendations(deviceMemoryGB: 8, languages: spoken)
        #expect(picks.contains { $0.model.id == "giga-am-v3-ru" })
        #expect(picks.contains { $0.model.id == "sense-voice" })
    }

    @Test func noChineseModelWithoutAChineseKeyboard() {
        let spoken = LocalModelCatalog.spokenLanguages(
            device: "en",
            keyboards: ["en-US", "ru-RU"]
        )
        #expect(spoken == ["en", "ru"])
        let picks = LocalModelCatalog.recommendations(deviceMemoryGB: 8, languages: spoken)
        #expect(!picks.contains { $0.model.id == "paraformer-zh-small" })
        #expect(!picks.contains { $0.model.id == "sense-voice" })
    }

    /// The phone region and preferred-language list are not keyboards. A
    /// Chinese iPhone with a Russian layout must not get Paraformer.
    @Test func deviceLanguageDoesNotInventAKeyboard() {
        let spoken = LocalModelCatalog.spokenLanguages(
            device: "zh",
            keyboards: ["en-US", "ru-RU"]
        )
        #expect(spoken == ["en", "ru"])
        #expect(!spoken.contains("zh"))
        let picks = LocalModelCatalog.recommendations(deviceMemoryGB: 8, languages: spoken)
        #expect(picks.contains { $0.model.id == "giga-am-v3-ru" })
        #expect(!picks.contains { $0.model.id == "paraformer-zh-small" })
        #expect(!picks.contains { $0.model.id == "sense-voice" })
    }

    @Test func emptyKeyboardsFallBackToThePhoneLanguage() {
        let spoken = LocalModelCatalog.spokenLanguages(
            device: "ru",
            keyboards: ["emoji", "com.vocahq.vocaphone.keyboard"]
        )
        #expect(spoken == ["ru"])
    }

    @Test func normalizedLanguageCodeSkipsEmojiDictationAndBundles() {
        #expect(LocalModelCatalog.normalizedLanguageCode("emoji") == nil)
        #expect(LocalModelCatalog.normalizedLanguageCode("dictation") == nil)
        #expect(LocalModelCatalog.normalizedLanguageCode("com.vocahq.vocaphone.keyboard") == nil)
        #expect(LocalModelCatalog.normalizedLanguageCode("ru_RU@sw=Russian") == "ru")
        #expect(LocalModelCatalog.normalizedLanguageCode("zh-Hans") == "zh")
        #expect(LocalModelCatalog.normalizedLanguageCode("yue-Hant") == "yue")
        #expect(LocalModelCatalog.normalizedLanguageCode("en-US") == "en")
        #expect(LocalModelCatalog.normalizedLanguageCode("auto") == nil)
    }

    @Test func multilingualPickCoversEveryLanguageOnThePhone() {
        let pick = LocalModelCatalog.bestMultilingual(
            deviceMemoryGB: 8,
            languages: ["ru", "en"]
        )
        #expect(pick?.id == "parakeet-tdt-0.6b-v3")
        #expect(pick?.covers("en") == true)
        #expect(pick?.covers("ru") == true)
    }

    /// An English iPhone that also types Hindi. Dolphin covers both, but it is
    /// an East Asian model, and leading with it put it above Parakeet — the
    /// best English model this phone can run — under FOR YOU.
    @Test func anEnglishPhoneWithAnIndicKeyboardLeadsWithTheBestEnglishModel() {
        let spoken = LocalModelCatalog.spokenLanguages(
            device: "en",
            keyboards: ["hi-IN", "en-IN"]
        )
        #expect(spoken == ["en", "hi"])
        let picks = LocalModelCatalog.recommendations(deviceMemoryGB: 6, languages: spoken)
        #expect(picks[0].model.id == "parakeet-tdt-0.6b-v2-en")
        #expect(picks.contains { $0.model.covers("hi") })
    }

    /// The phone language leads only when it is typed too. Globe order is not
    /// a preference, so a Hindi keyboard listed first must not outrank it.
    @Test func thePhoneLanguageLeadsTheKeyboardsItIsOn() {
        #expect(
            LocalModelCatalog.spokenLanguages(device: "en", keyboards: ["hi-IN", "en-US"])
                == ["en", "hi"]
        )
        #expect(
            LocalModelCatalog.spokenLanguages(device: "en", keyboards: ["hi-IN"]) == ["hi"]
        )
    }

    /// First run offers only the most accurate models. A wide model that
    /// merely covers English stays in More models; the small Parakeet is on the
    /// English accuracy list, so it takes the third card as the one download
    /// that is not 660 MB.
    @Test func onboardingOffersOnlyTheMostAccurateModels() {
        let picks = LocalModelCatalog.onboardingRecommendations(deviceMemoryGB: 6, languages: ["en"])
        #expect(picks.map(\.model.id) == [
            "parakeet-tdt-0.6b-v2-en", "parakeet-tdt-0.6b-v3", "parakeet-tdt-ctc-110m-en",
        ])
        #expect(picks.allSatisfy { LocalModelCatalog.isHighAccuracy($0.model, for: "en") })
    }

    /// A second keyboard earns its own most accurate model, after the phone
    /// language's best.
    @Test func onboardingKeepsTheBestModelForASecondKeyboard() {
        let picks = LocalModelCatalog.onboardingRecommendations(
            deviceMemoryGB: 6,
            languages: ["en", "hi"]
        )
        #expect(picks.count == 3)
        #expect(picks[0].model.id == "parakeet-tdt-0.6b-v2-en")
        #expect(picks.contains { $0.model.id == "dolphin-small-ctc" })
        #expect(!picks.contains { $0.model.id == "dolphin-base-ctc" })
    }

    /// A phone too small for any of them still gets something to download.
    @Test func onboardingFallsBackWhenNothingAccurateFits() {
        let picks = LocalModelCatalog.onboardingRecommendations(deviceMemoryGB: 1, languages: ["en"])
        #expect(!picks.isEmpty)
    }

    @Test func everyFamilyHasItsMaker() {
        let maker = { (id: String) in LocalModelCatalog.descriptor(for: id)?.maker }
        #expect(maker("parakeet-tdt-0.6b-v2-en") == .nvidia)
        #expect(maker("canary-180m-flash") == .nvidia)
        #expect(maker("openai_whisper-base") == .openAI)
        #expect(maker("parakeet-tdt-ctc-110m-en") == .nvidia)
        #expect(maker("zipformer-vi") == .nextGenKaldi)
        #expect(maker("sense-voice") == .alibaba)
        #expect(maker("paraformer-zh-small") == .alibaba)
        #expect(maker("dolphin-small-ctc") == .dataocean)
        #expect(maker("giga-am-v3-ru") == .sber)
    }

    @Test func accuracyRankingsOnlyReferenceAvailableModels() {
        for language in TranscriptionLanguage.allCases where language != .automatic {
            for id in LocalModelCatalog.accuracyRanking(for: language.rawValue) {
                #expect(LocalModelCatalog.descriptor(for: id) != nil)
            }
        }
    }

    /// Smallest is smallest first, and never a model built for another
    /// language that merely lists this one.
    @Test func theSmallestChoiceIsOrderedBySizeForTheLanguage() {
        let picks = LocalModelCatalog.onboardingRecommendations(
            deviceMemoryGB: 6,
            languages: ["en"],
            priority: .lighter
        )
        #expect(picks.count == 3)
        #expect(picks.map(\.model.sizeBytes) == picks.map(\.model.sizeBytes).sorted())
        #expect(!picks.contains { $0.model.id == "paraformer-zh-small" })
        #expect(!picks.contains { $0.model.maker == .dataocean })
    }

    @Test func theManyLanguagesChoiceNeverOffersAnEnglishOnlyModel() {
        let picks = LocalModelCatalog.onboardingRecommendations(
            deviceMemoryGB: 6,
            languages: ["en", "de"],
            priority: .multilingual
        )
        #expect(!picks.isEmpty)
        #expect(picks.allSatisfy { !$0.model.englishOnly })
        #expect(picks[0].model.covers("en") && picks[0].model.covers("de"))
    }

    @Test func spokenLanguagesUsesDeviceWhenItIsNotEnglish() {
        let spoken = LocalModelCatalog.spokenLanguages(
            device: "ru",
            keyboards: ["ru-RU", "en-US"]
        )
        #expect(spoken.first == "ru")
        #expect(spoken.contains("en"))
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
