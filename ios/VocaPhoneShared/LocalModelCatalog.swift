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

    /// Whether this family accepts `modified_beam_search`.
    ///
    /// This is not a preference. sherpa-onnx validates the decoding method when
    /// the recognizer is built, and every family except the transducer answers
    /// an unsupported one with `exit(-1)` — not an exception, not an error
    /// return, but the process gone. So the method has to be decided from the
    /// family and never from the user's setting alone.
    var supportsBeamSearch: Bool { self == .nemoTransducer }

    static let greedySearch = "greedy_search"

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

    /// Which language codes this model can be asked for. Empty means no
    /// restriction: the multilingual builds cover every language the picker
    /// offers. No WhisperKit model detects the language and then ignores the
    /// request, so there is no auto-detect case here.
    var languageCodes: Set<String> {
        if !languageCodesOverride.isEmpty { return languageCodesOverride }
        return englishOnly ? ["en"] : []
    }

    var sizeLabel: String {
        let megabytes = Double(sizeBytes) / 1_000_000
        if megabytes >= 1_000 {
            return String(format: "%.1f GB", megabytes / 1_000)
        }
        return "\(Int(megabytes.rounded())) MB"
    }
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
            id: "openai_whisper-tiny.en",
            displayName: "Whisper Tiny · English",
            engine: .whisperKit,
            tokenizerRepository: "openai/whisper-tiny.en",
            sizeBytes: 76623141,
            minimumRamGB: 3,
            languages: "English",
            englishOnly: true
        ),
        .init(
            id: "openai_whisper-tiny",
            displayName: "Whisper Tiny",
            engine: .whisperKit,
            tokenizerRepository: "openai/whisper-tiny",
            sizeBytes: 76635397,
            minimumRamGB: 3,
            languages: "100 languages",
            englishOnly: false
        ),
        .init(
            id: "openai_whisper-base.en",
            displayName: "Whisper Base · English",
            engine: .whisperKit,
            tokenizerRepository: "openai/whisper-base.en",
            sizeBytes: 146707731,
            minimumRamGB: 3,
            languages: "English",
            englishOnly: true
        ),
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
            id: "openai_whisper-small.en_217MB",
            displayName: "Whisper Small · English · 217 MB build",
            engine: .whisperKit,
            tokenizerRepository: "openai/whisper-small.en",
            sizeBytes: 217878408,
            minimumRamGB: 3,
            languages: "English",
            englishOnly: true
        ),
        .init(
            id: "openai_whisper-small",
            displayName: "Whisper Small",
            engine: .whisperKit,
            tokenizerRepository: "openai/whisper-small",
            sizeBytes: 486487465,
            minimumRamGB: 4,
            languages: "100 languages",
            englishOnly: false
        ),
        .init(
            id: "openai_whisper-small.en",
            displayName: "Whisper Small · English",
            engine: .whisperKit,
            tokenizerRepository: "openai/whisper-small.en",
            sizeBytes: 486510962,
            minimumRamGB: 4,
            languages: "English",
            englishOnly: true
        ),
        .init(
            id: "openai_whisper-large-v3-v20240930_547MB",
            displayName: "Whisper Large v3 Turbo · 547 MB build",
            engine: .whisperKit,
            tokenizerRepository: "openai/whisper-large-v3",
            sizeBytes: 549554198,
            minimumRamGB: 4,
            languages: "100 languages",
            englishOnly: false
        ),
        .init(
            id: "distil-whisper_distil-large-v3_594MB",
            displayName: "Distil Whisper Large v3 · 594 MB build",
            engine: .whisperKit,
            tokenizerRepository: "openai/whisper-large-v3",
            sizeBytes: 594534261,
            minimumRamGB: 4,
            languages: "100 languages",
            englishOnly: false
        ),
        .init(
            id: "distil-whisper_distil-large-v3_turbo_600MB",
            displayName: "Distil Whisper Large v3 · Turbo pipeline · 600 MB build",
            engine: .whisperKit,
            tokenizerRepository: "openai/whisper-large-v3",
            sizeBytes: 607114331,
            minimumRamGB: 4,
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
            id: "openai_whisper-large-v3-v20240930_turbo_632MB",
            displayName: "Whisper Large v3 Turbo · Turbo pipeline · 632 MB build",
            engine: .whisperKit,
            tokenizerRepository: "openai/whisper-large-v3",
            sizeBytes: 645668913,
            minimumRamGB: 4,
            languages: "100 languages",
            englishOnly: false
        ),
        .init(
            id: "openai_whisper-large-v3_947MB",
            displayName: "Whisper Large v3 · 947 MB build",
            engine: .whisperKit,
            tokenizerRepository: "openai/whisper-large-v3",
            sizeBytes: 948108786,
            minimumRamGB: 6,
            languages: "100 languages",
            englishOnly: false
        ),
        .init(
            id: "openai_whisper-large-v2_949MB",
            displayName: "Whisper Large v2 · 949 MB build",
            engine: .whisperKit,
            tokenizerRepository: "openai/whisper-large-v2",
            sizeBytes: 952159413,
            minimumRamGB: 6,
            languages: "100 languages",
            englishOnly: false
        ),
        .init(
            id: "openai_whisper-large-v3_turbo_954MB",
            displayName: "Whisper Large v3 · Turbo pipeline · 954 MB build",
            engine: .whisperKit,
            tokenizerRepository: "openai/whisper-large-v3",
            sizeBytes: 1052848880,
            minimumRamGB: 6,
            languages: "100 languages",
            englishOnly: false
        ),
        .init(
            id: "openai_whisper-large-v2_turbo_955MB",
            displayName: "Whisper Large v2 · Turbo pipeline · 955 MB build",
            engine: .whisperKit,
            tokenizerRepository: "openai/whisper-large-v2",
            sizeBytes: 1053135264,
            minimumRamGB: 6,
            languages: "100 languages",
            englishOnly: false
        ),
        .init(
            id: "distil-whisper_distil-large-v3",
            displayName: "Distil Whisper Large v3",
            engine: .whisperKit,
            tokenizerRepository: "openai/whisper-large-v3",
            sizeBytes: 1514534700,
            minimumRamGB: 8,
            languages: "100 languages",
            englishOnly: false
        ),
        .init(
            id: "distil-whisper_distil-large-v3_turbo",
            displayName: "Distil Whisper Large v3 · Turbo pipeline",
            engine: .whisperKit,
            tokenizerRepository: "openai/whisper-large-v3",
            sizeBytes: 1527111141,
            minimumRamGB: 8,
            languages: "100 languages",
            englishOnly: false
        ),
        .init(
            id: "openai_whisper-medium",
            displayName: "Whisper Medium",
            engine: .whisperKit,
            tokenizerRepository: "openai/whisper-medium",
            sizeBytes: 1529654233,
            minimumRamGB: 8,
            languages: "100 languages",
            englishOnly: false
        ),
        .init(
            id: "openai_whisper-medium.en",
            displayName: "Whisper Medium · English",
            engine: .whisperKit,
            tokenizerRepository: "openai/whisper-medium.en",
            sizeBytes: 1529674079,
            minimumRamGB: 8,
            languages: "English",
            englishOnly: true
        ),
        .init(
            id: "openai_whisper-large-v3-v20240930",
            displayName: "Whisper Large v3 Turbo",
            engine: .whisperKit,
            tokenizerRepository: "openai/whisper-large-v3",
            sizeBytes: 1619531263,
            minimumRamGB: 8,
            languages: "100 languages",
            englishOnly: false
        ),
        .init(
            id: "openai_whisper-large-v3-v20240930_turbo",
            displayName: "Whisper Large v3 Turbo · Turbo pipeline",
            engine: .whisperKit,
            tokenizerRepository: "openai/whisper-large-v3",
            sizeBytes: 1638464446,
            minimumRamGB: 8,
            languages: "100 languages",
            englishOnly: false
        ),
        .init(
            id: "moonshine-tiny-en",
            displayName: "Moonshine Tiny English",
            engine: .sherpaOnnx,
            repository: "csukuangfj/sherpa-onnx-moonshine-tiny-en-int8",
            revision: "bf2b762c076d8ea61e2af0b3851c9564fb77552e",
            sherpaFamily: .moonshine,
            sizeBytes: 123_967_539,
            minimumRamGB: 2,
            languages: "English",
            englishOnly: true
        ),
        .init(
            id: "moonshine-base-en",
            displayName: "Moonshine Base English",
            engine: .sherpaOnnx,
            repository: "csukuangfj/sherpa-onnx-moonshine-base-en-int8",
            revision: "052b0798ad1bf046a140fdd4efcd9426530fa3f5",
            sherpaFamily: .moonshine,
            sizeBytes: 286_929_760,
            minimumRamGB: 3,
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
            detectsLanguageAutomatically: true
        ),
        .init(
            id: "sense-voice",
            displayName: "SenseVoice Small",
            engine: .sherpaOnnx,
            repository: "csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09",
            revision: "355f4d4884d8afd08aef04b9007a8556d7b463b2",
            sherpaFamily: .senseVoice,
            sizeBytes: 237_431_441,
            minimumRamGB: 2,
            languages: "Mandarin · Cantonese · English · Japanese · Korean",
            englishOnly: false,
            detectsLanguageAutomatically: true
        ),
        .init(
            id: "dolphin-base-ctc",
            displayName: "Dolphin Base",
            engine: .sherpaOnnx,
            repository: "csukuangfj/sherpa-onnx-dolphin-base-ctc-multi-lang-int8-2025-04-02",
            revision: "1f3a53d0ecf658f8b0974e2cfde368eee40732fa",
            sherpaFamily: .dolphinCtc,
            sizeBytes: 104_234_464,
            minimumRamGB: 2,
            languages: "40 East Asian languages",
            englishOnly: false,
            detectsLanguageAutomatically: true
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
            id: "fast-conformer-ctc-4-lang",
            displayName: "Fast Conformer CTC",
            engine: .sherpaOnnx,
            repository: "csukuangfj/sherpa-onnx-nemo-fast-conformer-ctc-en-de-es-fr-14288",
            revision: "a472770bdbc5861d7e671dcdc349edaedf144cd0",
            sherpaFamily: .nemoCtc,
            sizeBytes: 461_337_434,
            minimumRamGB: 3,
            languages: "English · German · Spanish · French",
            englishOnly: false,
            languageCodesOverride: ["en", "de", "es", "fr"]
        ),
        .init(
            id: "giga-am-ctc-ru",
            displayName: "GigaAM CTC Russian",
            engine: .sherpaOnnx,
            repository: "csukuangfj/sherpa-onnx-nemo-ctc-giga-am-v2-russian-2025-04-19",
            revision: "f5555086f28ef11d600e30d76b61d75fd9685196",
            sherpaFamily: .nemoCtc,
            sizeBytes: 236_458_173,
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

    /// Best quality that fits, rather than a memory ladder that disagreed with
    /// the models' own floors.
    static var recommended: LocalModelDescriptor {
        let preference = [
            "openai_whisper-large-v3-v20240930_turbo_632MB",
            "openai_whisper-large-v3-v20240930_626MB",
            "openai_whisper-large-v3-v20240930_547MB",
            "openai_whisper-small_216MB",
            "openai_whisper-tiny",
        ]
        for id in preference {
            if let descriptor = descriptor(for: id), isUsableOnDevice(descriptor) {
                return descriptor
            }
        }
        return usableOnDevice.first ?? all[0]
    }
}
