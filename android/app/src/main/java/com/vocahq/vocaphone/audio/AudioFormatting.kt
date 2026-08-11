package com.vocahq.vocaphone.audio

import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** The one capture format: what the gateway normalizes to anyway. */
object CaptureFormat {
    const val SAMPLE_RATE = 16_000
    const val CHANNELS = 1
    const val BITS_PER_SAMPLE = 16
    const val BYTES_PER_SAMPLE = BITS_PER_SAMPLE / 8
}

object PcmConversion {

    /**
     * Converts PCM16 samples to the little-endian float32 frames `/v1/stream`
     * expects. Reuses [into] so the capture loop never allocates per frame.
     */
    fun pcm16ToFloat32LittleEndian(
        samples: ShortArray,
        count: Int = samples.size,
        into: ByteArray = ByteArray(count * 4),
    ): ByteArray {
        require(into.size >= count * 4) { "The output buffer is too small for $count samples." }
        val buffer = ByteBuffer.wrap(into).order(ByteOrder.LITTLE_ENDIAN)
        for (index in 0 until count) {
            buffer.putFloat(samples[index] / 32_768f)
        }
        return into
    }

    /** The loudest absolute sample in a frame, 0…32768. */
    fun peak(samples: ShortArray, count: Int = samples.size): Int {
        var peak = 0
        for (index in 0 until count) {
            val magnitude = kotlin.math.abs(samples[index].toInt())
            if (magnitude > peak) peak = magnitude
        }
        return peak
    }

    /** Root-mean-square amplitude in 0…1, for the recording meter only. */
    fun level(samples: ShortArray, count: Int = samples.size): Float {
        if (count <= 0) return 0f
        var sum = 0.0
        for (index in 0 until count) {
            val value = samples[index] / 32_768.0
            sum += value * value
        }
        return kotlin.math.sqrt(sum / count).toFloat().coerceIn(0f, 1f)
    }
}

/**
 * Android hands an app whose microphone another app has taken a stream of exact
 * zeros and reports nothing at all — no error, no callback on some devices. A
 * working microphone always has a noise floor, so a whole recording this quiet
 * is that silencing rather than a quiet room, and saying so beats reporting an
 * empty transcript the user cannot act on.
 */
object SilentCapture {
    /** Two least-significant bits: below any noise floor, above a dithered zero. */
    const val PEAK_THRESHOLD = 2

    fun heardSomething(peak: Int): Boolean = peak > PEAK_THRESHOLD
}

/**
 * Writes a complete WAV file while recording, so a dictation that fails to
 * stream can still be uploaded and retried.
 */
class WavWriter(private val file: File) : AutoCloseable {

    private val output = RandomAccessFile(file, "rw").apply {
        setLength(0)
        write(header(dataLength = 0))
    }
    private var dataLength = 0

    fun write(samples: ShortArray, count: Int = samples.size) {
        val bytes = ByteArray(count * CaptureFormat.BYTES_PER_SAMPLE)
        val buffer = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        for (index in 0 until count) buffer.putShort(samples[index])
        output.write(bytes)
        dataLength += bytes.size
    }

    val durationMillis: Long
        get() = dataLength.toLong() * 1000 /
            (CaptureFormat.SAMPLE_RATE * CaptureFormat.CHANNELS * CaptureFormat.BYTES_PER_SAMPLE)

    /** Patches the two length fields, leaving a file any decoder can read. */
    override fun close() {
        runCatching {
            output.seek(0)
            output.write(header(dataLength))
        }
        runCatching { output.close() }
    }

    companion object {
        const val HEADER_BYTES = 44

        fun header(
            dataLength: Int,
            sampleRate: Int = CaptureFormat.SAMPLE_RATE,
            channels: Int = CaptureFormat.CHANNELS,
            bitsPerSample: Int = CaptureFormat.BITS_PER_SAMPLE,
        ): ByteArray {
            val byteRate = sampleRate * channels * bitsPerSample / 8
            val blockAlign = channels * bitsPerSample / 8
            return ByteBuffer.allocate(HEADER_BYTES).order(ByteOrder.LITTLE_ENDIAN).apply {
                put("RIFF".toByteArray(Charsets.US_ASCII))
                putInt(36 + dataLength)
                put("WAVE".toByteArray(Charsets.US_ASCII))
                put("fmt ".toByteArray(Charsets.US_ASCII))
                putInt(16)
                putShort(1)                       // PCM, uncompressed
                putShort(channels.toShort())
                putInt(sampleRate)
                putInt(byteRate)
                putShort(blockAlign.toShort())
                putShort(bitsPerSample.toShort())
                put("data".toByteArray(Charsets.US_ASCII))
                putInt(dataLength)
            }.array()
        }
    }
}
