package com.example.localflow.android.gateway

import java.io.File
import java.util.UUID
import kotlinx.coroutines.test.runTest
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import okhttp3.Headers
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class GatewayClientTest {

    @get:Rule
    val folder = TemporaryFolder()

    private lateinit var server: MockWebServer

    private val sessionId = UUID.fromString("2f7d5f2b-6e2e-4c1e-9f7a-0d6a1e4b9c33")

    private val jsonHeaders = Headers.headersOf("Content-Type", "application/json")

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

    private fun json(code: Int = 200, body: String) =
        MockResponse(code = code, headers = jsonHeaders, body = body)

    @Test
    fun `health is read without a token`() = runTest {
        server.enqueue(
            json(
                body = """
                {"status":"ok","engine_ready":true,"engine":"moonshine","streaming_supported":true}
                """.trimIndent()
            )
        )

        val health = client().health()

        assertEquals("ok", health.status)
        assertEquals("moonshine", health.engine)
        assertTrue(health.engineReady)
        assertEquals(true, health.streamingSupported)

        val request = server.takeRequest()
        assertEquals("/health", request.url.encodedPath)
        assertNull(request.headers["Authorization"])
    }

    @Test
    fun `an older gateway without streaming support still parses`() = runTest {
        server.enqueue(json(body = """{"status":"ok","engine_ready":true,"engine":"whisper.cpp"}"""))

        assertNull(client().health().streamingSupported)
    }

    @Test
    fun `every session call carries the bearer token`() = runTest {
        server.enqueue(json(body = sessionBody("created")))

        client().createSession(sessionId, "en", "formal")

        val request = server.takeRequest()
        assertEquals("POST", request.method)
        assertEquals("/v1/sessions", request.url.encodedPath)
        assertEquals("Bearer test-token", request.headers["Authorization"])

        val body = request.body!!.utf8()
        assertTrue(body.contains(""""client_session_id":"$sessionId""""))
        assertTrue(body.contains(""""language":"en""""))
        assertTrue(body.contains(""""style":"formal""""))
    }

    @Test
    fun `the same session id is reused across the batch sequence`() = runTest {
        server.enqueue(json(body = sessionBody("created")))
        server.enqueue(json(body = sessionBody("uploaded")))
        server.enqueue(json(body = sessionBody("completed", transcript = "Hello there")))

        val wav = File(folder.root, "dictation.wav").apply { writeBytes(ByteArray(2048)) }
        val gateway = client()
        gateway.createSession(sessionId, "auto", "casual")
        gateway.uploadAudio(sessionId, wav)
        val finished = gateway.finish(sessionId)

        assertEquals("Hello there", finished.transcript)

        server.takeRequest()
        val upload = server.takeRequest()
        assertEquals("PUT", upload.method)
        assertEquals("/v1/sessions/$sessionId/audio", upload.url.encodedPath)
        assertEquals("audio/wav", upload.headers["Content-Type"])
        assertEquals(2048, upload.body?.size)

        val finish = server.takeRequest()
        assertEquals("POST", finish.method)
        assertEquals("/v1/sessions/$sessionId/finish", finish.url.encodedPath)
    }

    @Test
    fun `a rejected token is reported as unrecoverable`() = runTest {
        server.enqueue(
            json(code = 401, body = """{"error":{"code":"unauthorized","message":"no","recoverable":false}}""")
        )

        try {
            client().verifyAuthentication()
            fail("Expected the client to reject an unauthorized response.")
        } catch (error: GatewayException) {
            assertEquals("unauthorized", error.code)
            assertFalse(error.recoverable)
        }
    }

    @Test
    fun `a server error is recoverable so the audio is kept for retry`() = runTest {
        server.enqueue(
            json(code = 503, body = """{"error":{"code":"engine_unavailable","message":"busy","recoverable":true}}""")
        )

        try {
            client().finish(sessionId)
            fail("Expected the client to surface the server error.")
        } catch (error: GatewayException) {
            assertEquals("engine_unavailable", error.code)
            assertTrue(error.recoverable)
        }
    }

    @Test
    fun `an oversized recording is not retried`() = runTest {
        server.enqueue(
            json(code = 413, body = """{"error":{"code":"audio_too_large","message":"big","recoverable":false}}""")
        )

        val wav = File(folder.root, "long.wav").apply { writeBytes(ByteArray(512)) }
        try {
            client().uploadAudio(sessionId, wav)
            fail("Expected the client to reject an oversized upload.")
        } catch (error: GatewayException) {
            assertEquals("audio_too_large", error.code)
            assertFalse(error.recoverable)
        }
    }

    @Test
    fun `an unreachable gateway is recoverable`() = runTest {
        val unreachable = GatewayClient("http://127.0.0.1:1", "test-token")

        try {
            unreachable.health()
            fail("Expected the client to report an unreachable gateway.")
        } catch (error: GatewayException) {
            assertEquals("gateway_unreachable", error.code)
            assertTrue(error.recoverable)
        }
    }

    @Test
    fun `deleting a session that is already gone is not an error`() = runTest {
        server.enqueue(json(code = 404, body = """{"error":{"code":"not_found","message":"gone","recoverable":false}}"""))

        client().delete(sessionId)

        assertEquals("/v1/sessions/$sessionId", server.takeRequest().url.encodedPath)
    }

    private fun sessionBody(state: String, transcript: String? = null) = """
        {
          "session_id": "$sessionId",
          "job_id": "job-1",
          "state": "$state",
          "language": "auto",
          "style": "casual",
          "transcript": ${transcript?.let { "\"$it\"" } ?: "null"},
          "error_code": null,
          "created_at": "2026-08-02T10:00:00Z",
          "updated_at": "2026-08-02T10:00:01Z"
        }
    """.trimIndent()
}
