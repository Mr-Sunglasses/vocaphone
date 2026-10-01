package com.vocahq.vocaphone.gateway

import com.vocahq.vocaphone.audio.WavWriter
import java.io.File
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class GatewayUploadAudioTest {
    @get:Rule val folder = TemporaryFolder()

    @Test fun `smaller copy is disposable and the original stays byte identical`() = runBlocking {
        val source = recording(folder.root)
        val original = source.readBytes()
        val scratch = folder.newFolder()
        val prepared = GatewayUploadAudio.prepare(source, scratch, fakeEncoder)
        assertEquals("audio/mp4", prepared.contentType.toString())
        assertArrayEquals(encodedBytes, prepared.file.readBytes())
        assertTrue(prepared.file.length() < source.length())
        prepared.close()
        assertTrue(scratch.listFiles()!!.isEmpty())
        assertArrayEquals(original, source.readBytes())
    }

    @Test fun `larger container and encoding failure fall back without leaking files`() = runBlocking {
        val source = recording(folder.root)
        val original = source.readBytes()
        val scratch = folder.newFolder()
        val encoders = listOf(
            GatewayUploadAudio.Encoder { input, output, _ -> output.writeBytes(ByteArray(input.length().toInt() + 1)) },
            GatewayUploadAudio.Encoder { _, output, _ -> output.writeBytes(encodedBytes); throw IOException("codec failed") },
        )
        for (encoder in encoders) {
            GatewayUploadAudio.prepare(source, scratch, encoder).use { prepared ->
                assertEquals(source, prepared.file)
                assertEquals("audio/wav", prepared.contentType.toString())
            }
            assertTrue(scratch.listFiles()!!.isEmpty())
            assertArrayEquals(original, source.readBytes())
        }
    }

    @Test fun `unfamiliar WAV and existing M4A never enter the encoder`() = runBlocking {
        val encoder = GatewayUploadAudio.Encoder { _, _, _ -> error("Unexpected transcode") }
        for (extension in listOf("wav", "m4a")) {
            val source = File(folder.root, "legacy.$extension").apply { writeBytes(byteArrayOf(1, 2, 3)) }
            GatewayUploadAudio.prepare(source, folder.newFolder(), encoder).use {
                assertEquals(source, it.file)
                assertEquals(if (extension == "wav") "audio/wav" else "audio/mp4", it.contentType.toString())
            }
            assertArrayEquals(byteArrayOf(1, 2, 3), source.readBytes())
        }
    }

    @Test fun `cancellation after a partial file exists removes it and propagates`() = runBlocking {
        val source = recording(folder.root)
        val original = source.readBytes()
        val scratch = folder.newFolder()
        val created = CountDownLatch(1)
        val encoding = launch(Dispatchers.IO) {
            GatewayUploadAudio.prepare(source, scratch, GatewayUploadAudio.Encoder { _, output, check ->
                output.writeBytes(encodedBytes)
                created.countDown()
                while (true) { check(); Thread.sleep(1) }
            }).use { error("Cancelled encoding returned a copy") }
        }
        assertTrue(created.await(5, TimeUnit.SECONDS))
        assertFalse(scratch.listFiles()!!.isEmpty())
        encoding.cancelAndJoin()
        assertTrue(encoding.isCancelled)
        assertTrue(scratch.listFiles()!!.isEmpty())
        assertArrayEquals(original, source.readBytes())
    }

    @Test fun `read validation rejects truncated and non-mono capture`() {
        val source = recording(folder.root)
        assertEquals(32_000L, GatewayUploadAudio.pcmLength(source))
        source.appendBytes(byteArrayOf(0))
        assertEquals(null, GatewayUploadAudio.pcmLength(source))
        source.writeBytes(WavWriter.header(4, channels = 2) + ByteArray(4))
        assertEquals(null, GatewayUploadAudio.pcmLength(source))
    }

    companion object {
        // Deterministic test encoder output; real MediaCodec output is covered
        // by the device test, not simulated by the host JVM's Android stubs.
        val encodedBytes = ByteArray(256) { (it % 251).toByte() }
        val fakeEncoder = GatewayUploadAudio.Encoder { _, output, check -> check(); output.writeBytes(encodedBytes) }

        fun recording(directory: File): File = File(directory, "capture.wav").also { file ->
            WavWriter(file).use { writer -> writer.write(ShortArray(16_000) { (it % 8_000).toShort() }) }
        }
    }
}
