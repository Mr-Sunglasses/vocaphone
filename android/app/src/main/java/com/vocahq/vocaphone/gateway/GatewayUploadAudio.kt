package com.vocahq.vocaphone.gateway

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import com.vocahq.vocaphone.audio.CaptureFormat
import com.vocahq.vocaphone.audio.WavWriter
import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import okhttp3.MediaType
import okhttp3.MediaType.Companion.toMediaType

/** Disposable upload copy. The session WAV is kept intact for retry/local decoding. */
class GatewayUploadAudio private constructor(
    val file: File,
    val contentType: MediaType,
    private val temporaryDirectory: File? = null,
) : AutoCloseable {
    override fun close() { temporaryDirectory?.deleteRecursively() }

    fun interface Encoder {
        fun encode(source: File, destination: File, checkCancellation: () -> Unit)
    }

    companion object {
        private val MP4_MEDIA_TYPE = "audio/mp4".toMediaType()

        suspend fun prepare(
            source: File,
            temporaryRoot: File? = null,
            encoder: Encoder = Encoder(::encodeAAC),
        ): GatewayUploadAudio {
            var prepared: GatewayUploadAudio? = null
            try {
                return withContext(Dispatchers.IO) {
                    val context = currentCoroutineContext()
                    context.ensureActive()
                    val original = GatewayUploadAudio(
                        source,
                        if (source.extension.equals("m4a", true)) MP4_MEDIA_TYPE else GatewayClient.WAV_MEDIA_TYPE,
                    )
                    if (!source.extension.equals("wav", true) || pcmLength(source) == null) {
                        return@withContext original
                    }
                    val directory = File(temporaryRoot ?: source.parentFile, "gateway-upload-${UUID.randomUUID()}")
                    val destination = File(directory, "upload.m4a")
                    try {
                        if (!directory.mkdirs()) throw IOException("Cannot create upload directory.")
                        encoder.encode(source, destination) { context.ensureActive() }
                        context.ensureActive()
                        if (destination.length() <= 0 || destination.length() >= source.length()) {
                            directory.deleteRecursively()
                            original
                        } else {
                            GatewayUploadAudio(destination, MP4_MEDIA_TYPE, directory).also { prepared = it }
                        }
                    } catch (error: Exception) {
                        directory.deleteRecursively()
                        context.ensureActive()
                        if (error is CancellationException) throw error
                        original
                    }
                }
            } catch (error: CancellationException) {
                // withContext can discard a finished result when its caller is
                // cancelled just before dispatching back. It must still be deleted.
                prepared?.close()
                throw error
            }
        }

        /** Only the canonical capture WAV is transcoded; unfamiliar files stay intact. */
        internal fun pcmLength(source: File): Long? = runCatching {
            RandomAccessFile(source, "r").use { input ->
                val header = ByteArray(WavWriter.HEADER_BYTES)
                input.readFully(header)
                val fields = ByteBuffer.wrap(header).order(ByteOrder.LITTLE_ENDIAN)
                val length = fields.getInt(40).toLong() and 0xffff_ffffL
                val valid = String(header, 0, 4, Charsets.US_ASCII) == "RIFF" &&
                    String(header, 8, 8, Charsets.US_ASCII) == "WAVEfmt " &&
                    String(header, 36, 4, Charsets.US_ASCII) == "data" &&
                    fields.getInt(16) == 16 && fields.getShort(20).toInt() == 1 &&
                    fields.getShort(22).toInt() == CaptureFormat.CHANNELS &&
                    fields.getInt(24) == CaptureFormat.SAMPLE_RATE &&
                    fields.getInt(28) == CaptureFormat.SAMPLE_RATE * CaptureFormat.BYTES_PER_SAMPLE &&
                    fields.getShort(32).toInt() == CaptureFormat.BYTES_PER_SAMPLE &&
                    fields.getShort(34).toInt() == CaptureFormat.BITS_PER_SAMPLE &&
                    (fields.getInt(4).toLong() and 0xffff_ffffL) == input.length() - 8 &&
                    length > 0 && length % 2 == 0L && length + header.size == input.length() &&
                    input.length() <= 25 * 1_024 * 1_024L
                length.takeIf { valid }
            }
        }.getOrNull()

        private fun encodeAAC(source: File, destination: File, checkCancellation: () -> Unit) {
            val length = pcmLength(source) ?: throw IOException("Unsupported capture format.")
            val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
            try {
                val format = MediaFormat.createAudioFormat(
                    MediaFormat.MIMETYPE_AUDIO_AAC, CaptureFormat.SAMPLE_RATE, CaptureFormat.CHANNELS,
                ).apply {
                    setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
                    setInteger(MediaFormat.KEY_BIT_RATE, 48_000)
                    setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 8_192)
                }
                codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                codec.start()
                val muxer = MediaMuxer(destination.path, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
                try {
                    RandomAccessFile(source, "r").use { input ->
                        input.seek(WavWriter.HEADER_BYTES.toLong())
                        val bytes = ByteArray(8_192)
                        val info = MediaCodec.BufferInfo()
                        var consumed = 0L
                        var inputEnded = false
                        var outputEnded = false
                        var track = -1
                        var packets = 0
                        var lastProgress = System.nanoTime()
                        while (!outputEnded) {
                            checkCancellation()
                            if (!inputEnded) {
                                val index = codec.dequeueInputBuffer(10_000)
                                if (index >= 0) {
                                    val buffer = checkNotNull(codec.getInputBuffer(index))
                                    buffer.clear()
                                    val count = minOf(length - consumed, bytes.size.toLong(), buffer.remaining().toLong()).toInt() and -2
                                    val timestamp = consumed / CaptureFormat.BYTES_PER_SAMPLE * 1_000_000 / CaptureFormat.SAMPLE_RATE
                                    if (consumed == length) {
                                        codec.queueInputBuffer(index, 0, 0, timestamp, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                                        inputEnded = true
                                    } else {
                                        if (count == 0) throw IOException("AAC input buffer is too small.")
                                        input.readFully(bytes, 0, count)
                                        buffer.put(bytes, 0, count)
                                        codec.queueInputBuffer(index, 0, count, timestamp, 0)
                                        consumed += count
                                    }
                                    lastProgress = System.nanoTime()
                                }
                            }
                            val index = codec.dequeueOutputBuffer(info, 10_000)
                            if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                                check(track == -1)
                                check(codec.outputFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE) == CaptureFormat.SAMPLE_RATE)
                                check(codec.outputFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT) == CaptureFormat.CHANNELS)
                                track = muxer.addTrack(codec.outputFormat)
                                muxer.start()
                                lastProgress = System.nanoTime()
                            } else if (index >= 0) {
                                try {
                                    if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0 && info.size > 0) {
                                        check(track >= 0)
                                        val buffer = checkNotNull(codec.getOutputBuffer(index))
                                        buffer.position(info.offset)
                                        buffer.limit(info.offset + info.size)
                                        muxer.writeSampleData(track, buffer, info)
                                        packets++
                                    }
                                    outputEnded = info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                                } finally {
                                    codec.releaseOutputBuffer(index, false)
                                }
                                lastProgress = System.nanoTime()
                            }
                            if (System.nanoTime() - lastProgress > 5_000_000_000L) {
                                throw IOException("AAC encoder stalled.")
                            }
                        }
                        check(track >= 0 && packets > 0)
                        // Drain EOS before stopping: the last AAC packets carry
                        // the end of the sentence, not disposable padding.
                        muxer.stop()
                    }
                } finally {
                    muxer.release()
                }
            } finally {
                runCatching { codec.stop() }
                codec.release()
            }
        }
    }
}
