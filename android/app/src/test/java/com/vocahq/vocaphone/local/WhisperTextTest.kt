package com.vocahq.vocaphone.local

import org.junit.Assert.assertEquals
import org.junit.Test

class WhisperTextTest {

    /**
     * whisper.cpp splits segments between tokens, so "पुराने" can arrive as
     * two segments that each hold half of "ु". Joined as bytes it is whole.
     */
    @Test
    fun `a character split across segments is one character again`() {
        val bytes = "कुछ पुराने".toByteArray(Charsets.UTF_8)
        val split = bytes.indexOfFirst { it == 0xE0.toByte() } + 1
        val segments = listOf(bytes.copyOfRange(0, split), bytes.copyOfRange(split, bytes.size))
        assertEquals("कुछ पुराने", WhisperText.decode(segments.reduce(ByteArray::plus)))
    }

    /** A decode that stopped mid-character leaves nothing to type for it. */
    @Test
    fun `a character cut off at the end is dropped`() {
        val bytes = "स्क्रे".toByteArray(Charsets.UTF_8)
        assertEquals("स्क्र", WhisperText.decode(bytes.copyOfRange(0, bytes.size - 1)))
    }

    @Test
    fun `plain text passes through`() {
        assertEquals(" Hello, world.", WhisperText.decode(" Hello, world.".toByteArray()))
    }
}
