package com.vocahq.vocaphone.gateway

import com.vocahq.vocaphone.audio.PcmConversion
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

/** Ordered microphone PCM delivery, either incremental decoding or HTTP upload. */
interface GatewayRecordingTransport {
    val incremental: Boolean
    suspend fun sendFrames(samples: ShortArray): Boolean
    fun latestPartial(): String? = null
    suspend fun finishUpload() = Unit
    suspend fun finish(): String
    fun cancel()
}

private class IncrementalTransport(private val stream: GatewayAudioStream) : GatewayRecordingTransport {
    override val incremental = true
    private var scratch = ByteArray(0)

    override suspend fun sendFrames(samples: ShortArray): Boolean {
        if (scratch.size < samples.size * 4) scratch = ByteArray(samples.size * 4)
        PcmConversion.pcm16ToFloat32LittleEndian(samples, samples.size, scratch)
        return stream.sendFrames(scratch, samples.size * 4)
    }

    override fun latestPartial() = stream.latestPartial()
    override suspend fun finish() = stream.finish()
    override fun cancel() = stream.cancel()
}

private class UploadTransport(
    private val upload: GatewayRecordingUpload,
    private val client: GatewayClient,
    private val sessionId: UUID,
) : GatewayRecordingTransport {
    override val incremental = false
    override suspend fun sendFrames(samples: ShortArray): Boolean {
        upload.sendFrames(samples)
        return true
    }

    override suspend fun finishUpload() { upload.finish() }
    override suspend fun finish(): String {
        val result = client.finish(sessionId)
        return result.transcript?.takeIf { it.isNotBlank() } ?: throw GatewayException.emptyTranscript()
    }

    override fun cancel() = upload.cancel()
}

suspend fun GatewayClient.openRecordingTransport(
    sessionId: UUID, language: String, style: String, sampleRate: Int,
    attemptStreaming: Boolean,
): GatewayRecordingTransport {
    if (attemptStreaming) {
        val stream = openStream(sessionId, language, style, sampleRate)
        try {
            stream.connect()
            currentCoroutineContext().ensureActive()
            return IncrementalTransport(stream)
        } catch (error: CancellationException) {
            stream.cancel()
            throw error
        } catch (_: StreamingUnavailableException) {
            stream.cancel()
        } catch (_: GatewayException) {
            stream.cancel()
        }
    }
    currentCoroutineContext().ensureActive()
    return UploadTransport(startRecordingUpload(sessionId, language, style), this, sessionId)
}
