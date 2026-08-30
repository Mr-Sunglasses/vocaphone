package com.vocahq.vocaphone.local

import android.app.ActivityManager
import android.content.Context
import android.os.SystemClock
import com.vocahq.vocaphone.audio.CaptureFormat
import com.vocahq.vocaphone.audio.SpeechAudioConditioning
import com.vocahq.vocaphone.core.CustomVocabulary
import com.vocahq.vocaphone.core.ModelLanguageSupport
import com.vocahq.vocaphone.core.TranscriptionQuality
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.yield
import okhttp3.Call
import okhttp3.OkHttpClient
import okhttp3.Request

/**
 * What an on-device engine produced, and the language that governs its output.
 *
 * The language matters because the writing styles punctuate by script — a
 * Devanagari sentence ends in a danda, not a full stop — and with Automatic
 * selected the request says only "auto". Whisper detects and reports; the
 * sherpa bridges do not expose it, so they leave this empty and the styler
 * falls back to inspecting the text. An explicit selection stays authoritative
 * even if an engine reports something contradictory.
 */
/** App-private folder that holds downloaded on-device models. */
const val LOCAL_MODELS_DIR = "local-models"

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
    /** Bytes transferred and expected, so progress can say more than a percent. */
    val downloadedBytes: Long = 0,
    val totalBytes: Long = 0,
    /** `SystemClock.elapsedRealtime()` when the transfer began, for the estimate. */
    val startedAtMillis: Long = 0,
    /** Free space on the models volume, refreshed when the picker asks. */
    val availableStorageBytes: Long = 0,
    /** Whether the active connection bills by the byte. */
    val meteredNetwork: Boolean = false,
)

/** Leaving the picker or the activity must not cancel a running download. */
const val CANCEL_MODEL_DOWNLOAD_WHEN_HOST_LEAVES = false

/**
 * After the last dictation the native weights sit in RAM and keep the CPU
 * from sleeping. Two minutes of no use is long enough to start another
 * dictation without a reload, and short enough that a phone left in a bag
 * is not holding a gigabyte of weights all afternoon.
 */
internal const val LOCAL_ENGINE_IDLE_UNLOAD_MS = 2 * 60 * 1000L

internal fun idleEngineUnloadDue(
    users: Int,
    lastIdleAtMs: Long,
    nowMs: Long,
    idleMs: Long = LOCAL_ENGINE_IDLE_UNLOAD_MS,
): Boolean = users <= 0 && nowMs - lastIdleAtMs >= idleMs

/** Owns model storage, atomic downloads, and the verified inference engine. */
class LocalModelManager(
    context: Context,
    private val client: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(30, TimeUnit.SECONDS)
        .readTimeout(10, TimeUnit.MINUTES)
        .build(),
    private val downloadScope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
) {
    private val appContext = context.applicationContext
    private val modelRoot = File(appContext.filesDir, LOCAL_MODELS_DIR).also { it.mkdirs() }
    private val downloadMutex = Mutex()
    private val engineMutex = Mutex()
    private val engineScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val engineUsers = AtomicInteger(0)
    private var idleUnloadJob: Job? = null
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
     * Canary bakes source and target into the recognizer exactly as it bakes
     * the language, so a change of translation target has to rebuild it too.
     * Empty means transcribe.
     */
    private var loadedTranslateTo: String = ""

    /**
     * Sherpa bakes the decoding method into the recognizer, so changing quality
     * means building a new one. Whisper takes its search parameters per call and
     * does not care.
     */
    private var loadedQuality: TranscriptionQuality? = null
    /** The coroutine cannot interrupt a blocking OkHttp execute by itself. */
    private val activeDownloadCall = AtomicReference<Call?>(null)
    private val activeDownloadJob = AtomicReference<Job?>(null)

    /**
     * Stat-only pass. Anything present but not yet marked as digest-checked is
     * hashed once afterwards, off this path: an IME process starts often enough
     * that hashing gigabytes on every start is a battery bug of its own.
     */
    /**
     * Re-reads only what can change while the app is backgrounded: the radio the
     * phone came back on, and the space left after whatever else was deleted.
     *
     * Split out of [refresh] because that one migrates layouts and hashes
     * gigabytes, which is not what every return to the foreground should cost.
     */
    suspend fun refreshConditions() = withContext(Dispatchers.IO) {
        _state.value = _state.value.copy(
            availableStorageBytes = availableStorageBytes(modelRoot),
            meteredNetwork = appContext.isOnMeteredNetwork(),
        )
    }

    suspend fun refresh() = withContext(Dispatchers.IO) {
        _state.value = _state.value.copy(
            totalRamGB = totalRamGB,
            availableStorageBytes = availableStorageBytes(modelRoot),
            meteredNetwork = appContext.isOnMeteredNetwork(),
        )
        migrateLegacyLayout()
        deleteRetiredModelFiles()
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

    /**
     * Reclaim the disk a model still occupies after leaving the catalog.
     *
     * Nothing else will: every sweep in here iterates [LocalModelCatalog.all],
     * and the picker only ever lists catalog rows, so a removed model's files
     * become unreachable rather than deleted -- and these are not small. A
     * phone that had collected Whisper Medium and Large v2 is holding three
     * gigabytes it can no longer see, let alone free.
     *
     * Deletes only ids [RetiredModels] names, never "anything not in the
     * catalog": a directory this build does not recognise may belong to a newer
     * one the user downgraded from, and guessing there would delete a model
     * they are about to want back.
     */
    private fun deleteRetiredModelFiles() {
        RetiredModels.replacements.keys.forEach { id ->
            if (LocalModelCatalog.find(id) != null) return@forEach
            File(modelRoot, id).takeIf(File::isDirectory)?.deleteRecursively()
            // Whisper models predating the per-model directory sat in the root
            // as bare GGML files, and `migrateLegacyLayout` only relocates the
            // ones still in the catalog.
            File(modelRoot, "ggml-$id.bin").takeIf(File::isFile)?.delete()
        }
    }

    fun totalRamGB(): Long = totalRamGB

    fun isDownloaded(id: String): Boolean = id in _state.value.downloaded

    fun directoryFor(model: LocalModelDescriptor): File = File(modelRoot, model.id)

    /**
     * Starts the bounded Sherpa latency path. Whisper keeps its finish-time
     * decoder because its native context has a different streaming contract.
     */
    internal fun startIncrementalSession(
        modelID: String,
        language: String,
        scope: CoroutineScope,
        quality: TranscriptionQuality = TranscriptionQuality.DEFAULT,
        translateTo: String = "",
    ): SherpaIncrementalSession? {
        val model = LocalModelCatalog.find(modelID) ?: return null
        val resolved = if (model.englishOnly) "en" else language
        val target = model.resolveTranslationTarget(translateTo, resolved)
        if (!canStreamIncrementally(model.engine, target)) return null
        return SherpaIncrementalSession(
            scope = scope,
            prepare = { prepareEngine(model, resolved, quality, target) },
            decode = { samples ->
                decodePreparedSherpa(samples, model.id, resolved, quality, target)
            },
        )
    }

    /**
     * Starts a download on [downloadScope] so leaving setup or settings does
     * not cancel it. Only [cancelDownload] stops an in-flight job.
     */
    fun startDownload(model: LocalModelDescriptor): Job {
        cancelDownload()
        val job = downloadScope.launch { download(model) }
        activeDownloadJob.set(job)
        job.invokeOnCompletion { activeDownloadJob.compareAndSet(job, null) }
        return job
    }

    /** Cancels the in-flight HTTP request and the process-scoped download job. */
    fun cancelDownload() {
        activeDownloadCall.get()?.cancel()
        activeDownloadJob.getAndSet(null)?.cancel()
    }

    /**
     * Keeps a verified download recoverable when native engine initialization
     * fails. Selection is deliberately not changed: setup must not claim that a
     * model is ready until the runtime has loaded it successfully once.
     */
    fun reportPreparationFailure(model: LocalModelDescriptor) {
        _state.value = _state.value.copy(
            message = "Could not load ${model.displayName}. " +
                "The verified download is still available; try using it again.",
        )
    }

    suspend fun download(model: LocalModelDescriptor) = downloadMutex.withLock {
        // Checked here rather than only in the picker: a download reaching 95%
        // and then failing on a full phone is minutes of the user's time and an
        // error that does not say what to delete.
        val free = availableStorageBytes(modelRoot)
        val needed = requiredStorageBytes(model.sizeBytes)
        if (free in 1..<needed) {
            val sentence = "${model.displayName} needs ${byteLabel(needed)} free and this " +
                "phone has ${byteLabel(free)}. Free up some space and try again."
            _state.value = _state.value.copy(message = sentence)
            // Thrown rather than returned: the caller reads a normal return as a
            // finished download, reports it as one, and then tries to load a
            // model that was never fetched.
            throw LocalModelStorageException(sentence)
        }
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
                downloadedBytes = 0,
                totalBytes = model.sizeBytes,
                startedAtMillis = SystemClock.elapsedRealtime(),
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
                    downloadedBytes = model.sizeBytes,
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
                _state.value = _state.value.copy(
                    downloading = null,
                    downloadedBytes = 0,
                    totalBytes = 0,
                    startedAtMillis = 0,
                )
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
                                downloadedBytes = (alreadyCompleted + written)
                                    .coerceAtMost(totalBytes),
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
        loadedTranslateTo = ""
        loadedQuality = null
    }

    /**
     * A dictation owns the engine until [endUse]. Cancels an idle unload so a
     * model loaded during recording is not freed under the decoder.
     */
    fun beginUse() {
        cancelIdleUnload()
        engineUsers.incrementAndGet()
    }

    fun endUse(idleMs: Long = LOCAL_ENGINE_IDLE_UNLOAD_MS) {
        if (engineUsers.decrementAndGet() <= 0) {
            engineUsers.set(0)
            scheduleIdleUnload(idleMs)
        }
    }

    /**
     * Start loading weights without waiting. Recording can begin on the same
     * tap; [transcribe] joins this work via [engineMutex].
     */
    fun warm(
        modelID: String,
        language: String,
        quality: TranscriptionQuality,
        translateTo: String,
    ) {
        cancelIdleUnload()
        engineScope.launch {
            runCatching { prepare(modelID, language, quality, translateTo) }
        }
    }

    /** Drop native weights now if nothing is dictating. Used on memory trim. */
    fun releaseIfIdle() {
        if (engineUsers.get() > 0) return
        cancelIdleUnload()
        engineScope.launch {
            engineMutex.withLock { releaseEngines() }
        }
    }

    private fun scheduleIdleUnload(idleMs: Long) {
        cancelIdleUnload()
        if (idleMs < 0L) return
        idleUnloadJob = engineScope.launch {
            if (idleMs > 0L) delay(idleMs)
            if (engineUsers.get() > 0) return@launch
            engineMutex.withLock { releaseEngines() }
        }
    }

    private fun cancelIdleUnload() {
        idleUnloadJob?.cancel()
        idleUnloadJob = null
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
    suspend fun prepare(
        modelID: String,
        language: String,
        quality: TranscriptionQuality,
        translateTo: String,
    ) {
        val model = LocalModelCatalog.find(modelID) ?: return
        if (!isDownloaded(model.id)) return
        val spoken = if (model.englishOnly) "en" else language
        prepareEngine(
            model,
            spoken,
            quality,
            model.resolveTranslationTarget(translateTo, spoken),
        )
    }

    suspend fun transcribe(
        samples: FloatArray,
        modelID: String,
        language: String,
        quality: TranscriptionQuality = TranscriptionQuality.DEFAULT,
        vocabulary: String = "",
        conditioningStartSample: Int = 0,
        translateTo: String = "",
    ): LocalTranscription {
        val model = LocalModelCatalog.find(modelID) ?: error("Unknown local model: $modelID")
        val resolved = if (model.englishOnly) "en" else language
        val target = model.resolveTranslationTarget(translateTo, resolved)
        prepareEngine(model, resolved, quality, target)
        // One gain and one DC-offset correction cover the complete recording.
        // Sherpa used to have a separate during-recording path that could apply
        // different conditioning and silently omit a window; the complete WAV
        // is deliberately authoritative now.
        return decodePrepared(
            SpeechAudioConditioning.condition(samples, conditioningStartSample),
            model,
            resolved,
            quality,
            vocabulary,
            target,
        )
    }

    private suspend fun prepareEngine(
        model: LocalModelDescriptor,
        resolvedLanguage: String,
        requestedQuality: TranscriptionQuality,
        resolvedTranslateTo: String,
    ) {
        // Normalised to what the recognizer is actually built at. Every bundled
        // sherpa family is on greedy search, which reads neither field quality
        // reaches, so without this the accuracy control rebuilds a large model
        // to produce an identical one -- a long "Preparing…" and a peak-memory
        // spike for no change in the transcript.
        val quality = model.sherpaFamily?.effectiveQuality(requestedQuality) ?: requestedQuality
        val directory = directoryFor(model)
        // Stat-only: cheap enough to run per dictation, unlike a digest pass.
        withContext(Dispatchers.IO) { LocalModelIntegrity.verifySizes(model, directory) }

        cancelIdleUnload()
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
                    languageIsBakedIn = model.sherpaFamily?.acceptsLanguage ?: true,
                    loadedTranslateTo = loadedTranslateTo,
                    requestedTranslateTo = resolvedTranslateTo,
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
                                translateTo = resolvedTranslateTo,
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
                loadedTranslateTo = resolvedTranslateTo
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
        resolvedTranslateTo: String,
    ): LocalTranscription = engineMutex.withLock {
        check(
            loadedModelID == model.id &&
                (
                    model.engine == LocalModelEngine.WHISPER ||
                        model.sherpaFamily?.acceptsLanguage != true ||
                        (
                            loadedLanguage == resolvedLanguage &&
                                loadedTranslateTo == resolvedTranslateTo
                            )
                    ),
        ) {
            "Local transcription engine changed before inference started"
        }
        sherpaRecognizer?.let { recognizer ->
            return@withLock withContext(Dispatchers.Default) {
                val result = recognizer.transcribe(samples)
                LocalTranscription(
                    result.text,
                    ModelLanguageSupport.outputLanguage(
                        requested = resolvedLanguage,
                        reported = result.language,
                        translateTo = resolvedTranslateTo,
                    ),
                )
            }
        }
        whisperContext?.transcribe(
            samples,
            resolvedLanguage,
            resolvedTranslateTo,
            quality,
            CustomVocabulary.whisperPrompt(vocabulary),
            model.cropsAudioContext,
            WhisperCpuConfig.preferredThreadCount(model.id),
        ) ?: error("Local transcription engine is not loaded")
    }

    private suspend fun decodePreparedSherpa(
        samples: FloatArray,
        modelID: String,
        resolvedLanguage: String,
        quality: TranscriptionQuality,
        resolvedTranslateTo: String,
    ): SherpaTranscript = engineMutex.withLock {
        check(
            loadedModelID == modelID &&
                loadedLanguage == resolvedLanguage &&
                loadedTranslateTo == resolvedTranslateTo &&
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
        conditioningStartSample: Int = 0,
        translateTo: String = "",
    ): LocalTranscription = transcribe(
        withContext(Dispatchers.IO) { readWavSamples(wavFile) },
        modelID,
        language,
        quality,
        vocabulary,
        conditioningStartSample,
        translateTo,
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
 *
 * [languageIsBakedIn] is false for the families whose config has no language
 * field at all: rebuilding a 670 MB Parakeet because the user relabelled the
 * transcript language would cost seconds and change nothing about the decode.
 *
 * The translation target is baked in wherever the language is — it is the other
 * half of the same Canary config — so it is gated by the same flag. A family
 * that cannot translate has already had the target resolved away to empty by
 * [LocalModelDescriptor.resolveTranslationTarget], so it can never reload for a
 * setting it would ignore.
 */
internal fun shouldReloadLocalEngine(
    engine: LocalModelEngine,
    loadedModelID: String?,
    requestedModelID: String,
    loadedLanguage: String?,
    requestedLanguage: String,
    loadedQuality: TranscriptionQuality?,
    requestedQuality: TranscriptionQuality,
    languageIsBakedIn: Boolean = true,
    loadedTranslateTo: String = "",
    requestedTranslateTo: String = "",
): Boolean {
    if (loadedModelID != requestedModelID) return true
    if (engine != LocalModelEngine.SHERPA_ONNX) return false
    if (loadedQuality != requestedQuality) return true
    if (!languageIsBakedIn) return false
    return loadedLanguage != requestedLanguage || loadedTranslateTo != requestedTranslateTo
}

/**
 * The translation target this model can actually honour, or empty.
 *
 * Resolved here rather than trusted from the caller so that a stale setting —
 * a target picked under Canary and still stored after a switch to Parakeet —
 * can never reach an engine that would misread it, nor force a reload of one
 * that would ignore it.
 */
internal fun LocalModelDescriptor.resolveTranslationTarget(
    requested: String,
    spokenLanguage: String? = null,
): String {
    val target = requested.takeIf { it.isNotEmpty() && it in translationTargets }.orEmpty()
    if (target.isEmpty()) return ""
    // Canary has no detection. Automatic is resolved to English before the
    // recognizer is built, so a target with no spoken language named is a
    // translation out of English, not out of whatever was actually said.
    if (spokenLanguage != null &&
        translationNeedsExplicitSource &&
        (spokenLanguage.isEmpty() || spokenLanguage == "auto")
    ) {
        return ""
    }
    return target
}

/**
 * Whether a dictation may be decoded in windows while it is still being spoken.
 *
 * Whisper never streams here; only the sherpa families do. Translation rules
 * the rest out. Streaming decodes ten-second windows and stitches them by
 * matching repeated words across a half-second overlap, and both halves of that
 * assume the model returns the same words for the same audio. A translator does
 * not: the overlap comes back reworded, so nothing is deduplicated and the seam
 * is duplicated instead — and a sentence split across two windows is translated
 * twice, as two fragments that were never sentences. A translated dictation
 * gives up the latency and takes the whole-file path, where anything under
 * twelve seconds is a single decode of the whole thing.
 */
internal fun canStreamIncrementally(engine: LocalModelEngine, translateTo: String): Boolean =
    engine == LocalModelEngine.SHERPA_ONNX && translateTo.isEmpty()
