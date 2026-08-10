package com.vocahq.vocaphone.local

import java.io.File
import java.security.MessageDigest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class LocalModelIntegrityTest {
    private fun sha256(text: String) = MessageDigest.getInstance("SHA-256")
        .digest(text.toByteArray())
        .joinToString("") { "%02x".format(it) }

    private fun descriptor(vararg files: PinnedFile) = LocalModelDescriptor(
        id = "test",
        displayName = "Test",
        engine = LocalModelEngine.WHISPER,
        repository = "example/repo",
        revision = "0".repeat(40),
        files = files.toList(),
        sizeBytes = files.sumOf { it.sizeBytes },
        minimumRamGB = 1,
        languages = "English",
    )

    private fun directory(vararg contents: Pair<String, String>): File {
        val root = File.createTempFile("vocaphone-model", "").also {
            it.delete()
            it.mkdirs()
        }
        contents.forEach { (name, text) -> File(root, name).writeText(text) }
        return root
    }

    @Test
    fun sha256IsStableForDownloadedBytes() {
        val root = directory("weights.bin" to "verified model bytes")
        try {
            assertEquals(
                sha256("verified model bytes"),
                LocalModelIntegrity.sha256(File(root, "weights.bin")),
            )
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun mismatchedShaIsRejected() {
        val root = directory("weights.bin" to "tampered bytes")
        val model = descriptor(
            PinnedFile("weights.bin", "tampered bytes".length.toLong(), "0".repeat(64)),
        )
        try {
            assertThrows(LocalModelIntegrityException::class.java) {
                LocalModelIntegrity.verifyDigests(model, root)
            }
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun everyPinnedFileMustBePresent() {
        val root = directory("encoder.onnx" to "encoder")
        val model = descriptor(
            PinnedFile("encoder.onnx", 7, sha256("encoder")),
            PinnedFile("decoder.onnx", 7, sha256("decoder")),
        )
        try {
            assertThrows(IllegalStateException::class.java) {
                LocalModelIntegrity.verifyDigests(model, root)
            }
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun digestPassWritesMarkerThatTheCheapPassAccepts() {
        val root = directory("weights.bin" to "good bytes")
        val model = descriptor(PinnedFile("weights.bin", 10, sha256("good bytes")))
        try {
            assertFalse(LocalModelIntegrity.markerMatches(model, root))
            LocalModelIntegrity.verifyDigests(model, root)
            assertTrue(LocalModelIntegrity.markerMatches(model, root))
            LocalModelIntegrity.verifySizes(model, root)
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun cheapPassRejectsADirectoryThatWasNeverDigestChecked() {
        val root = directory("weights.bin" to "good bytes")
        val model = descriptor(PinnedFile("weights.bin", 10, sha256("good bytes")))
        try {
            LocalModelIntegrity.verifySizes(model, root, requireMarker = false)
            assertThrows(IllegalStateException::class.java) {
                LocalModelIntegrity.verifySizes(model, root)
            }
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun changingAPinInvalidatesTheMarker() {
        val root = directory("weights.bin" to "good bytes")
        val model = descriptor(PinnedFile("weights.bin", 10, sha256("good bytes")))
        try {
            LocalModelIntegrity.verifyDigests(model, root)
            val repinned = descriptor(PinnedFile("weights.bin", 10, "1".repeat(64)))
            assertNotEquals(
                LocalModelIntegrity.fingerprint(model),
                LocalModelIntegrity.fingerprint(repinned),
            )
            assertFalse(LocalModelIntegrity.markerMatches(repinned, root))
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun catalogPinsAreWellFormedAndUnique() {
        val ids = LocalModelCatalog.all.map { it.id }
        assertEquals(ids.size, ids.toSet().size)
        LocalModelCatalog.all.forEach { model ->
            assertTrue("${model.id} has no files", model.files.isNotEmpty())
            assertEquals(
                "${model.id} advertises the wrong size",
                model.files.sumOf { it.sizeBytes },
                model.sizeBytes,
            )
            model.files.forEach { pinned ->
                assertEquals("${model.id}/${pinned.path} sha", 64, pinned.sha256.length)
                assertTrue("${model.id}/${pinned.path} bytes", pinned.sizeBytes > 0)
            }
            if (model.engine == LocalModelEngine.SHERPA_ONNX) {
                assertTrue("${model.id} needs a family", model.sherpaFamily != null)
                assertTrue(
                    "${model.id} needs tokens.txt",
                    model.files.any { it.path == "tokens.txt" },
                )
            }
        }
    }
}
