package com.vocahq.vocaphone.local

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assume.assumeTrue
import org.junit.BeforeClass
import org.junit.Test

/**
 * The native side of [WhisperLib.getText]: segments joined as bytes in C, by
 * the same `joined_segment_text` the app runs on whisper's own segments.
 * [WhisperTextTest] covers the Kotlin decode; this covers what reaches it.
 *
 * Needs the host build of the whisper library, so it is skipped unless
 * `vocaphone.whisperLibrary` points at one. `just android model-test` builds
 * it and runs this.
 */
class WhisperSegmentTextTest {

    @Test
    fun `a character split across segments arrives whole`() {
        val bytes = "कुछ पुराने".toByteArray(Charsets.UTF_8)
        // The first byte of a three-byte character ends the first segment.
        val split = bytes.indexOfFirst { it == 0xE0.toByte() } + 1
        val joined = join(arrayOf(bytes.copyOfRange(0, split), bytes.copyOfRange(split, bytes.size)))
        assertArrayEquals(bytes, joined)
        assertEquals("कुछ पुराने", WhisperText.decode(joined))
    }

    @Test
    fun `every segment is kept in order`() {
        val segments = listOf(" Hello,", " world.", "", " नमस्ते")
        val joined = join(segments.map { it.toByteArray(Charsets.UTF_8) }.toTypedArray())
        assertArrayEquals(segments.joinToString("").toByteArray(Charsets.UTF_8), joined)
    }

    @Test
    fun `no segments is no text`() {
        assertArrayEquals(ByteArray(0), join(emptyArray()))
    }

    companion object {
        @JvmStatic
        @BeforeClass
        fun loadLibrary() {
            assumeTrue(
                "host whisper library not built; run just android model-test",
                runCatching { System.loadLibrary("whisper") }.isSuccess,
            )
        }

        /** Joins `segments` with `joined_segment_text` (src/test/cpp/segment_text_test.c). */
        external fun join(segments: Array<ByteArray>): ByteArray
    }
}
