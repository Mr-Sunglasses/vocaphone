import Testing

/// Shrinking the catalog is only safe if everyone it stranded lands somewhere
/// sensible. The failure this guards is silent: an unknown id reads back as no
/// selection, and the app re-derives a first-run recommendation, so an iPhone
/// deliberately running a large model comes back on the smallest one.
struct RetiredLocalModelsTests {

    @Test func everyRetiredIDIsGoneAndEveryReplacementExists() {
        for (retired, replacements) in RetiredLocalModels.replacements {
            #expect(
                LocalModelCatalog.descriptor(for: retired) == nil,
                "\(retired) is still in the catalog and must not be listed as retired"
            )
            #expect(!replacements.isEmpty, "\(retired) has no replacements")
            for replacement in replacements {
                #expect(
                    LocalModelCatalog.descriptor(for: replacement) != nil,
                    "\(retired) points at \(replacement), which is not in the catalog"
                )
            }
        }
    }

    @Test func aModelStillInTheCatalogIsLeftAlone() {
        #expect(!RetiredLocalModels.isRetired("openai_whisper-base"))
        #expect(
            RetiredLocalModels.replacement(for: "openai_whisper-base", deviceMemoryGB: 8)
                == "openai_whisper-base"
        )
    }

    @Test func aDroppedEnglishBuildLandsOnTheMultilingualOneBesideIt() {
        #expect(
            RetiredLocalModels.replacement(for: "openai_whisper-tiny.en", deviceMemoryGB: 8)
                == "openai_whisper-base"
        )
        #expect(
            RetiredLocalModels.replacement(for: "openai_whisper-small.en", deviceMemoryGB: 8)
                == "openai_whisper-small_216MB"
        )
    }

    /// Five builds of one set of weights collapse onto the one that survived.
    @Test func theCompressionVariantsCollapseOntoTheSurvivingBuild() {
        for id in [
            "openai_whisper-large-v3-v20240930",
            "openai_whisper-large-v3-v20240930_turbo",
            "openai_whisper-large-v3-v20240930_547MB",
            "openai_whisper-large-v3-v20240930_turbo_632MB"
        ] {
            #expect(
                RetiredLocalModels.replacement(for: id, deviceMemoryGB: 8)
                    == "openai_whisper-large-v3-v20240930_626MB"
            )
        }
    }

    /// The case the migration exists for. Someone on Medium chose a heavy model
    /// on purpose, so they get the heaviest one still shipping -- not the floor.
    @Test func aDroppedSizePromotesRatherThanFallingToTheFloor() {
        for id in [
            "openai_whisper-medium", "openai_whisper-medium.en",
            "openai_whisper-large-v2_949MB", "openai_whisper-large-v3_947MB",
            "distil-whisper_distil-large-v3"
        ] {
            #expect(
                RetiredLocalModels.replacement(for: id, deviceMemoryGB: 8)
                    == "openai_whisper-large-v3-v20240930_626MB"
            )
        }
    }

    /// "Nearest" has to survive the device: the 626 MB build needs 4 GB, so a
    /// 3 GB iPhone steps down the surviving ladder instead of off it.
    @Test func aPromotionTheDeviceCannotHoldStepsDownInstead() {
        #expect(
            RetiredLocalModels.replacement(for: "openai_whisper-medium", deviceMemoryGB: 3)
                == "openai_whisper-small_216MB"
        )
    }

    @Test func retiredSherpaModelsLandOnWhatReplacedThem() {
        #expect(
            RetiredLocalModels.replacement(for: "fast-conformer-ctc-4-lang", deviceMemoryGB: 8)
                == "canary-180m-flash"
        )
        #expect(
            RetiredLocalModels.replacement(for: "dolphin-base-ctc", deviceMemoryGB: 8)
                == "dolphin-small-ctc"
        )
        // The Russian model kept its weights family and changed id, so that an
        // already-downloaded v2 is swept rather than failing its SHA-256 check.
        #expect(
            RetiredLocalModels.replacement(for: "giga-am-ctc-ru", deviceMemoryGB: 8)
                == "giga-am-v3-ru"
        )
    }

    /// The case a 2 GB iPhone on Dolphin Base lands in: every replacement wants
    /// more memory than it has. Clearing the selection alone would leave
    /// on-device transcription switched on with nothing behind it, and every
    /// dictation would record the audio and then fail.
    @Test func aRetiredModelWithNoReplacementThisDeviceCanRunClearsTheSelection() {
        #expect(RetiredLocalModels.resolve("dolphin-base-ctc", deviceMemoryGB: 2) == .cleared)
        #expect(RetiredLocalModels.replacement(for: "dolphin-base-ctc", deviceMemoryGB: 2) == nil)
        // It fits on a 3 GB device, so nothing is cleared there.
        #expect(
            RetiredLocalModels.resolve("dolphin-base-ctc", deviceMemoryGB: 3)
                == .replaced("dolphin-small-ctc")
        )
    }

    @Test func resolveReportsTheThreeOutcomesApart() {
        #expect(RetiredLocalModels.resolve("openai_whisper-base", deviceMemoryGB: 8) == .unchanged)
        #expect(RetiredLocalModels.resolve("nobody-shipped-this", deviceMemoryGB: 8) == .unchanged)
        #expect(
            RetiredLocalModels.resolve("openai_whisper-medium", deviceMemoryGB: 8)
                == .replaced("openai_whisper-large-v3-v20240930_626MB")
        )
    }

    /// An id this build does not recognise is what a downgrade looks like, so
    /// it is left alone rather than discarded.
    @Test func anIDFromNeitherTheCatalogNorTheTableIsLeftAlone() {
        #expect(
            RetiredLocalModels.replacement(for: "something-nobody-shipped", deviceMemoryGB: 8)
                == "something-nobody-shipped"
        )
    }

    /// The two tables are maintained by hand on either side of the repository.
    /// Every sherpa id is shared, so the sherpa half of them has to agree.
    @Test func theSherpaHalfOfTheTableCoversTheSameIDs() {
        let sherpaRetired = Set(
            ["dolphin-base-ctc", "fast-conformer-ctc-4-lang", "giga-am-ctc-ru"]
        )
        #expect(sherpaRetired.isSubset(of: Set(RetiredLocalModels.replacements.keys)))
    }
}
