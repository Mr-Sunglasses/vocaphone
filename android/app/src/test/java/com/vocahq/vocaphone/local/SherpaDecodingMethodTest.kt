package com.vocahq.vocaphone.local

import com.vocahq.vocaphone.core.TranscriptionQuality
import org.junit.Assert.assertEquals
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
    fun `only the transducer family may be asked for beam search`() {
        SherpaFamily.entries.forEach { family ->
            TranscriptionQuality.entries.forEach { quality ->
                val method = family.decodingMethod(quality)
                if (family == SherpaFamily.NEMO_TRANSDUCER) return@forEach
                assertEquals(
                    "$family must stay on greedy search at $quality",
                    SherpaFamily.GREEDY_SEARCH,
                    method,
                )
            }
        }
    }

    @Test
    fun `the transducer still widens its search when quality asks for it`() {
        assertEquals(
            "greedy_search",
            SherpaFamily.NEMO_TRANSDUCER.decodingMethod(TranscriptionQuality.FAST),
        )
        assertEquals(
            "modified_beam_search",
            SherpaFamily.NEMO_TRANSDUCER.decodingMethod(TranscriptionQuality.BALANCED),
        )
        assertEquals(
            "modified_beam_search",
            SherpaFamily.NEMO_TRANSDUCER.decodingMethod(TranscriptionQuality.ACCURATE),
        )
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
}
