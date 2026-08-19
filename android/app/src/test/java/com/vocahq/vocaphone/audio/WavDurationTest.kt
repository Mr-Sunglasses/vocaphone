package com.vocahq.vocaphone.audio

import java.io.ByteArrayInputStream
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The dictation start cue is played while the microphone opens, and the length
 * read here is what tells the capture loop how many frames to drop. A header
 * this cannot read reports 0, which sounds fine and quietly puts the chime back
 * in the transcript -- so the shipped cues are held to their real lengths.
 */
class WavDurationTest {
    private val rawDirectory = File("src/main/res/raw")

    private fun duration(name: String): Long =
        File(rawDirectory, name).inputStream().use { readWavDurationMillis(it) }

    @Test
    fun `reads the length of the shipped cues`() {
        // 9702 frames at 44100 Hz, and 26460, and 3528.
        assertEquals(220L, duration("dictation_tone_voca_start.wav"))
        assertEquals(600L, duration("dictation_tone_lift_start.wav"))
        assertEquals(80L, duration("dictation_tone_soft_start.wav"))
    }

    @Test
    fun `every shipped cue reports a length`() {
        val cues = rawDirectory.listFiles { file -> file.name.startsWith("dictation_tone_") }
        assertTrue("no cues found in $rawDirectory", !cues.isNullOrEmpty())
        for (cue in cues!!) {
            val millis = cue.inputStream().use { readWavDurationMillis(it) }
            assertTrue("${cue.name} reported ${millis}ms", millis in 50..1000)
        }
    }

    @Test
    fun `walks past a chunk that sits before the data`() {
        // 100 frames of 16-bit mono at 8000 Hz is 12 ms, behind a LIST chunk
        // that the parser has to skip rather than read as audio.
        val wav = wav(sampleRate = 8000, frames = 100, extraChunk = "LIST" to 10)
        assertEquals(12L, readWavDurationMillis(ByteArrayInputStream(wav)))
    }

    @Test
    fun `skips a padded odd-sized chunk`() {
        val wav = wav(sampleRate = 8000, frames = 100, extraChunk = "LIST" to 7)
        assertEquals(12L, readWavDurationMillis(ByteArrayInputStream(wav)))
    }

    @Test
    fun `reports zero for something that is not a wav`() {
        assertEquals(0L, readWavDurationMillis(ByteArrayInputStream(ByteArray(64))))
    }

    @Test
    fun `reports zero for a truncated header`() {
        val truncated = wav(sampleRate = 8000, frames = 100).copyOf(20)
        assertEquals(0L, readWavDurationMillis(ByteArrayInputStream(truncated)))
    }

    /** A minimal 16-bit mono RIFF file, optionally with a chunk before `data`. */
    private fun wav(
        sampleRate: Int,
        frames: Int,
        extraChunk: Pair<String, Int>? = null,
    ): ByteArray {
        val out = java.io.ByteArrayOutputStream()
        fun ascii(text: String) = out.write(text.toByteArray(Charsets.US_ASCII))
        fun int32(value: Int) = out.write(
            byteArrayOf(
                value.toByte(),
                (value shr 8).toByte(),
                (value shr 16).toByte(),
                (value shr 24).toByte(),
            ),
        )
        fun int16(value: Int) = out.write(byteArrayOf(value.toByte(), (value shr 8).toByte()))

        val dataBytes = frames * 2
        ascii("RIFF"); int32(0); ascii("WAVE")
        ascii("fmt "); int32(16)
        int16(1); int16(1); int32(sampleRate); int32(sampleRate * 2); int16(2); int16(16)
        if (extraChunk != null) {
            val (id, size) = extraChunk
            ascii(id); int32(size)
            // Odd sizes carry a pad byte the parser also has to step over.
            out.write(ByteArray(size + (size and 1)))
        }
        ascii("data"); int32(dataBytes)
        out.write(ByteArray(dataBytes))
        return out.toByteArray()
    }
}
