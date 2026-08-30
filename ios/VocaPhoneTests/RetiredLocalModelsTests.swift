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
        // Canary is smaller and more accurate than the Moonshine Base it took over.
        #expect(
            RetiredLocalModels.replacement(for: "moonshine-base-en", deviceMemoryGB: 8)
                == "canary-180m-flash"
        )
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
                == "giga-am-ctc-v3-ru"
        )
    }

    @Test func anIDFromNeitherTheCatalogNorTheTableHasNoAnswer() {
        #expect(
            RetiredLocalModels.replacement(for: "something-nobody-shipped", deviceMemoryGB: 8)
                == nil
        )
    }

    /// The two tables are maintained by hand on either side of the repository.
    /// Every sherpa id is shared, so the sherpa half of them has to agree.
    @Test func theSherpaHalfOfTheTableCoversTheSameIDs() {
        let sherpaRetired = Set(
            ["moonshine-base-en", "dolphin-base-ctc", "fast-conformer-ctc-4-lang", "giga-am-ctc-ru"]
        )
        #expect(sherpaRetired.isSubset(of: Set(RetiredLocalModels.replacements.keys)))
    }
}
