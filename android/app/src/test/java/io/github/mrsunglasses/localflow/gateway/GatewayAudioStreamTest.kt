package io.github.mrsunglasses.localflow.gateway

import java.util.UUID
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.runBlocking
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import org.json.JSONObject

class GatewayAudioStreamTest {

    private lateinit var server: MockWebServer

    private val sessionId = UUID.fromString("9d8e6c37-1f4b-4b3a-a2a2-7c6c1f0d5e21")

    @Before
    fun start() {
        server = MockWebServer()
        server.start()
    }

    @After
    fun stop() {
        server.close()
    }

    private fun client(token: String = "test-token") =
        GatewayClient(server.url("/").toString().trimEnd('/'), token)

    /** Records what the client sent and replies with the scripted events. */
    private class Gateway(private val script: (JSONObject, WebSocket) -> Unit) : WebSocketListener() {
        val textMessages = LinkedBlockingQueue<String>()
        val binaryMessages = LinkedBlockingQueue<ByteString>()
        var authorization: String? = null

        override fun onOpen(webSocket: WebSocket, response: Response) {
            authorization = response.request.header("Authorization")
        }

        override fun onMessage(webSocket: WebSocket, text: String) {
            textMessages.add(text)
            script(JSONObject(text), webSocket)
        }

        override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
            binaryMessages.add(bytes)
        }

        /** Completes the closing handshake the client starts after `complete`. */
        override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
            webSocket.close(code, reason)
        }
    }

    private fun enqueue(gateway: Gateway) {
        server.enqueue(MockResponse.Builder().webSocketUpgrade(gateway).build())
    }

    @Test
    fun `handshake sends start and waits for ready`() = runBlocking {
        val gateway = Gateway { message, socket ->
            if (message.optString("type") == "start") {
                socket.send("""{"type":"ready","engine":"moonshine"}""")
            }
        }
        enqueue(gateway)

        val stream = client().openStream(sessionId, "en", "formal", 16_000)
        stream.connect()

        val start = JSONObject(gateway.textMessages.poll(5, TimeUnit.SECONDS)!!)
        assertEquals("start", start.getString("type"))
        assertEquals(sessionId.toString(), start.getString("session_id"))
        assertEquals("en", start.getString("language"))
        assertEquals("formal", start.getString("style"))
        assertEquals(16_000, start.getInt("sample_rate"))
        assertEquals("Bearer test-token", gateway.authorization)

        stream.cancel()
    }

    @Test
    fun `frames are sent as binary and the transcript comes back on finish`() = runBlocking {
        val gateway = Gateway { message, socket ->
            when (message.optString("type")) {
                "start" -> socket.send("""{"type":"ready","engine":"moonshine"}""")
                "finish" -> socket.send("""{"type":"complete","transcript":"  Hello there  "}""")
            }
        }
        enqueue(gateway)

        val stream = client().openStream(sessionId, "auto", "casual", 16_000)
        stream.connect()
        assertTrue(stream.sendFrames(ByteArray(1600)))
        val transcript = stream.finish()

        assertEquals("Hello there", transcript)
        assertEquals(1600, gateway.binaryMessages.poll(5, TimeUnit.SECONDS)!!.size)
    }

    @Test
    fun `partials are surfaced without blocking the control events`() = runBlocking {
        val gateway = Gateway { message, socket ->
            when (message.optString("type")) {
                "start" -> socket.send("""{"type":"ready","engine":"moonshine"}""")
                "finish" -> {
                    socket.send("""{"type":"partial","transcript":"Hello"}""")
                    socket.send("""{"type":"partial","transcript":"Hello there"}""")
                    socket.send("""{"type":"complete","transcript":"Hello there"}""")
                }
            }
        }
        enqueue(gateway)

        val stream = client().openStream(sessionId, "auto", "casual", 16_000)
        stream.connect()
        assertNull(stream.latestPartial())
        assertEquals("Hello there", stream.finish())
        assertEquals("Hello there", stream.latestPartial())
    }

    @Test
    fun `an engine without streaming support falls back rather than failing`() = runBlocking {
        val gateway = Gateway { message, socket ->
            if (message.optString("type") == "start") {
                socket.send("""{"type":"unsupported","reason":"active_engine","engine":"whisper.cpp"}""")
            }
        }
        enqueue(gateway)

        val stream = client().openStream(sessionId, "auto", "casual", 16_000)
        try {
            stream.connect()
            fail("Expected the stream to report that the engine cannot stream.")
        } catch (error: StreamingUnavailableException) {
            assertEquals("active_engine", error.message)
        }
    }

    @Test
    fun `an engine that is not warmed up also falls back`() = runBlocking {
        val gateway = Gateway { message, socket ->
            if (message.optString("type") == "start") {
                socket.send("""{"type":"unavailable","reason":"engine_not_ready"}""")
            }
        }
        enqueue(gateway)

        try {
            client().openStream(sessionId, "auto", "casual", 16_000).connect()
            fail("Expected the stream to report that the engine is not ready.")
        } catch (error: StreamingUnavailableException) {
            assertEquals("engine_not_ready", error.message)
        }
    }

    @Test
    fun `a stream error after capture is recoverable so the batch path can run`() = runBlocking {
        val gateway = Gateway { message, socket ->
            when (message.optString("type")) {
                "start" -> socket.send("""{"type":"ready","engine":"moonshine"}""")
                "finish" -> socket.send("""{"type":"error","message":"engine crashed"}""")
            }
        }
        enqueue(gateway)

        val stream = client().openStream(sessionId, "auto", "casual", 16_000)
        stream.connect()
        try {
            stream.finish()
            fail("Expected the stream to surface the gateway error.")
        } catch (error: GatewayException) {
            assertEquals("stream_error", error.code)
            assertTrue(error.recoverable)
        }
    }

    @Test
    fun `an empty transcript is rejected rather than inserted`() = runBlocking {
        val gateway = Gateway { message, socket ->
            when (message.optString("type")) {
                "start" -> socket.send("""{"type":"ready","engine":"moonshine"}""")
                "finish" -> socket.send("""{"type":"complete","transcript":"   "}""")
            }
        }
        enqueue(gateway)

        val stream = client().openStream(sessionId, "auto", "casual", 16_000)
        stream.connect()
        try {
            stream.finish()
            fail("Expected an empty transcript to be rejected.")
        } catch (error: GatewayException) {
            assertEquals("empty_transcript", error.code)
        }
    }
}
