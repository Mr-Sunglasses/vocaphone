package io.github.mrsunglasses.localflow.core

import org.junit.Assert.assertEquals
import org.junit.Test

class TranscriptSanitizerTest {

    @Test
    fun `a whisper silence marker never reaches the field`() {
        // Exactly what whisper.cpp returned for a near-silent recording on a Pixel.
        assertEquals("", TranscriptSanitizer.clean("[BLANK_AUDIO]"))
        assertEquals("", TranscriptSanitizer.clean("  [BLANK_AUDIO]  "))
        assertEquals("", TranscriptSanitizer.clean("[ blank_audio ]"))
        assertEquals("", TranscriptSanitizer.clean("[SILENCE]"))
        assertEquals("", TranscriptSanitizer.clean("(inaudible)"))
    }

    @Test
    fun `markers are stripped from around real speech`() {
        assertEquals(
            "Hey, we are using local flow app",
            TranscriptSanitizer.clean("[BLANK_AUDIO] Hey, we are using local flow app"),
        )
        assertEquals(
            "Hello there",
            TranscriptSanitizer.clean("Hello [NOISE] there"),
        )
        assertEquals(
            "Good morning",
            TranscriptSanitizer.clean("[MUSIC] Good morning [APPLAUSE]"),
        )
    }

    @Test
    fun `brackets the user actually dictated are left alone`() {
        assertEquals("It cost [1,200]", TranscriptSanitizer.clean("It cost [1,200]"))
        assertEquals("Ship it (see below)", TranscriptSanitizer.clean("Ship it (see below)"))
        assertEquals("Call me (soon)", TranscriptSanitizer.clean("Call me (soon)"))
    }

    @Test
    fun `line structure from the writing style survives`() {
        assertEquals("First line\nSecond line", TranscriptSanitizer.clean("First line\n[NOISE] Second line"))
    }

    @Test
    fun `blank input stays blank`() {
        assertEquals("", TranscriptSanitizer.clean(null))
        assertEquals("", TranscriptSanitizer.clean("   "))
    }
}
