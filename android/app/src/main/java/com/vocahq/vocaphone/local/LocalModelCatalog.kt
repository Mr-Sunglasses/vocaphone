package com.vocahq.vocaphone.local

import android.os.Build
import com.vocahq.vocaphone.core.TranscriptionQuality

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
    /**
     * Whether this family accepts `modified_beam_search`.
     *
     * This is not a preference. sherpa-onnx validates the decoding method when
     * the recognizer is built, and every family except the transducer answers an
     * unsupported one with `exit(-1)` — not an exception, not an error return,
     * but the process gone. In the IME that is the keyboard vanishing mid-
     * sentence, so the method has to be decided from the family and never from
     * the user's setting alone.
     */
    val supportsBeamSearch: Boolean = false,
) {
    NEMO_TRANSDUCER("nemo_transducer", supportsBeamSearch = true),
    SENSE_VOICE,
    MOONSHINE,
    DOLPHIN_CTC,
    CANARY,
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
    /** True when the model decides the language itself and ignores the request. */
    val detectsLanguage: Boolean = false,
) {
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

    val all: List<LocalModelDescriptor> = whisper + SherpaModelCatalog.all

    /**
     * sherpa-onnx ships as a prebuilt JNI library, and the tree only carries the
     * two Arm ABIs. An x86_64 emulator still runs every whisper.cpp model
     * because that one is built from source for whatever ABI Gradle asks for.
     */
    val sherpaAvailable: Boolean by lazy {
        Build.SUPPORTED_ABIS?.any { it == "arm64-v8a" || it == "armeabi-v7a" } == true
    }

    fun find(id: String): LocalModelDescriptor? = all.firstOrNull { it.id == id }

    /**
     * A model fitting in RAM does not mean the CPU can transcribe with it at an
     * interactive speed. Older high-RAM phones report no media performance
     * class, so keep their default conservative while leaving every model that
     * fits available as an explicit choice.
     */
    fun recommended(
        totalRamGB: Long,
        mediaPerformanceClass: Int = Build.VERSION.MEDIA_PERFORMANCE_CLASS,
    ): LocalModelDescriptor = when {
        totalRamGB >= 12 && mediaPerformanceClass >= 34 -> find("large-v3-turbo")
        totalRamGB >= 6 && mediaPerformanceClass >= 31 -> find("large-v3-turbo-q5_0")
        // RAM only says that a model fits. Older high-RAM phones such as the
        // POCO F1 still need the smaller encoder to finish at a usable speed.
        totalRamGB >= 4 && mediaPerformanceClass >= 31 -> find("small-q5_1")
        totalRamGB >= 4 -> find("base-q5_1")
        totalRamGB >= 3 -> find("base-q5_1")
        else -> find("tiny-q5_1")
    } ?: all.first()

    fun isUsableOnDevice(model: LocalModelDescriptor, totalRamGB: Long): Boolean =
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
    )

    fun downloadUrl(model: LocalModelDescriptor, file: PinnedFile): String =
        "https://huggingface.co/${model.repository}/resolve/${model.revision}/${file.path}"
}
