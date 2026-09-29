import Foundation

/// Where a stored selection goes when the model it names has left the catalog.
///
/// The chosen model id is persisted verbatim in the App Group so the keyboard
/// and the app agree on it, which means shrinking the catalog strands everyone
/// who had picked one of the removed rows: `LocalModelCatalog.descriptor(for:)`
/// returns nil and the app quietly re-derives a first-run recommendation.
/// Someone who deliberately downloaded Whisper Medium would come back to the
/// smallest model in the catalog, with nothing on screen to say why.
///
/// Each entry is a preference *list* rather than a single id, because "nearest"
/// has to survive the device: a 4 GB iPhone cannot hold the build that replaces
/// Medium on quality, so the fallback steps down the surviving ladder instead of
/// off it. `replacement(for:deviceMemoryGB:)` resolves the list against what the
/// device can actually run.
///
/// Mirrors `RetiredModels.kt`. The two catalogs differ -- Core ML here,
/// whisper.cpp GGML there -- so the tables differ; the rule does not.
enum RetiredLocalModels {

    /// Retired id to its replacements, best first.
    ///
    /// The WhisperKit rows collapse three axes that no longer exist in the
    /// catalog: the `.en` builds, the several compressions of one set of
    /// weights, and the sizes that were never viable on a phone. Anything that
    /// still has a rung of its own lands on it; the rest move up to the 626 MB
    /// Large v3 Turbo build and step down where that will not fit.
    static let replacements: [String: [String]] = {
        var table: [String: [String]] = [:]

        // Whisper: same rung, surviving build.
        for id in ["openai_whisper-tiny", "openai_whisper-tiny.en", "openai_whisper-base.en"] {
            table[id] = ["openai_whisper-base"]
        }
        for id in [
            "openai_whisper-small",
            "openai_whisper-small.en",
            "openai_whisper-small.en_217MB"
        ] {
            table[id] = ["openai_whisper-small_216MB", "openai_whisper-base"]
        }

        // Whisper: no surviving rung, so promote and let the device decide.
        //
        // The four Distil rows belong here rather than beside the other English
        // models: Distil-Whisper is an English-only distillation that this
        // catalog advertised as "100 languages", and it scores 9.7 against
        // large-v3's 8.4 on Distil-Whisper's own short-form evaluation. There is
        // nothing to preserve about the choice except its size class.
        for id in [
            "openai_whisper-medium", "openai_whisper-medium.en",
            "openai_whisper-large-v3-v20240930", "openai_whisper-large-v3-v20240930_turbo",
            "openai_whisper-large-v3-v20240930_547MB",
            "openai_whisper-large-v3-v20240930_turbo_632MB",
            "openai_whisper-large-v3_947MB", "openai_whisper-large-v3_turbo_954MB",
            "openai_whisper-large-v2_949MB", "openai_whisper-large-v2_turbo_955MB",
            "distil-whisper_distil-large-v3", "distil-whisper_distil-large-v3_turbo",
            "distil-whisper_distil-large-v3_594MB",
            "distil-whisper_distil-large-v3_turbo_600MB"
        ] {
            table[id] = [
                "openai_whisper-large-v3-v20240930_626MB",
                "openai_whisper-small_216MB",
                "openai_whisper-base"
            ]
        }

        // Sherpa. Canary covers the same four languages as the Fast Conformer
        // it replaces, in 207 MB against 461 MB, with better WER and the only
        // speech-translation path in the catalog.
        table["fast-conformer-ctc-4-lang"] = ["canary-180m-flash"]
        // Every Moonshine build retires onto the 110M Parakeet. v2 returns
        // nothing for a window of 9.4 s or more, and on the clips it can decode
        // it is still the less accurate model (LibriSpeech test-other 9.16
        // against 6.20); v1 was already behind v2.
        for id in ["moonshine-tiny-en", "moonshine-base-en", "moonshine-v2-tiny-en", "moonshine-v2-base-en"] {
            table[id] = ["parakeet-tdt-ctc-110m-en"]
        }
        // Both Dolphin builds prefer Whisper, then SenseVoice. Dolphin Small
        // listed English but returned nothing for it, nor for German, and
        // answered French in Persian script. Large v3 covers the languages
        // Dolphin claimed, including Cantonese; Small does not cover Cantonese,
        // so a phone that cannot hold Large steps to SenseVoice when that still
        // covers what the user speaks.
        for id in ["dolphin-base-ctc", "dolphin-small-ctc"] {
            table[id] = [
                "openai_whisper-large-v3-v20240930_626MB",
                "openai_whisper-small_216MB",
                "sense-voice"
            ]
        }
        // SenseVoice is the stronger Mandarin model, also covers Cantonese,
        // and needs the same memory.
        table["paraformer-zh-small"] = ["sense-voice"]
        // Same weights family, new export: v3 with punctuation. The id changed
        // rather than the pins so an already-downloaded v2 directory is an
        // unknown model to be swept, not a SHA-256 mismatch on a known one.
        table["giga-am-ctc-ru"] = ["giga-am-v3-ru"]
        // Only ever on the unmerged branch, but testers have it downloaded.
        table["giga-am-ctc-v3-ru"] = ["giga-am-v3-ru"]

        return table
    }()

    /// Whether `id` names something the catalog used to ship and no longer does.
    static func isRetired(_ id: String) -> Bool { replacements[id] != nil }

    /// What should happen to a stored selection, decided without touching
    /// storage so it can be reasoned about and tested on its own.
    enum Outcome: Equatable {
        /// The selection still names a model in the catalog.
        case unchanged
        /// The selection was retired and this is its nearest surviving model.
        case replaced(String)
        /// The selection was retired and nothing that replaces it fits this
        /// device. On-device transcription has to be turned off along with it:
        /// see `resolve(_:deviceMemoryGB:)`.
        case cleared
    }

    /// The id `stored` should become, or nil when it is retired and nothing
    /// fits. Kept for callers that only want the replacement.
    ///
    /// An id in neither the catalog nor `replacements` comes back unchanged
    /// rather than nil: this build does not recognise it, which is what a
    /// downgrade from a newer one looks like, and discarding a selection on
    /// that basis would lose a model the user is about to want back. The same
    /// reason `deleteRetiredModelFiles` deletes only named ids.
    static func replacement(
        for stored: String,
        deviceMemoryGB: Int = LocalModelCatalog.deviceMemoryGB,
        primaryLanguage: String? = nil,
        languages: [String] = []
    ) -> String? {
        switch resolve(
            stored, deviceMemoryGB: deviceMemoryGB,
            primaryLanguage: primaryLanguage, languages: languages
        ) {
        case .unchanged: return stored
        case let .replaced(id): return id
        case .cleared: return nil
        }
    }

    /// What to do with `stored` on this device.
    ///
    /// `cleared` is the case worth being careful about. A 1 GB iPhone on
    /// `dolphin-base-ctc` has nothing to move to -- every replacement needs more
    /// memory than it has -- and clearing the model alone would leave on-device
    /// transcription still switched on with nothing behind it. Every dictation
    /// would then record the audio and fail at the end with "choose and download
    /// a model first", forever, which is worse than the honest answer. So the
    /// switch goes off with the selection, exactly as `LocalModelManager.delete`
    /// already does when it removes the model in use: the app stops claiming a
    /// route it cannot take, and setup says so before recording rather than
    /// after.
    ///
    /// `languages` is what the user actually speaks: empty means unknown, and
    /// then the first fitting candidate wins, which is how English-only and
    /// legacy migrations behave. When it is set, a fitting candidate that
    /// covers every requested language is preferred, so Cantonese on a 3 GB
    /// phone lands on SenseVoice instead of Whisper Small. If none of the
    /// fitting candidates cover the languages, the first fitting one is kept
    /// so the phone is not left without a model.
    ///
    /// `primaryLanguage` is the one the user chose to dictate in, nil for
    /// Automatic, and it outranks the rest: the extra languages can only break
    /// a tie between models that keep it. A Cantonese speaker who also has a
    /// Hindi keyboard on a 3 GB phone still lands on SenseVoice, not on Whisper
    /// Small, which has Hindi but not Cantonese. And when this ladder could
    /// serve that language but nothing that fits does -- Hindi on a 2 GB phone,
    /// where only SenseVoice fits -- the selection is cleared rather than
    /// swapped for a model without it. A ladder that never covered the
    /// language, such as Moonshine's English-only one under a stale German
    /// setting, ignores it and behaves as before.
    static func resolve(
        _ stored: String,
        deviceMemoryGB: Int = LocalModelCatalog.deviceMemoryGB,
        primaryLanguage: String? = nil,
        languages: [String] = []
    ) -> Outcome {
        if LocalModelCatalog.descriptor(for: stored) != nil { return .unchanged }
        guard let candidates = replacements[stored] else { return .unchanged }
        let ladder = candidates.compactMap(LocalModelCatalog.descriptor(for:))
        var pool = ladder.filter { deviceMemoryGB >= $0.minimumRamGB }
        if let primary = primaryLanguage.flatMap(LocalModelCatalog.normalizedLanguageCode),
           ladder.contains(where: { $0.covers(primary) }) {
            pool = pool.filter { $0.covers(primary) }
        }
        let covering = pool.filter { model in languages.allSatisfy { model.covers($0) } }
        return (covering.first ?? pool.first).map { Outcome.replaced($0.id) } ?? .cleared
    }

    /// Languages the launch migration should try to keep covering.
    ///
    /// The stored transcription language, the last model-language claim, and
    /// the phone's preferred languages, each run through the catalog's own
    /// normaliser so `yue` stays `yue` and `auto` drops out.
    static func languagesForMigration(
        transcriptionLanguage: String = KeyboardPreferences.transcriptionLanguage.rawValue,
        modelLanguages: Set<String> = KeyboardPreferences.modelLanguages,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in [transcriptionLanguage] + modelLanguages.sorted() + preferredLanguages {
            guard let code = LocalModelCatalog.normalizedLanguageCode(raw) else { continue }
            if seen.insert(code).inserted {
                result.append(code)
            }
        }
        return result
    }

    /// Rewrite the stored selection once, at launch, before anything reads it.
    ///
    /// Writing back rather than translating on every read keeps the history of
    /// the catalog out of the keyboard process, which shares this value and has
    /// no reason to know it. `defaults` stays injectable so tests can drive the
    /// write without touching the App Group.
    static func migrateStoredSelection(
        deviceMemoryGB: Int = LocalModelCatalog.deviceMemoryGB,
        languages: [String] = [],
        defaults: UserDefaults? = UserDefaults(suiteName: AppConfiguration.appGroupIdentifier)
    ) {
        guard let defaults,
              let stored = defaults.string(forKey: LocalTranscriptionPreferences.modelKey)
        else { return }
        let chosen = defaults.string(forKey: KeyboardPreferences.transcriptionLanguageKey) ?? ""
        let needed = languages.isEmpty
            ? languagesForMigration(
                transcriptionLanguage: chosen,
                modelLanguages: Set(defaults.stringArray(forKey: KeyboardPreferences.modelLanguagesKey) ?? []),
                preferredLanguages: []
            )
            : languages
        switch resolve(
            stored, deviceMemoryGB: deviceMemoryGB, primaryLanguage: chosen, languages: needed
        ) {
        case .unchanged:
            break
        case let .replaced(id):
            // Clear any old marker, then write the selection and its notice.
            // Interrupted in between, the before-recording check still covers
            // a replacement that has not been downloaded yet.
            defaults.removeObject(forKey: LocalTranscriptionPreferences.retiredModelReplacementKey)
            defaults.set(id, forKey: LocalTranscriptionPreferences.modelKey)
            // Remembered so the picker can say why the model changed and offer
            // the download.
            defaults.set(id, forKey: LocalTranscriptionPreferences.retiredModelReplacementKey)
        case .cleared:
            // The switch goes off first. `UserDefaults` has no transaction, so
            // these two writes can in principle be separated -- and only one
            // order is safe to be interrupted in. Off with a stale id left
            // behind is a route nobody takes; a cleared id with the switch still
            // on is the state that records a dictation and then fails.
            defaults.set(false, forKey: LocalTranscriptionPreferences.enabledKey)
            defaults.removeObject(forKey: LocalTranscriptionPreferences.modelKey)
            defaults.removeObject(forKey: LocalTranscriptionPreferences.retiredModelReplacementKey)
        }
    }
}
