package com.vocahq.vocaphone.local

import android.content.Context
import android.net.ConnectivityManager
import android.os.StatFs
import java.io.File
import java.util.Locale
import kotlin.math.roundToLong

/**
 * What is worth saying before a first-run download starts.
 *
 * The catalog has always reasoned about the phone radio — the whole reason the
 * picker offers a small answer next to a 670 MB one — but nothing ever asked
 * the system whether the radio was actually in use, and nothing ever asked
 * whether the download would fit. Both answers are cheap, and both change what
 * the recommendation card should say.
 */
/** A download refused before it started because the phone has no room for it. */
class LocalModelStorageException(message: String) : Exception(message)

sealed interface DownloadWarning {
    /**
     * Not enough room. Reported before the transfer rather than after it, so a
     * full phone does not spend several minutes failing.
     */
    data class NotEnoughStorage(
        val freeBytes: Long,
        val requiredBytes: Long,
    ) : DownloadWarning

    /** A metered connection, where the size of the download is the user's bill. */
    data class MeteredConnection(val sizeBytes: Long) : DownloadWarning
}

/**
 * The headroom a download needs beyond the model itself.
 *
 * A model is staged into a sibling directory and only renamed over the target
 * once every digest matches, so the peak on disk is the download plus whatever
 * the extraction step holds. A quarter of the model, floored at 128 MB, covers
 * that without refusing a download that would have fit.
 */
internal fun storageHeadroomBytes(sizeBytes: Long): Long =
    maxOf(128L * 1_000_000L, sizeBytes / 4)

fun requiredStorageBytes(sizeBytes: Long): Long = sizeBytes + storageHeadroomBytes(sizeBytes)

/**
 * The one thing worth interrupting for, or null.
 *
 * Storage outranks the radio: a download that cannot finish is a hard stop,
 * while a metered one is the user's call. Only ever one warning, because two
 * stacked cautions on a setup card are read as neither.
 */
fun downloadWarning(
    sizeBytes: Long,
    freeBytes: Long,
    metered: Boolean,
    meteredThresholdBytes: Long = METERED_WARNING_THRESHOLD_BYTES,
): DownloadWarning? {
    val required = requiredStorageBytes(sizeBytes)
    // A zero reading means the query failed, not that the disk is full.
    if (freeBytes > 0 && freeBytes < required) {
        return DownloadWarning.NotEnoughStorage(freeBytes = freeBytes, requiredBytes = required)
    }
    if (metered && sizeBytes >= meteredThresholdBytes) {
        return DownloadWarning.MeteredConnection(sizeBytes)
    }
    return null
}

/**
 * Below this a download on mobile data is not worth a warning. Set just under
 * the smallest non-trivial catalog entry so the compact models — the ones the
 * warning would point someone at — never trigger it themselves.
 */
const val METERED_WARNING_THRESHOLD_BYTES = 100L * 1_000_000L

fun byteLabel(bytes: Long): String = if (bytes >= 1_000_000_000) {
    "%.1f GB".format(Locale.US, bytes / 1_000_000_000.0)
} else {
    "${bytes / 1_000_000} MB"
}

/**
 * How much longer the transfer has, in plain words, or null while the estimate
 * would still be noise.
 *
 * A rate measured over the first second of a transfer is mostly connection
 * setup, and an estimate that swings from "12 minutes" to "40 seconds" is worse
 * than no estimate at all. So nothing is claimed until the transfer has both
 * run for a moment and actually moved.
 */
fun downloadTimeRemaining(
    downloadedBytes: Long,
    totalBytes: Long,
    elapsedMillis: Long,
): String? {
    if (totalBytes <= 0 || downloadedBytes <= 0) return null
    if (elapsedMillis < MIN_ESTIMATE_ELAPSED_MILLIS) return null
    if (downloadedBytes >= totalBytes) return null
    val bytesPerMilli = downloadedBytes.toDouble() / elapsedMillis
    if (bytesPerMilli <= 0) return null
    val remainingMillis = ((totalBytes - downloadedBytes) / bytesPerMilli).roundToLong()
    val seconds = remainingMillis / 1000
    return when {
        seconds < 10 -> "a few seconds left"
        seconds < 45 -> "about ${((seconds + 5) / 10) * 10} seconds left"
        seconds < 90 -> "about a minute left"
        // Past an hour the figure is a guess dressed as a number, and saying
        // nothing is more honest than saying "about 74 minutes".
        seconds < 3600 -> "about ${(seconds + 30) / 60} minutes left"
        else -> null
    }
}

private const val MIN_ESTIMATE_ELAPSED_MILLIS = 2_500L

/** "412 MB of 670 MB", the line a bare percentage does not give. */
fun downloadSizeProgress(downloadedBytes: Long, totalBytes: Long): String? {
    if (totalBytes <= 0) return null
    return "${byteLabel(downloadedBytes.coerceIn(0, totalBytes))} of ${byteLabel(totalBytes)}"
}

/**
 * Whether the active connection bills by the byte.
 *
 * `isActiveNetworkMetered` already folds in the user's own "treat this Wi-Fi as
 * metered" choice, which is the answer that matters here rather than the
 * transport type.
 */
fun Context.isOnMeteredNetwork(): Boolean = runCatching {
    getSystemService(ConnectivityManager::class.java)?.isActiveNetworkMetered == true
}.getOrDefault(false)

/** Free space on the volume models are written to, or 0 when it cannot be read. */
fun availableStorageBytes(directory: File): Long = runCatching {
    StatFs(directory.absolutePath).availableBytes
}.getOrDefault(0L)
