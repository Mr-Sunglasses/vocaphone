package com.vocahq.vocaphone.local

import android.os.Build
import com.vocahq.vocaphone.core.TranscriptionLanguage
import com.vocahq.vocaphone.core.TranscriptionQuality
import com.vocahq.vocaphone.BuildConfig
import java.util.Locale

/** Native engines that can run without the gateway. */
enum class LocalModelEngine { WHISPER, SHERPA_ONNX }

/**
 * How a sherpa-onnx model's files are assembled into an `OfflineModelConfig`.
 *
 * `sherpaModelType` is only set where the populated config field is ambiguous on
 * its own: a transducer config could be zipformer or NeMo, and a NeMo TDT model
 * needs the NeMo path. Everywhere else it stays empty so sherpa-onnx dispatches
 * on which field was filled in and reads the type from the ONNX metadata, rather
 * than logging "Invalid model_type" against a value it does not recognize.
 */
enum class SherpaFamily(
    val sherpaModelType: String = "",
    /** Tiny feature noise used only where zero dither can collapse valid speech. */
    val featureDither: Float = 0f,
    /**
     * Whether this family can safely use `modified_beam_search`.
     *
     * This is not a preference. sherpa-onnx validates the decoding method when
     * the recognizer is built, and unsupported families answer with `exit(-1)`
     * — not an exception, but the process gone. NeMo TDT accepts the value, but
     * the implementation in the bundled sherpa-onnx v1.13.6 can intermittently
     * emit empty or hallucinated text (upstream #3267; its proposed fix #3657
     * is not merged). It stays false until a fixed native runtime is shipped
     * and exercised on a phone.
     */
    val supportsBeamSearch: Boolean = false,
    /**
     * Whether the recognizer config for this family has a language field at all.
     *
     * The transducer and CTC families do not: sherpa-onnx exposes no language on
     * `OfflineTransducerModelConfig`, `OfflineDolphinModelConfig` or the NeMo CTC
     * config, so those models decide the language from the audio whatever the
     * user picked. The picker still offers the languages they cover, because the
     * choice governs how the transcript is punctuated, but nothing here can pin
     * the decoder and this flag is what keeps the two facts apart.
     */
    val acceptsLanguage: Boolean = false,
) {
    // Kaldi's dither=1 on int16 audio is approximately 1 / 32768 here. It is
    // the upstream workaround for Parakeet returning no tokens on valid audio
    // with an all-zero dither setting (sherpa-onnx #2258).
    NEMO_TRANSDUCER("nemo_transducer", featureDither = 0.00003f),
    SENSE_VOICE(acceptsLanguage = true),
    MOONSHINE,
    DOLPHIN_CTC,
    CANARY(acceptsLanguage = true),
    NEMO_CTC,
    PARAFORMER,
    ;

    /** The only safe way to turn a quality setting into a decoding method. */
    fun decodingMethod(quality: TranscriptionQuality): String =
        if (supportsBeamSearch) quality.sherpaDecodingMethod else GREEDY_SEARCH

    companion object {
        const val GREEDY_SEARCH = "greedy_search"
    }
}

/** One file of a model, pinned by exact byte length and SHA-256. */
data class PinnedFile(val path: String, val sizeBytes: Long, val sha256: String)

data class LocalModelDescriptor(
    val id: String,
    val displayName: String,
    val engine: LocalModelEngine,
    /** Hugging Face repository the files are fetched from. */
    val repository: String,
    /** Immutable commit the files are fetched at. */
    val revision: String,
    val files: List<PinnedFile>,
    val sizeBytes: Long,
    val minimumRamGB: Int,
    val languages: String,
    val englishOnly: Boolean = false,
    val sherpaFamily: SherpaFamily? = null,
    /**
     * Which language codes this model can be asked for. Empty means no
     * restriction, which is the honest answer for whisper's multilingual builds:
     * they cover every language the picker offers.
     */
    val languageCodes: Set<String> = emptySet(),
    /**
     * True when the decoder picks the language from the audio and no request can
     * pin it. The languages in [languageCodes] are still offered, because the
     * choice decides how the transcript is punctuated, but the picker says
     * plainly that it does not steer the decoder.
     */
    val detectsLanguage: Boolean = false,
    /** Whether short recordings may use a cropped whisper encoder window. */
    val cropsAudioContext: Boolean = false,
    /**
     * Kept out of every recommendation, and labelled where it is offered.
     *
     * Not the same as "big" or "slow", both of which the picker already warns
     * about. This says the model's *output* has not been validated to the
     * standard the rest of the catalog is held to, so it must never be reached
     * by a user who did not go looking for it.
     */
    val experimental: Boolean = false,
) {
    /**
     * Whether this model's output script is the whole point of it.
     *
     * The Roman Hinglish model is the only one so far: it does not transcribe
     * "Hindi", it transcribes Hindi and English into one Latin script, and that
     * is a different promise from any language code. Declaring the output-script
     * code in [languageCodes] is how a model says so, and it is what stops the
     * translate row offering to turn the result into English — which is exactly
     * the failure this mode exists to avoid.
     */
    val producesFixedScript: Boolean
        get() = com.vocahq.vocaphone.core.TranscriptionLanguage.HINGLISH_ROMAN.wireValue in
            languageCodes
    /**
     * Which languages this model can translate speech *into*.
     *
     * Derived rather than declared, because only two things in the catalog can
     * translate at all and both derive it from something already written down.
     * Canary is a speech-translation model across exactly the languages it
     * lists; a multilingual whisper build has the `<|translate|>` task, whose
     * only trained target is English. Everything else transcribes the language
     * it heard, so an empty set here is the ordinary answer and the one the
     * translate row reports as unsupported. See
     * [com.vocahq.vocaphone.core.ModelTranslationSupport].
     */
    val translationTargets: Set<String>
        get() = when {
            sherpaFamily == SherpaFamily.CANARY -> languageCodes
            englishOnly || "distil" in id -> emptySet()
            // A fixed-script model has one output contract and translating is
            // not it. Whisper's translate task would still run — it is the same
            // decoder — and it would hand back the English translation this mode
            // exists to avoid, from a row the user reasonably read as harmless.
            producesFixedScript -> emptySet()
            engine == LocalModelEngine.WHISPER -> setOf("en")
            else -> emptySet()
        }

    /**
     * Whether translating needs the spoken language named explicitly.
     *
     * Canary has no detection mode: its config carries a source language and
     * takes whatever it is given, so "auto" has to be resolved to a real code
     * before the recognizer is built and English is the only defensible guess.
     * That is harmless while source and target match — the model was going to
     * assume something either way — but once the two differ it decides what the
     * audio is being translated *from*, and a German speaker left on Automatic
     * gets German translated as though it were English. Whisper is the opposite:
     * it detects the language and then translates, so it needs nothing here.
     */
    val translationNeedsExplicitSource: Boolean
        get() = sherpaFamily == SherpaFamily.CANARY

    val sizeLabel: String
        get() = if (sizeBytes >= 1_000_000_000) {
            "%.1f GB".format(sizeBytes / 1_000_000_000.0)
        } else {
            "${sizeBytes / 1_000_000} MB"
        }

    /** The single file a whisper.cpp context is initialized from. */
    val primaryFile: PinnedFile get() = files.first()

    /**
     * Whether a custom word list can reach this model at all.
     *
     * Whisper's decoder reads previous text tokens, which is the slot a
     * vocabulary prompt goes into. The sherpa families have no equivalent: the
     * CTC and non-autoregressive ones condition on audio alone, and the two
     * that could be biased — the Parakeet transducers — need a BPE vocabulary
     * file that their upstream repositories do not publish.
     */
    val supportsCustomVocabulary: Boolean get() = engine == LocalModelEngine.WHISPER

    /**
     * What the language picker may offer for this model.
     *
     * Almost always [languageCodes], and empty still means "no restriction".
     * The exception is the pre-large-v3 Whisper builds: they cover every
     * language the picker knows except Cantonese, which is a claim that can only
     * be made by listing the rest. See [LARGE_V3_ONLY_LANGUAGES].
     */
    val selectableLanguageCodes: Set<String>
        get() = when {
            languageCodes.isNotEmpty() -> languageCodes
            engine != LocalModelEngine.WHISPER -> emptySet()
            "large-v3" in id -> emptySet()
            else -> PICKER_LANGUAGES - LARGE_V3_ONLY_LANGUAGES
        }
}

/** Every code the picker can show, which is the ceiling on any coverage claim. */
private val PICKER_LANGUAGES: Set<String> by lazy {
    TranscriptionLanguage.entries
        .filter { it != TranscriptionLanguage.AUTOMATIC }
        .map { it.wireValue }
        .toSet()
}

/**
 * Everything the phone can run without the gateway.
 *
 * whisper.cpp models come from `ggerganov/whisper.cpp` and sherpa-onnx models
 * from the Hugging Face mirrors of the k2-fsa release assets. Both are pinned
 * per file by SHA-256 at an immutable revision: the GitHub release tarballs
 * publish no checksums, and the mirrors expose one for every weight file.
 */
object LocalModelCatalog {
    private const val WHISPER_REPOSITORY = "ggerganov/whisper.cpp"
    private const val WHISPER_REVISION = "5359861c739e955e79d9a303bcbc70fb988958b1"

    /**
     * Quantized builds are included wherever upstream publishes them, because a
     * phone gets far more out of a q5 large than out of a full small.
     */
    private val whisper: List<LocalModelDescriptor> = listOf(
        // Tiny
        model("tiny-q5_1", "Whisper Tiny Q5", 32_152_673L,
            "818710568da3ca15689e31a743197b520007872ff9576237bda97bd1b469c3d7", 2, "100 languages"),
        model("tiny-q8_0", "Whisper Tiny Q8", 43_537_433L,
            "c2085835d3f50733e2ff6e4b41ae8a2b8d8110461e18821b09a15c40c42d1cca", 2, "100 languages"),
        model("tiny", "Whisper Tiny", 77_691_713L,
            "be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21", 2, "100 languages"),
        model("tiny.en-q5_1", "Whisper Tiny English Q5", 32_166_155L,
            "c77c5766f1cef09b6b7d47f21b546cbddd4157886b3b5d6d4f709e91e66c7c2b", 2, "English", true),
        model("tiny.en-q8_0", "Whisper Tiny English Q8", 43_550_795L,
            "5bc2b3860aa151a4c6e7bb095e1fcce7cf12c7b020ca08dcec0c6d018bb7dd94", 2, "English", true),
        model("tiny.en", "Whisper Tiny English", 77_704_715L,
            "921e4cf8686fdd993dcd081a5da5b6c365bfde1162e72b08d75ac75289920b1f", 2, "English", true),
        // Base
        model("base-q5_1", "Whisper Base Q5", 59_707_625L,
            "422f1ae452ade6f30a004d7e5c6a43195e4433bc370bf23fac9cc591f01a8898", 2, "100 languages"),
        model("base-q8_0", "Whisper Base Q8", 81_768_585L,
            "c577b9a86e7e048a0b7eada054f4dd79a56bbfa911fbdacf900ac5b567cbb7d9", 2, "100 languages"),
        model("base", "Whisper Base", 147_951_465L,
            "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe", 3, "100 languages"),
        model("base.en-q5_1", "Whisper Base English Q5", 59_721_011L,
            "4baf70dd0d7c4247ba2b81fafd9c01005ac77c2f9ef064e00dcf195d0e2fdd2f", 2, "English", true),
        model("base.en-q8_0", "Whisper Base English Q8", 81_781_811L,
            "a4d4a0768075e13cfd7e19df3ae2dbc4a68d37d36a7dad45e8410c9a34f8c87e", 2, "English", true),
        model("base.en", "Whisper Base English", 147_964_211L,
            "a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002", 3, "English", true),
        // Small
        model("small-q5_1", "Whisper Small Q5", 190_085_487L,
            "ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb", 3, "100 languages"),
        model("small-q8_0", "Whisper Small Q8", 264_464_607L,
            "49c8fb02b65e6049d5fa6c04f81f53b867b5ec9540406812c643f177317f779f", 3, "100 languages"),
        model("small", "Whisper Small", 487_601_967L,
            "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b", 4, "100 languages"),
        model("small.en-q5_1", "Whisper Small English Q5", 190_098_681L,
            "bfdff4894dcb76bbf647d56263ea2a96645423f1669176f4844a1bf8e478ad30", 3, "English", true),
        model("small.en-q8_0", "Whisper Small English Q8", 264_477_561L,
            "67a179f608ea6114bd3fdb9060e762b588a3fb3bd00c4387971be4d177958067", 3, "English", true),
        model("small.en", "Whisper Small English", 487_614_201L,
            "c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d", 4, "English", true),
        // Medium
        model("medium-q5_0", "Whisper Medium Q5", 539_212_467L,
            "19fea4b380c3a618ec4723c3eef2eb785ffba0d0538cf43f8f235e7b3b34220f", 4, "100 languages"),
        model("medium-q8_0", "Whisper Medium Q8", 823_369_779L,
            "42a1ffcbe4167d224232443396968db4d02d4e8e87e213d3ee2e03095dea6502", 6, "100 languages"),
        model("medium", "Whisper Medium", 1_533_763_059L,
            "6c14d5adee5f86394037b4e4e8b59f1673b6cee10e3cf0b11bbdbee79c156208", 8, "100 languages"),
        model("medium.en-q5_0", "Whisper Medium English Q5", 539_225_533L,
            "76733e26ad8fe1c7a5bf7531a9d41917b2adc0f20f2e4f5531688a8c6cd88eb0", 4, "English", true),
        model("medium.en-q8_0", "Whisper Medium English Q8", 823_382_461L,
            "43fa2cd084de5a04399a896a9a7a786064e221365c01700cea4666005218f11c", 6, "English", true),
        model("medium.en", "Whisper Medium English", 1_533_774_781L,
            "cc37e93478338ec7700281a7ac30a10128929eb8f427dda2e865faa8f6da4356", 8, "English", true),
        // Large v3 Turbo
        model("large-v3-turbo-q5_0", "Whisper Large v3 Turbo Q5", 574_041_195L,
            "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2", 4, "100 languages"),
        model("large-v3-turbo-q8_0", "Whisper Large v3 Turbo Q8", 874_188_075L,
            "317eb69c11673c9de1e1f0d459b253999804ec71ac4c23c17ecf5fbe24e259a1", 6, "100 languages"),
        model("large-v3-turbo", "Whisper Large v3 Turbo", 1_624_555_275L,
            "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69", 8, "100 languages"),
        // Large
        model("large-v3-q5_0", "Whisper Large v3 Q5", 1_081_140_203L,
            "d75795ecff3f83b5faa89d1900604ad8c780abd5739fae406de19f23ecd98ad1", 6, "100 languages"),
        model("large-v3", "Whisper Large v3", 3_095_033_483L,
            "64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2", 12, "100 languages"),
        model("large-v2-q5_0", "Whisper Large v2 Q5", 1_080_732_091L,
            "3a214837221e4530dbc1fe8d734f302af393eb30bd0ed046042ebf4baf70f6f2", 6, "100 languages"),
        model("large-v2-q8_0", "Whisper Large v2 Q8", 1_656_129_691L,
            "fef54e6d898246a65c8285bfa83bd1807e27fadf54d5d4e81754c47634737e8c", 8, "100 languages"),
        model("large-v2", "Whisper Large v2", 3_094_623_691L,
            "9a423fe4d40c82774b6af34115b8b935f34152246eb19e80e376071d3f999487", 12, "100 languages"),
    )

    /**
     * Roman Hinglish: mixed Hindi and English, written in one Latin script.
     *
     * `Oriserve/Whisper-Hindi2Hinglish-Apex` is a fine-tune of
     * `openai/whisper-large-v3-turbo` (Apache-2.0) whose training target is
     * romanized Hindi, so the script comes out of the decoder rather than out of
     * a transliteration pass. Its `config.json` is turbo's topology exactly — 32
     * encoder layers, 4 decoder layers, `d_model` 1280, 128 mel bins, 51866
     * tokens — which is why whisper.cpp runs it unmodified and why the quantized
     * file is byte-for-byte the size of the stock turbo build.
     *
     * Upstream publishes safetensors and nothing else. The GGML conversion is
     * pinned at a third-party repository, at an immutable commit, by SHA-256 —
     * and the digest was not taken on trust: `tools/hinglish/convert-apex-ggml.sh`
     * reproduces it from Oriserve's own weights, and that script is how it should
     * be re-checked before this pin is ever moved.
     *
     * [languageCodes] holds one entry and it is not a language. That is the
     * honest claim: asking this model for Hindi gets Roman Hinglish, and asking
     * it for German gets Roman Hinglish too.
     */
    private val hinglish: List<LocalModelDescriptor> = listOf(
        LocalModelDescriptor(
            id = "hinglish-apex-large-v3-turbo-q5_0",
            displayName = "Hinglish — Roman (Experimental)",
            engine = LocalModelEngine.WHISPER,
            repository = "Marquestra/Whisper-Hindi2Hinglish-Apex-GGML",
            revision = "d1de3ff618856e5675c47d3158ca820506fb4d9e",
            files = listOf(
                PinnedFile(
                    "ggml-apex-hinglish-q5_0.bin",
                    574_041_195L,
                    "9d877151b15cec1feb9110cfbc0a3162cf377bcc0ab1935174226f461cf60f13",
                ),
            ),
            sizeBytes = 574_041_195L,
            minimumRamGB = 4,
            languages = "Hindi + English, Roman script",
            languageCodes = setOf(TranscriptionLanguage.HINGLISH_ROMAN.wireValue),
            // Fine-tuned onto one output contract, so nothing is detected and
            // nothing can be pinned to something else.
            detectsLanguage = false,
            // Large-class encoder: the same reason the stock turbo builds keep
            // whisper's full thirty-second window.
            cropsAudioContext = false,
            experimental = true,
        ),
    )

    val all: List<LocalModelDescriptor> = whisper + SherpaModelCatalog.all + hinglish

    /**
     * sherpa-onnx ships as a prebuilt JNI library, so it is absent from builds
     * that compile everything from source (the `fdroid` flavor), and the tree
     * only carries the two Arm ABIs for the flavors that do include it. An
     * x86_64 emulator still runs every whisper.cpp model because that one is
     * built from source for whatever ABI Gradle asks for.
     */
    val sherpaAvailable: Boolean by lazy {
        BuildConfig.SHERPA_ONNX &&
            Build.SUPPORTED_ABIS?.any { it == "arm64-v8a" || it == "armeabi-v7a" } == true
    }

    fun find(id: String): LocalModelDescriptor? = all.firstOrNull { it.id == id }

    fun recommended(
        totalRamGB: Long,
        mediaPerformanceClass: Int = Build.VERSION.MEDIA_PERFORMANCE_CLASS,
        abi: String = Build.SUPPORTED_ABIS?.firstOrNull().orEmpty(),
        sherpaAvailable: Boolean = LocalModelCatalog.sherpaAvailable,
        cpuCores: Int = Runtime.getRuntime().availableProcessors(),
        maxCpuKHz: Int = 0,
        language: String = Locale.getDefault().language,
    ): LocalModelDescriptor = recommended(
        DeviceProfile(
            totalRamGB = totalRamGB,
            cpuCores = cpuCores,
            performanceClass = mediaPerformanceClass,
            abi = abi,
            maxCpuKHz = maxCpuKHz,
            sherpaAvailable = sherpaAvailable,
            language = language,
        ),
    )

    /**
     * The default pick: the first of [recommendations], which is the one that
     * covers this phone's language best.
     */
    fun recommended(profile: DeviceProfile): LocalModelDescriptor =
        recommendations(profile).firstOrNull()?.model ?: lastResort(profile)

    /**
     * Three or four models worth offering on this phone, best first.
     *
     * One recommendation cannot answer the question people actually have. A
     * phone that can run the 0.6B Parakeet encoder should be told so, but the
     * person holding it may want their own language instead of English, or a
     * 100 MB download instead of a 670 MB one on mobile data. So the picker
     * offers the accurate English model, the widest multilingual model, the
     * specialist for the phone's own language, and the smallest thing that
     * still covers that language, deduplicated and capped at four.
     *
     * The first entry leads: the phone's own language decides which of the
     * roles that is.
     */
    fun recommendations(profile: DeviceProfile): List<ModelPick> {
        val english = bestEnglish(profile)
        val multilingual = bestMultilingual(profile)
        val regional = starterForLanguage(profile.language)?.takeIf { profile.fits(it) }
        val compact = smallestCovering(profile)

        // First role wins when two roles land on the same model, which is why
        // the order these are added in is the order the picker shows.
        val picks = LinkedHashMap<String, ModelPick>()
        fun add(role: ModelPickRole, model: LocalModelDescriptor?) {
            if (model == null) return
            picks.putIfAbsent(model.id, ModelPick(role, model))
        }
        if (profile.language.lowercase(Locale.ROOT) == "en") {
            add(ModelPickRole.ENGLISH, english)
            add(ModelPickRole.MULTILINGUAL, multilingual)
        } else {
            add(ModelPickRole.REGIONAL, regional)
            add(ModelPickRole.MULTILINGUAL, multilingual)
            add(ModelPickRole.ENGLISH, english)
        }
        add(ModelPickRole.COMPACT, compact)

        val ordered = picks.values.toList().take(4)
        return ordered.ifEmpty {
            listOf(ModelPick(ModelPickRole.COMPACT, lastResort(profile)))
        }
    }

    /**
     * The most accurate English model this phone can hold. Parakeet first: on
     * anything with a 4 GB budget it is both faster and more accurate than the
     * Whisper of the same size, and it is the reason this list is not one line.
     */
    private fun bestEnglish(profile: DeviceProfile): LocalModelDescriptor? =
        firstFitting(profile, ENGLISH_PREFERENCE)
            ?: whisper.filter { profile.fits(it) && it.englishOnly }
                .maxByOrNull { scoreModel(it, profile) }
            ?: recommendedWhisper(profile)

    /** The widest-coverage model that still covers this phone's own language. */
    private fun bestMultilingual(profile: DeviceProfile): LocalModelDescriptor? =
        MULTILINGUAL_PREFERENCE.firstNotNullOfOrNull { id ->
            find(id)?.takeIf { profile.fits(it) && it.coversLanguage(profile.language) }
        } ?: whisper.filter { profile.fits(it) && !it.englishOnly }
            .maxByOrNull { scoreModel(it, profile) }

    /** The lightest download that still transcribes this phone's language. */
    private fun smallestCovering(profile: DeviceProfile): LocalModelDescriptor? =
        recommendable.filter { profile.fits(it) && it.coversLanguage(profile.language) }
            .minByOrNull { it.sizeBytes }

    /**
     * Everything a recommendation may land on.
     *
     * An experimental model has to be gone looking for. Reaching one by way of
     * "smallest download" or "nothing else fit" would put unvalidated output in
     * front of a user who never asked for it, which is the one thing the flag is
     * there to prevent.
     */
    private val recommendable: List<LocalModelDescriptor> get() = all.filterNot { it.experimental }

    private fun firstFitting(
        profile: DeviceProfile,
        ids: List<String>,
    ): LocalModelDescriptor? = ids.firstNotNullOfOrNull { id ->
        find(id)?.takeIf { profile.fits(it) }
    }

    /** Nothing fit the budget, so fall back to whatever the phone can hold. */
    private fun lastResort(profile: DeviceProfile): LocalModelDescriptor =
        recommendable.filter { isUsableOnDevice(it, profile.totalRamGB, profile.sherpaAvailable) }
            .minByOrNull { it.minimumRamGB }
            ?: recommendable.first()

    /** The fastest sensible Whisper fallback for this CPU class. */
    fun recommendedWhisper(profile: DeviceProfile): LocalModelDescriptor =
        whisper.filter { profile.fits(it) }
            .maxByOrNull { scoreModel(it, profile) }
            ?: whisper.filter { isUsableOnDevice(it, profile.totalRamGB, sherpaAvailable = false) }
                .minByOrNull { it.sizeBytes }
            ?: whisper.first()

    /**
     * Whisper medium and larger are too heavy for live dictation on a phone.
     * Medium is a full decoder; it is often slower than large-v3-turbo at the
     * same quant. The catalog still offers them; the tile is marked so the
     * download is an informed choice.
     */
    fun isSlowOnMobile(model: LocalModelDescriptor): Boolean {
        if (model.engine != LocalModelEngine.WHISPER) return false
        return whisperClass(model.id) >= 4
    }

    /**
     * Warn only when a slower Whisper class or full-precision variant is
     * selected. Sherpa file size is not a speed signal, so a working Parakeet
     * must not look "too big".
     */
    fun needsHeavierWarning(
        selected: LocalModelDescriptor,
        profile: DeviceProfile,
    ): Boolean {
        if (selected.engine != LocalModelEngine.WHISPER) return false
        val recommended = recommendedWhisper(profile)
        return whisperClass(selected.id) > whisperClass(recommended.id) ||
            (whisperClass(selected.id) == whisperClass(recommended.id) &&
                selected.sizeBytes > recommended.sizeBytes * 2)
    }

    fun isUsableOnDevice(
        model: LocalModelDescriptor,
        totalRamGB: Long,
        sherpaAvailable: Boolean = LocalModelCatalog.sherpaAvailable,
    ): Boolean =
        totalRamGB >= model.minimumRamGB &&
            (model.engine != LocalModelEngine.SHERPA_ONNX || sherpaAvailable)

    /** Everything this device can actually run, smallest first. */
    fun usableOnDevice(totalRamGB: Long): List<LocalModelDescriptor> =
        all.filter { isUsableOnDevice(it, totalRamGB) }

    private fun model(
        name: String,
        displayName: String,
        sizeBytes: Long,
        sha256: String,
        minimumRamGB: Int,
        languages: String,
        englishOnly: Boolean = false,
    ) = LocalModelDescriptor(
        id = name,
        displayName = displayName,
        engine = LocalModelEngine.WHISPER,
        repository = WHISPER_REPOSITORY,
        revision = WHISPER_REVISION,
        files = listOf(PinnedFile("ggml-$name.bin", sizeBytes, sha256)),
        sizeBytes = sizeBytes,
        minimumRamGB = minimumRamGB,
        languages = languages,
        englishOnly = englishOnly,
        languageCodes = if (englishOnly) setOf("en") else emptySet(),
        // The larger encoders are much more sensitive to an off-distribution
        // cropped window. Tiny through small retain the short-dictation speedup;
        // medium and large keep Whisper's trained thirty-second context.
        cropsAudioContext = !name.startsWith("medium") && !name.startsWith("large"),
    )

    fun downloadUrl(model: LocalModelDescriptor, file: PinnedFile): String =
        "https://huggingface.co/${model.repository}/resolve/${model.revision}/${file.path}"

    /**
     * The first-run pick for [language], or null when the catalog has no
     * specialist and scoring should choose a small Whisper instead.
     *
     * Moonshine has no multilingual build, so English gets the tiny English
     * checkpoint and other languages get a compact specialist, not Parakeet.
     */
    internal fun starterForLanguage(language: String): LocalModelDescriptor? {
        val id = when (language.lowercase(Locale.ROOT)) {
            "en" -> "moonshine-tiny-en"
            "de", "es", "fr" -> "canary-180m-flash"
            "zh" -> "paraformer-zh-small"
            // SenseVoice rather than Paraformer for Cantonese: Paraformer is
            // Mandarin and English only, and now that Cantonese is a row in the
            // picker, leading with a model that cannot transcribe it is worse
            // than having offered nothing.
            "yue", "ja", "ko" -> "sense-voice"
            "ru" -> "giga-am-ctc-ru"
            in DOLPHIN_STARTER_LANGUAGES -> "dolphin-base-ctc"
            else -> null
        }
        return id?.let { find(it) }
    }
}

/**
 * Why a model is being offered. The picker shows this next to each alternate,
 * so the four picks read as four different answers rather than a ranking.
 */
enum class ModelPickRole(val label: String) {
    ENGLISH("Best for English"),
    MULTILINGUAL("Multilingual"),
    REGIONAL("Your language"),
    COMPACT("Smallest download"),
}

data class ModelPick(val role: ModelPickRole, val model: LocalModelDescriptor)

/** English models best first. Parakeet leads wherever the budget allows it. */
private val ENGLISH_PREFERENCE = listOf(
    "parakeet-tdt-0.6b-v2-en",
    "moonshine-base-en",
    "moonshine-tiny-en",
)

/** Multilingual models by breadth of coverage, widest first. */
private val MULTILINGUAL_PREFERENCE = listOf(
    "parakeet-tdt-0.6b-v3",
    "canary-180m-flash",
    "dolphin-small-ctc",
    "sense-voice",
    "dolphin-base-ctc",
)

/** Indic and nearby languages Dolphin actually covers well at first-run size. */
internal val DOLPHIN_STARTER_LANGUAGES = setOf(
    "hi", "bn", "ta", "te", "gu", "pa", "mr", "as", "ne", "ur", "th", "vi", "id", "ms",
)

internal val SENSE_VOICE_LANGUAGES = setOf("zh", "en", "ja", "ko", "yue")

/** Everything Dolphin transcribes that the picker also offers. */
internal val DOLPHIN_LANGUAGES = DOLPHIN_STARTER_LANGUAGES + SENSE_VOICE_LANGUAGES

/** NVIDIA Parakeet TDT 0.6B v3: 25 European languages. */
internal val PARAKEET_V3_LANGUAGES = setOf(
    "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it",
    "lv", "lt", "mt", "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk",
)

/**
 * Cantonese is the one language OpenAI added after Whisper v2.
 *
 * Every multilingual build before large-v3 stops at 99 language tokens, and the
 * hundredth id lands on the token those models use for something else: the
 * decode does not fail, it just comes back wrong. whisper.cpp will happily
 * accept the string, so the catalog is where this has to be caught.
 */
private val LARGE_V3_ONLY_LANGUAGES = setOf("yue")

/**
 * Whether this model transcribes [language] at all.
 *
 * Every model that covers a fixed list declares it in [languageCodes],
 * including the ones that detect the language themselves: a model that decides
 * for itself still only knows 25 languages, and the picker has to be able to say
 * which. Empty means no restriction, which is the honest answer for whisper's
 * multilingual builds apart from [LARGE_V3_ONLY_LANGUAGES].
 */
fun LocalModelDescriptor.coversLanguage(language: String): Boolean {
    val lang = language.lowercase(Locale.ROOT)
    if (lang.isBlank()) return true
    if (englishOnly) return lang == "en"
    if (languageCodes.isNotEmpty()) return lang in languageCodes
    if (engine == LocalModelEngine.WHISPER && lang in LARGE_V3_ONLY_LANGUAGES) {
        return "large-v3" in id
    }
    return true
}
