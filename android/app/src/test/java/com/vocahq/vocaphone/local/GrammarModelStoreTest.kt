package com.vocahq.vocaphone.local

import java.io.File
import java.security.MessageDigest
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.runBlocking
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import okhttp3.OkHttpClient
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class GrammarModelStoreTest {
    @get:Rule val temp = TemporaryFolder()

    private val bodies = mapOf("model.onnx" to "pretend weights", "labels.json" to "[\"KEEP\"]")

    private fun sha256(text: String) = MessageDigest.getInstance("SHA-256")
        .digest(text.toByteArray())
        .joinToString("") { "%02x".format(it) }

    private val model = GrammarModelDescriptor(
        id = "grammar-test",
        displayName = "Grammar model",
        repository = "example/grammar",
        revision = "0".repeat(40),
        files = bodies.map { (path, body) -> PinnedFile(path, body.length.toLong(), sha256(body)) },
        sizeBytes = bodies.values.sumOf { it.length.toLong() },
    )

    private fun store(server: MockWebServer, root: File = temp.root) = GrammarModelStore(
        root = root,
        model = model,
        client = OkHttpClient.Builder().readTimeout(5, TimeUnit.SECONDS).build(),
        downloadUrl = { server.url("/${it.path}").toString() },
    )

    private fun ok(body: String) = MockResponse.Builder().code(200).body(body).build()

    @Test
    fun downloadVerifiesCommitsAndMarksTheModel() = runBlocking {
        MockWebServer().use { server ->
            server.start()
            bodies.values.forEach { server.enqueue(ok(it)) }
            val store = store(server)
            assertFalse(store.isReady())

            store.download()

            assertTrue(store.isReady())
            assertTrue(store.state.value.ready)
            assertNull(store.state.value.failure)
            assertEquals(model.sizeBytes, store.state.value.downloadedBytes)
            assertEquals(File(temp.root, model.id), store.directory)
            assertTrue(LocalModelIntegrity.markerMatches(model.files, store.directory))
            assertFalse(File(temp.root, ".${model.id}.staging").exists())
        }
    }

    @Test
    fun aChecksumMismatchDiscardsTheFilesAndSaysSo() = runBlocking {
        MockWebServer().use { server ->
            server.start()
            server.enqueue(ok("pretend weightz"))
            val store = store(server)

            assertThrows(LocalModelIntegrityException::class.java) { runBlocking { store.download() } }

            assertFalse(store.isReady())
            assertNotNull(store.state.value.failure)
            assertFalse(store.state.value.downloading)
            assertFalse(File(temp.root, ".${model.id}.staging").exists())
        }
    }

    @Test
    fun aServerErrorKeepsThePrefixAndRetryResumesIt() = runBlocking {
        MockWebServer().use { server ->
            server.start()
            val weights = bodies.getValue("model.onnx")
            // An earlier attempt left the first half of the weights behind.
            val staging = File(temp.root, ".${model.id}.staging").also { it.mkdirs() }
            File(staging, "model.onnx").writeText(weights.take(7))
            server.enqueue(MockResponse.Builder().code(503).build())
            val store = store(server)

            assertThrows(ModelDownloadHttpException::class.java) { runBlocking { store.download() } }
            assertEquals(7L, File(staging, "model.onnx").length())

            server.enqueue(
                MockResponse.Builder().code(206)
                    .addHeader("Content-Range", "bytes 7-${weights.length - 1}/${weights.length}")
                    .body(weights.drop(7))
                    .build(),
            )
            server.enqueue(ok(bodies.getValue("labels.json")))
            store.download()

            assertTrue(store.isReady())
            server.takeRequest(5, TimeUnit.SECONDS) // the 503
            assertEquals("bytes=7-", server.takeRequest(5, TimeUnit.SECONDS)!!.headers["Range"])
        }
    }

    @Test
    fun refreshHashesUnmarkedFilesOnceAndDeleteRemovesThem() = runBlocking {
        MockWebServer().use { server ->
            val directory = File(temp.root, model.id).also { it.mkdirs() }
            bodies.forEach { (path, body) -> File(directory, path).writeText(body) }
            val store = store(server)
            assertFalse(store.isReady())

            store.refresh()
            assertTrue(store.state.value.ready)
            assertTrue(store.isReady())

            assertTrue(store.delete())
            assertFalse(store.isReady())
            assertFalse(store.state.value.ready)
            assertFalse(directory.exists())
        }
    }

    @Test
    fun aMarkerForOtherPinsIsNotTrusted() {
        val directory = File(temp.root, model.id).also { it.mkdirs() }
        bodies.forEach { (path, body) -> File(directory, path).writeText(body) }
        LocalModelIntegrity.writeMarker(model.files.map { it.copy(sha256 = "0".repeat(64)) }, directory)
        MockWebServer().use { server -> assertFalse(store(server).isReady()) }
    }

    /** Greptile on #415: a cancel with no request open must still stop the install. */
    @Test
    fun aCancelMidDownloadNeverInstallsTheModel() = runBlocking {
        MockWebServer().use { server ->
            lateinit var store: GrammarModelStore
            server.dispatcher = object : mockwebserver3.Dispatcher() {
                override fun dispatch(request: mockwebserver3.RecordedRequest): MockResponse {
                    // The first file is served whole; the cancel lands as it
                    // finishes, before the second request exists.
                    store.cancel()
                    return ok(bodies.getValue(request.url.encodedPath.removePrefix("/")))
                }
            }
            server.start()
            store = store(server)

            assertThrows(kotlinx.coroutines.CancellationException::class.java) { runBlocking { store.download() } }

            assertFalse(store.isReady())
            assertFalse(File(temp.root, model.id).exists())
            assertFalse(File(temp.root, ".${model.id}.staging").exists())
            assertEquals(1, server.requestCount)
        }
    }

    /** The pinned v2.0 files live in the repository's `onnx/` folder, and keep it on disk. */
    @Test
    fun filesInAFolderLandInThatFolder() = runBlocking {
        val nested = model.copy(files = model.files.map { it.copy(path = "onnx/${it.path}") })
        MockWebServer().use { server ->
            server.start()
            bodies.values.forEach { server.enqueue(ok(it)) }
            val store = GrammarModelStore(
                root = temp.root,
                model = nested,
                client = OkHttpClient.Builder().readTimeout(5, TimeUnit.SECONDS).build(),
                downloadUrl = { server.url("/${it.path}").toString() },
            )

            store.download()

            assertTrue(store.isReady())
            assertEquals(File(temp.root, "${model.id}/onnx"), store.modelDirectory)
            assertTrue(File(store.modelDirectory, "model.onnx").isFile)
        }
    }

    @Test
    fun aRetiredModelsFolderIsRemovedAndReported() = runBlocking {
        MockWebServer().use { server ->
            server.start()
            val old = File(temp.root, "grammar-old").apply { mkdirs() }
            File(old, "model.onnx").writeText("old weights")
            val store = store(server)

            assertTrue(store.removeRetired(listOf("grammar-old")))
            assertFalse(old.exists())
            assertFalse(store.removeRetired(listOf("grammar-old")))
        }
    }

    @Test
    fun theCurrentModelIsNeverRemovedAsRetired() = runBlocking {
        MockWebServer().use { server ->
            server.start()
            bodies.values.forEach { server.enqueue(ok(it)) }
            val store = store(server)
            store.download()

            assertFalse(store.removeRetired(listOf(model.id)))
            assertTrue(store.isReady())
        }
    }

    /**
     * Greptile on #435: the first start after an update removes the old
     * folder; if that download fails, the next start has no old folder to
     * find and must still retry.
     */
    @Test
    fun aFailedUpgradeDownloadIsRetriedOnTheNextStart() = runBlocking {
        MockWebServer().use { server ->
            server.start()
            val old = File(temp.root, "grammar-old").apply { mkdirs() }
            File(old, "model.onnx").writeText("old weights")
            server.enqueue(MockResponse.Builder().code(404).build())

            assertFalse(store(server).restore(retired = listOf("grammar-old")) { true })
            assertFalse(old.exists())

            bodies.values.forEach { server.enqueue(ok(it)) }
            val nextStart = store(server)
            assertTrue(nextStart.restore(retired = listOf("grammar-old")) { true })
            assertTrue(nextStart.isReady())
        }
    }

    @Test
    fun noGrammarSettingOnMeansNoDownloadAtStart() = runBlocking {
        MockWebServer().use { server ->
            server.start()
            val store = store(server)

            assertFalse(store.restore(retired = emptyList()) { false })

            assertFalse(store.isReady())
            assertEquals(0, server.requestCount)
        }
    }

    @Test
    fun aReadyModelIsNotDownloadedAgainOrTheSettingsAsked() = runBlocking {
        MockWebServer().use { server ->
            val directory = File(temp.root, model.id).also { it.mkdirs() }
            bodies.forEach { (path, body) -> File(directory, path).writeText(body) }
            val store = store(server)

            assertFalse(store.restore(retired = emptyList()) { error("asked although the model is ready") })

            assertTrue(store.isReady())
            assertEquals(0, server.requestCount)
        }
    }
}
