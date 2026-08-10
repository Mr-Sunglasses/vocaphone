package com.vocahq.vocaphone.local

import java.io.File
import java.io.FileInputStream
import java.security.MessageDigest

class LocalModelIntegrityException(
    val modelId: String,
    val expected: String,
    val actual: String,
) : Exception("The downloaded model failed its SHA-256 check and was discarded.")

/**
 * Two levels of check, deliberately.
 *
 * [verifyDigests] hashes every pinned file and is what a download must pass. It
 * reads the whole model, which for a 1.5 GB whisper build is seconds of I/O, so
 * it must never sit on a path that runs per dictation or per process start.
 * [verifySizes] only stats the files and confirms the marker left behind by a
 * previous digest check still describes these exact pins, which is what the
 * launch and load paths use.
 */
object LocalModelIntegrity {
    const val VERIFIED_MARKER = ".vocaphone-verified"

    /** Stats every pinned file; optionally requires the digest marker as well. */
    fun verifySizes(
        model: LocalModelDescriptor,
        directory: File,
        requireMarker: Boolean = true,
    ) {
        model.files.forEach { pinned ->
            val file = File(directory, pinned.path)
            check(file.isFile) { "${model.displayName} is incomplete: ${pinned.path} is missing." }
            check(file.length() == pinned.sizeBytes) {
                "${pinned.path} has ${file.length()} bytes; expected ${pinned.sizeBytes}."
            }
        }
        if (requireMarker) {
            check(markerMatches(model, directory)) {
                "${model.displayName} has not been verified on this device."
            }
        }
    }

    /** Hashes every pinned file, then records the marker. */
    fun verifyDigests(model: LocalModelDescriptor, directory: File) {
        verifySizes(model, directory, requireMarker = false)
        model.files.forEach { pinned ->
            val actual = sha256(File(directory, pinned.path))
            if (!actual.equals(pinned.sha256, ignoreCase = true)) {
                throw LocalModelIntegrityException(model.id, pinned.sha256, actual)
            }
        }
        writeMarker(model, directory)
    }

    fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        FileInputStream(file).use { input ->
            val buffer = ByteArray(1024 * 1024)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                if (count > 0) digest.update(buffer, 0, count)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    /**
     * Identifies the pin set a directory was verified against, so a build that
     * changes a pin invalidates the marker instead of trusting stale bytes.
     */
    fun fingerprint(model: LocalModelDescriptor): String {
        val digest = MessageDigest.getInstance("SHA-256")
        model.files.sortedBy { it.path }.forEach { pinned ->
            digest.update("${pinned.path}|${pinned.sizeBytes}|${pinned.sha256}\n".toByteArray())
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    fun markerMatches(model: LocalModelDescriptor, directory: File): Boolean {
        val marker = File(directory, VERIFIED_MARKER)
        if (!marker.isFile) return false
        return runCatching { marker.readText().trim() }
            .getOrNull()
            ?.equals(fingerprint(model), ignoreCase = true) == true
    }

    fun writeMarker(model: LocalModelDescriptor, directory: File) {
        File(directory, VERIFIED_MARKER).writeText(fingerprint(model))
    }
}
