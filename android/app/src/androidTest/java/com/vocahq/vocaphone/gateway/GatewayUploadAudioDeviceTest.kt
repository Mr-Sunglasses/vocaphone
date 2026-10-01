package com.vocahq.vocaphone.gateway

import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.vocahq.vocaphone.audio.WavWriter
import java.io.File
import java.nio.ByteOrder
import java.util.UUID
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/** Exercises Android's real AAC encoder/muxer/decoder, which host stubs cannot. */
@RunWith(AndroidJUnit4::class)
class GatewayUploadAudioDeviceTest {
    @Test fun encodedAudioDecodesThroughTheFinalToneAndCleansUp() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val directory = File(context.cacheDir, "gateway-codec-test-${UUID.randomUUID()}")
        assertTrue(directory.mkdirs())
        try {
            val source = File(directory, "capture.wav")
            WavWriter(source).use { writer ->
                writer.write(ShortArray(160_000) { index ->
                    val time = index / 16_000.0
                    val frequency = if (time > 9.75) 880 else 440
                    if (time > 9.5 && time < 9.75) 0
                    else (kotlin.math.sin(time * 2 * Math.PI * frequency) * 13_000).toInt().toShort()
                })
            }
            val original = source.readBytes()
            val scratch = File(directory, "scratch")
            val prepared = GatewayUploadAudio.prepare(source, scratch)
            try {
                assertEquals("m4a", prepared.file.extension)
                assertTrue(prepared.file.length() < source.length() / 3)
                val (samples, tailEnergy) = decode(prepared.file)
                assertTrue(kotlin.math.abs(samples - 160_000) < 4_096)
                assertTrue("The final tone was not flushed", tailEnergy > 0.01)
            } finally { prepared.close() }
            assertTrue(scratch.listFiles()!!.isEmpty())
            assertArrayEquals(original, source.readBytes())
        } finally { directory.deleteRecursively() }
    }

    private fun decode(file: File): Pair<Int, Double> {
        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(file.path)
            assertEquals(1, extractor.trackCount)
            val format = extractor.getTrackFormat(0)
            assertEquals(MediaFormat.MIMETYPE_AUDIO_AAC, format.getString(MediaFormat.KEY_MIME))
            assertEquals(16_000, format.getInteger(MediaFormat.KEY_SAMPLE_RATE))
            assertEquals(1, format.getInteger(MediaFormat.KEY_CHANNEL_COUNT))
            format.setInteger(MediaFormat.KEY_PCM_ENCODING, AudioFormat.ENCODING_PCM_16BIT)
            extractor.selectTrack(0)
            val decoder = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
            try {
                decoder.configure(format, null, null, 0)
                decoder.start()
                val info = MediaCodec.BufferInfo()
                var inputEnded = false
                var outputEnded = false
                var sampleCount = 0
                val tail = ArrayDeque<Double>()
                val deadline = System.nanoTime() + 30_000_000_000L
                while (!outputEnded) {
                    check(System.nanoTime() < deadline) { "AAC decoder stalled" }
                    if (!inputEnded) {
                        val index = decoder.dequeueInputBuffer(10_000)
                        if (index >= 0) {
                            val buffer = checkNotNull(decoder.getInputBuffer(index))
                            buffer.clear()
                            val size = extractor.readSampleData(buffer, 0)
                            if (size < 0) {
                                decoder.queueInputBuffer(index, 0, 0, 10_000_000, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                                inputEnded = true
                            } else {
                                decoder.queueInputBuffer(index, 0, size, extractor.sampleTime, 0)
                                extractor.advance()
                            }
                        }
                    }
                    val index = decoder.dequeueOutputBuffer(info, 10_000)
                    if (index >= 0) {
                        try {
                            val buffer = checkNotNull(decoder.getOutputBuffer(index)).order(ByteOrder.LITTLE_ENDIAN)
                            buffer.position(info.offset)
                            buffer.limit(info.offset + info.size)
                            while (buffer.remaining() >= 2) {
                                val sample = buffer.short / 32_768.0
                                sampleCount++
                                tail.addLast(sample * sample)
                                if (tail.size > 2_000) tail.removeFirst()
                            }
                            outputEnded = info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                        } finally { decoder.releaseOutputBuffer(index, false) }
                    }
                }
                return sampleCount to tail.average()
            } finally {
                runCatching { decoder.stop() }
                decoder.release()
            }
        } finally { extractor.release() }
    }
}
