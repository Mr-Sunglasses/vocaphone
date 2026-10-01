package com.vocahq.vocaphone.gateway

import java.util.UUID
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.runBlocking
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.junit.Rule
import org.junit.rules.TemporaryFolder

class GatewayRecordingTransportTest {
    @get:Rule val folder = TemporaryFolder()
    private val sessionId = UUID.randomUUID()
    private fun session(state: String, transcript: String = "") =
        """{"session_id":"$sessionId","job_id":"test","state":"$state","transcript":"$transcript"}"""

    @Test fun `a batch model uploads first and transcribes only after EOF`() = runBlocking {
        batchSequence(attemptStreaming = false)
    }

    @Test fun `unsupported WebSocket negotiation switches to HTTP during recording`() = runBlocking {
        batchSequence(attemptStreaming = true)
    }

    private suspend fun batchSequence(attemptStreaming: Boolean) {
        MockWebServer().use { server ->
            server.start()
            if (attemptStreaming) server.enqueue(MockResponse.Builder().webSocketUpgrade(object : WebSocketListener() {
                override fun onMessage(webSocket: WebSocket, text: String) {
                    webSocket.send("""{"type":"unsupported","reason":"batch_only"}""")
                }
            }).build())
            server.enqueue(MockResponse(body = """{"status":"ok","engine_ready":true}"""))
            server.enqueue(MockResponse(body = session("created")))
            server.enqueue(MockResponse(body = session("uploaded")))
            server.enqueue(MockResponse(body = session("completed", "Hello there")))
            val client = GatewayClient(server.url("/").toString(), "test-token")
            val transport = client.openRecordingTransport(sessionId, "en", "formal", 16_000, attemptStreaming)
            try {
                assertFalse(transport.incremental)
                if (attemptStreaming) assertEquals("/v1/stream", server.takeRequest().url.encodedPath)
                val health = server.takeRequest()
                assertEquals("/health", health.url.encodedPath)
                assertEquals(null, health.headers["Authorization"])
                val created = server.takeRequest()
                assertEquals("/v1/sessions", created.url.encodedPath)
                assertTrue(created.body!!.utf8().contains(sessionId.toString()))
                assertTrue(transport.sendFrames(shortArrayOf(1, -1)))
                assertTrue(transport.sendFrames(shortArrayOf(2, -2)))
                transport.finishUpload()
                val upload = server.takeRequest(5, TimeUnit.SECONDS)!!
                assertEquals("PUT", upload.method)
                assertEquals("/v1/sessions/$sessionId/audio", upload.url.encodedPath)
                assertEquals("Bearer test-token", upload.headers["Authorization"])
                assertEquals("audio/wav", upload.headers["Content-Type"])
                assertArrayEquals(GatewayRecordingUpload.wavHeader() + byteArrayOf(1, 0, -1, -1, 2, 0, -2, -1), upload.body!!.toByteArray())
                assertEquals(if (attemptStreaming) 4 else 3, server.requestCount)
                assertEquals("Hello there", transport.finish())
                assertEquals("/v1/sessions/$sessionId/finish", server.takeRequest().url.encodedPath)
            } finally { transport.cancel() }
        }
    }

    @Test fun `a ready streaming model keeps float32 incremental transcription`() = runBlocking {
        MockWebServer().use { server ->
            server.start()
            val binary = LinkedBlockingQueue<ByteString>()
            server.enqueue(MockResponse.Builder().webSocketUpgrade(object : WebSocketListener() {
                override fun onMessage(webSocket: WebSocket, text: String) {
                    when (JSONObject(text).getString("type")) {
                        "start" -> webSocket.send("""{"type":"ready","engine":"moonshine"}""")
                        "finish" -> webSocket.send("""{"type":"complete","transcript":"Hello there"}""")
                    }
                }
                override fun onMessage(webSocket: WebSocket, bytes: ByteString) { binary.add(bytes) }
                override fun onClosing(webSocket: WebSocket, code: Int, reason: String) { webSocket.close(code, reason) }
            }).build())
            val transport = GatewayClient(server.url("/").toString(), "test-token")
                .openRecordingTransport(sessionId, "en", "formal", 16_000, attemptStreaming = true)
            try {
                assertTrue(transport.incremental)
                assertTrue(transport.sendFrames(shortArrayOf(0, -32_768)))
                assertArrayEquals(byteArrayOf(0, 0, 0, 0, 0, 0, -128, -65), binary.poll(5, TimeUnit.SECONDS)!!.toByteArray())
                transport.finishUpload()
                assertEquals("Hello there", transport.finish())
                assertEquals(1, server.requestCount)
            } finally { transport.cancel() }
        }
    }

    @Test fun `an unready batch engine sends no session or audio`() = runBlocking {
        MockWebServer().use { server ->
            server.start()
            server.enqueue(MockResponse(body = """{"status":"ok","engine_ready":false}"""))
            try {
                GatewayClient(server.url("/").toString(), "test-token")
                    .openRecordingTransport(sessionId, "en", "formal", 16_000, attemptStreaming = false)
                fail("Expected readiness failure")
            } catch (error: GatewayException) { assertEquals("engine_not_ready", error.code) }
            assertEquals(1, server.requestCount)
        }
    }

    @Test fun `failed live upload can retry the complete compressed file using the same session`() = runBlocking {
        MockWebServer().use { server ->
            server.start()
            server.enqueue(MockResponse(body = """{"status":"ok","engine_ready":true}"""))
            server.enqueue(MockResponse(body = session("created")))
            server.enqueue(MockResponse(code = 503, body = """{"error":{"code":"busy"}}"""))
            server.enqueue(MockResponse(body = session("created")))
            server.enqueue(MockResponse(body = session("uploaded")))
            server.enqueue(MockResponse(body = session("completed", "Hello there")))
            val source = GatewayUploadAudioTest.recording(folder.root)
            val original = source.readBytes()
            val scratch = folder.newFolder()
            val client = GatewayClient(server.url("/").toString(), "test-token",
                uploadPreparer = { GatewayUploadAudio.prepare(it, scratch, GatewayUploadAudioTest.fakeEncoder) })
            val transport = client.openRecordingTransport(sessionId, "en", "formal", 16_000, attemptStreaming = false)
            try {
                transport.sendFrames(shortArrayOf(1, 2))
                transport.finishUpload()
                fail("Expected failed live upload")
            } catch (error: GatewayException) { assertTrue(error.recoverable) }
            finally { transport.cancel() }
            client.createSession(sessionId, "en", "formal")
            client.uploadAudio(sessionId, source)
            assertEquals("Hello there", client.finish(sessionId).transcript)
            val requests = List(6) { server.takeRequest(5, TimeUnit.SECONDS)!! }
            assertEquals(requests[2].url.encodedPath, requests[4].url.encodedPath)
            assertEquals("audio/mp4", requests[4].headers["Content-Type"])
            assertArrayEquals(GatewayUploadAudioTest.encodedBytes, requests[4].body!!.toByteArray())
            assertArrayEquals(original, source.readBytes())
            assertTrue(scratch.listFiles()!!.isEmpty())
        }
    }
}
