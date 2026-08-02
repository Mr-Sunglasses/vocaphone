package io.github.mrsunglasses.localflow.gateway

import java.util.UUID
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.withTimeout
import okhttp3.HttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString.Companion.toByteString
import org.json.JSONObject

/**
 * Raised when the gateway answered the handshake but cannot stream — an engine
 * without streaming support, or one that is not warmed up yet. The caller falls
 * back to the batch upload endpoints rather than failing the dictation.
 */
class StreamingUnavailableException(message: String) : Exception(message)

/**
 * The float32 PCM streaming protocol: `start`, raw little-endian frames,
 * `finish`, and a `complete` event carrying the styled transcript.
 */
class GatewayAudioStream(
    private val client: OkHttpClient,
    private val url: HttpUrl,
    private val token: String,
    private val sessionId: UUID,
    private val language: String,
    private val style: String,
    private val sampleRate: Int,
) {
    private sealed interface Event {
        data class Ready(val engine: String) : Event
        data class Complete(val transcript: String) : Event
        data class Unsupported(val reason: String) : Event
        data class Failed(val error: Throwable) : Event
    }

    private val events = Channel<Event>(Channel.UNLIMITED)

    /**
     * Partial transcripts arrive far faster than the UI needs them, so the latest
     * one is kept here instead of queued behind the control events.
     */
    @Volatile
    private var latestPartial: String? = null

    @Volatile
    private var socket: WebSocket? = null

    @Volatile
    private var closed = false

    private val listener = object : WebSocketListener() {
        override fun onMessage(webSocket: WebSocket, text: String) {
            val json = runCatching { JSONObject(text) }.getOrNull() ?: return
            if (json.optString("type") == "partial") {
                latestPartial = json.optString("transcript")
                return
            }
            val event = when (json.optString("type")) {
                "ready" -> Event.Ready(json.optString("engine", "unknown"))
                "complete" -> Event.Complete(json.optString("transcript"))
                "unsupported", "unavailable" -> Event.Unsupported(json.optString("reason", "unknown"))
                "error" -> Event.Failed(
                    GatewayException(
                        "stream_error",
                        "Your gateway could not finish the stream.",
                        recoverable = true,
                    )
                )

                else -> return
            }
            events.trySend(event)
        }

        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
            val status = response?.code
            val failure = when {
                closed -> return
                status == 401 || status == 403 -> GatewayException.fromStatus(status, "unauthorized")
                else -> GatewayException.unreachable(t)
            }
            events.trySend(Event.Failed(failure))
        }

        override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
            if (!closed) {
                events.trySend(
                    Event.Failed(
                        GatewayException(
                            "stream_closed",
                            "Your gateway closed the stream.",
                            recoverable = true,
                        )
                    )
                )
            }
        }
    }

    /**
     * Connects and completes the handshake. Throws [StreamingUnavailableException]
     * when the gateway is reachable but not streaming-capable, and
     * [GatewayException] when it is not reachable or rejects the token.
     */
    suspend fun connect() {
        val request = Request.Builder()
            .url(url)
            .header("Authorization", "Bearer $token")
            .build()
        socket = client.newWebSocket(request, listener)

        val start = JSONObject()
            .put("type", "start")
            .put("session_id", sessionId.toString())
            .put("language", language)
            .put("style", style)
            .put("sample_rate", sampleRate)
        if (socket?.send(start.toString()) != true) {
            cancel()
            throw GatewayException.unreachable()
        }

        val event = try {
            withTimeout(HANDSHAKE_TIMEOUT_MILLIS) { events.receive() }
        } catch (_: TimeoutCancellationException) {
            cancel()
            throw StreamingUnavailableException("The gateway did not answer the streaming handshake.")
        }
        when (event) {
            is Event.Ready -> Unit
            is Event.Unsupported -> {
                cancel()
                throw StreamingUnavailableException(event.reason)
            }

            is Event.Failed -> {
                cancel()
                throw event.error
            }

            else -> {
                cancel()
                throw StreamingUnavailableException("Unexpected streaming handshake reply.")
            }
        }
    }

    /** Returns false once the socket has dropped, so the caller can fall back. */
    fun sendFrames(pcmFloat32: ByteArray, length: Int = pcmFloat32.size): Boolean {
        val active = socket ?: return false
        return active.send(pcmFloat32.toByteString(0, length))
    }

    /** The most recent partial transcript, or null if none has arrived. */
    fun latestPartial(): String? = latestPartial?.takeIf { it.isNotEmpty() }

    suspend fun finish(): String {
        val active = socket ?: throw GatewayException.unreachable()
        val finish = JSONObject().put("type", "finish")
        if (!active.send(finish.toString())) throw GatewayException.unreachable()
        return withTimeout(FINISH_TIMEOUT_MILLIS) { awaitComplete(active) }
    }

    private suspend fun awaitComplete(active: WebSocket): String {
        while (true) {
            when (val event = events.receive()) {
                is Event.Complete -> {
                    val transcript = event.transcript.trim()
                    closed = true
                    active.close(NORMAL_CLOSURE, null)
                    if (transcript.isEmpty()) throw GatewayException.emptyTranscript()
                    return transcript
                }

                is Event.Failed -> {
                    cancel()
                    throw event.error
                }

                is Event.Unsupported -> {
                    cancel()
                    throw StreamingUnavailableException(event.reason)
                }

                is Event.Ready -> Unit
            }
        }
    }

    fun cancel() {
        closed = true
        socket?.cancel()
        socket = null
        events.close()
    }

    private companion object {
        const val HANDSHAKE_TIMEOUT_MILLIS = 8_000L
        const val FINISH_TIMEOUT_MILLIS = 120_000L
        const val NORMAL_CLOSURE = 1000
    }
}
