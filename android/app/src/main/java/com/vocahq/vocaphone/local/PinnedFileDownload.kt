package com.vocahq.vocaphone.local

import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.security.MessageDigest
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import okhttp3.Call
import okhttp3.OkHttpClient
import okhttp3.Request

/**
 * Streams one pinned file to [destination] and returns its SHA-256.
 *
 * Continues a partial file left by an interrupted attempt with an HTTP Range
 * request. The bytes already there are hashed first, so the digest returned --
 * and checked against the pin -- covers the whole file exactly as a fresh
 * download's would. A server that ignores the range gets the file from the
 * start.
 *
 * Shared by the speech models and the grammar model so both get the same
 * resume and hashing. [onResumed] hears the bytes carried over from disk (and
 * the same amount negated when the server ignores the range and sends them
 * again); [onProgress] hears how much of this file is on disk.
 */
internal suspend fun fetchPinnedFile(
    client: OkHttpClient,
    url: String,
    destination: File,
    expectedBytes: Long,
    activeCall: AtomicReference<Call?>,
    onResumed: (bytes: Long) -> Unit = {},
    onProgress: (bytesOnDisk: Long) -> Unit = {},
): String {
    val digest = MessageDigest.getInstance("SHA-256")
    val offset = resumeOffset(if (destination.isFile) destination.length() else 0L, expectedBytes)
    if (offset == 0L) {
        destination.delete()
    } else {
        hashInto(digest, destination)
        onResumed(offset)
        onProgress(offset)
        // Complete already; there is nothing left to ask the server for.
        if (offset == expectedBytes) return digest.hex()
    }
    val request = Request.Builder().url(url).apply {
        if (offset > 0L) header("Range", "bytes=$offset-")
    }.build()
    val call = client.newCall(request)
    activeCall.set(call)
    // Tie coroutine cancellation to the blocking OkHttp call too. This
    // closes the small race between finishing one file and starting the
    // next one, where the UI could otherwise cancel the job while the
    // synchronous request kept running.
    val cancellationHandle = currentCoroutineContext()[Job]?.invokeOnCompletion {
        call.cancel()
    }
    try {
        val response = call.execute()
        response.use { result ->
            if (!result.isSuccessful) throw ModelDownloadHttpException(result.code)
            val append = rangeHonoured(offset, result.code, result.header("Content-Range"))
            var written = if (append) offset else 0L
            if (!append && offset > 0L) {
                digest.reset()
                // The server sent the whole file: the bytes on disk are
                // being fetched again, not carried over.
                onResumed(-offset)
            }
            FileOutputStream(destination, append).use { output ->
                result.body.byteStream().use { input ->
                    val buffer = ByteArray(1024 * 1024)
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        if (count == 0) continue
                        output.write(buffer, 0, count)
                        digest.update(buffer, 0, count)
                        written += count
                        onProgress(written)
                    }
                }
            }
            return digest.hex()
        }
    } finally {
        cancellationHandle?.dispose()
        activeCall.compareAndSet(call, null)
    }
}

private suspend fun hashInto(digest: MessageDigest, file: File) {
    FileInputStream(file).use { input ->
        val buffer = ByteArray(1024 * 1024)
        while (true) {
            currentCoroutineContext().ensureActive()
            val count = input.read(buffer)
            if (count < 0) break
            digest.update(buffer, 0, count)
        }
    }
}

private fun MessageDigest.hex(): String = digest().joinToString("") { "%02x".format(it) }
