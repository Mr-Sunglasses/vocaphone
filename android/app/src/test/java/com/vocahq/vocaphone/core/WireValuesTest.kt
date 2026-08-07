package com.vocahq.vocaphone.core

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * These literals are the gateway's contract, shared with the iOS client. A
 * rename here would silently change what the server transcribes.
 */
class WireValuesTest {

    @Test
    fun `writing styles match the server literals in order`() {
        assertEquals(
            listOf("raw", "clean", "formal", "casual", "very_casual", "excited"),
            WritingStyle.entries.map { it.wireValue },
        )
    }

    @Test
    fun `languages match the server literals in order`() {
        assertEquals(
            listOf(
                "auto", "ar", "as", "bn", "nl", "en", "fr", "de", "gu", "hi",
                "it", "ja", "kn", "ko", "ml", "zh", "mr", "ne", "pl", "pt",
                "pa", "ru", "es", "ta", "te", "uk", "ur", "vi",
            ),
            TranscriptionLanguage.entries.map { it.wireValue },
        )
    }

    @Test
    fun `unknown or missing values fall back to the gateway defaults`() {
        assertEquals(WritingStyle.CASUAL, WritingStyle.fromWire(null))
        assertEquals(WritingStyle.CASUAL, WritingStyle.fromWire("shouty"))
        assertEquals(WritingStyle.VERY_CASUAL, WritingStyle.fromWire("very_casual"))
        assertEquals(TranscriptionLanguage.AUTOMATIC, TranscriptionLanguage.fromWire(null))
        assertEquals(TranscriptionLanguage.AUTOMATIC, TranscriptionLanguage.fromWire("kl"))
        assertEquals(TranscriptionLanguage.UKRAINIAN, TranscriptionLanguage.fromWire("uk"))
    }

    @Test
    fun `short labels are the uppercased codes except automatic`() {
        assertEquals("Auto", TranscriptionLanguage.AUTOMATIC.shortLabel)
        assertEquals("ZH", TranscriptionLanguage.MANDARIN_CHINESE.shortLabel)
    }
}
