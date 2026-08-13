package com.vocahq.vocaphone.core

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
            "Hey, we are using vocaphone app",
            TranscriptSanitizer.clean("[BLANK_AUDIO] Hey, we are using vocaphone app"),
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

    @Test
    fun `a repeated phrase collapses to one copy`() {
        assertEquals(
            "Thank you.",
            TranscriptSanitizer.clean("Thank you. Thank you. Thank you. Thank you."),
        )
        assertEquals(
            "Let me know Ship it tomorrow",
            TranscriptSanitizer.clean("Let me know Let me know Let me know Ship it tomorrow"),
        )
    }

    @Test
    fun `a repeated single word keeps the emphasis it may have carried`() {
        assertEquals("no no", TranscriptSanitizer.clean("no no no no no no"))
        // Three is within what a person says, so it is left exactly as dictated.
        assertEquals("no no no", TranscriptSanitizer.clean("no no no"))
    }

    @Test
    fun `ordinary prose with repeated words is not collapsed`() {
        val sentence = "I think that that meeting was the one we moved"
        assertEquals(sentence, TranscriptSanitizer.clean(sentence))
        val listing = "one two three four five six seven eight"
        assertEquals(listing, TranscriptSanitizer.clean(listing))
    }

    @Test
    fun `a loop is matched across the punctuation that differs between copies`() {
        assertEquals(
            "Okay then,",
            TranscriptSanitizer.clean("Okay then, okay then. Okay then!"),
        )
        // The single-word rule still keeps two, whatever the punctuation was.
        assertEquals("Okay, okay.", TranscriptSanitizer.clean("Okay, okay. Okay! okay,"))
    }
}
