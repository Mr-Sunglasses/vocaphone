package com.vocahq.vocaphone.local

import com.vocahq.vocaphone.audio.SpeechAudioConditioning
import com.vocahq.vocaphone.core.DictatedTranscript
import com.vocahq.vocaphone.core.TranscriptionQuality
import com.vocahq.vocaphone.core.WritingStyle
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlinx.coroutines.runBlocking
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
                val started = System.nanoTime()
                val transcription = requireNotNull(context).transcribe(
                    SpeechAudioConditioning.condition(samples),
                    language = language,
                    translateTo = "",
                    quality = quality,
                    prompt = "",
                    cropAudioContext = crop,
                    threads = WhisperCpuConfig.preferredThreadCount(model.id),
                )
                val milliseconds = (System.nanoTime() - started) / 1_000_000
                val finished = DictatedTranscript.finished(
                    transcription.text,
                    style = WritingStyle.CASUAL,
                    language = language,
                    repairSpeech = true,
                    numbersAsDigits = true,
                    spokenEmoji = true,
                )
                val line = JSONObject()
                    .put("id", id)
                    .put("raw", transcription.text)
                    .put("finished", finished)
                    .put("milliseconds", milliseconds)
                    .put("emptyWindows", 0)
                output.appendText(line.toString() + "\n")
                decoded += 1
            }
            println("asr-bench: android-${model.id} $set.file: decoded $decoded, ${done.size} already done")
        }
    }

    /**
     * A run resumed with a different crop or quality would mix two
     * measurements under one name, so the settings are written once and every
     * resume must match.
     */
    private fun checkSettings(directory: File) {
        val settings = JSONObject().put("crop", crop.toString()).put("quality", quality.storedValue)
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
