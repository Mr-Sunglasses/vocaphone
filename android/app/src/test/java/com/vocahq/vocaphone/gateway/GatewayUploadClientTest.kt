package com.vocahq.vocaphone.gateway

import java.io.File
import java.util.UUID
import java.util.concurrent.TimeUnit
import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.runBlocking
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import okhttp3.Call
import okhttp3.EventListener
import okhttp3.OkHttpClient
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
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

    @Test fun `combined file upload handles newer and older gateways without audio replay`() = runBlocking {
        for (combined in listOf(true, false)) {
            MockWebServer().use { server ->
                server.start()
                val completed = """{"session_id":"$sessionId","job_id":"test","state":"completed","transcript":"Hello there"}"""
                server.enqueue(MockResponse(body = if (combined) completed else uploaded))
                if (!combined) server.enqueue(MockResponse(body = completed))
                val source = GatewayUploadAudioTest.recording(folder.root)
                val scratch = folder.newFolder()
                val client = client(server, scratch)
                val result = client.uploadAudio(sessionId, source, finishOnUpload = true)
                assertEquals("Hello there", client.finishUploaded(sessionId, result).transcript)
                val upload = server.takeRequest(5, TimeUnit.SECONDS)!!
                assertEquals("true", upload.url.queryParameter("finish"))
                assertEquals("audio/mp4", upload.headers["Content-Type"])
                assertArrayEquals(GatewayUploadAudioTest.encodedBytes, upload.body!!.toByteArray())
                if (!combined) {
                    assertEquals("/v1/sessions/$sessionId/finish", server.takeRequest().url.encodedPath)
                }
                assertEquals(if (combined) 1 else 2, server.requestCount)
                assertTrue(scratch.listFiles()!!.isEmpty())
            }
        }
    }

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

    @Test fun `combined deadline retains the upload and full finish budgets`() = runBlocking {
        MockWebServer().use { server ->
            server.start()
            val deadline = AtomicLong()
            val http = OkHttpClient.Builder().eventListener(object : EventListener() {
                override fun callStart(call: Call) {
                    deadline.set(TimeUnit.NANOSECONDS.toSeconds(call.timeout().timeoutNanos()))
                }
            }).build()
            val scratch = folder.newFolder()
            val client = GatewayClient(server.url("/").toString(), "test-token", http,
                uploadPreparer = { GatewayUploadAudio.prepare(it, scratch, GatewayUploadAudioTest.fakeEncoder) })
            val source = GatewayUploadAudioTest.recording(folder.root)
            for (combined in listOf(false, true)) {
                server.enqueue(MockResponse(body = uploaded))
                client.uploadAudio(sessionId, source, finishOnUpload = combined)
                assertEquals(GatewayClient.UPLOAD_TIMEOUT_SECONDS +
                    (if (combined) GatewayClient.FINISH_TIMEOUT_SECONDS else 0), deadline.get())
            }
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
            val notifications = AtomicInteger()
            val bodySent = CountDownLatch(1)
            val uploading = async(Dispatchers.IO) {
                client.uploadAudio(sessionId, source, finishOnUpload = true, onUploadFinished = {
                    notifications.incrementAndGet()
                    bodySent.countDown()
                })
            }
            assertTrue(server.eofReceived.await(5, TimeUnit.SECONDS))
            assertTrue(bodySent.await(5, TimeUnit.SECONDS))
            assertEquals(1, notifications.get())
            assertFalse(uploading.isCompleted)
            assertTrue(scratch.listFiles()!!.isNotEmpty())
            uploading.cancelAndJoin()
            assertTrue(uploading.isCancelled)
            assertEquals(1, notifications.get())
            assertTrue(scratch.listFiles()!!.isEmpty())
            assertArrayEquals(original, source.readBytes())
        }
    }
}
