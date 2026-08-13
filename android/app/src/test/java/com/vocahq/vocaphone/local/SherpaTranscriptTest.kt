package com.vocahq.vocaphone.local

import org.junit.Assert.assertEquals
import org.junit.Test

/** Mirrors the iOS client's `SherpaTranscriptTests`. */
class SherpaTranscriptTest {

    @Test
    fun `sense voice language tags become codes`() {
        assertEquals("en", SherpaTranscript.languageCode("<|en|>"))
        assertEquals("zh", SherpaTranscript.languageCode("<|zh|>"))
        assertEquals("yue", SherpaTranscript.languageCode("<|yue|>"))
        assertEquals("ja", SherpaTranscript.languageCode(" <|JA|> "))
        // A family that reports nothing is the common case, not an error.
        assertEquals("", SherpaTranscript.languageCode(""))
        assertEquals("", SherpaTranscript.languageCode(null))
    }

    @Test
    fun `anything not shaped like a language code is discarded`() {
        // Better no code than a wrong one: an unrecognized code would choose
        // punctuation with more confidence than the text-sniffing fallback.
        assertEquals("", SherpaTranscript.languageCode("<|nospeech|>"))
        assertEquals("", SherpaTranscript.languageCode("<|withitn|>"))
        assertEquals("", SherpaTranscript.languageCode("<|0|>"))
        assertEquals("", SherpaTranscript.languageCode("hello there"))
    }

    @Test
    fun `the first reported language survives the merge`() {
        val first = SherpaTranscript("你好", "zh")
        val second = SherpaTranscript("世界", "")
        assertEquals("zh", first.append(second, deduplicateOverlap = false).language)
        // A chunk that reported nothing does not erase what came before, and a
        // later report fills in for an earlier silence.
        assertEquals("zh", second.append(first, deduplicateOverlap = false).language)
    }

    @Test
    fun `merging still joins the text it always did`() {
        val merged = SherpaTranscript("hello there", "en")
            .append(SherpaTranscript("there world"), deduplicateOverlap = true)
        assertEquals("hello there world", merged.text)
    }
}
