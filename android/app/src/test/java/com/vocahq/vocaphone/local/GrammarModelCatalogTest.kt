package com.vocahq.vocaphone.local

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class GrammarModelCatalogTest {
    private val tagger = GrammarModelCatalog.tagger

    @Test
    fun sizeIsTheSumOfThePinnedFiles() {
        assertEquals(tagger.files.sumOf { it.sizeBytes }, tagger.sizeBytes)
    }

    @Test
    fun everyFileIsPinnedToAFullDigestAtAFixedRevision() {
        assertEquals(40, tagger.revision.length)
        tagger.files.forEach { assertTrue(it.path, Regex("[0-9a-f]{64}").matches(it.sha256)) }
        assertEquals(
            setOf("mindtype_tagger.onnx", "tokenizer.json", "labels.json", "plausible_pairs.json", "config.json"),
            tagger.files.map { it.path }.toSet(),
        )
    }

    /** The grammar model transcribes nothing; it must never reach the speech picker. */
    @Test
    fun itIsNotASpeechModel() {
        assertNull(LocalModelCatalog.find(tagger.id))
        assertFalse(LocalModelCatalog.all.any { it.repository == tagger.repository })
    }

    @Test
    fun downloadUrlPinsTheRevision() {
        assertEquals(
            "https://huggingface.co/VocaHQ/mindtype-tagger-v1.5-onnx/resolve/" +
                "5b6d7c3004677870122c10d84f78b35dcb760ff8/tokenizer.json",
            GrammarModelCatalog.downloadUrl(tagger, tagger.files.first { it.path == "tokenizer.json" }),
        )
    }
}
