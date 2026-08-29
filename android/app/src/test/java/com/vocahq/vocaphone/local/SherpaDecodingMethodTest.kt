package com.vocahq.vocaphone.local

import com.vocahq.vocaphone.core.TranscriptionQuality
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * sherpa-onnx answers an unsupported decoding method with `exit(-1)`, so a
 * wrong value here is not a bad transcript — it is the app, or the keyboard,
 * disappearing. These are the tests that keep a quality setting from ever
 * reaching a family that cannot survive it.
 */
class SherpaDecodingMethodTest {

    @Test
    fun `every bundled family stays on its stable greedy decoder`() {
        SherpaFamily.entries.forEach { family ->
            TranscriptionQuality.entries.forEach { quality ->
                val method = family.decodingMethod(quality)
                assertEquals(
                    "$family must stay on greedy search at $quality",
                    SherpaFamily.GREEDY_SEARCH,
                    method,
                )
            }
        }
    }

    @Test
    fun `parakeet never enters the unstable NeMo TDT beam decoder`() {
        TranscriptionQuality.entries.forEach { quality ->
            assertEquals(
                "greedy_search",
                SherpaFamily.NEMO_TRANSDUCER.decodingMethod(quality),
            )
        }
    }

    @Test
    fun `parakeet enables the upstream empty-result dither workaround`() {
        assertEquals(0.00003f, SherpaFamily.NEMO_TRANSDUCER.featureDither, 0f)
        SherpaFamily.entries
            .filterNot { it == SherpaFamily.NEMO_TRANSDUCER }
            .forEach { family -> assertEquals(0f, family.featureDither, 0f) }
    }

    @Test
    fun `every model in the catalog resolves to a method its family survives`() {
        val sherpaModels = LocalModelCatalog.all.filter { it.engine == LocalModelEngine.SHERPA_ONNX }
        assertTrue("the catalog should still ship sherpa models", sherpaModels.isNotEmpty())
        sherpaModels.forEach { model ->
            val family = requireNotNull(model.sherpaFamily) { "${model.id} has no family" }
            TranscriptionQuality.entries.forEach { quality ->
                val method = family.decodingMethod(quality)
                assertTrue(
                    "${model.id} would be sent $method, which $family cannot accept",
                    method == SherpaFamily.GREEDY_SEARCH || family.supportsBeamSearch,
                )
            }
        }
    }

    /**
     * The accuracy control reaches `decodingMethod` and `maxActivePaths`, and
     * greedy search reads neither. Letting it stay part of the loaded identity
     * rebuilds a several-hundred-megabyte graph to produce an identical one.
     */
    @Test
    fun `a greedy family builds the same recognizer at every accuracy setting`() {
        for (family in SherpaFamily.entries) {
            assertFalse(family.nativeConfigVariesWithQuality)
            for (quality in TranscriptionQuality.entries) {
                assertEquals(TranscriptionQuality.DEFAULT, family.effectiveQuality(quality))
            }
        }
    }

    @Test
    fun `changing accuracy alone does not reload a sherpa engine`() {
        for (quality in TranscriptionQuality.entries) {
            val effective = SherpaFamily.NEMO_TRANSDUCER.effectiveQuality(quality)
            assertFalse(
                shouldReloadLocalEngine(
                    engine = LocalModelEngine.SHERPA_ONNX,
                    loadedModelID = "parakeet",
                    requestedModelID = "parakeet",
                    loadedLanguage = "en",
                    requestedLanguage = "en",
                    loadedQuality = SherpaFamily.NEMO_TRANSDUCER
                        .effectiveQuality(TranscriptionQuality.FAST),
                    requestedQuality = effective,
                    languageIsBakedIn = false,
                ),
            )
        }
    }

    /** Everything else still invalidates it. */
    @Test
    fun `a different model still reloads`() {
        assertTrue(
            shouldReloadLocalEngine(
                engine = LocalModelEngine.SHERPA_ONNX,
                loadedModelID = "parakeet",
                requestedModelID = "canary",
                loadedLanguage = "en",
                requestedLanguage = "en",
                loadedQuality = TranscriptionQuality.DEFAULT,
                requestedQuality = TranscriptionQuality.DEFAULT,
            ),
        )
    }
}
