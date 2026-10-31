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
            setOf("mindtype_tagger.onnx", "tokenizer.json", "labels.json", "plausible_pairs.json", "config.json")
                .map { "onnx/$it" }.toSet(),
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
            "https://huggingface.co/Mindscend/mindtype-tagger-v2.0/resolve/" +
                "e58cbb68c382a894a9f6de704fe385ec260f0949/onnx/tokenizer.json",
            GrammarModelCatalog.downloadUrl(tagger, tagger.files.first { it.path == "onnx/tokenizer.json" }),
        )
    }

    /** The loader opens the files where the repository's layout put them. */
    @Test
    fun theModelFolderIsTheRepositorysOnnxFolder() {
        assertEquals("onnx", GrammarModelCatalog.modelFolder(tagger))
    }

    @Test
    fun theCurrentModelIsNeverRetired() {
        assertFalse(tagger.id in GrammarModelCatalog.retiredIds)
    }
}
