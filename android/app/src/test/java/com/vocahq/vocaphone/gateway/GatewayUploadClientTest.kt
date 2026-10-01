package com.vocahq.vocaphone.gateway

import java.io.File
import java.util.UUID
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.runBlocking
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class GatewayUploadClientTest {
    @get:Rule val folder = TemporaryFolder()
    private val sessionId = UUID.randomUUID()
    private val uploaded = """{"session_id":"$sessionId","job_id":"test","state":"uploaded"}"""

    private fun client(server: MockWebServer, scratch: File) = GatewayClient(
        server.url("/").toString(), "test-token",
        uploadPreparer = { GatewayUploadAudio.prepare(it, scratch, GatewayUploadAudioTest.fakeEncoder) },
    )

    @Test fun `actual encoded bytes reach HTTP and success removes the copy`() = runBlocking {
        MockWebServer().use { server ->
            server.start()
            server.enqueue(MockResponse(body = uploaded))
            val source = GatewayUploadAudioTest.recording(folder.root)
            val original = source.readBytes()
            val scratch = folder.newFolder()
            assertEquals("uploaded", client(server, scratch).uploadAudio(sessionId, source).state)
            val request = server.takeRequest(5, TimeUnit.SECONDS)!!
            assertEquals("PUT", request.method)
            assertEquals("/v1/sessions/$sessionId/audio", request.url.encodedPath)
            assertEquals("Bearer test-token", request.headers["Authorization"])
            assertEquals("audio/mp4", request.headers["Content-Type"])
            assertArrayEquals(GatewayUploadAudioTest.encodedBytes, request.body!!.toByteArray())
            assertTrue(scratch.listFiles()!!.isEmpty())
            assertArrayEquals(original, source.readBytes())
        }
    }

    @Test fun `HTTP rejection retains the WAV and removes the upload copy`() = runBlocking {
        MockWebServer().use { server ->
            server.start()
            server.enqueue(MockResponse(code = 503, body = """{"error":{"code":"busy"}}"""))
            val source = GatewayUploadAudioTest.recording(folder.root)
            val original = source.readBytes()
            val scratch = folder.newFolder()
            try {
                client(server, scratch).uploadAudio(sessionId, source)
                fail("Expected rejection")
            } catch (error: GatewayException) { assertEquals("busy", error.code) }
            assertTrue(scratch.listFiles()!!.isEmpty())
            assertArrayEquals(original, source.readBytes())
        }
    }

    @Test fun `cancelling the HTTP wait cancels the call and removes the upload copy`() = runBlocking {
        GatewayRecordingUploadTest.Receiver(holdResponse = true).use { server ->
            val source = GatewayUploadAudioTest.recording(folder.root)
            val original = source.readBytes()
            val scratch = folder.newFolder()
            val client = GatewayClient(
                "http://127.0.0.1:${server.port}", "test-token",
                uploadPreparer = { GatewayUploadAudio.prepare(it, scratch, GatewayUploadAudioTest.fakeEncoder) },
            )
            val uploading = async(Dispatchers.IO) { client.uploadAudio(sessionId, source) }
            assertTrue(server.eofReceived.await(5, TimeUnit.SECONDS))
            assertTrue(scratch.listFiles()!!.isNotEmpty())
            uploading.cancelAndJoin()
            assertTrue(uploading.isCancelled)
            assertTrue(scratch.listFiles()!!.isEmpty())
            assertArrayEquals(original, source.readBytes())
        }
    }
}
