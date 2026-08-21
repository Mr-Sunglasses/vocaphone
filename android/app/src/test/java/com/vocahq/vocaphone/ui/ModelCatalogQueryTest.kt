package com.vocahq.vocaphone.ui

import com.vocahq.vocaphone.local.LocalModelCatalog
import com.vocahq.vocaphone.local.LocalModelEngine
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
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

    @Test
    fun recommendationWhyNamesTheFitWithoutHardware() {
        val moonshine = LocalModelCatalog.find("moonshine-tiny-en")!!
        val why = moonshine.recommendationWhy()
        assertTrue(why.contains("small English"))
        assertTrue(!why.contains("RAM"))
        assertTrue(!why.contains("GHz"))
        assertTrue(!why.contains("cores"))
        assertTrue(!why.contains("—"))
        val canary = LocalModelCatalog.find("canary-180m-flash")!!
        assertTrue(canary.recommendationWhy().contains("language"))
        val whisper = LocalModelCatalog.find("tiny-q5_1")!!
        assertTrue(whisper.recommendationWhy().contains("Whisper"))
        assertTrue(!whisper.recommendationWhy().contains("SHA-256"))
    }

    @Test
    fun setupMetaIsOnlySizeAndLanguages() {
        val model = LocalModelCatalog.find("tiny-q5_1")!!
        val meta = model.setupMeta()
        assertTrue(meta.contains("MB"))
        assertTrue(meta.contains(model.languages))
        assertTrue(!meta.contains("Whisper"))
        assertTrue(!meta.contains("RAM"))
        assertTrue(!meta.contains("GHz"))
        assertTrue(!meta.contains("cores"))
        assertTrue(!meta.contains("budget"))
        assertTrue(!meta.contains("SHA-256"))
    }

    @Test
    fun compactSetupDoesNotExposeTheCatalogUntilMoreModelsOpens() {
        val recommended = models.first()
        val available = models.drop(1)
        val closed = modelPickerSections(
            recommended = recommended,
            showRecommended = true,
            installed = emptyList(),
            available = available,
            compact = true,
            catalogOpen = false,
        )
        val open = modelPickerSections(
            recommended = recommended,
            showRecommended = true,
            installed = emptyList(),
            available = available,
            compact = true,
            catalogOpen = true,
        )

        assertTrue(models.size >= 30)
        assertTrue(!closed.showCatalog)
        assertTrue(closed.catalog.isEmpty())
        assertTrue(closed.recommended?.id == recommended.id)
        val withInstalled = modelPickerSections(
            recommended = recommended,
            showRecommended = true,
            installed = listOf(available.first()),
            available = available,
            compact = true,
            catalogOpen = false,
        )
        assertEquals(available.first().id, withInstalled.installed.single().id)
        assertTrue(withInstalled.catalog.isEmpty())
        assertTrue(open.showCatalog)
        assertTrue(open.catalog.size == available.size)
        assertTrue(open.catalog.size >= 30)
    }

    @Test
    fun settingsKeepsTheCatalogOnThePage() {
        val recommended = models.first()
        val available = models.drop(1)
        val sections = modelPickerSections(
            recommended = recommended,
            showRecommended = true,
            installed = emptyList(),
            available = available,
            compact = false,
            catalogOpen = false,
        )

        assertTrue(sections.showCatalog)
        assertTrue(sections.catalog.size == available.size)
    }

    @Test
    fun installedIncludesTheRecommendedModel() {
        val recommended = models.first()
        val extra = models.drop(1).first()
        val installed = pickerInstalledModels(
            candidates = listOf(recommended, extra),
            downloaded = setOf(recommended.id, extra.id),
        )

        assertEquals(listOf(recommended.id, extra.id), installed.map { it.id })
        assertTrue(installed.any { it.id == recommended.id })
    }

    @Test
    fun recommendedDownloadDoesNotAlsoShowTheBusyBanner() {
        val recommended = LocalModelCatalog.find("tiny-q5_1")!!

        assertFalse(
            showPickerBusyBanner(
                downloadingId = recommended.id,
                preparingName = null,
                recommended = recommended,
            ),
        )
        assertFalse(
            showPickerBusyBanner(
                downloadingId = null,
                preparingName = recommended.displayName,
                recommended = recommended,
            ),
        )
        assertTrue(
            showPickerBusyBanner(
                downloadingId = "large-v3-turbo-q5_0",
                preparingName = null,
                recommended = recommended,
            ),
        )
        assertFalse(showPickerBusyBanner(null, null, recommended))
    }
}
