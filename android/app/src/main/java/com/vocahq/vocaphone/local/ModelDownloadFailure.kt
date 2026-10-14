package com.vocahq.vocaphone.local

import java.io.IOException
import java.net.UnknownHostException

/** The model host answered, but not with the file. */
class ModelDownloadHttpException(val code: Int) : IOException("Model download failed: HTTP $code")

/** A file arrived complete as far as the server was concerned, but at the wrong size. */
class ModelDownloadSizeException(path: String, actual: Long, expected: Long) :
    Exception("$path downloaded $actual bytes; expected $expected.")

/**
 * Where to pick a partly downloaded file back up.
 *
 * A file already on disk is reused only when it is no longer than the pinned
 * size: anything longer is not a prefix of the file we want. Whatever is kept
 * is hashed again before the rest is appended, so the SHA-256 the download is
 * checked against still covers every byte -- resuming changes where the bytes
 * came from, never what they are checked against.
 */
internal fun resumeOffset(existingBytes: Long, expectedBytes: Long): Long =
    if (existingBytes in 1..expectedBytes) existingBytes else 0L

/**
 * Whether a server honoured `Range: bytes=[offset]-`. Only a 206 whose
 * Content-Range starts exactly at [offset] is appended to the partial file; a
 * 200 is the whole file again, and anything else is not trusted at all.
 */
internal fun rangeHonoured(offset: Long, code: Int, contentRange: String?): Boolean {
    if (offset <= 0L || code != 206 || contentRange == null) return false
    val start = contentRange.trim()
        .removePrefix("bytes")
        .trim()
        .substringBefore('-')
        .toLongOrNull()
    return start == offset
}

/**
 * Whether the partly downloaded files are worth keeping for a Retry.
 *
 * A dropped connection, a server hiccup or Android's six-hour limit leaves a
 * good prefix behind, and starting a 600 MB download over because the train
 * went into a tunnel is the failure people complained about. A failed checksum
 * or wrong size means the bytes themselves are bad, and a user's own Cancel
 * means they did not want the download; both are deleted.
 */
internal fun keepsPartialDownload(error: Throwable?, cancelReason: DownloadCancelReason?): Boolean = when {
    cancelReason != null -> cancelReason == DownloadCancelReason.TIME_LIMIT
    error is LocalModelIntegrityException || error is ModelDownloadSizeException -> false
    error is ModelDownloadHttpException -> error.code == 429 || error.code >= 500
    error is IOException -> true
    else -> false
}

/**
 * What the Models page says when a download fails, in words rather than the
 * exception text it used to show ("Model download failed: HTTP 503",
 * "unexpected end of stream on https://…").
 */
internal fun downloadFailureMessage(modelName: String, error: Throwable): String = when (error) {
    is LocalModelStorageException -> error.message ?: "There is not enough free space for $modelName."
    is LocalModelIntegrityException, is ModelDownloadSizeException ->
        "$modelName did not match its checksum, so the download was discarded. Tap Retry to download it again."
    is ModelDownloadHttpException -> when {
        error.code == 404 -> "$modelName is no longer at its download address. Try another model."
        error.code == 429 || error.code >= 500 ->
            "The download server is busy. Tap Retry in a few minutes to continue the download."
        else -> "The download server refused the request (error ${error.code}). Try again later."
    }
    is UnknownHostException ->
        "No internet connection. Connect, then tap Retry to continue the download."
    is IOException -> "The connection dropped. Tap Retry to continue the download."
    else -> "$modelName could not be downloaded. Tap Retry to try again."
}
