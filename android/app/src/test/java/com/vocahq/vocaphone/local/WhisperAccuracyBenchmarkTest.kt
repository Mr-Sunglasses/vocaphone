package com.vocahq.vocaphone.local

import com.vocahq.vocaphone.audio.SpeechAudioConditioning
import com.vocahq.vocaphone.core.ContextTerms
import com.vocahq.vocaphone.core.CustomVocabulary
import com.vocahq.vocaphone.core.DictatedTranscript
import com.vocahq.vocaphone.core.TranscriptionQuality
import com.vocahq.vocaphone.core.WritingStyle
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.AfterClass
import org.junit.Assume.assumeTrue
import org.junit.BeforeClass
import org.junit.Test

/**
 * Word error rate on real speech for one pinned whisper.cpp model, through the
 * app's JNI glue, levelling, decode parameters and text finishing, as
 * `LocalModelManager.transcribe` decodes a finished recording.
 *
 * Not a pass/fail test. It writes what the model said for every clip
 * `tools/asr-bench/prepare.py` built, raw and finished, for
 * `tools/asr-bench/score.py`. Skipped unless `just android accuracy` set
 * `vocaphone.asrBench`.
 *
 * Two settings can be overridden to measure them rather than argue about them:
 * `vocaphone.asrBench.crop` (`on` / `off`, default the catalog's) and
 * `vocaphone.asrBench.quality` (default Balanced). A clip already in the
 * results file is skipped, so an interrupted run resumes.
 *
 * A clip that lists a `vocabulary` (the `vocab-en` set) is decoded with it as
 * the user's custom vocabulary: into the decoder as `LocalModelManager` hands
 * it over, and into the finishing funnel with the keyboard's word list, as
 * `DictationController` finishes a dictation. Every other clip has none.
 *
 * `vocaphone.asrBench.hints=none` decodes every clip with no vocabulary.
 * `vocaphone.asrBench.hints=context` decodes with no vocabulary either, but
 * with the terms [ContextTerms] takes from a text before the cursor
 * (`tools/asr-bench/vocab_en_context.json`): an earlier message in the same
 * thread for a `vocab-en` clip, one unrelated message for every other set.
 * The terms go where `DictationController` sends them: Whisper's prompt and
 * the finishing funnel's exact-match pass.
 */
class WhisperAccuracyBenchmarkTest {

    @Test
    fun decodeEverySet() = runBlocking {
        for (set in sets) {
            val clips = clips(set)
            val language = clips.firstOrNull()?.getString("language") ?: continue
            if (model.englishOnly && language != "en") continue
            val output = File(root, "results/$tag/android-${model.id}/$set.file.jsonl")
            output.parentFile.mkdirs()
            checkSettings(output.parentFile)
            trimIncompleteRecord(output)
            val done = if (output.exists()) {
                output.readLines().filter { it.isNotBlank() }.map { JSONObject(it).getString("id") }.toSet()
            } else {
                emptySet()
            }
            var decoded = 0
            for (clip in clips) {
                val id = clip.getString("id")
                if (id in done) continue
                val samples = readWav(File(root, "sets/$set/${clip.getString("file")}"))
                val vocabulary = if (hints == "vocabulary") vocabulary(clip) else ""
                val contextTerms = if (hints == "context") contextTerms(clip) else emptyList()
                val started = System.nanoTime()
                val transcription = requireNotNull(context).transcribe(
                    SpeechAudioConditioning.condition(samples),
                    language = language,
                    translateTo = "",
                    quality = quality,
                    prompt = whisperPrompt(vocabulary, contextTerms = contextTerms),
                    cropAudioContext = crop,
                    threads = WhisperCpuConfig.preferredThreadCount(model.id),
                )
                val milliseconds = (System.nanoTime() - started) / 1_000_000
                val unsure = transcription.confidence.lowConfidenceWords
                val finished = finish(transcription.text, language, CustomVocabulary.terms(vocabulary), unsure, contextTerms)
                val line = JSONObject()
                    .put("id", id)
                    .put("raw", transcription.text)
                    .put("finished", finished)
                    .put("milliseconds", milliseconds)
                    .put("emptyWindows", 0)
                    .put("unsure", unsure?.let { JSONArray(it.sorted()) } ?: JSONObject.NULL)
                if (!clip.has("vocabulary")) {
                    finishVocabulary?.let {
                        line.put("finishedVocabulary", finish(transcription.text, language, it, unsure))
                    }
                }
                output.appendText(line.toString() + "\n")
                decoded += 1
            }
            println("asr-bench: android-${model.id} $set.file: decoded $decoded, ${done.size} already done")
        }
    }

    /** As the app finishes an on-device dictation, with no replacements. */
    private fun finish(
        raw: String,
        language: String,
        vocabulary: List<String>,
        unsure: Set<String>?,
        contextTerms: List<String> = emptyList(),
    ): String =
        DictatedTranscript.finished(
            raw,
            style = WritingStyle.CASUAL,
            language = language,
            repairSpeech = true,
            numbersAsDigits = true,
            spokenEmoji = true,
            vocabulary = vocabulary,
            replacements = emptyList(),
            lowConfidenceWords = unsure,
            isDictionaryWord = { it in englishWords },
            contextTerms = contextTerms,
        )

    /**
     * A run resumed with a different crop or quality would mix two
     * measurements under one name, so the settings are written once and every
     * resume must match.
     */
    private fun checkSettings(directory: File) {
        val settings = JSONObject().put("crop", crop.toString()).put("quality", quality.storedValue)
        // The list itself, not its file name: a resume with other terms, or
        // with none where there were some, must not pass as the same control.
        finishVocabulary?.let { settings.put("finishVocabulary", it.joinToString("\n")) }
        if (hints != "vocabulary") settings.put("hints", hints)
        val file = File(directory, "settings.json")
        if (!file.exists()) {
            file.writeText(settings.toString())
            return
        }
        val recorded = JSONObject(file.readText())
        val same = recorded.length() == settings.length() &&
            settings.keys().asSequence().all { recorded.optString(it) == settings.getString(it) }
        check(same) { "$directory was recorded with $recorded, not $settings; use another tag" }
    }

    /** An interrupted write leaves a last line with no newline; cut it off before resuming. */
    private fun trimIncompleteRecord(file: File) {
        if (!file.exists() || file.length() == 0L) return
        val bytes = file.readBytes()
        if (bytes.last() == '\n'.code.toByte()) return
        val keep = bytes.lastIndexOf('\n'.code.toByte()) + 1
        file.writeBytes(bytes.copyOf(keep))
    }

    private fun clips(set: String): List<JSONObject> {
        val lines = File(root, "sets/$set/manifest.jsonl").readLines().filter { it.isNotBlank() }
        val all = lines.map(::JSONObject)
        // Spread across the set, as prepare.py spreads the set across the
        // corpus, so a short run still hears every speaker.
        val count = limit?.takeIf { it < all.size } ?: return all
        return (0 until count).map { all[it * all.size / count] }
    }

    /** The Settings field's stored text: the clip's terms, one a line. */
    private fun vocabulary(clip: JSONObject): String {
        val terms = clip.optJSONArray("vocabulary") ?: return ""
        return (0 until terms.length()).joinToString("\n") { terms.getString(it) }
    }

    /**
     * The terms from the clip's text before the cursor, as the keyboard's
     * dictation reads them. The earlier message sits above the cursor, as a
     * reply's would.
     */
    private fun contextTerms(clip: JSONObject): List<String> {
        val texts = JSONObject(File(requireNotNull(contextFile) { "set -Dvocaphone.asrBench.context" }).readText())
        val before = if (clip.has("vocabulary")) {
            texts.getJSONObject("contexts").getString(clip.getString("text"))
        } else {
            texts.getString("unrelated")
        }
        return ContextTerms.extract(before = before + "\n", after = null) { it in englishWords }
    }

    /** The prepared WAVs are 32-bit float, mono, 16 kHz. */
    private fun readWav(file: File): FloatArray {
        val bytes = file.readBytes()
        var offset = 12
        while (offset + 8 <= bytes.size) {
            val id = String(bytes, offset, 4, Charsets.US_ASCII)
            val size = ByteBuffer.wrap(bytes, offset + 4, 4).order(ByteOrder.LITTLE_ENDIAN).int
            if (id == "data") {
                val floats = ByteBuffer.wrap(bytes, offset + 8, size).order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer()
                return FloatArray(floats.remaining()).also(floats::get)
            }
            offset += 8 + size
        }
        error("${file.name} has no data chunk")
    }

    companion object {
        private val root: String? = System.getProperty("vocaphone.asrBench")
        private val models: String? = System.getProperty("vocaphone.asrBench.models")
        private val model by lazy {
            requireNotNull(LocalModelCatalog.find(System.getProperty("vocaphone.asrBench.model") ?: "small-q8_0"))
        }
        private val tag = System.getProperty("vocaphone.asrBench.tag")?.ifBlank { null } ?: "current"
        private val sets = (System.getProperty("vocaphone.asrBench.sets") ?: "librispeech-clean librispeech-other librispeech-long fleurs-hi")
            .split(" ").filter { it.isNotBlank() }
        private val limit = System.getProperty("vocaphone.asrBench.limit")?.toIntOrNull()

        /**
         * Terms, one a line, that clips without a vocabulary of their own are
         * finished with a second time, as `finishedVocabulary`: the same
         * decode, so the two columns differ only by what correction did to
         * ordinary speech.
         */
        private val finishVocabulary: List<String>? =
            System.getProperty("vocaphone.asrBench.finishVocabulary")?.ifBlank { null }
                ?.let { CustomVocabulary.terms(File(it).readText()) }
        private val quality by lazy {
            TranscriptionQuality.entries.firstOrNull { it.storedValue == System.getProperty("vocaphone.asrBench.quality") }
                ?: TranscriptionQuality.DEFAULT
        }
        private val crop by lazy {
            when (System.getProperty("vocaphone.asrBench.crop")) {
                "on" -> true
                "off" -> false
                else -> model.cropsAudioContext && quality.whisperCropsAudioContext
            }
        }
        private var context: WhisperContext? = null
        private val hints = System.getProperty("vocaphone.asrBench.hints")?.ifBlank { null } ?: "vocabulary"
        private val contextFile: String? = System.getProperty("vocaphone.asrBench.context")

        /** `DictationController.englishWords`, from the repository's copy of the asset. */
        private val englishWords: Set<String> by lazy {
            generateSequence(File("").absoluteFile) { it.parentFile }
                .map { File(it, "assets/keyboard/en.txt") }
                .firstOrNull(File::isFile)
                ?.readLines()
                ?.map { it.trim().lowercase() }
                ?.filter { it.isNotEmpty() }
                ?.toHashSet()
                ?: emptySet()
        }

        @BeforeClass
        @JvmStatic
        fun loadModel() {
            assumeTrue("set -Dvocaphone.asrBench; see just android accuracy", root != null && models != null)
            val file = File(models, model.primaryFile.path)
            context = runBlocking { WhisperContext.create(file.absolutePath) }
            check(context != null) { "whisper.cpp could not load $file" }
        }

        @AfterClass
        @JvmStatic
        fun releaseModel() {
            runBlocking { context?.release() }
        }
    }
}
