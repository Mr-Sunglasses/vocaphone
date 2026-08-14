package com.vocahq.vocaphone.ui

import com.vocahq.vocaphone.local.LocalModelCatalog
import com.vocahq.vocaphone.local.LocalModelEngine
import org.junit.Assert.assertTrue
import org.junit.Test

class ModelCatalogQueryTest {

    private val models = LocalModelCatalog.all

    @Test
    fun queryMatchesDisplayNameAndHidesUnrelatedSizes() {
        val hits = filterModelCatalog(models, "tiny q5")
        assertTrue(hits.any { it.id == "tiny-q5_1" })
        assertTrue(hits.none { it.id.startsWith("large") })
    }

    @Test
    fun whisperFilterDropsSherpa() {
        val hits = filterModelCatalog(models, "", ModelEngineFilter.WHISPER)
        assertTrue(hits.isNotEmpty())
        assertTrue(hits.all { it.engine == LocalModelEngine.WHISPER })
    }

    @Test
    fun sherpaFilterDropsWhisper() {
        val hits = filterModelCatalog(models, "", ModelEngineFilter.SHERPA)
        assertTrue(hits.isNotEmpty())
        assertTrue(hits.all { it.engine == LocalModelEngine.SHERPA_ONNX })
    }

    @Test
    fun sizeFilterKeepsOnlySmallerModels() {
        val hits = filterModelCatalog(models, "", size = ModelSizeFilter.UNDER_100MB)
        assertTrue(hits.any { it.id == "tiny-q5_1" })
        assertTrue(hits.all { it.sizeBytes < 100_000_000L })
    }

    @Test
    fun englishFilterKeepsEnglishOnlyBuilds() {
        val hits = filterModelCatalog(models, "", language = ModelLanguageFilter.ENGLISH)
        assertTrue(hits.any { it.id.contains(".en") || it.englishOnly })
        assertTrue(hits.all { it.englishOnly })
    }

    @Test
    fun multilingualFilterDropsEnglishOnlyBuilds() {
        val hits = filterModelCatalog(models, "", language = ModelLanguageFilter.MULTILINGUAL)
        assertTrue(hits.all { !it.englishOnly })
    }

    @Test
    fun catalogMetaNamesEngineAndSize() {
        val model = LocalModelCatalog.find("tiny-q5_1")!!
        val meta = model.catalogMeta(recommended = true)
        assertTrue(meta.contains("MB"))
        assertTrue(meta.contains("Whisper"))
        assertTrue(meta.contains("recommended"))
    }
}
