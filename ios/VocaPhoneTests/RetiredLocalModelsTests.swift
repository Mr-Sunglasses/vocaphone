import Foundation
import Testing

/// Shrinking the catalog is only safe if everyone it stranded lands somewhere
/// sensible. The failure this guards is silent: an unknown id reads back as no
/// selection, and the app re-derives a first-run recommendation, so an iPhone
/// deliberately running a large model comes back on the smallest one.
struct RetiredLocalModelsTests {

    @Test func launchMigrationPersistsTheReplacementAndDownloadNotice() throws {
        let suite = "RetiredLocalModelsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: LocalTranscriptionPreferences.enabledKey)
        defaults.set("openai_whisper-medium", forKey: LocalTranscriptionPreferences.modelKey)

        RetiredLocalModels.migrateStoredSelection(deviceMemoryGB: 8, defaults: defaults)

        #expect(defaults.bool(forKey: LocalTranscriptionPreferences.enabledKey))
        #expect(defaults.string(forKey: LocalTranscriptionPreferences.modelKey)
            == "openai_whisper-large-v3-v20240930_626MB")
        #expect(defaults.string(forKey: LocalTranscriptionPreferences.retiredModelReplacementKey)
            == "openai_whisper-large-v3-v20240930_626MB")
    }

    @Test func launchMigrationTurnsOffAnUnreplaceableLocalRoute() throws {
        let suite = "RetiredLocalModelsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: LocalTranscriptionPreferences.enabledKey)
        defaults.set("dolphin-base-ctc", forKey: LocalTranscriptionPreferences.modelKey)

        RetiredLocalModels.migrateStoredSelection(deviceMemoryGB: 1, defaults: defaults)

        #expect(!defaults.bool(forKey: LocalTranscriptionPreferences.enabledKey))
        #expect(defaults.string(forKey: LocalTranscriptionPreferences.modelKey) == nil)
        #expect(defaults.string(forKey: LocalTranscriptionPreferences.retiredModelReplacementKey) == nil)
    }

    @Test func retiredFileCleanupDeletesOnlyNamedFoldersAndReportsFailures() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let retired = root.appendingPathComponent("openai_whisper-medium")
        let newer = root.appendingPathComponent("newer-model")
        try FileManager.default.createDirectory(at: retired, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newer, withIntermediateDirectories: true)

        let failed = RetiredModelFileCleanup.delete(in: root, ids: ["openai_whisper-medium"]) { _ in
            throw CocoaError(.fileWriteNoPermission)
        }
        #expect(failed.deleted.isEmpty)
        #expect(failed.failed == ["openai_whisper-medium"])
        #expect(FileManager.default.fileExists(atPath: retired.path))

        let completed = RetiredModelFileCleanup.delete(in: root, ids: ["openai_whisper-medium"])
        #expect(completed.deleted == ["openai_whisper-medium"])
        #expect(completed.failed.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: retired.path))
        #expect(FileManager.default.fileExists(atPath: newer.path))
    }

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

    @Test func everyMoonshineBuildLandsOnTheSmallParakeet() {
        for id in ["moonshine-tiny-en", "moonshine-base-en", "moonshine-v2-tiny-en", "moonshine-v2-base-en"] {
            #expect(
                RetiredLocalModels.replacement(for: id, deviceMemoryGB: 2) == "parakeet-tdt-ctc-110m-en",
                "\(id)"
            )
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
        // Both Dolphin builds prefer Whisper Large, then Small, then SenseVoice.
        // Empty languages keep the Whisper path, including Small on a 3 GB phone.
        for id in ["dolphin-base-ctc", "dolphin-small-ctc"] {
            #expect(
                RetiredLocalModels.replacement(for: id, deviceMemoryGB: 8)
                    == "openai_whisper-large-v3-v20240930_626MB"
            )
            #expect(
                RetiredLocalModels.replacement(for: id, deviceMemoryGB: 3)
                    == "openai_whisper-small_216MB"
            )
        }
        #expect(
            RetiredLocalModels.replacement(for: "paraformer-zh-small", deviceMemoryGB: 2)
                == "sense-voice"
        )
        // The Russian model kept its weights family and changed id, so that an
        // already-downloaded v2 is swept rather than failing its SHA-256 check.
        #expect(
            RetiredLocalModels.replacement(for: "giga-am-ctc-ru", deviceMemoryGB: 8)
                == "giga-am-v3-ru"
        )
    }

    /// SenseVoice needs 2 GB, so a 2 GB iPhone can land there. The cleared
    /// case is a device smaller than every remaining candidate.
    @Test func aRetiredModelWithNoReplacementThisDeviceCanRunClearsTheSelection() {
        #expect(RetiredLocalModels.resolve("dolphin-base-ctc", deviceMemoryGB: 1) == .cleared)
        #expect(RetiredLocalModels.replacement(for: "dolphin-base-ctc", deviceMemoryGB: 1) == nil)
        #expect(
            RetiredLocalModels.resolve("dolphin-base-ctc", deviceMemoryGB: 2)
                == .replaced("sense-voice")
        )
        // Empty languages on a 3 GB device still take Whisper Small.
        #expect(
            RetiredLocalModels.resolve("dolphin-base-ctc", deviceMemoryGB: 3)
                == .replaced("openai_whisper-small_216MB")
        )
    }

    /// Whisper Small cannot transcribe Cantonese, so a 3 GB Dolphin install
    /// that was used for `yue` must not stay on Small. SenseVoice covers it
    /// and fits. English, and a migration with no language information, still
    /// prefer Small so SenseVoice does not steal those phones.
    @Test func dolphinRetirementPrefersAFittingModelThatStillCoversTheLanguage() {
        for id in ["dolphin-base-ctc", "dolphin-small-ctc"] {
            #expect(
                RetiredLocalModels.replacement(for: id, deviceMemoryGB: 3, languages: ["yue"])
                    == "sense-voice",
                "\(id)"
            )
            #expect(
                RetiredLocalModels.replacement(for: id, deviceMemoryGB: 8, languages: ["yue"])
                    == "openai_whisper-large-v3-v20240930_626MB",
                "\(id)"
            )
            #expect(
                RetiredLocalModels.replacement(for: id, deviceMemoryGB: 3, languages: ["en"])
                    == "openai_whisper-small_216MB",
                "\(id)"
            )
            #expect(
                RetiredLocalModels.replacement(for: id, deviceMemoryGB: 3, languages: ["hi"])
                    == "openai_whisper-small_216MB",
                "\(id)"
            )
            #expect(
                RetiredLocalModels.replacement(for: id, deviceMemoryGB: 3)
                    == "openai_whisper-small_216MB",
                "\(id)"
            )
            #expect(
                RetiredLocalModels.replacement(for: id, deviceMemoryGB: 2, languages: ["yue"])
                    == "sense-voice",
                "\(id)"
            )
        }
    }

    /// The language someone chose to dictate in outranks the others the
    /// migration collects, and is never traded for a model without it.
    @Test func theChosenLanguageOutranksTheOthersAndIsNeverDropped() {
        for id in ["dolphin-base-ctc", "dolphin-small-ctc"] {
            // Cantonese chosen, Hindi also on the phone: nothing covers both,
            // and Small would keep Hindi but lose Cantonese.
            #expect(
                RetiredLocalModels.replacement(
                    for: id, deviceMemoryGB: 3, primaryLanguage: "yue", languages: ["yue", "hi"]
                ) == "sense-voice",
                "\(id)"
            )
            // The other way round, Small keeps the chosen Hindi.
            #expect(
                RetiredLocalModels.replacement(
                    for: id, deviceMemoryGB: 3, primaryLanguage: "hi", languages: ["hi", "yue"]
                ) == "openai_whisper-small_216MB",
                "\(id)"
            )
        }
        // Hindi chosen on a 2 GB phone: only SenseVoice fits, and it has no
        // Hindi, so the route is cleared as it was before SenseVoice was a rung.
        #expect(
            RetiredLocalModels.resolve(
                "dolphin-base-ctc", deviceMemoryGB: 2, primaryLanguage: "hi", languages: ["hi"]
            ) == .cleared
        )
        // Automatic is not a chosen language.
        #expect(
            RetiredLocalModels.resolve("dolphin-base-ctc", deviceMemoryGB: 2, primaryLanguage: "auto")
                == .replaced("sense-voice")
        )
        // A ladder that never covered the language ignores it: a stale German
        // setting does not strand a Moonshine user.
        #expect(
            RetiredLocalModels.replacement(for: "moonshine-base-en", deviceMemoryGB: 2, primaryLanguage: "de")
                == "parakeet-tdt-ctc-110m-en"
        )
    }

    @Test func launchMigrationClearsAHindiDolphinThatNothingFittingCovers() throws {
        let suite = "RetiredLocalModelsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: LocalTranscriptionPreferences.enabledKey)
        defaults.set("dolphin-base-ctc", forKey: LocalTranscriptionPreferences.modelKey)
        defaults.set("hi", forKey: KeyboardPreferences.transcriptionLanguageKey)

        RetiredLocalModels.migrateStoredSelection(deviceMemoryGB: 2, languages: ["hi", "en"], defaults: defaults)

        #expect(!defaults.bool(forKey: LocalTranscriptionPreferences.enabledKey))
        #expect(defaults.string(forKey: LocalTranscriptionPreferences.modelKey) == nil)
    }

    @Test func launchMigrationSendsCantoneseDolphinToSenseVoiceOnASmallPhone() throws {
        let suite = "RetiredLocalModelsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: LocalTranscriptionPreferences.enabledKey)
        defaults.set("dolphin-small-ctc", forKey: LocalTranscriptionPreferences.modelKey)

        defaults.set("yue", forKey: KeyboardPreferences.transcriptionLanguageKey)
        RetiredLocalModels.migrateStoredSelection(deviceMemoryGB: 3, defaults: defaults)

        #expect(defaults.bool(forKey: LocalTranscriptionPreferences.enabledKey))
        #expect(defaults.string(forKey: LocalTranscriptionPreferences.modelKey) == "sense-voice")
        #expect(
            defaults.string(forKey: LocalTranscriptionPreferences.retiredModelReplacementKey)
                == "sense-voice"
        )
    }

    @Test func languagesForMigrationDropsAutomaticAndKeepsCantonese() {
        #expect(
            RetiredLocalModels.languagesForMigration(
                transcriptionLanguage: "yue",
                modelLanguages: ["auto", "en"],
                preferredLanguages: ["en-US"]
            ) == ["yue", "en"]
        )
        #expect(
            RetiredLocalModels.languagesForMigration(
                transcriptionLanguage: "auto",
                modelLanguages: [],
                preferredLanguages: []
            ).isEmpty
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
            [
                "dolphin-base-ctc", "dolphin-small-ctc", "paraformer-zh-small",
                "fast-conformer-ctc-4-lang", "giga-am-ctc-ru",
            ]
        )
        #expect(sherpaRetired.isSubset(of: Set(RetiredLocalModels.replacements.keys)))
    }
}
