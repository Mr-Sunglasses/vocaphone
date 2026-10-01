package com.vocahq.vocaphone.gateway

import com.vocahq.vocaphone.core.DictationState
import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.runBlocking
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import okhttp3.OkHttpClient
import okhttp3.Call
import okhttp3.EventListener
import okhttp3.Request
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class GatewayRecordingUploadTest {
    @Test fun `call deadline covers maximum recording and bounded finish time`() = runBlocking {
        val deadline = AtomicLong()
        val client = OkHttpClient.Builder().eventListener(object : EventListener() {
            override fun callStart(call: Call) {
                deadline.set(TimeUnit.NANOSECONDS.toMillis(call.timeout().timeoutNanos()))
            }
        }).build()
        Receiver().use { server ->
            val upload = GatewayRecordingUpload(client, request(server.port))
            try {
                assertEquals(DictationState.MAXIMUM_RECORDING_MILLIS +
                    TimeUnit.SECONDS.toMillis(GatewayClient.UPLOAD_TIMEOUT_SECONDS +
                        GatewayClient.FINISH_TIMEOUT_SECONDS), deadline.get())
                upload.sendFrames(shortArrayOf(1, 2, 3))
                assertEquals("uploaded", upload.finish().state)
            } finally { upload.cancel() }
        }
    }

    @Test fun `audio arrives before EOF with exact PCM16 bytes in order`() = runBlocking {
        Receiver().use { server ->
            val upload = GatewayRecordingUpload(OkHttpClient(), request(server.port))
            try {
                upload.sendFrames(shortArrayOf(0, -32_768, 32_767))
                assertTrue(server.samplesReceived.await(5, TimeUnit.SECONDS))
                assertArrayEquals(
                    GatewayRecordingUpload.wavHeader() + byteArrayOf(0, 0, 0, -128, -1, 127),
                    server.bytes(),
                )
                assertTrue(server.headers.lowercase().contains("transfer-encoding: chunked"))
                assertTrue(server.headers.contains("Bearer test-token"))
                assertFalse(server.eofReceived.await(50, TimeUnit.MILLISECONDS))
                assertEquals("uploaded", upload.finish().state)
                assertTrue(server.eofReceived.await(5, TimeUnit.SECONDS))
            } finally { upload.cancel() }
        }
    }

    @Test fun `cancelling finish aborts the HTTP request`() = runBlocking {
        Receiver(holdResponse = true).use { server ->
            val notifications = AtomicInteger()
            val bodySent = CountDownLatch(1)
            val upload = GatewayRecordingUpload(OkHttpClient(), request(server.port), onUploadFinished = {
                notifications.incrementAndGet()
                bodySent.countDown()
            })
            upload.sendFrames(shortArrayOf(0, 1, 2))
            assertEquals(0, notifications.get())
            val finishing = async(Dispatchers.IO) { upload.finish() }
            assertTrue(server.eofReceived.await(5, TimeUnit.SECONDS))
            assertTrue(bodySent.await(5, TimeUnit.SECONDS))
            assertEquals(1, notifications.get())
            assertFalse(finishing.isCompleted)
            finishing.cancelAndJoin()
            assertTrue(finishing.isCancelled)
            assertEquals(1, notifications.get())
        }
    }

    @Test fun `a stalled body consumer fails rather than growing the buffer`() = runBlocking {
        val release = CountDownLatch(1)
        val http = OkHttpClient.Builder().addInterceptor {
            release.await(5, TimeUnit.SECONDS)
            throw java.io.IOException("Stopped test interceptor")
        }.build()
        val upload = GatewayRecordingUpload(http, request(1), writeTimeoutMillis = 100)
        try {
            // No consumer reads the body. This is larger than the 64 KiB pipe.
            upload.sendFrames(ShortArray(40_000))
            fail("Expected bounded write deadline")
        } catch (error: GatewayException) {
            assertTrue(error.recoverable)
        } finally {
            upload.cancel()
            release.countDown()
        }
    }

    @Test fun `HTTP rejection and redirects cannot replay live audio`() = runBlocking {
        MockWebServer().use { server ->
            server.start()
            for (status in listOf(503, 307)) {
                server.enqueue(MockResponse.Builder().code(status)
                    .addHeader("Location", server.url("/replay"))
                    .body("""{"error":{"code":"rejected"}}""").build())
                val upload = GatewayRecordingUpload(OkHttpClient(), request(server.port))
                try {
                    upload.sendFrames(shortArrayOf(1, 2))
                    upload.finish()
                    fail("Expected failed HTTP upload")
                } catch (error: GatewayException) { assertEquals("rejected", error.code) }
                finally { upload.cancel() }
                assertEquals("/audio", server.takeRequest(5, TimeUnit.SECONDS)!!.url.encodedPath)
            }
            assertEquals(2, server.requestCount)
        }
    }

    private fun request(port: Int) = Request.Builder().url("http://127.0.0.1:$port/audio")
        .header("Authorization", "Bearer test-token").build()

    /** Real HTTP receiver: MockWebServer records a request only after EOF. */
    internal class Receiver(private val holdResponse: Boolean = false) : AutoCloseable {
        private val server = ServerSocket(0, 1, InetAddress.getByName("127.0.0.1"))
        private val executor = Executors.newSingleThreadExecutor()
        private val received = ByteArrayOutputStream()
        private val release = CountDownLatch(1)
        @Volatile private var socket: Socket? = null
        @Volatile var headers = ""
        val port get() = server.localPort
        val samplesReceived = CountDownLatch(1)
        val eofReceived = CountDownLatch(1)

        init {
            executor.submit {
                server.accept().use { connection ->
                    socket = connection
                    connection.soTimeout = 5_000
                    val input = BufferedInputStream(connection.getInputStream())
                    val lines = mutableListOf<String>()
                    while (true) {
                        val line = line(input)
                        if (line.isEmpty()) break
                        lines += line
                    }
                    headers = lines.joinToString("\r\n")
                    val length = lines.firstOrNull { it.startsWith("Content-Length:", ignoreCase = true) }
                        ?.substringAfter(':')?.trim()?.toInt()
                    if (length != null) {
                        synchronized(received) { received.write(input.readNBytes(length)) }
                        samplesReceived.countDown()
                    } else while (true) {
                        val count = line(input).substringBefore(';').toInt(16)
                        if (count == 0) { line(input); break }
                        val chunk = input.readNBytes(count)
                        check(chunk.size == count)
                        synchronized(received) { received.write(chunk) }
                        check(line(input).isEmpty())
                        if (bytes().size >= 50) samplesReceived.countDown()
                    }
                    eofReceived.countDown()
                    if (holdResponse) release.await(5, TimeUnit.SECONDS)
                    val body = """{"session_id":"test","job_id":"test","state":"uploaded"}"""
                    connection.getOutputStream().write(
                        ("HTTP/1.1 200 OK\r\nContent-Length: ${body.length}\r\nConnection: close\r\n\r\n" + body).toByteArray(),
                    )
                }
            }
        }

        fun bytes(): ByteArray = synchronized(received) { received.toByteArray() }
        private fun line(input: BufferedInputStream): String {
            val bytes = ByteArrayOutputStream()
            while (bytes.size() < 8_192) {
                val next = input.read()
                check(next >= 0)
                if (next == 10) return bytes.toString(Charsets.US_ASCII.name()).removeSuffix("\r")
                bytes.write(next)
            }
            error("HTTP header too large")
        }

        override fun close() {
            release.countDown()
            socket?.close()
            server.close()
            executor.shutdownNow()
        }
    }
}
