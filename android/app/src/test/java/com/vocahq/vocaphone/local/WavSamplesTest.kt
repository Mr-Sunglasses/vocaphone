package com.vocahq.vocaphone.local

import com.vocahq.vocaphone.audio.WavWriter
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Test

class WavSamplesTest {

    @Test
    fun `the capture WAV reads back sample for sample across read blocks`() {
        val file = File.createTempFile("vocaphone-capture", ".wav")
        try {
            // Several 64 KiB blocks and a ragged tail.
            val samples = ShortArray(100_003) { index -> ((index * 37) % 65_536 - 32_768).toShort() }
            WavWriter(file).use { writer ->
                writer.write(samples.copyOfRange(0, 1_600))
                writer.write(samples.copyOfRange(1_600, samples.size))
            }

            val read = readPcm16WavSamples(file)

            assertEquals(samples.size, read.size)
            for (index in samples.indices) {
                assertEquals(samples[index] / 32_768f, read[index], 0f)
            }
        } finally {
            file.delete()
        }
    }
}
