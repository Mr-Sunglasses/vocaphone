package com.vocahq.vocaphone.local

import android.content.Context
import java.io.File
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import okhttp3.Call
import okhttp3.OkHttpClient

/** App-private folder that holds the downloaded grammar model. */
const val GRAMMAR_MODELS_DIR = "grammar-models"

data class GrammarModelState(
    /** Every pinned file is present at its size and was digest-checked here once. */
    val ready: Boolean = false,
    val downloading: Boolean = false,
    val downloadedBytes: Long = 0,
    val totalBytes: Long = 0,
    /** What the last failed download says, in words; null once one succeeds. */
    val failure: String? = null,
)

/**
 * Storage, download and verification for the grammar model, apart from
 * [LocalModelManager].
 *
 * Separate on purpose: that manager's single download slot, its picker state
 * and its sweeps all belong to speech models, and a 28 MB grammar download must
 * neither queue behind a 600 MB speech model nor cancel one. What it shares is
 * the part that has to be right everywhere: [fetchPinnedFile] (SHA-256 while
 * streaming, HTTP resume) and [LocalModelIntegrity] (the `.vocaphone-verified`
 * marker and its pin fingerprint). Files land in a staging folder and are
 * renamed into place only once all of them match.
 */
class GrammarModelStore internal constructor(
    private val root: File,
    private val model: GrammarModelDescriptor = GrammarModelCatalog.tagger,
    private val client: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(30, TimeUnit.SECONDS)
        .readTimeout(2, TimeUnit.MINUTES)
        .build(),
    private val downloadUrl: (PinnedFile) -> String = { GrammarModelCatalog.downloadUrl(model, it) },
) {
    constructor(context: Context) : this(File(context.applicationContext.filesDir, GRAMMAR_MODELS_DIR))

    private val mutex = Mutex()
    private val activeCall = AtomicReference<Call?>(null)
    private val cancelled = AtomicBoolean(false)
    private val activeJob = AtomicReference<Job?>(null)
    private val _state = MutableStateFlow(GrammarModelState(totalBytes = model.sizeBytes))
    val state: StateFlow<GrammarModelState> = _state.asStateFlow()

    val sizeBytes: Long get() = model.sizeBytes

    /** Where the verified files live. Only meaningful while [isReady]. */
    val directory: File get() = File(root, model.id)

    /**
     * The folder inside [directory] that holds the model's own files, keeping
     * the repository's layout (`onnx/`). This is what a loader opens.
     */
    val modelDirectory: File
        get() = GrammarModelCatalog.modelFolder(model).let { if (it.isEmpty()) directory else File(directory, it) }

    private val staging: File get() = File(root, ".${model.id}.staging")

    /** Stat-only: safe on any path that runs per dictation. */
    fun isReady(): Boolean = runCatching {
        LocalModelIntegrity.verifySizes(model.displayName, model.files, directory)
    }.isSuccess

    /**
     * Re-reads the folder. Files that are present at the right sizes but carry
     * no marker for these pins (a build that moved the pin, or a marker lost to
     * a crash) are hashed once here, never on the dictation path.
     */
    suspend fun refresh() = withContext(Dispatchers.IO) {
        mutex.withLock {
            deleteAbandonedStaging()
            val ready = isReady() || runCatching {
                LocalModelIntegrity.verifyDigests(model.id, model.displayName, model.files, directory)
            }.isSuccess
            _state.update { it.copy(ready = ready) }
        }
    }

    /**
     * Fetches and verifies every pinned file. Returns normally only when the
     * model is ready; every failure throws, after recording a sentence in
     * [state].
     */
    suspend fun download() = withContext(Dispatchers.IO) {
        mutex.withLock {
            if (isReady()) {
                _state.update { it.copy(ready = true, failure = null) }
                return@withLock
            }
            root.mkdirs()
            val stagedBytes = staging.walkBottomUp().filter(File::isFile).sumOf(File::length)
            val needed = (requiredStorageBytes(model.sizeBytes) - stagedBytes).coerceAtLeast(0)
            val free = availableStorageBytes(root)
            if (free in 1..<needed) {
                val sentence = "The grammar model needs ${byteLabel(needed)} free and this " +
                    "phone has ${byteLabel(free)}. Free up some space and try again."
                _state.update { it.copy(failure = sentence) }
                throw LocalModelStorageException(sentence)
            }
            // Kept from an interrupted attempt, so the files continue.
            staging.mkdirs()
            cancelled.set(false)
            activeJob.set(currentCoroutineContext()[Job])
            _state.update {
                it.copy(downloading = true, failure = null, downloadedBytes = 0, totalBytes = model.sizeBytes)
            }
            try {
                var completed = 0L
                model.files.forEach { pinned ->
                    // A cancel can land while no request is open -- hashing a
                    // resumed prefix, between files -- where aborting the call
                    // reaches nothing.
                    throwIfCancelled()
                    val destination = File(staging, pinned.path)
                    destination.parentFile?.mkdirs()
                    val actual = fetchPinnedFile(
                        client = client,
                        url = downloadUrl(pinned),
                        destination = destination,
                        expectedBytes = pinned.sizeBytes,
                        activeCall = activeCall,
                        onProgress = { onDisk ->
                            _state.update { it.copy(downloadedBytes = completed + onDisk) }
                        },
                    )
                    if (destination.length() != pinned.sizeBytes) {
                        throw ModelDownloadSizeException(pinned.path, destination.length(), pinned.sizeBytes)
                    }
                    if (!actual.equals(pinned.sha256, ignoreCase = true)) {
                        throw LocalModelIntegrityException(model.id, pinned.sha256, actual)
                    }
                    completed += pinned.sizeBytes
                }
                throwIfCancelled()
                // Each file was hashed as it streamed in; only the set is left.
                LocalModelIntegrity.verifySizes(model.displayName, model.files, staging, requireMarker = false)
                LocalModelIntegrity.writeMarker(model.files, staging)
                directory.deleteRecursively()
                check(staging.renameTo(directory)) { "Could not commit the verified grammar model" }
                LocalModelIntegrity.verifySizes(model.displayName, model.files, directory)
                _state.update { it.copy(ready = true, downloadedBytes = model.sizeBytes) }
            } catch (error: CancellationException) {
                staging.deleteRecursively()
                throw error
            } catch (error: Throwable) {
                // [cancel] aborts the blocking call, which surfaces as an
                // IOException rather than a cancellation.
                if (cancelled.get()) {
                    staging.deleteRecursively()
                    throw CancellationException("Grammar model download canceled", error)
                }
                if (!keepsPartialDownload(error, cancelReason = null)) staging.deleteRecursively()
                _state.update { it.copy(failure = downloadFailureMessage("The grammar model", error)) }
                throw error
            } finally {
                activeJob.set(null)
                _state.update { it.copy(downloading = false) }
            }
        }
    }

    /** Stops a download in flight and discards what it fetched. */
    fun cancel() {
        cancelled.set(true)
        activeJob.get()?.cancel()
        activeCall.get()?.cancel()
    }

    private fun throwIfCancelled() {
        if (cancelled.get()) throw CancellationException("Grammar model download canceled")
    }

    /** Removes the model and any half-finished download of it. Returns whether everything went. */
    suspend fun delete(): Boolean = withContext(Dispatchers.IO) {
        cancel()
        mutex.withLock {
            val removed = directory.deleteRecursively() and staging.deleteRecursively()
            _state.update { it.copy(ready = isReady(), failure = null, downloadedBytes = 0) }
            removed
        }
    }

    /**
     * What app start does: sweeps retired models, re-reads the folder, and
     * downloads the current model when [wanted] says a grammar setting is on
     * over missing files. Returns whether it downloaded one.
     *
     * The settings can only be turned on once the files are verified, so on
     * over missing files means an update moved the pin or an earlier attempt
     * at this download failed. Whoever turned the setting on agreed to the
     * download already, so it is retried on every start until it succeeds,
     * not only on the start that removed the old folder. [wanted] is asked
     * only when the files are missing, and nobody who never turned grammar on
     * gets a download.
     */
    suspend fun restore(
        retired: List<String> = GrammarModelCatalog.retiredIds,
        wanted: suspend () -> Boolean,
    ): Boolean {
        removeRetired(retired)
        refresh()
        if (state.value.ready || !wanted()) return false
        return runCatching { download() }.isSuccess
    }

    /**
     * Removes the folders of grammar models this build no longer pins.
     * Returns whether there was one.
     */
    suspend fun removeRetired(retired: List<String> = GrammarModelCatalog.retiredIds): Boolean =
        withContext(Dispatchers.IO) {
            mutex.withLock {
                retired.filter { it != model.id }.fold(false) { found, id ->
                    val folder = File(root, id)
                    val staged = File(root, ".$id.staging")
                    val existed = folder.exists() || staged.exists()
                    folder.deleteRecursively()
                    staged.deleteRecursively()
                    found || existed
                }
            }
        }

    private fun deleteAbandonedStaging(now: Long = System.currentTimeMillis()) {
        if (!staging.exists()) return
        val newest = staging.walkBottomUp().maxOfOrNull(File::lastModified) ?: 0L
        if (now - newest > ABANDONED_STAGING_MILLIS) staging.deleteRecursively()
    }
}
