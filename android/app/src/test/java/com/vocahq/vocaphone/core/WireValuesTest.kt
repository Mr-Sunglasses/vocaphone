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
                "auto", "ar", "as", "bn", "bg", "yue", "ca", "hr", "cs", "da",
                "nl", "en", "et", "tl", "fi", "fr", "de", "el", "gu", "he",
                "hi", "hinglish_roman", "hu", "id", "it", "ja", "kn", "ko", "lv", "lt",
                "ms",
                "ml", "mt", "zh", "mr", "ne", "no", "fa", "pl", "pt", "pa",
                "ro", "ru", "sr", "sk", "sl", "es", "sw", "sv", "ta", "te",
                "th", "tr", "uk", "ur", "vi",
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
