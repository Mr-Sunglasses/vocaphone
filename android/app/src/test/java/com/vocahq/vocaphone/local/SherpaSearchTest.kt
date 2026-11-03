package com.vocahq.vocaphone.local

import com.vocahq.vocaphone.core.RecognitionHints
import com.vocahq.vocaphone.core.TranscriptionQuality
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Parakeet Unified's beam search with hotwords, short of the native runtime,
 * which the host JVM cannot load: which models get it, the config they are
 * built with, and when the recognizer has to be rebuilt. Mirrors the iOS
 * client's transducer tests in `RecognitionHintsTests`.
 */
class SherpaSearchTest {

    private val unified = LocalModelCatalog.find("parakeet-unified-0.6b-en")!!

    @Test
    fun `only parakeet unified has a hotword vocabulary`() {
        val models = LocalModelCatalog.all.filter { it.hotwordVocabularyFile != null }
        assertEquals(listOf("parakeet-unified-0.6b-en"), models.map { it.id })
        assertEquals("parakeet-unified-0.6b-en.bpe.vocab", unified.hotwordVocabularyFile)
        assertEquals(SherpaFamily.NEMO_TRANSDUCER, unified.sherpaFamily)
        // The TDT Parakeets drop sentences in beam search on the pinned runtime.
        listOf("parakeet-tdt-0.6b-v2-en", "parakeet-tdt-0.6b-v3").forEach { id ->
            assertNull(id, LocalModelCatalog.find(id)!!.hotwordVocabularyFile)
        }
    }

    @Test
    fun `a vocabulary turns the transducer to beam search with hotwords`() {
        TranscriptionQuality.entries.forEach { quality ->
            val beam = SherpaSearch.of(SherpaFamily.NEMO_TRANSDUCER, quality, "/x/u.bpe.vocab")
            assertEquals("modified_beam_search", beam.decodingMethod)
            assertEquals(RecognitionHints.TRANSDUCER_BEAM_WIDTH, beam.maxActivePaths)
            assertEquals("/x/u.bpe.vocab", beam.bpeVocabulary)
            assertEquals("bpe", beam.modelingUnit)
            assertEquals(RecognitionHints.TRANSDUCER_HOTWORD_SCORE, beam.hotwordScore, 0f)
            assertTrue(beam.takesHotwords)

            listOf(null, "").forEach { vocabulary ->
                val greedy = SherpaSearch.of(SherpaFamily.NEMO_TRANSDUCER, quality, vocabulary)
                assertEquals("greedy_search", greedy.decodingMethod)
                assertEquals("", greedy.modelingUnit)
                assertEquals("", greedy.bpeVocabulary)
                assertFalse(greedy.takesHotwords)
            }
        }
    }

    @Test
    fun `no other family ever gets beam search from a vocabulary`() {
        SherpaFamily.entries.filter { it != SherpaFamily.NEMO_TRANSDUCER }.forEach { family ->
            TranscriptionQuality.entries.forEach { quality ->
                val search = SherpaSearch.of(family, quality, "/x/u.bpe.vocab")
                assertEquals("$family", SherpaFamily.GREEDY_SEARCH, search.decodingMethod)
                assertFalse("$family", search.takesHotwords)
            }
        }
    }

    /** A tone at speech level for [seconds], then [silence] seconds of nothing. */
    private fun audio(seconds: Double, silence: Double = 0.0): FloatArray {
        val rate = SherpaLongAudio.SAMPLE_RATE
        val voiced = FloatArray((seconds * rate).toInt()) { (0.1 * kotlin.math.sin(it * 0.07)).toFloat() }
        return voiced + FloatArray((silence * rate).toInt())
    }

    @Test
    fun `speech after the last token is a stop too early`() {
        val samples = audio(8.0)
        assertTrue(SherpaHotwordCheck.stoppedEarly(samples, 3.0))
        assertTrue(SherpaHotwordCheck.stoppedEarly(samples, null))
    }

    @Test
    fun `a transcript that runs to the end of the speech is not`() {
        assertFalse(SherpaHotwordCheck.stoppedEarly(audio(8.0), 7.8))
        // The usual end of a dictation: the last word, then a pause.
        assertFalse(SherpaHotwordCheck.stoppedEarly(audio(4.0, silence = 4.0), 3.8))
        // Silence alone never asks for another decode.
        assertFalse(SherpaHotwordCheck.stoppedEarly(audio(0.0, silence = 5.0), null))
    }

    @Test
    fun `a tail shorter than the minimum is not judged`() {
        val total = 6.0
        val last = total - SherpaHotwordCheck.MARGIN_SECONDS - SherpaHotwordCheck.MINIMUM_TAIL_SECONDS + 0.2
        assertFalse(SherpaHotwordCheck.stoppedEarly(audio(total), last))
    }

    @Test
    fun `a hotword said twice in a row is a loop`() {
        val hotwords = "Aoife/Slack/Jetpack Compose"
        assertTrue(SherpaHotwordCheck.repeatsAHotword("tell Aoife on Slack Slack Slack", hotwords))
        assertTrue(SherpaHotwordCheck.repeatsAHotword("Jetpack Compose, Jetpack Compose.", hotwords))
        assertFalse(SherpaHotwordCheck.repeatsAHotword("tell Aoife on Slack", hotwords))
        assertFalse(SherpaHotwordCheck.repeatsAHotword("Slack it on Slack", hotwords))
        // Only the user's words: an ordinary repeat is the speaker's.
        assertFalse(SherpaHotwordCheck.repeatsAHotword("very very good", hotwords))
        assertFalse(SherpaHotwordCheck.repeatsAHotword("", hotwords))
    }

    @Test
    fun `a repeat is found whatever its case`() {
        assertTrue(SherpaHotwordCheck.repeatsAHotword("on Slack Slack", "slack"))
        assertTrue(SherpaHotwordCheck.repeatsAHotword("on Slack slack", "Slack"))
        assertTrue(SherpaHotwordCheck.repeatsAHotword("JETPACK compose Jetpack Compose", "Jetpack Compose"))
        assertFalse(SherpaHotwordCheck.repeatsAHotword("on Slack", "slack"))
    }

    @Test
    fun `the tuned search stays below the runaway score`() {
        // Score 4 with a beam of 4 repeated hotwords into ordinary speech
        // ("Jira Jira Jira") on vocab-en; see docs/local-model-review.md.
        assertTrue(RecognitionHints.TRANSDUCER_HOTWORD_SCORE > 0f)
        assertTrue(RecognitionHints.TRANSDUCER_HOTWORD_SCORE < 2.5f)
        assertTrue(RecognitionHints.TRANSDUCER_BEAM_WIDTH in 1..8)
    }

    @Test
    fun `beam search is only for a model with a vocabulary and a user with words`() {
        assertTrue(takesHotwordSearch(unified, sherpaHotwords(unified, "Kanishk\nTailscale")))
        assertFalse(takesHotwordSearch(unified, sherpaHotwords(unified, "")))
        assertFalse(takesHotwordSearch(unified, sherpaHotwords(unified, " ,\n")))
        LocalModelCatalog.all.filter { it.id != unified.id }.forEach { model ->
            assertFalse(model.id, takesHotwordSearch(model, sherpaHotwords(model, "Kanishk")))
        }
    }

    @Test
    fun `adding or clearing the words rebuilds the recognizer and nothing else does`() {
        fun reload(loaded: Boolean, requested: Boolean) = shouldReloadLocalEngine(
            engine = LocalModelEngine.SHERPA_ONNX,
            loadedModelID = unified.id,
            requestedModelID = unified.id,
            loadedLanguage = "en",
            requestedLanguage = "en",
            loadedQuality = TranscriptionQuality.DEFAULT,
            requestedQuality = TranscriptionQuality.DEFAULT,
            languageIsBakedIn = false,
            loadedHotwordSearch = loaded,
            requestedHotwordSearch = requested,
        )
        assertTrue(reload(loaded = false, requested = true))
        assertTrue(reload(loaded = true, requested = false))
        assertFalse(reload(loaded = true, requested = true))
        assertFalse(reload(loaded = false, requested = false))
    }

    @Test
    fun `a window prepared for the other search is not decoded by this one`() {
        fun stillLoaded(loaded: Boolean, requested: Boolean) = sherpaEngineStillLoaded(
            model = unified,
            requestedLanguage = "en",
            requestedQuality = TranscriptionQuality.DEFAULT,
            requestedTranslateTo = "",
            loadedModelID = unified.id,
            loadedLanguage = "en",
            loadedQuality = TranscriptionQuality.DEFAULT,
            loadedTranslateTo = "",
            requestedHotwordSearch = requested,
            loadedHotwordSearch = loaded,
        )
        assertTrue(stillLoaded(loaded = true, requested = true))
        assertTrue(stillLoaded(loaded = false, requested = false))
        assertFalse(stillLoaded(loaded = true, requested = false))
        assertFalse(stillLoaded(loaded = false, requested = true))
    }

    @Test
    fun `the vocabulary is an asset at the name the catalog gives`() {
        val root = generateSequence(File("").absoluteFile) { it.parentFile }
            .first { File(it, "assets/speech").isDirectory }
        val vocabulary = File(root, "assets/speech/${unified.hotwordVocabularyFile}")
        val lines = vocabulary.readLines()
        assertEquals(1_024, lines.size)
        assertEquals("<unk>\t0.0", lines.first())
        // The source set that makes it an asset, by that same name.
        val gradle = File(root, "android/app/build.gradle.kts").readText()
        assertTrue(gradle.contains("assets.srcDir(\"\${rootDir}/../assets/speech\")"))
    }
}
