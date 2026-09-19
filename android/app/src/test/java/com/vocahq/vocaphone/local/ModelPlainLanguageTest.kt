package com.vocahq.vocaphone.local

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The picker leads with these words instead of the upstream model names, so a
 * catalog row without them would reach someone as "Parakeet TDT 0.6B" and
 * nothing else.
 */
class ModelPlainLanguageTest {

    @Test
    fun `every catalog model is explained and nothing else is`() {
        val catalog = LocalModelCatalog.all.map { it.id }.toSet()
        assertEquals(catalog, ModelPlainLanguage.byId.keys)
    }

    @Test
    fun `titles and summaries stay free of model jargon`() {
        val jargon = listOf("TDT", "CTC", "0.6B", "180M", "int8", "q8", "q5", "RAM", "WER")
        ModelPlainLanguage.byId.forEach { (id, plain) ->
            jargon.forEach { word ->
                assertFalse("$id title says $word", plain.title.contains(word))
                assertFalse("$id summary says $word", plain.summary.contains(word))
            }
            assertTrue("$id accuracy", plain.accuracy in 1..ModelPlainLanguage.MAXIMUM_RATING)
            assertTrue("$id speed", plain.speed in 1..ModelPlainLanguage.MAXIMUM_RATING)
        }
    }

    @Test
    fun `titles tell the models apart`() {
        val titles = ModelPlainLanguage.byId.values.map { it.title }
        assertEquals(titles.size, titles.toSet().size)
    }

    @Test
    fun `reported memory is rounded up to the size the phone was sold with`() {
        val gib = 1024L * 1024L * 1024L
        // What real phones report once the kernel and modem have taken theirs.
        assertEquals(4L, DeviceMemory.advertisedGB((3.6 * gib).toLong()))
        assertEquals(6L, DeviceMemory.advertisedGB((5.5 * gib).toLong()))
        assertEquals(8L, DeviceMemory.advertisedGB((7.3 * gib).toLong()))
        assertEquals(12L, DeviceMemory.advertisedGB((11.2 * gib).toLong()))
        assertEquals(8L, DeviceMemory.advertisedGB(8 * gib))
        assertEquals(0L, DeviceMemory.advertisedGB(0))
    }

    @Test
    fun `a zipformer transcript keeps the spaces its tokens carry`() {
        // The tokens sherpa-onnx 1.13.8 returns for the Korean model's own
        // test_wavs/1.wav; its `text` for the same decode has no spaces at all.
        val tokens = arrayOf(" 지하철", "에서", " 다리", "를", " 벌", "리고", " ", "앉", "지", " 마", "라", ".")
        assertEquals("지하철에서 다리를 벌리고 앉지 마라.", SherpaFamily.joinTokens(tokens))
    }

    @Test
    fun `only an all-capitals transcript is lower-cased`() {
        assertEquals("âm lượng tivi giảm", SherpaFamily.lowercasingCapitals("ÂM LƯỢNG TIVI GIẢM"))
        assertEquals("Call NASA today", SherpaFamily.lowercasingCapitals("Call NASA today"))
        assertEquals("지하철에서 다리를", SherpaFamily.lowercasingCapitals("지하철에서 다리를"))
        assertTrue(SherpaFamily.ZIPFORMER_TRANSDUCER.joinsTokens)
        assertFalse(SherpaFamily.NEMO_TRANSDUCER.joinsTokens)
    }

    @Test
    fun `vietnamese and korean get their specialists`() {
        assertEquals("zipformer-vi", LocalModelCatalog.starterForLanguage("vi")?.id)
        val korean = LocalModelCatalog.find("zipformer-ko")!!
        assertTrue(korean.coversLanguage("ko"))
        assertFalse(korean.coversLanguage("en"))
        assertEquals(SherpaFamily.ZIPFORMER_TRANSDUCER, korean.sherpaFamily)
    }
}
