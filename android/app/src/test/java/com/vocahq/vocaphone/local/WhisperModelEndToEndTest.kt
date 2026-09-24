package com.vocahq.vocaphone.local

import com.vocahq.vocaphone.audio.SpeechAudioConditioning
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
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.BeforeClass
import org.junit.Test

/**
 * The pinned whisper.cpp and the app's own JNI glue, built for this computer,
 * decoding synthesized speech with a real pinned model through the same
 * levelling, decode parameters and text finishing as a dictation on a phone.
 *
 * Every other test of this path stops short of native code, so a whisper.cpp
 * bump that returned empty or truncated text would pass them. This runs on the
 * CI host with no emulator. It is skipped unless `vocaphone.modelE2E` names a
 * directory; `just android model-test` builds the library, fetches the model,
 * speaks the scenarios and sets it. See `tools/model-e2e/`.
 */
class WhisperModelEndToEndTest {

    /**
     * With `vocaphone.modelE2E.report` set, records each scenario's missing
     * words to that file instead of failing. CI uses that to compare a
     * re-pinned model with the pin it replaces: a weaker model mishearing a
     * word is not a regression, the new pin doing worse than the old one is.
     */
    @Test
    fun everySentenceIsTyped() = runBlocking {
        val missingByScenario = scenarios().associate { scenario ->
            val text = dictate(scenario.samples())
            scenario.name to (scenario.markers.filterNot { text.lowercase().contains(it) } to text)
        }
        System.getProperty("vocaphone.modelE2E.report")?.let { path ->
            val report = JSONObject()
            missingByScenario.forEach { (name, result) -> report.put(name, JSONArray(result.first)) }
            File(path).writeText(report.toString(2))
            return@runBlocking
        }
        val failures = missingByScenario.mapNotNull { (name, result) ->
            val (missing, text) = result
            if (missing.isEmpty()) null else "$name: missing $missing in \"$text\""
        }
        assertTrue(failures.joinToString("\n"), failures.isEmpty())
    }

    /**
     * Where speech starts inside the audio whisper is handed decides what its
     * first token is, and that is exactly where a decoder regression shows up:
     * WhisperKit 1.1.0 ended such windows on the spot and returned nothing. A
     * dozen seconds of continuous speech from many offsets, most of them
     * mid-word, at full and at a whispered level, must all produce text.
     */
    @Test
    fun noWindowOfSpeechDecodesToNothing() = runBlocking {
        val speech = scenarios().single { it.name == "continuous" }.samples()
        val empty = mutableListOf<String>()
        for (gain in listOf(1f, 0.12f)) {
            for (step in 0 until 16) {
                val start = step * 8_000 + 3_000
                val window = speech.copyOfRange(start, minOf(speech.size, start + 12 * RATE))
                for (index in 0 until minOf(window.size, 3 * RATE)) window[index] *= gain
                if (dictate(window).isBlank()) empty += "${start.toDouble() / RATE}s x$gain"
            }
        }
        assertTrue("empty windows starting at $empty", empty.isEmpty())
    }

    /** Custom vocabulary reaches whisper.cpp as an initial prompt. */
    @Test
    fun customVocabularyDoesNotEmptyTheTranscript() = runBlocking {
        val scenario = scenarios().single { it.name == "two_windows" }
        val text = dictate(scenario.samples(), vocabulary = "VocaPhone, Kanishk, whisper.cpp")
        val missing = scenario.markers.filterNot { text.lowercase().contains(it) }
        assertTrue("with vocabulary: missing $missing in \"$text\"", missing.isEmpty())
    }

    private class Scenario(val name: String, val file: File, val markers: List<String>) {
        fun samples(): FloatArray {
            // The scenario WAVs are 32-bit float, mono, 16 kHz.
            val bytes = file.readBytes()
            var offset = 12
            while (offset + 8 <= bytes.size) {
                val id = String(bytes, offset, 4, Charsets.US_ASCII)
                val size = ByteBuffer.wrap(bytes, offset + 4, 4).order(ByteOrder.LITTLE_ENDIAN).int
                if (id == "data") {
                    val floats = ByteBuffer.wrap(bytes, offset + 8, size)
                        .order(ByteOrder.LITTLE_ENDIAN)
                        .asFloatBuffer()
                    return FloatArray(floats.remaining()).also(floats::get)
                }
                offset += 8 + size
            }
            error("${file.name} has no data chunk")
        }
    }

    private fun scenarios(): List<Scenario> {
        val directory = File(requireNotNull(root), "scenarios")
        val manifest = JSONArray(File(directory, "scenarios.json").readText())
        return (0 until manifest.length()).map { index ->
            val entry = manifest.getJSONObject(index)
            val markers = entry.getJSONArray("markers")
            Scenario(
                name = entry.getString("name"),
                file = File(directory, entry.getString("file")),
                markers = (0 until markers.length()).map(markers::getString),
            )
        }
    }

    /** What `LocalModelManager.transcribe` does with a finished recording. */
    private suspend fun dictate(samples: FloatArray, vocabulary: String = ""): String {
        val transcription = requireNotNull(context).transcribe(
            SpeechAudioConditioning.condition(samples),
            language = "auto",
            translateTo = "",
            quality = TranscriptionQuality.DEFAULT,
            prompt = CustomVocabulary.whisperPrompt(vocabulary),
            cropAudioContext = model.cropsAudioContext,
            threads = WhisperCpuConfig.preferredThreadCount(model.id),
        )
        return DictatedTranscript.finished(
            transcription.text,
            style = WritingStyle.CASUAL,
            language = "en",
            repairSpeech = true,
            numbersAsDigits = true,
            spokenEmoji = true,
        )
    }

    companion object {
        private const val RATE = 16_000
        private val root: String? = System.getProperty("vocaphone.modelE2E")
        private val model = requireNotNull(
            LocalModelCatalog.find(System.getProperty("vocaphone.modelE2E.model") ?: "base-q8_0"),
        )
        private var context: WhisperContext? = null

        @BeforeClass
        @JvmStatic
        fun loadModel() {
            assumeTrue("set -Dvocaphone.modelE2E; see just android model-test", root != null)
            val file = File(root, model.primaryFile.path)
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
