package com.vocahq.vocaphone.audio

import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class PcmConversionTest {

    @Test
    fun `converts pcm16 to little endian float32`() {
        val samples = shortArrayOf(0, 16_384, -16_384, Short.MIN_VALUE)
        val bytes = PcmConversion.pcm16ToFloat32LittleEndian(samples)

        assertEquals(samples.size * 4, bytes.size)
        val buffer = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        assertEquals(0f, buffer.getFloat(), 0f)
        assertEquals(0.5f, buffer.getFloat(), 1e-6f)
        assertEquals(-0.5f, buffer.getFloat(), 1e-6f)
        assertEquals(-1f, buffer.getFloat(), 1e-6f)
    }

    @Test
    fun `converts only the requested sample count into a reused buffer`() {
        val scratch = ByteArray(64)
        val samples = shortArrayOf(16_384, 16_384, 0, 0)
        PcmConversion.pcm16ToFloat32LittleEndian(samples, count = 2, into = scratch)

        val buffer = ByteBuffer.wrap(scratch).order(ByteOrder.LITTLE_ENDIAN)
        assertEquals(0.5f, buffer.getFloat(), 1e-6f)
        assertEquals(0.5f, buffer.getFloat(), 1e-6f)
        // Everything past the requested count is left untouched.
        assertEquals(0f, buffer.getFloat(), 0f)
    }

    @Test
    fun `reports silence as zero and full scale as one`() {
        assertEquals(0f, PcmConversion.level(ShortArray(160)), 0f)
        assertEquals(0f, PcmConversion.level(ShortArray(0)), 0f)
        assertEquals(1f, PcmConversion.level(ShortArray(160) { Short.MIN_VALUE }), 1e-6f)
    }
}

class WavWriterTest {

    @get:Rule
    val folder = TemporaryFolder()

    @Test
    fun `writes a header a decoder can read`() {
        val header = WavWriter.header(dataLength = 320)
        val buffer = ByteBuffer.wrap(header).order(ByteOrder.LITTLE_ENDIAN)

        assertEquals("RIFF", String(header, 0, 4, Charsets.US_ASCII))
        assertEquals("WAVE", String(header, 8, 4, Charsets.US_ASCII))
        assertEquals("data", String(header, 36, 4, Charsets.US_ASCII))
        assertEquals(WavWriter.HEADER_BYTES, header.size)
        assertEquals(36 + 320, buffer.getInt(4))
        assertEquals(1, buffer.getShort(20).toInt())                       // PCM
        assertEquals(CaptureFormat.CHANNELS, buffer.getShort(22).toInt())
        assertEquals(CaptureFormat.SAMPLE_RATE, buffer.getInt(24))
        assertEquals(CaptureFormat.SAMPLE_RATE * 2, buffer.getInt(28))     // byte rate
        assertEquals(CaptureFormat.BITS_PER_SAMPLE, buffer.getShort(34).toInt())
        assertEquals(320, buffer.getInt(40))
    }

    @Test
    fun `patches the length fields when the recording is closed`() {
        val file = File(folder.root, "dictation.wav")
        val samples = ShortArray(CaptureFormat.SAMPLE_RATE) { it.toShort() }

        val writer = WavWriter(file)
        writer.write(samples)
        assertEquals(1000L, writer.durationMillis)
        writer.close()

        val bytes = file.readBytes()
        val expectedData = samples.size * CaptureFormat.BYTES_PER_SAMPLE
        assertEquals(WavWriter.HEADER_BYTES + expectedData, bytes.size)

        val buffer = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        assertEquals(36 + expectedData, buffer.getInt(4))
        assertEquals(expectedData, buffer.getInt(40))
    }

    @Test
    fun `writes samples little endian`() {
        val file = File(folder.root, "sample.wav")
        WavWriter(file).use { it.write(shortArrayOf(0x0102)) }

        val bytes = file.readBytes()
        assertEquals(0x02.toByte(), bytes[WavWriter.HEADER_BYTES])
        assertEquals(0x01.toByte(), bytes[WavWriter.HEADER_BYTES + 1])
        assertTrue(file.length() > WavWriter.HEADER_BYTES)
    }
}
