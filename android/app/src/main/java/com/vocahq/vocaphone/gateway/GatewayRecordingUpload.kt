package com.vocahq.vocaphone.gateway

import com.vocahq.vocaphone.audio.CaptureFormat
import com.vocahq.vocaphone.audio.WavWriter
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runInterruptible
import okhttp3.Call
import okhttp3.Callback
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.Response
import okio.Buffer
import okio.BufferedSink
import okio.Pipe

/** A bounded, one-shot WAV PUT. EOF, rather than the RIFF length, ends capture. */
class GatewayRecordingUpload internal constructor(
    client: OkHttpClient, request: Request, writeTimeoutMillis: Long = 8_000,
) {
    private val pipe = Pipe(65_536)
    private val completed = CompletableDeferred<GatewaySession>()
    private val call: Call

    init {
        pipe.sink.timeout().timeout(writeTimeoutMillis, TimeUnit.MILLISECONDS)
        val body = object : RequestBody() {
            override fun contentType() = GatewayClient.WAV_MEDIA_TYPE
            override fun contentLength() = -1L
            override fun isOneShot() = true

            override fun writeTo(sink: BufferedSink) {
                sink.write(wavHeader())
                sink.flush()
                pipe.source.use { source ->
                    val buffer = Buffer()
                    while (true) {
                        val count = source.read(buffer, 8_192)
                        if (count == -1L) break
                        sink.write(buffer, count)
                        sink.flush()
                    }
                }
            }
        }
        call = client.newBuilder()
            .callTimeout(150, TimeUnit.SECONDS)
            .readTimeout(30, TimeUnit.SECONDS)
            .writeTimeout(writeTimeoutMillis, TimeUnit.MILLISECONDS)
            .retryOnConnectionFailure(false)
            .followRedirects(false)
            .followSslRedirects(false)
            .build()
            .newCall(request.newBuilder().put(body).build())
        call.enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) {
                completed.completeExceptionally(GatewayException.unreachable(e))
                pipe.cancel()
            }

            override fun onResponse(call: Call, response: Response) {
                try {
                    completed.complete(GatewayClient.decodeSession(response))
                } catch (error: Exception) {
                    completed.completeExceptionally(error)
                } finally {
                    pipe.cancel()
                }
            }
        })
    }

    /** Called by the sole IO consumer, never by AudioRecord's read thread. */
    suspend fun sendFrames(samples: ShortArray) {
        if (completed.isCompleted) {
            completed.await()
            throw GatewayException.unreachable()
        }
        try {
            runInterruptible(Dispatchers.IO) {
                val bytes = ByteBuffer.allocate(samples.size * CaptureFormat.BYTES_PER_SAMPLE)
                    .order(ByteOrder.LITTLE_ENDIAN)
                samples.forEach { bytes.putShort(it) }
                val buffer = Buffer().write(bytes.array())
                pipe.sink.write(buffer, buffer.size)
            }
        } catch (error: CancellationException) {
            cancel()
            throw error
        } catch (error: IOException) {
            cancel()
            throw GatewayException.unreachable(error)
        }
    }

    suspend fun finish(): GatewaySession {
        try {
            pipe.sink.close()
            return completed.await()
        } catch (error: CancellationException) {
            cancel()
            throw error
        }
    }

    fun cancel() {
        call.cancel()
        pipe.cancel()
        completed.cancel()
    }

    internal companion object {
        fun wavHeader(): ByteArray = WavWriter.header(0).also {
            ByteBuffer.wrap(it).order(ByteOrder.LITTLE_ENDIAN)
                .putInt(4, -1).putInt(40, -1)
        }
    }
}
