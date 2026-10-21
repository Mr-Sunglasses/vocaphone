package com.vocahq.vocaphone.grammar

import com.vocahq.vocaphone.local.GrammarModelDescriptor
import com.vocahq.vocaphone.local.GrammarModelStore
import com.vocahq.vocaphone.local.LocalModelIntegrity
import com.vocahq.vocaphone.local.PinnedFile
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** Every way the stage can fail must hand the transcript back unchanged. Mirrors GrammarCorrectorTests.swift. */
class GrammarCorrectorTest {
    @get:Rule val temp = TemporaryFolder()

    private val pinned = listOf(PinnedFile("mindtype_tagger.onnx", 4, "0".repeat(64)))

    private fun readyStore(): GrammarModelStore {
        val model = GrammarModelDescriptor("grammar-test", "Grammar model", "x/y", "0".repeat(40), pinned, 4)
        val directory = File(temp.root, model.id).also { it.mkdirs() }
        File(directory, "mindtype_tagger.onnx").writeText("onnx")
        LocalModelIntegrity.writeMarker(pinned, directory)
        return GrammarModelStore(temp.root, model)
    }

    private fun emptyStore() = GrammarModelStore(
        temp.root,
        GrammarModelDescriptor("grammar-missing", "Grammar model", "x/y", "0".repeat(40), pinned, 4),
    )

    private val fixing = GrammarTagger.Logits { _, rows ->
        Array(rows.size) { FloatArray(GrammarFixtures.labels.size) }
    }

    private fun loaded(logits: GrammarTagger.Logits = fixing): (File) -> GrammarCorrector.Loaded = {
        GrammarCorrector.Loaded(GrammarFixtures.tagger(logits)) {}
    }

    @Test
    fun withoutAModelTheTextIsUnchangedAndNothingLoads() {
        var loads = 0
        val corrector = GrammarCorrector(emptyStore(), {}, available = { true }, load = { loads++; error("no") })
        assertEquals("He don't know.", corrector.correct("He don't know.", emptySet()))
        assertEquals(0, loads)
    }

    @Test
    fun aBuildWithoutOnnxRuntimeNeverLoads() {
        var loads = 0
        val corrector = GrammarCorrector(readyStore(), {}, available = { false }, load = { loads++; error("no") })
        corrector.warm()
        assertEquals("He don't know.", corrector.correct("He don't know.", emptySet()))
        assertEquals(0, loads)
    }

    @Test
    fun theFirstTranscriptBeforeTheLoadFinishesIsLeftAlone() {
        val started = CountDownLatch(1)
        val release = CountDownLatch(1)
        val log = ArrayList<String>()
        val corrector = GrammarCorrector(readyStore(), { log.add(it) }, available = { true }, load = {
            started.countDown()
            release.await(5, TimeUnit.SECONDS)
            GrammarCorrector.Loaded(GrammarFixtures.tagger(fixing)) {}
        })
        assertEquals("He don't know.", corrector.correct("He don't know.", emptySet()))
        assertTrue(started.await(5, TimeUnit.SECONDS))
        release.countDown()
        assertTrue(log.isEmpty())
    }

    @Test
    fun aFailedLoadIsLoggedOnceAndNotRetriedPerDictation() {
        val log = ArrayList<String>()
        var loads = 0
        val corrector = GrammarCorrector(readyStore(), { synchronized(log) { log.add(it) } }, available = { true }, load = {
            loads++
            error("corrupt")
        })
        repeat(5) {
            corrector.warm()
            Thread.sleep(20)
            assertEquals("He don't know.", corrector.correct("He don't know.", emptySet()))
        }
        assertEquals(1, loads)
        assertEquals(listOf("grammar_load_failed"), log)
    }

    @Test
    fun aRuntimeErrorReturnsTheInputAndIsLogged() {
        val log = ArrayList<String>()
        val throwing = GrammarTagger.Logits { _, _ -> throw IllegalStateException("ORT said no") }
        val corrector = GrammarCorrector(readyStore(), { log.add(it) }, available = { true }, load = loaded(throwing))
        corrector.warm()
        Thread.sleep(100)
        assertEquals("He don't know.", corrector.correct("He don't know.", emptySet()))
        assertEquals(listOf("grammar_failed"), log)
    }

    @Test
    fun releaseDropsTheSessionAndWarmLoadsItAgain() {
        var closes = 0
        var loads = 0
        val corrector = GrammarCorrector(readyStore(), {}, available = { true }, load = {
            loads++
            GrammarCorrector.Loaded(GrammarFixtures.tagger(fixing)) { closes++ }
        })
        corrector.warm()
        Thread.sleep(100)
        corrector.release()
        assertEquals(1, closes)
        corrector.warm()
        Thread.sleep(100)
        assertEquals(2, loads)
    }
}
