import Foundation

enum LocalModelEngine: String, Codable, Sendable {
    case whisperKit
    case sherpaOnnx
}

enum SherpaFamily: String, Codable, Sendable {
    case nemoTransducer
    case senseVoice
    case moonshine
    case dolphinCtc
    case canary
    case nemoCtc
    case paraformer
    /// Moonshine v2: two `.ort` graphs instead of v1's four `.onnx` files.
    /// A separate case rather than a flag, because the file names and the
    /// sherpa-onnx config fields both differ and every switch has to answer.
    case moonshineV2
    case omnilingualCtc
    /// An icefall Zipformer transducer. Three graphs like NeMo's transducer,
    /// but sherpa-onnx has to read its own metadata rather than be told it is
    /// NeMo, and its tokens have to be joined by the bridge: see
    /// `SherpaOnnxBridge.c`.
    case zipformerTransducer

    /// Whether this family can safely use `modified_beam_search`.
    ///
    /// This is not a preference, and it is false for two separate reasons that
    /// both have to stay written down.
    ///
    /// sherpa-onnx validates the decoding method when the recognizer is built,
    /// and every family except the transducer answers an unsupported one with
    /// `exit(-1)` — not an exception, not an error return, but the process
    /// gone. So the method can never be taken from the user's setting alone.
    ///
    /// NeMo TDT does accept the value, but its implementation in the bundled
    /// runtimes can intermittently emit empty or hallucinated text (upstream
    /// #3267; its proposed fix #3657 is not merged). That keeps the transducer
    /// false too, until a fixed native runtime is pinned and exercised on a
    /// phone. Both halves are load-bearing: restoring the transducer here is
    /// only ever safe for the transducer.
    var supportsBeamSearch: Bool { false }

    /// Tiny feature noise used only where zero dither can collapse valid speech.
    ///
    /// Kaldi's `dither=1` on int16 audio is approximately `1 / 32768` in the
    /// float scale VocaPhone captures at. It is the upstream workaround for
    /// Parakeet returning no tokens on valid audio with an all-zero dither
    /// setting (sherpa-onnx #2258), and matches the Android client exactly.
    ///
    /// Android passes this into `FeatureConfig.dither`. The pinned iOS runtime
    /// (sherpa-onnx 1.13.8) has no `dither` field on `SherpaOnnxFeatureConfig`
    /// at all, so `SherpaFeatureDither` reproduces its effect on the waveform
    /// instead. Move this to `config.feat_config.dither` if a later runtime
    /// grows that field.
    var featureDither: Float { self == .nemoTransducer ? 0.00003 : 0 }

    /// Whether the recognizer config for this family has a language field at all.
    ///
    /// The transducer and CTC families do not: sherpa-onnx exposes no language
    /// on the transducer, Dolphin or NeMo CTC configs, so those models decide
    /// the language from the audio whatever the user picked. The picker still
    /// offers the languages they cover, because the choice governs how the
    /// transcript is punctuated, but nothing here can pin the decoder and this
    /// flag is what keeps a relabelling from rebuilding a 670 MB recognizer.
    var acceptsLanguage: Bool { self == .senseVoice || self == .canary }

    static let greedySearch = "greedy_search"

    /// Whether this family was trained on upper-cased transcripts.
    ///
    /// The icefall recipes normalise their training text to capitals, so the
    /// Vietnamese Zipformer answers "ÂM LƯỢNG TIVI GIẢM". The styler cannot
    /// undo that on its own: it keeps two-to-four letter capitals as acronyms,
    /// and most Vietnamese syllables are exactly that long.
    var transcribesInCapitals: Bool { self == .zipformerTransducer }

    /// `text` in lower case when it has no lower-case letter at all, which is
    /// what a capitals-trained model looks like; anything mixed is left alone.
    /// Scripts without case — the Korean Zipformer's — pass through unchanged.
    static func lowercasingCapitals(_ text: String) -> String {
        let letters = text.unicodeScalars.filter(CharacterSet.letters.contains)
        let hasUpper = letters.contains(where: CharacterSet.uppercaseLetters.contains)
        let hasLower = letters.contains(where: CharacterSet.lowercaseLetters.contains)
        return hasUpper && !hasLower ? text.lowercased() : text
    }

    /// Whether the accuracy setting changes the recognizer this family builds.
    ///
    /// It changes exactly two config fields, and greedy search reads neither:
    /// `decoding_method` is pinned, and `max_active_paths` is the beam width a
    /// beam search would have used. So while `supportsBeamSearch` is false the
    /// three accuracy settings produce a byte-identical recognizer — and
    /// treating quality as part of this family's cached identity rebuilds a
    /// several-hundred-megabyte ONNX graph to arrive at the one already loaded.
    var nativeConfigVariesWithQuality: Bool { supportsBeamSearch }

    /// The quality this family's recognizer is actually built at, so a cache key
    /// cannot record a distinction the native config does not have.
    func effectiveQuality(_ quality: TranscriptionQuality) -> TranscriptionQuality {
        nativeConfigVariesWithQuality ? quality : .default
    }

    /// The only safe way to turn a quality setting into a decoding method.
    func decodingMethod(for quality: TranscriptionQuality) -> String {
        supportsBeamSearch ? quality.sherpaDecodingMethod : Self.greedySearch
    }
}

struct LocalModelDescriptor: Identifiable, Codable, Sendable, Equatable {
    let id: String
    let displayName: String
    let engine: LocalModelEngine
    /// WhisperKit resolves the tokenizer from the variant it detects in the
    /// loaded model. Sherpa models carry their own `tokens.txt` file instead.
    let tokenizerRepository: String?
    let repository: String?
    let revision: String?
    let sherpaFamily: SherpaFamily?
    let sizeBytes: Int64
    let minimumRamGB: Int
    let languages: String
    let englishOnly: Bool
    let languageCodesOverride: Set<String>
    /// True when the decoder picks the language from the audio and no request
    /// can pin it. The languages in `languageCodes` are still offered, because
    /// the choice decides how the transcript is punctuated, but the picker says
    /// plainly that it does not steer the decoder.
    let detectsLanguageAutomatically: Bool

    /// Whether a custom word list can reach this model at all.
    ///
    /// Whisper's decoder reads previous text tokens, which is the slot a
    /// vocabulary prompt goes into. The sherpa families have no equivalent: the
    /// CTC and non-autoregressive ones condition on audio alone, and the two
    /// that could be biased — the Parakeet transducers — need a BPE vocabulary
    /// file that their upstream repositories do not publish.
    var supportsCustomVocabulary: Bool { engine == .whisperKit }

    init(
        id: String,
        displayName: String,
        engine: LocalModelEngine,
        tokenizerRepository: String,
        sizeBytes: Int64,
        minimumRamGB: Int,
        languages: String,
        englishOnly: Bool
    ) {
        self.init(
            id: id,
            displayName: displayName,
            engine: engine,
            tokenizerRepository: Optional(tokenizerRepository),
            repository: nil,
            revision: nil,
            sherpaFamily: nil,
            sizeBytes: sizeBytes,
            minimumRamGB: minimumRamGB,
            languages: languages,
            englishOnly: englishOnly,
            languageCodesOverride: [],
            detectsLanguageAutomatically: false
        )
    }

    init(
        id: String,
        displayName: String,
        engine: LocalModelEngine,
        repository: String,
        revision: String,
        sherpaFamily: SherpaFamily,
        sizeBytes: Int64,
        minimumRamGB: Int,
        languages: String,
        englishOnly: Bool,
        languageCodesOverride: Set<String> = [],
        detectsLanguageAutomatically: Bool = false
    ) {
        self.init(
            id: id,
            displayName: displayName,
            engine: engine,
            tokenizerRepository: nil,
            repository: repository,
            revision: revision,
            sherpaFamily: sherpaFamily,
            sizeBytes: sizeBytes,
            minimumRamGB: minimumRamGB,
            languages: languages,
            englishOnly: englishOnly,
            languageCodesOverride: languageCodesOverride,
            detectsLanguageAutomatically: detectsLanguageAutomatically
        )
    }

    private init(
        id: String,
        displayName: String,
        engine: LocalModelEngine,
        tokenizerRepository: String?,
        repository: String?,
        revision: String?,
        sherpaFamily: SherpaFamily?,
        sizeBytes: Int64,
        minimumRamGB: Int,
        languages: String,
        englishOnly: Bool,
        languageCodesOverride: Set<String>,
        detectsLanguageAutomatically: Bool
    ) {
        self.id = id
        self.displayName = displayName
        self.engine = engine
        self.tokenizerRepository = tokenizerRepository
        self.repository = repository
        self.revision = revision
        self.sherpaFamily = sherpaFamily
        self.sizeBytes = sizeBytes
        self.minimumRamGB = minimumRamGB
        self.languages = languages
        self.englishOnly = englishOnly
        self.languageCodesOverride = languageCodesOverride
        self.detectsLanguageAutomatically = detectsLanguageAutomatically
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, engine, tokenizerRepository, repository, revision
        case sherpaFamily, sizeBytes, minimumRamGB, languages, englishOnly
        case languageCodesOverride, detectsLanguageAutomatically
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(String.self, forKey: .id),
            displayName: try values.decode(String.self, forKey: .displayName),
            engine: try values.decode(LocalModelEngine.self, forKey: .engine),
            tokenizerRepository: try values.decodeIfPresent(String.self, forKey: .tokenizerRepository),
            repository: try values.decodeIfPresent(String.self, forKey: .repository),
            revision: try values.decodeIfPresent(String.self, forKey: .revision),
            sherpaFamily: try values.decodeIfPresent(SherpaFamily.self, forKey: .sherpaFamily),
            sizeBytes: try values.decode(Int64.self, forKey: .sizeBytes),
            minimumRamGB: try values.decode(Int.self, forKey: .minimumRamGB),
            languages: try values.decode(String.self, forKey: .languages),
            englishOnly: try values.decode(Bool.self, forKey: .englishOnly),
            languageCodesOverride: try values.decodeIfPresent(Set<String>.self, forKey: .languageCodesOverride) ?? [],
            detectsLanguageAutomatically: try values.decodeIfPresent(Bool.self, forKey: .detectsLanguageAutomatically) ?? false
        )
    }

    /// Which language codes this model covers. Empty means no restriction: the
    /// multilingual WhisperKit builds cover every language the picker offers.
    /// A model that detects the language itself still declares its coverage
    /// here, because detecting is not the same as covering everything.
    var languageCodes: Set<String> {
        if !languageCodesOverride.isEmpty { return languageCodesOverride }
        return englishOnly ? ["en"] : []
    }

    /// What the language picker may offer for this model.
    ///
    /// Almost always `languageCodes`, and empty still means "no restriction".
    /// The exception is the pre-large-v3 Whisper builds: they cover every
    /// language the picker knows except Cantonese, which is a claim that can
    /// only be made by listing the rest. See `LocalModelLanguages.largeV3Only`.
    var selectableLanguageCodes: Set<String> {
        if !languageCodes.isEmpty { return languageCodes }
        guard engine == .whisperKit else { return [] }
        if id.contains("large-v3") { return [] }
        return LocalModelLanguages.picker.subtracting(LocalModelLanguages.largeV3Only)
    }

    /// Which languages this model can translate speech *into*.
    ///
    /// Derived rather than declared, because only two things in the catalog can
    /// translate at all and both derive it from something already written down.
    /// Canary is a speech-translation model across the languages it lists; a
    /// multilingual Whisper build has the translate task, whose only trained
    /// target is English. Everything else transcribes the language it heard, so
    /// an empty set here is the ordinary answer. Mirrors
    /// `LocalModelCatalog.kt`; see `ModelTranslationSupport`.
    /// The `distil` special case is gone with the models it was written for.
    /// Distil-Whisper is an English-only distillation that this catalog listed
    /// as "100 languages", so its rows needed excluding by id from a rule that
    /// reads `englishOnly`; nothing in the catalog is mislabelled that way any
    /// more, and a check with no subject reads as a rule that still applies.
    var translationTargets: Set<String> {
        if sherpaFamily == .canary { return languageCodes }
        if englishOnly { return [] }
        return engine == .whisperKit ? ["en"] : []
    }

    /// The stored translation target, if this model can honour it.
    ///
    /// Read here rather than threaded through every call for the same reason
    /// accuracy is: a setting that takes effect on the next dictation cannot be
    /// carried by a session that started before it changed. Resolving against
    /// `translationTargets` is what stops a stale pick — chosen under Canary,
    /// still stored after a switch to Parakeet — reaching an engine that would
    /// misread it or forcing a rebuild of one that would ignore it.
    var resolvedTranslationTarget: String {
        let target = ModelTranslationSupport.target(
            KeyboardPreferences.translateTo,
            targets: translationTargets
        )
        if translationNeedsExplicitSource,
           KeyboardPreferences.effectiveTranscriptionLanguage == .automatic
        {
            return ""
        }
        return target
    }

    /// Whether translating needs the spoken language named explicitly.
    ///
    /// Canary has no detection mode: its config carries a source language and
    /// takes whatever it is given, so "auto" has to be resolved to a real code
    /// before the recognizer is built and English is the only defensible guess.
    /// That is harmless while source and target match — the model was going to
    /// assume something either way — but once the two differ it decides what the
    /// audio is being translated *from*, and a German speaker left on Automatic
    /// gets German translated as though it were English. Whisper is the
    /// opposite: it detects the language and then translates.
    var translationNeedsExplicitSource: Bool { sherpaFamily == .canary }

    var sizeLabel: String {
        let megabytes = Double(sizeBytes) / 1_000_000
        if megabytes >= 1_000 {
            return String(format: "%.1f GB", megabytes / 1_000)
        }
        return "\(Int(megabytes.rounded())) MB"
    }
}

/// What the multilingual models actually transcribe, mirroring
/// `LocalModelCatalog.kt`.
///
/// Declared even for the models that detect the language themselves: deciding
/// for itself does not make a model multilingual beyond what it was trained on,
/// and the picker has to be able to say which languages those are.
enum LocalModelLanguages {

    /// NVIDIA Parakeet TDT 0.6B v3: 25 European languages.
    static let parakeetV3: Set<String> = [
        "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it",
        "lv", "lt", "mt", "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk"
    ]

    static let senseVoice: Set<String> = ["zh", "en", "ja", "ko", "yue"]

    /// Cantonese is the one language OpenAI added after Whisper v2.
    ///
    /// Every multilingual build before large-v3 stops at 99 language tokens, and
    /// the hundredth id lands on the token those models use for something else:
    /// the decode does not fail, it just comes back wrong.
    static let largeV3Only: Set<String> = ["yue"]

    /// Every code the picker can show, which is the ceiling on any coverage claim.
    static let picker: Set<String> = Set(
        TranscriptionLanguage.allCases.filter { $0 != .automatic }.map(\.rawValue)
    )

    /// Indic and nearby languages Dolphin covers well at first-run size.
    static let dolphinStarters: Set<String> = [
        "hi", "bn", "ta", "te", "gu", "pa", "mr", "as", "ne", "ur", "th", "vi", "id", "ms"
    ]

    /// Everything Dolphin transcribes that the picker also offers.
    static let dolphin: Set<String> = dolphinStarters.union(senseVoice)
}

/// Every local model that fits on an iPhone, pinned file-by-file in the matching
/// integrity manifest. WhisperKit models are followed by Sherpa ONNX models so
/// the picker can compare the two engines in one place.
///
/// The `NNN MB build` variants are argmax's compressed weights: the only thing
/// separating two of them is the compression, so the upstream token stays in the
/// name. Ordered smallest first, which is also roughly worst-to-best.
enum LocalModelCatalog {
    static let all: [LocalModelDescriptor] = [
        .init(
            id: "openai_whisper-base",
            displayName: "Whisper Base",
            engine: .whisperKit,
            tokenizerRepository: "openai/whisper-base",
            sizeBytes: 146719453,
            minimumRamGB: 3,
            languages: "100 languages",
            englishOnly: false
        ),
        .init(
            id: "openai_whisper-small_216MB",
            displayName: "Whisper Small · 216 MB build",
            engine: .whisperKit,
            tokenizerRepository: "openai/whisper-small",
            sizeBytes: 217350763,
            minimumRamGB: 3,
            languages: "100 languages",
            englishOnly: false
        ),
        .init(
            id: "openai_whisper-large-v3-v20240930_626MB",
            displayName: "Whisper Large v3 Turbo · 626 MB build",
            engine: .whisperKit,
            tokenizerRepository: "openai/whisper-large-v3",
            sizeBytes: 626718238,
            minimumRamGB: 4,
            languages: "100 languages",
            englishOnly: false
        ),
        .init(
            id: "omnilingual-300m-ctc",
            displayName: "Omnilingual ASR 300M",
            engine: .sherpaOnnx,
            repository: "csukuangfj2/sherpa-onnx-omnilingual-asr-1600-languages-300M-ctc-int8-2025-11-12",
            revision: "6fc542a3b0661c8278cca1230c34deb989f31202",
            sherpaFamily: .omnilingualCtc,
            sizeBytes: 365_438_543,
            minimumRamGB: 6,
            languages: "Multilingual · auto-detect",
            englishOnly: false,
            languageCodesOverride: [
                "en", "de", "es", "fr", "hi", "bn", "ta", "te", "gu", "pa", "mr", "as",
                "ne", "ur", "th", "vi", "id", "ms", "ar", "sw",
            ],
            detectsLanguageAutomatically: true
        ),
        .init(
            id: "parakeet-tdt-ctc-110m-en",
            displayName: "Parakeet TDT-CTC 110M English",
            engine: .sherpaOnnx,
            // The small English model, in place of both Moonshine v2 builds.
            // Upstream publishes this one only as a 458 MB FP32 graph, so the
            // int8 build is VocaHQ's own: dynamic weight quantization of the
            // pinned sherpa-onnx export, reproducible from `quantize.py` in the
            // repository. LibriSpeech, sherpa-onnx 1.13.8, greedy CTC:
            //   test-clean  3.00 WER (FP32 2.93)   test-other  6.20
            // against Moonshine v2 Base's 3.68 / 9.16 on the clips it could
            // decode at all -- Moonshine v2 returns nothing for any window of
            // 9.4 s or more, which every dictation past that length paid for
            // with a failed decode and a blind half-split. Cased and
            // punctuated by the model itself.
            repository: "VocaHQ/sherpa-onnx-nemo-parakeet-tdt-ctc-110m-en-int8",
            revision: "548291ccad79f80d9fb75b2de04cc8f6e4f45342",
            sherpaFamily: .nemoCtc,
            sizeBytes: 131_662_124,
            minimumRamGB: 2,
            languages: "English",
            englishOnly: true
        ),
        .init(
            id: "parakeet-tdt-0.6b-v2-en",
            displayName: "Parakeet TDT 0.6B English",
            engine: .sherpaOnnx,
            repository: "csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8",
            revision: "1ab9323565ddb038682214b292f588070a538ce2",
            sherpaFamily: .nemoTransducer,
            sizeBytes: 661_190_513,
            minimumRamGB: 4,
            languages: "English",
            englishOnly: true
        ),
        .init(
            id: "parakeet-tdt-0.6b-v3",
            displayName: "Parakeet TDT 0.6B",
            engine: .sherpaOnnx,
            repository: "csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8",
            revision: "2bda32ec70b097a55adaa07d9a7173915b43cc78",
            sherpaFamily: .nemoTransducer,
            sizeBytes: 670_478_772,
            minimumRamGB: 4,
            languages: "25 languages · auto-detect",
            englishOnly: false,
            languageCodesOverride: LocalModelLanguages.parakeetV3,
            detectsLanguageAutomatically: true
        ),
        .init(
            id: "sense-voice",
            displayName: "SenseVoice Small",
            engine: .sherpaOnnx,
            // Pinned to the 2024-07-17 export. The newer 2025-09-09 build
            // decodes badly against both runtimes this repository ships, and it
            // was the one in the catalog. Measured on macOS arm64 with the same
            // sherpa-onnx versions -- v1.12.34 (iOS) and v1.13.6 (Android) --
            // against the model's own `test_wavs`:
            //
            //   ja  2025-09-09  "家中学便当制持合五十円学校贩売交"
            //       2024-07-17  "うちの中学は弁当制で持っていけない場合は..."
            //   ko  2025-09-09  "如万性 하면서面 훨씬过呀"
            //       2024-07-17  "조금만 생각을 하면서 살면 훨씬 편할 거야"
            //   en  2025-09-09  "THE TRIVAL CHIEFTHIN CALLED FOR THE BOY..."
            //       2024-07-17  "the tribal chieftain called for the boy..."
            //   zh  2025-09-09  "开放时间早上九点至下午五点"
            //       2024-07-17  "开饭时间早上九点至下午五点"
            //
            // Japanese and Korean come back as Chinese characters, English
            // loses its casing and its words, and Chinese picks the wrong one.
            // Cantonese is identical on both, so nothing is lost by the older
            // export. Both runtimes fail the same way, so this is the export
            // and not a version range: re-measure before moving the pin.
            repository: "csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17",
            revision: "2365baeacb507f821a0c8120fcee3d484dba7a07",
            sherpaFamily: .senseVoice,
            sizeBytes: 239_549_735,
            minimumRamGB: 2,
            languages: "Mandarin · Cantonese · English · Japanese · Korean",
            englishOnly: false,
            // sherpa-onnx exposes a language on the SenseVoice config, so a pick
            // here pins the decoder rather than only the punctuation.
            languageCodesOverride: LocalModelLanguages.senseVoice
        ),
        .init(
            id: "dolphin-small-ctc",
            displayName: "Dolphin Small",
            engine: .sherpaOnnx,
            repository: "csukuangfj/sherpa-onnx-dolphin-small-ctc-multi-lang-int8-2025-04-02",
            revision: "c8b6689509acfcd744c04e5e169164f9ac4cae32",
            sherpaFamily: .dolphinCtc,
            sizeBytes: 250_163_616,
            minimumRamGB: 3,
            languages: "40 East Asian languages",
            englishOnly: false,
            languageCodesOverride: LocalModelLanguages.dolphin,
            detectsLanguageAutomatically: true
        ),
        .init(
            id: "canary-180m-flash",
            displayName: "Canary 180M Flash",
            engine: .sherpaOnnx,
            repository: "csukuangfj/sherpa-onnx-nemo-canary-180m-flash-en-es-de-fr-int8",
            revision: "9077164e0d3dd1d5353743e89ceaa1d3a770838c",
            sherpaFamily: .canary,
            sizeBytes: 207_170_046,
            minimumRamGB: 2,
            languages: "English · German · Spanish · French",
            englishOnly: false,
            languageCodesOverride: ["en", "de", "es", "fr"]
        ),
        .init(
            id: "giga-am-v3-ru",
            displayName: "GigaAM v3 Russian",
            engine: .sherpaOnnx,
            // The RNN-T export, not the CTC one. GigaAM publishes both and its
            // own evaluation puts the transducer ahead on every set it reports
            // -- 8.4 average WER against the CTC's 9.2, and Whisper's 25.1 --
            // for 7 MB more download and no measurable latency cost (362 ms
            // against 367 ms on an 11 s clip, arm64, two threads). The
            // difference shows up as punctuation on the sample: the CTC drops
            // the comma in "может быть, украдкой" and invents one after
            // "Ничьих".
            //
            // `punct` rather than the plain export for the same reason it was
            // chosen for the CTC: a bare Russian model emits an unpunctuated
            // stream, which is the one thing dictation cannot paper over.
            //
            // The decoder and joiner are full precision while the encoder is
            // int8 -- that is how upstream ships it, and `quantizedOrPlain` in
            // the recognizers resolves each graph independently because of it.
            repository: "csukuangfj/sherpa-onnx-nemo-transducer-punct-giga-am-v3-russian-2025-12-16",
            revision: "a6039be7cee829a9044a69ac0ebaf1c191217c97",
            sherpaFamily: .nemoTransducer,
            sizeBytes: 231_897_202,
            minimumRamGB: 2,
            languages: "Russian",
            englishOnly: false,
            languageCodesOverride: ["ru"]
        ),
        .init(
            id: "parakeet-tdt-ctc-ja",
            displayName: "Parakeet TDT CTC Japanese",
            engine: .sherpaOnnx,
            repository: "csukuangfj/sherpa-onnx-nemo-parakeet-tdt_ctc-0.6b-ja-35000-int8",
            revision: "bef18eb066808c90bd0f5df5be685767b0732de8",
            sherpaFamily: .nemoCtc,
            sizeBytes: 655_571_161,
            minimumRamGB: 4,
            languages: "Japanese",
            englishOnly: false,
            languageCodesOverride: ["ja"]
        ),
        .init(
            id: "paraformer-zh-small",
            displayName: "Paraformer Small Chinese",
            engine: .sherpaOnnx,
            repository: "csukuangfj/sherpa-onnx-paraformer-zh-small-2024-03-09",
            revision: "63ddc3cd0f2810b68289a7b3876e62ef5d53d6df",
            sherpaFamily: .paraformer,
            sizeBytes: 81_904_027,
            minimumRamGB: 2,
            languages: "Mandarin · English",
            englishOnly: false,
            languageCodesOverride: ["zh", "en"]
        ),
        .init(
            id: "zipformer-ko",
            displayName: "Zipformer Korean",
            engine: .sherpaOnnx,
            // icefall's KsponSpeech recipe: 10.6 CER on eval_clean with greedy
            // search, in 76 MB. The smallest Korean download by a factor of three,
            // and a specialist rather than SenseVoice's fifth language. Its
            // transcript arrives without word spacing unless the bridge joins
            // the tokens itself; see `SherpaOnnxBridge.c`.
            repository: "k2-fsa/sherpa-onnx-zipformer-korean-2024-06-24",
            revision: "0fb4b2b5c8d3e5766121481ba911961e3649c664",
            sherpaFamily: .zipformerTransducer,
            sizeBytes: 76_271_087,
            minimumRamGB: 2,
            languages: "Korean",
            englishOnly: false,
            languageCodesOverride: ["ko"]
        ),
        .init(
            id: "zipformer-vi",
            displayName: "Zipformer Vietnamese",
            engine: .sherpaOnnx,
            // VietASR's 68M Zipformer, trained on about 70,000 hours of
            // Vietnamese. Published comparisons put it level with PhoWhisper
            // Large -- a 1.5B Whisper fine-tuned for Vietnamese -- and ahead of
            // it on four of five VLSP sets, in 77 MB. It transcribes in capitals
            // with no punctuation; the recognizer lower-cases it and the styler
            // restores sentence case.
            repository: "csukuangfj/sherpa-onnx-zipformer-vi-int8-2025-04-20",
            revision: "b2745a435379992ad3f299635468db0c34918e1e",
            sherpaFamily: .zipformerTransducer,
            sizeBytes: 77_100_477,
            minimumRamGB: 2,
            languages: "Vietnamese",
            englishOnly: false,
            languageCodesOverride: ["vi"]
        ),
    ]

    static func descriptor(for id: String?) -> LocalModelDescriptor? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }

    static var deviceMemoryGB: Int {
        Int(ProcessInfo.processInfo.physicalMemory / 1_000_000_000)
    }

    static func isUsableOnDevice(_ descriptor: LocalModelDescriptor) -> Bool {
        deviceMemoryGB >= descriptor.minimumRamGB
    }

    /// Everything this iPhone can actually run, smallest first.
    static var usableOnDevice: [LocalModelDescriptor] { all.filter(isUsableOnDevice) }

    /// The default pick: the first of `recommendations`, which is the one that
    /// covers this iPhone's language best.
    static var recommended: LocalModelDescriptor {
        recommended(deviceMemoryGB: deviceMemoryGB)
    }

    static func recommended(
        deviceMemoryGB: Int,
        language: String = deviceLanguage
    ) -> LocalModelDescriptor {
        recommendations(deviceMemoryGB: deviceMemoryGB, language: language).first?.model
            ?? lastResort(deviceMemoryGB: deviceMemoryGB)
    }

    /// Three or four models worth offering on this iPhone, best first.
    ///
    /// One recommendation cannot answer the question people actually have. A
    /// phone that can run the 0.6B Parakeet encoder should be told so, but the
    /// person holding it may want their own language instead of English, or a
    /// 100 MB download instead of a 670 MB one on cellular. So the picker offers
    /// the accurate English model, the widest multilingual model, the specialist
    /// for the phone's own language, and the smallest thing that still covers
    /// that language, deduplicated and capped at four.
    ///
    /// Mirrors `recommendations` in `LocalModelCatalog.kt`; the catalogs differ,
    /// the roles do not.
    static func recommendations(
        deviceMemoryGB: Int,
        language: String = deviceLanguage
    ) -> [ModelPick] {
        recommendations(deviceMemoryGB: deviceMemoryGB, languages: [language])
    }

    /// `languages` is the enabled-keyboard list from `spokenLanguages`.
    /// Each non-English code gets its compact specialist (GigaAM for `ru`,
    /// Paraformer for `zh`, …). A language that is not on a keyboard must not
    /// appear here — that is how Chinese stopped showing up on a Russian layout.
    static func recommendations(
        deviceMemoryGB: Int,
        languages: [String]
    ) -> [ModelPick] {
        var needed: [String] = []
        for raw in languages {
            guard let code = normalizedLanguageCode(raw) else { continue }
            if !needed.contains(code) { needed.append(code) }
        }
        if needed.isEmpty { needed = [deviceLanguage] }

        let lead = needed[0]
        let english = bestEnglish(deviceMemoryGB: deviceMemoryGB)
        let multilingual = bestMultilingual(deviceMemoryGB: deviceMemoryGB, languages: needed)
        let leadMultilingual = bestMultilingual(deviceMemoryGB: deviceMemoryGB, language: lead)
        let compact = smallestCovering(deviceMemoryGB: deviceMemoryGB, language: lead)

        var picks: [ModelPick] = []
        func add(_ role: ModelPickRole, _ model: LocalModelDescriptor?) {
            guard let model, !picks.contains(where: { $0.model.id == model.id }) else { return }
            picks.append(ModelPick(role: role, model: model))
        }
        // Two keyboard languages mean no single-language specialist can serve
        // them both, so a model that covers them can lead — the Russian
        // specialist in first place, the card that carries FOR YOU, cannot
        // hear a word of the English keyboard next to it.
        //
        // Only when that model is also the one the lead language would pick on
        // its own. Parakeet v3 covering English and Russian is a first-rate
        // English model; Dolphin covering English and Hindi is not, and leading
        // with it put an East Asian model above Parakeet on an English iPhone.
        if needed.count > 1, let multilingual, multilingual.id == leadMultilingual?.id {
            add(.multilingual, multilingual)
        }
        if lead == "en" {
            add(.english, english)
        } else {
            add(.regional, starter(for: lead, deviceMemoryGB: deviceMemoryGB))
        }
        add(.multilingual, multilingual)
        for language in needed.dropFirst() where language != "en" {
            add(.regional, starter(for: language, deviceMemoryGB: deviceMemoryGB))
        }
        if lead != "en" {
            add(.english, english)
        }
        add(.compact, compact)

        // One card per language on top of the usual four, so a phone with
        // several keyboards still sees each language's specialist in Settings.
        let ordered = Array(picks.prefix(max(4, needed.count + 1)))
        return ordered.isEmpty
            ? [ModelPick(role: .compact, model: lastResort(deviceMemoryGB: deviceMemoryGB))]
            : ordered
    }

    /// The three cards on Choose model: only models at the top for accuracy.
    ///
    /// `recommendations` answers several questions at once, and two of its
    /// answers — the smallest download, and a wide model that merely covers a
    /// language — are the ones that dictate worst. First run is where someone
    /// decides whether dictation works, so it offers only the lowest word error
    /// rates this iPhone can hold, and leaves the rest to More models.
    ///
    /// Falls back to the plain recommendations on a phone that fits none of
    /// them, because an empty page is worse than a smaller model.
    static func onboardingRecommendations(
        deviceMemoryGB: Int,
        languages: [String],
        priority: ModelGuidancePriority = .balanced,
        limit: Int = 3
    ) -> [ModelPick] {
        var needed: [String] = []
        for raw in languages {
            guard let code = normalizedLanguageCode(raw) else { continue }
            if !needed.contains(code) { needed.append(code) }
        }
        if needed.isEmpty { needed = [deviceLanguage] }
        let lead = needed[0]
        let base = recommendations(deviceMemoryGB: deviceMemoryGB, languages: needed)

        var picks: [ModelPick]
        switch priority {
        case .balanced:
            picks = base.filter { pick in
                needed.contains { isHighAccuracy(pick.model, for: $0) }
            }
            // Lead language first: its best models fill the page before a
            // second keyboard's do.
            for language in needed {
                for id in accuracyRanking(for: language) {
                    guard picks.count < limit else { break }
                    guard let model = descriptor(for: id),
                          deviceMemoryGB >= model.minimumRamGB,
                          model.covers(language),
                          !picks.contains(where: { $0.model.id == id })
                    else { continue }
                    let role: ModelPickRole = model.englishOnly ? .english
                        : model.languageCodes.count == 1 ? .regional : .multilingual
                    picks.append(ModelPick(role: role, model: model))
                }
            }
        case .lighter:
            // Smallest first, among models that are actually for this
            // language. Paraformer lists English, but it is a Mandarin model,
            // and the smallest English download should not be one.
            picks = fitting(deviceMemoryGB: deviceMemoryGB)
                .filter { $0.covers(lead) && incidentalCoverage[$0.id]?.contains(lead) != true }
                .sorted { ($0.sizeBytes, $0.id) < ($1.sizeBytes, $1.id) }
                .reduce(into: [LocalModelDescriptor]()) { kept, model in
                    // One build per family. Whisper Tiny and Whisper Tiny
                    // English side by side are one choice shown twice.
                    let family = model.displayName.components(separatedBy: " · ").first
                    if !kept.contains(where: { $0.displayName.components(separatedBy: " · ").first == family }) {
                        kept.append(model)
                    }
                }
                .map { ModelPick(role: .compact, model: $0) }
        case .multilingual:
            let candidates = manyLanguagesPreference.compactMap(descriptor(for:)).filter {
                deviceMemoryGB >= $0.minimumRamGB && !$0.englishOnly && $0.covers(lead)
                    && incidentalCoverage[$0.id]?.contains(lead) != true
            }
            let coversAll = candidates.filter { model in needed.allSatisfy { model.covers($0) } }
            let rest = candidates.filter { model in !coversAll.contains { $0.id == model.id } }
            picks = (coversAll + rest).map { ModelPick(role: .multilingual, model: $0) }
        }
        let chosen = Array(picks.prefix(limit))
        return chosen.isEmpty ? Array(base.prefix(limit)) : chosen
    }

    /// A language a model transcribes on paper but was not built for.
    private static let incidentalCoverage: [String: Set<String>] = [
        "paraformer-zh-small": ["en"],
        "dolphin-small-ctc": ["en"],
    ]

    /// Several languages in one model, the accurate ones first.
    private static let manyLanguagesPreference = [
        "parakeet-tdt-0.6b-v3",
        "openai_whisper-large-v3-v20240930_626MB",
        "canary-180m-flash",
        "dolphin-small-ctc",
        "sense-voice",
        "openai_whisper-small_216MB",
        "openai_whisper-base",
    ]

    /// Whether `model` is among the most accurate for `language`.
    static func isHighAccuracy(_ model: LocalModelDescriptor, for language: String) -> Bool {
        model.covers(language) && accuracyRanking(for: language).contains(model.id)
    }

    /// The most accurate models for a language, lowest word error rate first,
    /// from the published benchmarks for each family (Hugging Face Open ASR
    /// Leaderboard for English, the model cards elsewhere). Whisper large-v3
    /// closes every list: it is the accurate answer for any language it covers,
    /// and the specialists above it beat it on theirs.
    ///
    /// A ranking, not measured numbers — nothing here was benchmarked on a
    /// phone. Small, tiny and base builds are left out on purpose.
    static func accuracyRanking(for language: String) -> [String] {
        let code = language.lowercased()
        let largeV3 = [
            "openai_whisper-large-v3-v20240930_626MB",
        ]
        switch code {
        case "en":
            return [
                "parakeet-tdt-0.6b-v2-en",
                "parakeet-tdt-0.6b-v3",
                "canary-180m-flash",
                "parakeet-tdt-ctc-110m-en",
            ] + largeV3
        case "ru":
            return ["giga-am-v3-ru", "parakeet-tdt-0.6b-v3"] + largeV3
        case "ja":
            return ["parakeet-tdt-ctc-ja", "sense-voice"] + largeV3
        case "zh", "yue":
            return ["sense-voice"] + largeV3
        case "ko":
            return ["sense-voice", "zipformer-ko"] + largeV3
        case "vi":
            return ["zipformer-vi", "dolphin-small-ctc"] + largeV3
        case "de", "es", "fr":
            return ["parakeet-tdt-0.6b-v3", "canary-180m-flash"] + largeV3
        default:
            if LocalModelLanguages.parakeetV3.contains(code) {
                return ["parakeet-tdt-0.6b-v3"] + largeV3
            }
            if LocalModelLanguages.dolphinStarters.contains(code) {
                return ["dolphin-small-ctc"] + largeV3
            }
            return largeV3
        }
    }

    /// The BCP-47 subtag from the phone, used to pick a first-run model.
    static var deviceLanguage: String {
        Locale.current.language.languageCode?.identifier ?? "en"
    }

    /// Languages that should drive the model picker.
    ///
    /// `keyboards` is primary-language tags from enabled IMEs (and test
    /// fixtures that look like them). One enabled Russian keyboard must
    /// recommend Russian — and must not recommend Chinese.
    static func spokenLanguages(
        device: String,
        keyboards: [String],
        explicit: String = ""
    ) -> [String] {
        let deviceCode = normalizedLanguageCode(device) ?? "en"
        let keyboardCodes = uniqueLanguageCodes(keyboards)

        var needed: [String] = []
        func append(_ code: String) {
            if !needed.contains(code) { needed.append(code) }
        }
        if let explicitCode = normalizedLanguageCode(explicit) {
            append(explicitCode)
        }
        // The phone's own language leads when it is also typed. It is still
        // not a keyboard on its own: a Chinese iPhone with Russian and English
        // layouts gets neither Paraformer nor SenseVoice.
        if keyboardCodes.contains(deviceCode) {
            append(deviceCode)
        }
        keyboardCodes.forEach(append)
        if needed.isEmpty {
            append(deviceCode)
        }
        return needed
    }

    /// BCP-47 / keyboard `primaryLanguage` → catalog code (`ru`, `zh`, `en`).
    static func normalizedLanguageCode(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let lowered = raw.lowercased()
        if lowered.contains("emoji") || lowered.contains("dictation") { return nil }
        if lowered.contains("vocaphone") { return nil }
        let localePart = raw.split(separator: "@").first.map(String.init) ?? raw
        // Third-party keyboard bundle IDs, e.g. com.foo.keyboard.
        if localePart.contains(".") { return nil }
        var code = Locale(identifier: localePart).language.languageCode?.identifier.lowercased()
            ?? localePart.split { $0 == "-" || $0 == "_" }.first.map(String.init)?.lowercased()
            ?? localePart.lowercased()
        if code.hasPrefix("zh") { code = "zh" }
        if code == "yue" { return "yue" }
        if code == TranscriptionLanguage.automatic.rawValue { return nil }
        if code == "und" || code == "mul" { return nil }
        guard LocalModelLanguages.picker.contains(code) else { return nil }
        return code
    }

    private static func uniqueLanguageCodes(_ raw: [String]) -> [String] {
        raw.compactMap(normalizedLanguageCode).reduce(into: [String]()) {
            if !$0.contains($1) { $0.append($1) }
        }
    }

    /// The most accurate English model this iPhone can hold. Parakeet first: on
    /// anything with the memory for it, it is both faster and more accurate than
    /// the Whisper of the same size, and it is why this list is not one line.
    private static func bestEnglish(deviceMemoryGB: Int) -> LocalModelDescriptor? {
        firstFitting(englishPreference, deviceMemoryGB: deviceMemoryGB)
            ?? fitting(deviceMemoryGB: deviceMemoryGB).first { $0.englishOnly }
    }

    /// The widest-coverage model that still covers this phone's own language.
    static func bestMultilingual(
        deviceMemoryGB: Int,
        language: String
    ) -> LocalModelDescriptor? {
        multilingualPreference.lazy
            .compactMap(descriptor(for:))
            .first {
                deviceMemoryGB >= $0.minimumRamGB && $0.covers(language)
            }
            ?? fitting(deviceMemoryGB: deviceMemoryGB).first {
                !$0.englishOnly && $0.covers(language)
            }
    }

    /// Widest model that still transcribes the lead language (`languages[0]`).
    /// Extra keyboard languages only widen coverage; they must not elect
    /// SenseVoice just because it hits more of {zh, ja, ko} than Parakeet hits
    /// of Russian.
    static func bestMultilingual(
        deviceMemoryGB: Int,
        languages: [String]
    ) -> LocalModelDescriptor? {
        let needed = languages.compactMap(normalizedLanguageCode)
        guard let lead = needed.first else {
            return bestMultilingual(deviceMemoryGB: deviceMemoryGB, language: deviceLanguage)
        }
        if needed.count == 1 {
            return bestMultilingual(deviceMemoryGB: deviceMemoryGB, language: lead)
        }
        let candidates = multilingualPreference.compactMap(descriptor(for:)).filter {
            deviceMemoryGB >= $0.minimumRamGB && $0.covers(lead)
        }
        if let coversAll = candidates.first(where: { model in
            needed.allSatisfy { model.covers($0) }
        }) {
            return coversAll
        }
        return candidates.max { a, b in
            let ac = needed.filter { a.covers($0) }.count
            let bc = needed.filter { b.covers($0) }.count
            if ac != bc { return ac < bc }
            func breadth(_ model: LocalModelDescriptor) -> Int {
                if model.englishOnly { return 1 }
                return model.languageCodes.isEmpty ? .max : model.languageCodes.count
            }
            return breadth(a) < breadth(b)
        } ?? bestMultilingual(deviceMemoryGB: deviceMemoryGB, language: lead)
    }

    /// The lightest download that still transcribes this phone's language.
    private static func smallestCovering(
        deviceMemoryGB: Int,
        language: String
    ) -> LocalModelDescriptor? {
        // Not a model that only lists the language. Paraformer transcribes some
        // English but is a Mandarin model, and with no Whisper Tiny on iOS it
        // is also the smallest thing that "covers" English -- which put a
        // Chinese model on an English iPhone as its smallest download.
        fitting(deviceMemoryGB: deviceMemoryGB)
            .filter { $0.covers(language) && !isIncidental($0, for: language) }
            .min { $0.sizeBytes < $1.sizeBytes }
    }

    /// Whether `model` lists `language` without being built for it.
    static func isIncidental(_ model: LocalModelDescriptor, for language: String) -> Bool {
        incidentalCoverage[model.id]?.contains(language.lowercased()) == true
    }

    /// The compact specialist for `language`, or nil when the catalog has none
    /// and scoring should fall through to a small multilingual model instead.
    private static func starter(
        for language: String,
        deviceMemoryGB: Int
    ) -> LocalModelDescriptor? {
        guard let id = starterIDs[language.lowercased()] else { return nil }
        guard let model = descriptor(for: id), deviceMemoryGB >= model.minimumRamGB
        else { return nil }
        return model
    }

    private static func fitting(deviceMemoryGB: Int) -> [LocalModelDescriptor] {
        all.filter { deviceMemoryGB >= $0.minimumRamGB }
    }

    private static func firstFitting(
        _ ids: [String],
        deviceMemoryGB: Int
    ) -> LocalModelDescriptor? {
        ids.lazy.compactMap(descriptor(for:)).first { deviceMemoryGB >= $0.minimumRamGB }
    }

    /// Nothing fit, so fall back to whatever the phone can hold.
    private static func lastResort(deviceMemoryGB: Int) -> LocalModelDescriptor {
        fitting(deviceMemoryGB: deviceMemoryGB).min { $0.minimumRamGB < $1.minimumRamGB } ?? all[0]
    }

    /// English models best first. Parakeet leads wherever the memory allows it.
    ///
    /// The 110M Parakeet is the small English model: a fifth of the 0.6B's
    /// download, about three times as fast on the same CPU, at 3.00 against
    /// 1.75 WER on LibriSpeech test-clean. See the note on its catalog entry.
    ///
    /// The `.en` WhisperKit builds are gone from the catalog, so the multilingual
    /// Base build is the whisper fallback for English too.
    private static let englishPreference = [
        "parakeet-tdt-0.6b-v2-en",
        "parakeet-tdt-ctc-110m-en",
        "openai_whisper-base"
    ]

    /// Multilingual models by breadth of coverage, widest first.
    private static let multilingualPreference = [
        "parakeet-tdt-0.6b-v3",
        "canary-180m-flash",
        "dolphin-small-ctc",
        "sense-voice",
        "openai_whisper-base"
    ]

    /// The compact specialist each language gets at first run, where one exists.
    ///
    /// This is the first transcription most people ever see, so "compact" is a
    /// tie-breaker here and never the whole argument. Two entries used to be
    /// chosen on size alone and have moved:
    ///
    /// - The Dolphin starters pointed at `dolphin-base-ctc`, which the Dolphin
    ///   paper measures at 33.3% average WER against `dolphin-small-ctc`'s
    ///   25.2%. Handing a Hindi or Bengali speaker the least accurate model in
    ///   the catalog on first launch cost far more than the 146 MB it saved,
    ///   and base is no longer in the catalog at all.
    /// - Mandarin pointed at `paraformer-zh-small`, an 82 MB 2024 build, when
    ///   SenseVoice is stronger on both Mandarin and Cantonese. Paraformer
    ///   stays as the smallest download that covers Chinese -- that is the one
    ///   role it wins -- but it is not what first run leads with.
    ///
    /// Mirrors `starterForLanguage` in `LocalModelCatalog.kt`.
    private static let starterIDs: [String: String] = [
        "de": "canary-180m-flash", "es": "canary-180m-flash", "fr": "canary-180m-flash",
        // SenseVoice rather than Paraformer for Cantonese: Paraformer is
        // Mandarin and English only, and now that Cantonese is a row in the
        // picker, leading with a model that cannot transcribe it is worse than
        // having offered nothing.
        "zh": "sense-voice", "yue": "sense-voice", "ja": "sense-voice", "ko": "sense-voice",
        "ru": "giga-am-v3-ru",
        // A Vietnamese specialist trained on 70,000 hours beats Dolphin's
        // forty-language model on its one language, in a third of the size.
        "vi": "zipformer-vi"
    ].merging(
        Dictionary(
            uniqueKeysWithValues: LocalModelLanguages.dolphinStarters.map { ($0, "dolphin-small-ctc") }
        ),
        uniquingKeysWith: { existing, _ in existing }
    )
}

/// The small set of practical choices that can change a first-run model.
enum ModelGuidancePriority: String, CaseIterable, Identifiable, Sendable {
    case balanced
    case lighter
    case multilingual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .balanced: "Balanced"
        case .lighter: "Smallest download"
        case .multilingual: "Works across languages"
        }
    }

    /// The tile symbol on Choose model.
    var symbol: String {
        switch self {
        case .balanced: "checkmark.seal"
        case .lighter: "arrow.down.circle"
        case .multilingual: "globe"
        }
    }

    /// Segment labels on Choose model. Three words a person can pick between
    /// without knowing what a word error rate is.
    var shortTitle: String {
        switch self {
        case .balanced: "Accurate"
        case .lighter: "Smallest"
        case .multilingual: "Multilingual"
        }
    }

    /// The line under the segments, saying what the choice trades.
    var onboardingDetail: String {
        switch self {
        case .balanced: "The best at getting your words right. Larger downloads."
        case .lighter: "Quick to download and light on storage. Less accurate."
        case .multilingual: "One model that understands several languages."
        }
    }

    var detail: String {
        switch self {
        case .balanced: "The best all-round match for this iPhone and your language."
        case .lighter: "Least data and storage. Best on a metered connection."
        case .multilingual: "One model for several languages, instead of a specialist in one."
        }
    }
}

struct ModelGuidanceIntent: Sendable, Equatable {
    let language: String
    let priority: ModelGuidancePriority

    init(language: String, priority: ModelGuidancePriority = .balanced) {
        self.language = language
        self.priority = priority
    }
}

enum ModelGuidanceConfidence: Sendable, Equatable {
    case goodDefault
    case noMatch
}

struct ModelGuidanceResult: Sendable {
    let model: LocalModelDescriptor?
    let intent: ModelGuidanceIntent
    let confidence: ModelGuidanceConfidence
    let reason: String

    var languageName: String {
        TranscriptionLanguage(rawValue: intent.language)?.displayName
            ?? Locale.current.localizedString(forLanguageCode: intent.language)
            ?? intent.language.uppercased()
    }

    /// The one line that says what this download costs and what it covers.
    /// Mirrors `downloadDetail` in `ModelGuidance.kt`.
    var downloadDetail: String? {
        model.map { "Works with \(languageName) · \($0.sizeLabel) download" }
    }
}

extension LocalModelCatalog {
    /// A single, plain-language answer for first-run setup. The existing role
    /// recommendations remain available to the advanced Settings catalog.
    static func guidance(
        deviceMemoryGB: Int,
        intent: ModelGuidanceIntent
    ) -> ModelGuidanceResult {
        let requestedLanguage = intent.language.lowercased()
        let language = requestedLanguage.isEmpty || requestedLanguage == TranscriptionLanguage.automatic.rawValue
            ? deviceLanguage
            : requestedLanguage
        let candidates = all.filter { deviceMemoryGB >= $0.minimumRamGB && $0.covers(language) }
        let normalized = ModelGuidanceIntent(language: language, priority: intent.priority)
        guard !candidates.isEmpty else {
            return ModelGuidanceResult(
                model: nil,
                intent: normalized,
                confidence: .noMatch,
                reason: "No on-device model in this build supports \(displayName(for: language)) on this iPhone."
            )
        }

        let balanced = recommended(deviceMemoryGB: deviceMemoryGB, language: language)
            .takeIf { candidates.contains($0) }
            ?? candidates.min(by: stableGuidanceOrder)
            ?? candidates[0]
        let model: LocalModelDescriptor
        switch intent.priority {
        case .balanced:
            model = balanced
        case .lighter:
            // Same rule as `smallestCovering`: the smallest model *for* this
            // language, falling back to any that covers it.
            let purposeBuilt = candidates.filter { !isIncidental($0, for: language) }
            model = (purposeBuilt.isEmpty ? candidates : purposeBuilt).min {
                if $0.sizeBytes != $1.sizeBytes { return $0.sizeBytes < $1.sizeBytes }
                if $0.minimumRamGB != $1.minimumRamGB { return $0.minimumRamGB < $1.minimumRamGB }
                return $0.id < $1.id
            } ?? candidates[0]
        case .multilingual:
            model = bestMultilingual(deviceMemoryGB: deviceMemoryGB, language: language)
                .flatMap { pick in candidates.contains(pick) ? pick : nil }
                ?? candidates.max(by: widestCoverage)
                ?? balanced
        }

        let languageName = displayName(for: language)
        let reason: String
        switch intent.priority {
        case .balanced:
            reason = "A balanced match that fits this iPhone and covers \(languageName)."
        case .lighter:
            reason = "The smallest compatible download that covers \(languageName)."
        case .multilingual:
            reason = model.id == balanced.id
                ? "The balanced match already covers several languages on this iPhone."
                : "Covers \(model.languages), so you can switch language without "
                    + "switching model. " + qualityDownloadComparison(model, balanced)
        }
        return ModelGuidanceResult(
            model: model,
            intent: normalized,
            confidence: .goodDefault,
            reason: reason
        )
    }

    /// How wide a model's coverage is, for ranking breadth.
    ///
    /// An empty `languageCodes` means no restriction rather than no coverage —
    /// that is how the multilingual Whisper builds are declared — so it sorts
    /// above every model that names its languages.
    private static func widestCoverage(
        _ lhs: LocalModelDescriptor,
        _ rhs: LocalModelDescriptor
    ) -> Bool {
        func breadth(_ model: LocalModelDescriptor) -> Int {
            if model.englishOnly { return 1 }
            return model.languageCodes.isEmpty ? .max : model.languageCodes.count
        }
        if breadth(lhs) != breadth(rhs) { return breadth(lhs) < breadth(rhs) }
        if lhs.sizeBytes != rhs.sizeBytes { return lhs.sizeBytes < rhs.sizeBytes }
        return lhs.id > rhs.id
    }

    private static func displayName(for language: String) -> String {
        TranscriptionLanguage(rawValue: language)?.displayName
            ?? Locale.current.localizedString(forLanguageCode: language)
            ?? language.uppercased()
    }

    private static func stableGuidanceOrder(
        _ lhs: LocalModelDescriptor,
        _ rhs: LocalModelDescriptor
    ) -> Bool {
        if lhs.sizeBytes != rhs.sizeBytes { return lhs.sizeBytes < rhs.sizeBytes }
        if lhs.minimumRamGB != rhs.minimumRamGB { return lhs.minimumRamGB < rhs.minimumRamGB }
        return lhs.id < rhs.id
    }

    private static func qualityDownloadComparison(
        _ model: LocalModelDescriptor,
        _ balanced: LocalModelDescriptor
    ) -> String {
        if model.sizeBytes > balanced.sizeBytes {
            return "Bigger download than the balanced match."
        }
        if model.sizeBytes < balanced.sizeBytes {
            return "Smaller download than the balanced match."
        }
        return "About the same download size as the balanced match."
    }
}

private extension LocalModelDescriptor {
    func takeIf(_ predicate: (LocalModelDescriptor) -> Bool) -> LocalModelDescriptor? {
        predicate(self) ? self : nil
    }
}

/// Why a model is being offered. The picker shows this next to each alternate,
/// so the picks read as several different answers rather than a ranking.
enum ModelPickRole: String, Sendable {
    case guided
    case english
    case multilingual
    case regional
    case compact

    var label: String {
        switch self {
        case .guided: "Your match"
        case .english: "Best for English"
        case .multilingual: "Multilingual"
        case .regional: "Your language"
        case .compact: "Smallest download"
        }
    }
}

struct ModelPick: Sendable, Equatable {
    let role: ModelPickRole
    let model: LocalModelDescriptor
}

/// Who trained a model. Shown as its icon, because a name like "Parakeet TDT
/// 0.6B" means nothing to most people and "NVIDIA" or "OpenAI" often does.
enum ModelMaker: String, CaseIterable, Sendable {
    case nvidia
    case openAI
    case huggingFace
    case alibaba
    case usefulSensors
    case dataocean
    case sber
    case meta
    case nextGenKaldi

    var displayName: String {
        switch self {
        case .nvidia: "NVIDIA"
        case .openAI: "OpenAI"
        case .huggingFace: "Hugging Face"
        case .alibaba: "Alibaba"
        case .usefulSensors: "Useful Sensors"
        case .dataocean: "DataoceanAI"
        case .sber: "Sber"
        case .meta: "Meta"
        case .nextGenKaldi: "Next-gen Kaldi"
        }
    }
}

extension LocalModelDescriptor {
    /// Read from the identifier's family, which is stable across builds.
    var maker: ModelMaker {
        if id.hasPrefix("omnilingual") { return .meta }
        if id.hasPrefix("openai_whisper") { return .openAI }
        if id.hasPrefix("moonshine") { return .usefulSensors }
        if id.hasPrefix("sense-voice") || id.hasPrefix("paraformer") { return .alibaba }
        if id.hasPrefix("dolphin") { return .dataocean }
        if id.hasPrefix("giga-am") { return .sber }
        if id.hasPrefix("zipformer") { return .nextGenKaldi }
        return .nvidia
    }
}

extension LocalModelDescriptor {
    /// Whether this model transcribes `language` at all. Empty coverage means no
    /// restriction, which is the honest answer for Whisper's multilingual builds.
    func covers(_ language: String) -> Bool {
        let code = language.lowercased()
        if code.isEmpty { return true }
        if englishOnly { return code == "en" }
        if !languageCodes.isEmpty { return languageCodes.contains(code) }
        if engine == .whisperKit, LocalModelLanguages.largeV3Only.contains(code) {
            return id.contains("large-v3")
        }
        return true
    }
}
