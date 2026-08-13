package com.vocahq.vocaphone.local

import android.app.ActivityManager
import android.content.Context
import com.vocahq.vocaphone.audio.CaptureFormat
import com.vocahq.vocaphone.audio.SpeechAudioConditioning
import com.vocahq.vocaphone.core.CustomVocabulary
import com.vocahq.vocaphone.core.TranscriptionQuality
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.isActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.yield
import okhttp3.Call
import okhttp3.OkHttpClient
import okhttp3.Request

/**
 * What an on-device engine produced, and the language it actually decoded.
 *
 * The language matters because the writing styles punctuate by script — a
 * Devanagari sentence ends in a danda, not a full stop — and with Automatic
 * selected the request says only "auto". Whisper detects and reports; the
 * sherpa bridges do not expose it, so they leave this empty and the styler
 * falls back to inspecting the text.
 */
data class LocalTranscription(val text: String, val language: String = "")

data class LocalModelState(
    val downloaded: Set<String> = emptySet(),
    val downloading: String? = null,
    val progress: Int = 0,
    val message: String? = null,
    /** Reported so the picker can hide models this phone cannot run. */
    val totalRamGB: Long = 0,
    /**
     * The model being loaded into memory right now, if any.
     *
     * Loading is slow enough to be worth saying out loud — hundreds of megabytes
     * of ONNX or GGML — and it happens again whenever the accuracy setting
     * changes a sherpa engine. Without this a dictation started in that window
     * just appears to hang.
     */
    val preparing: String? = null,
)

/** Owns model storage, atomic downloads, and the verified inference engine. */
class LocalModelManager(
    context: Context,
    private val client: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(30, TimeUnit.SECONDS)
        .readTimeout(10, TimeUnit.MINUTES)
        .build(),
) {
    private val appContext = context.applicationContext
    private val modelRoot = File(appContext.filesDir, "local-models").also { it.mkdirs() }
    private val downloadMutex = Mutex()
    private val engineMutex = Mutex()
    private val _state = MutableStateFlow(LocalModelState())
    val state: StateFlow<LocalModelState> = _state.asStateFlow()
    private val totalRamGB: Long by lazy {
        val info = ActivityManager.MemoryInfo()
        appContext.getSystemService(ActivityManager::class.java)?.getMemoryInfo(info)
        info.totalMem / (1024L * 1024L * 1024L)
    }
    private var whisperContext: WhisperContext? = null
    private var sherpaRecognizer: SherpaRecognizer? = null
    private var loadedModelID: String? = null
    private var loadedLanguage: String? = null

    /**
     * Sherpa bakes the decoding method into the recognizer, so changing quality
     * means building a new one. Whisper takes its search parameters per call and
     * does not care.
     */
    private var loadedQuality: TranscriptionQuality? = null
    /** The coroutine cannot interrupt a blocking OkHttp execute by itself. */
    private val activeDownloadCall = AtomicReference<Call?>(null)

    /**
     * Stat-only pass. Anything present but not yet marked as digest-checked is
     * hashed once afterwards, off this path: an IME process starts often enough
     * that hashing gigabytes on every start is a battery bug of its own.
     */
    suspend fun refresh() = withContext(Dispatchers.IO) {
        _state.value = _state.value.copy(totalRamGB = totalRamGB)
        migrateLegacyLayout()
        val verified = mutableSetOf<String>()
        val pending = mutableListOf<LocalModelDescriptor>()
        LocalModelCatalog.all.forEach { model ->
            val directory = directoryFor(model)
            val present = runCatching {
                LocalModelIntegrity.verifySizes(model, directory, requireMarker = false)
            }.isSuccess
            if (!present) return@forEach
            if (LocalModelIntegrity.markerMatches(model, directory)) {
                verified += model.id
            } else {
                pending += model
            }
        }
        _state.value = _state.value.copy(downloaded = verified)
        pending.forEach { model ->
            val directory = directoryFor(model)
            val ok = runCatching { LocalModelIntegrity.verifyDigests(model, directory) }.isSuccess
            _state.value = if (ok) {
                _state.value.copy(downloaded = _state.value.downloaded + model.id)
            } else {
                directory.deleteRecursively()
                _state.value.copy(downloaded = _state.value.downloaded - model.id)
            }
        }
    }

    /**
     * Whisper models used to live as bare `ggml-*.bin` files in the root. Moving
     * them into their own directory saves testers a multi-gigabyte re-download.
     */
    private fun migrateLegacyLayout() {
        LocalModelCatalog.all
            .filter { it.engine == LocalModelEngine.WHISPER }
            .forEach { model ->
                val legacy = File(modelRoot, model.primaryFile.path)
                if (!legacy.isFile) return@forEach
                val directory = directoryFor(model)
                val target = File(directory, model.primaryFile.path)
                if (target.isFile) {
                    legacy.delete()
                    return@forEach
                }
                directory.mkdirs()
                if (!legacy.renameTo(target)) legacy.delete()
            }
    }

    fun totalRamGB(): Long = totalRamGB

    fun isDownloaded(id: String): Boolean = id in _state.value.downloaded

    fun directoryFor(model: LocalModelDescriptor): File = File(modelRoot, model.id)

    /** Cancels the in-flight HTTP request as well as the caller's coroutine. */
    fun cancelDownload() {
        activeDownloadCall.get()?.cancel()
    }

    suspend fun download(model: LocalModelDescriptor) = downloadMutex.withLock {
        require(LocalModelCatalog.isUsableOnDevice(model, totalRamGB)) {
            if (model.engine == LocalModelEngine.SHERPA_ONNX && !LocalModelCatalog.sherpaAvailable) {
                "${model.displayName} needs an Arm device."
            } else {
                "${model.displayName} needs at least ${model.minimumRamGB} GB of RAM."
            }
        }
        withContext(Dispatchers.IO) {
            val target = directoryFor(model)
            if (runCatching { LocalModelIntegrity.verifySizes(model, target) }.isSuccess) {
                _state.value = _state.value.copy(downloaded = _state.value.downloaded + model.id)
                return@withContext
            }

            val staging = File(modelRoot, ".${model.id}.staging")
            staging.deleteRecursively()
            staging.mkdirs()
            _state.value = _state.value.copy(
                downloading = model.id,
                progress = 0,
                message = null,
            )
            try {
                var completed = 0L
                model.files.forEach { pinned ->
                    val destination = File(staging, pinned.path)
                    destination.parentFile?.mkdirs()
                    val actual = downloadFile(
                        url = LocalModelCatalog.downloadUrl(model, pinned),
                        destination = destination,
                        alreadyCompleted = completed,
                        totalBytes = model.sizeBytes,
                    )
                    if (destination.length() != pinned.sizeBytes) {
                        error(
                            "${pinned.path} downloaded ${destination.length()} bytes; " +
                                "expected ${pinned.sizeBytes}.",
                        )
                    }
                    if (!actual.equals(pinned.sha256, ignoreCase = true)) {
                        throw LocalModelIntegrityException(model.id, pinned.sha256, actual)
                    }
                    completed += pinned.sizeBytes
                }

                LocalModelIntegrity.verifyDigests(model, staging)
                target.deleteRecursively()
                check(staging.renameTo(target)) { "Could not commit the verified model" }
                LocalModelIntegrity.verifySizes(model, target)
                _state.value = _state.value.copy(
                    downloaded = _state.value.downloaded + model.id,
                    progress = 100,
                    message = "${model.displayName} downloaded and verified.",
                )
            } catch (error: CancellationException) {
                staging.deleteRecursively()
                _state.value = _state.value.copy(message = "Model download canceled.")
                throw error
            } catch (error: Throwable) {
                if (!currentCoroutineContext().isActive) {
                    staging.deleteRecursively()
                    _state.value = _state.value.copy(message = "Model download canceled.")
                    throw CancellationException("Model download canceled", error)
                }
                staging.deleteRecursively()
                _state.value = _state.value.copy(
                    message = error.localizedMessage ?: "Model download failed",
                )
                throw error
            } finally {
                _state.value = _state.value.copy(downloading = null)
            }
        }
    }

    /** Streams one file to disk and returns its SHA-256. */
    private suspend fun downloadFile(
        url: String,
        destination: File,
        alreadyCompleted: Long,
        totalBytes: Long,
    ): String {
        val call = client.newCall(Request.Builder().url(url).build())
        activeDownloadCall.set(call)
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
                check(result.isSuccessful) { "Model download failed: HTTP ${result.code}" }
                val digest = MessageDigest.getInstance("SHA-256")
                var written = 0L
                FileOutputStream(destination).use { output ->
                    result.body.byteStream().use { input ->
                        val buffer = ByteArray(1024 * 1024)
                        while (true) {
                            val count = input.read(buffer)
                            if (count < 0) break
                            if (count == 0) continue
                            output.write(buffer, 0, count)
                            digest.update(buffer, 0, count)
                            written += count
                            _state.value = _state.value.copy(
                                progress = (((alreadyCompleted + written) * 100) / totalBytes)
                                    .toInt().coerceIn(0, 99),
                            )
                        }
                    }
                }
                return digest.digest().joinToString("") { "%02x".format(it) }
            }
        } finally {
            cancellationHandle?.dispose()
            activeDownloadCall.compareAndSet(call, null)
        }
    }

    suspend fun delete(model: LocalModelDescriptor) = withContext(Dispatchers.IO) {
        engineMutex.withLock {
            if (loadedModelID == model.id) releaseEngines()
        }
        directoryFor(model).deleteRecursively()
        _state.value = _state.value.copy(downloaded = _state.value.downloaded - model.id)
    }

    private suspend fun releaseEngines() {
        whisperContext?.release()
        sherpaRecognizer?.release()
        whisperContext = null
        sherpaRecognizer = null
        loadedModelID = null
        loadedLanguage = null
        loadedQuality = null
    }

    /**
     * Starts preloading and consuming Sherpa audio immediately. Whisper keeps
     * its existing finish-time path because it has a separate native engine.
     */
    internal fun startIncrementalSession(
        modelID: String,
        language: String,
        scope: CoroutineScope,
        quality: TranscriptionQuality = TranscriptionQuality.DEFAULT,
    ): SherpaIncrementalSession? {
        val model = LocalModelCatalog.find(modelID) ?: return null
        if (model.engine != LocalModelEngine.SHERPA_ONNX) return null
        val resolved = if (model.englishOnly) "en" else language
        return SherpaIncrementalSession(
            scope = scope,
            prepare = { prepareEngine(model, resolved, quality) },
            decode = { samples -> decodePreparedSherpa(samples, model.id, resolved, quality) },
        )
    }

    /**
     * Loads the engine before a dictation needs it.
     *
     * Model loading is measured in seconds, and until now it always happened on
     * the critical path of whatever dictation happened to be first. Changing the
     * accuracy setting rebuilds a sherpa engine, so without this a user who
     * changes it and immediately dictates waits through the whole load with no
     * explanation. Failures are the caller's to ignore: this is an optimization,
     * and the real attempt will report the same problem properly.
     */
    suspend fun prepare(modelID: String, language: String, quality: TranscriptionQuality) {
        val model = LocalModelCatalog.find(modelID) ?: return
        if (!isDownloaded(model.id)) return
        prepareEngine(model, if (model.englishOnly) "en" else language, quality)
    }

    suspend fun transcribe(
        samples: FloatArray,
        modelID: String,
        language: String,
        quality: TranscriptionQuality = TranscriptionQuality.DEFAULT,
        vocabulary: String = "",
    ): LocalTranscription {
        val model = LocalModelCatalog.find(modelID) ?: error("Unknown local model: $modelID")
        val resolved = if (model.englishOnly) "en" else language
        prepareEngine(model, resolved, quality)
        // Safe here and not on the incremental path: this is the whole recording,
        // so one gain covers all of it.
        return decodePrepared(
            SpeechAudioConditioning.condition(samples),
            model,
            resolved,
            quality,
            vocabulary,
        )
    }

    private suspend fun prepareEngine(
        model: LocalModelDescriptor,
        resolvedLanguage: String,
        quality: TranscriptionQuality,
    ) {
        val directory = directoryFor(model)
        // Stat-only: cheap enough to run per dictation, unlike a digest pass.
        withContext(Dispatchers.IO) { LocalModelIntegrity.verifySizes(model, directory) }

        engineMutex.withLock {
            if (
                shouldReloadLocalEngine(
                    engine = model.engine,
                    loadedModelID = loadedModelID,
                    requestedModelID = model.id,
                    loadedLanguage = loadedLanguage,
                    requestedLanguage = resolvedLanguage,
                    loadedQuality = loadedQuality,
                    requestedQuality = quality,
                )
            ) {
                releaseEngines()
                _state.value = _state.value.copy(preparing = model.displayName)
                try {
                    // Let Compose render the loading message before native model
                    // initialization occupies the worker thread for seconds.
                    yield()
                    withContext(Dispatchers.IO) {
                        if (model.engine == LocalModelEngine.SHERPA_ONNX) {
                            sherpaRecognizer = SherpaRecognizer.create(
                                model = model,
                                directory = directory,
                                language = resolvedLanguage,
                                threads = WhisperCpuConfig.preferredSherpaThreadCount,
                                quality = quality,
                            )
                        } else {
                            whisperContext = WhisperContext.create(
                                File(directory, model.primaryFile.path).absolutePath,
                            ) ?: error("Could not load ${model.displayName}")
                        }
                    }
                } finally {
                    _state.value = _state.value.copy(preparing = null)
                }
                loadedModelID = model.id
                loadedLanguage = resolvedLanguage
                loadedQuality = quality
            }
        }
    }

    private suspend fun decodePrepared(
        samples: FloatArray,
        model: LocalModelDescriptor,
        resolvedLanguage: String,
        quality: TranscriptionQuality,
        vocabulary: String,
    ): LocalTranscription = engineMutex.withLock {
        check(
            loadedModelID == model.id &&
                (model.engine == LocalModelEngine.WHISPER || loadedLanguage == resolvedLanguage),
        ) {
            "Local transcription engine changed before inference started"
        }
        sherpaRecognizer?.let { recognizer ->
            return@withLock withContext(Dispatchers.Default) {
                val result = recognizer.transcribe(samples)
                LocalTranscription(result.text, result.language)
            }
        }
        whisperContext?.transcribe(
            samples,
            resolvedLanguage,
            quality,
            CustomVocabulary.whisperPrompt(vocabulary),
        ) ?: error("Local transcription engine is not loaded")
    }

    private suspend fun decodePreparedSherpa(
        samples: FloatArray,
        modelID: String,
        resolvedLanguage: String,
        quality: TranscriptionQuality,
    ): SherpaTranscript = engineMutex.withLock {
        check(
            loadedModelID == modelID &&
                loadedLanguage == resolvedLanguage &&
                loadedQuality == quality,
        ) {
            "On-device model changed during transcription"
        }
        val recognizer = sherpaRecognizer ?: error("Sherpa transcription engine is not loaded")
        withContext(Dispatchers.Default) { recognizer.transcribeChunk(samples) }
    }

    suspend fun transcribe(
        wavFile: File,
        modelID: String,
        language: String,
        quality: TranscriptionQuality = TranscriptionQuality.DEFAULT,
        vocabulary: String = "",
    ): LocalTranscription = transcribe(
        withContext(Dispatchers.IO) { readWavSamples(wavFile) },
        modelID,
        language,
        quality,
        vocabulary,
    )

    private fun readWavSamples(file: File): FloatArray {
        require(file.isFile) { "Recording is missing" }
        FileInputStream(file).use { input ->
            val header = ByteArray(44)
            require(input.read(header) == header.size) { "Recording header is incomplete" }
            require(header.copyOfRange(0, 4).contentEquals("RIFF".toByteArray())) {
                "Recording is not a RIFF WAV file"
            }
            val dataBytes = (file.length() - header.size).coerceAtLeast(0).toInt()
            val pcm = ByteArray(dataBytes)
            var offset = 0
            while (offset < pcm.size) {
                val count = input.read(pcm, offset, pcm.size - offset)
                if (count < 0) break
                offset += count
            }
            val samples = FloatArray(offset / CaptureFormat.BYTES_PER_SAMPLE)
            val buffer = ByteBuffer.wrap(pcm, 0, offset).order(ByteOrder.LITTLE_ENDIAN)
            for (index in samples.indices) samples[index] = buffer.short / 32_768f
            return samples
        }
    }
}

/**
 * Whisper receives language, quality, and vocabulary with each decode; none of
 * them change the loaded native context. Sherpa bakes language and quality into
 * its recognizer and must rebuild when either changes.
 */
internal fun shouldReloadLocalEngine(
    engine: LocalModelEngine,
    loadedModelID: String?,
    requestedModelID: String,
    loadedLanguage: String?,
    requestedLanguage: String,
    loadedQuality: TranscriptionQuality?,
    requestedQuality: TranscriptionQuality,
): Boolean {
    if (loadedModelID != requestedModelID) return true
    return engine == LocalModelEngine.SHERPA_ONNX &&
        (loadedLanguage != requestedLanguage || loadedQuality != requestedQuality)
}
