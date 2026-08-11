package com.vocahq.vocaphone.dictation

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.os.SystemClock
import androidx.core.content.ContextCompat
import com.vocahq.vocaphone.audio.AudioCapture
import com.vocahq.vocaphone.audio.CaptureFormat
import com.vocahq.vocaphone.audio.MicrophoneInterruptedException
import com.vocahq.vocaphone.audio.MicrophoneInterruption
import com.vocahq.vocaphone.audio.PcmConversion
import com.vocahq.vocaphone.audio.SilentCapture
import com.vocahq.vocaphone.audio.WavWriter
import com.vocahq.vocaphone.core.DictationFailure
import com.vocahq.vocaphone.core.DictationPhase
import com.vocahq.vocaphone.core.DictationState
import com.vocahq.vocaphone.core.MissingPermission
import com.vocahq.vocaphone.core.TranscriptSanitizer
import com.vocahq.vocaphone.core.TranscriptStyler
import com.vocahq.vocaphone.data.HistoryRepository
import com.vocahq.vocaphone.data.DiagnosticLog
import com.vocahq.vocaphone.gateway.GatewayClient
import com.vocahq.vocaphone.gateway.GatewayException
import com.vocahq.vocaphone.gateway.GatewayAudioStream
import com.vocahq.vocaphone.gateway.GatewayStreamingPolicy
import com.vocahq.vocaphone.gateway.StreamingUnavailableException
import com.vocahq.vocaphone.local.LocalModelManager
import com.vocahq.vocaphone.local.SherpaIncrementalSession
import com.vocahq.vocaphone.settings.VocaPhoneSettings
import com.vocahq.vocaphone.settings.SettingsRepository
import java.io.File
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

/** Where a dictation was started from, which decides where its transcript goes. */
enum class DictationSource {
    /** The companion app's scratchpad: the transcript stays in the app. */
    COMPANION_APP,

    /** The system keyboard: commit into its current InputConnection. */
    IME,
}

/**
 * Owns one dictation at a time: capture, gateway delivery, insertion, retry and
 * the state every surface renders from.
 */
class DictationController(
    private val context: Context,
    private val settings: SettingsRepository,
    private val history: HistoryRepository,
    private val diagnostics: DiagnosticLog,
    private val audioDirectory: File,
    private val localModels: LocalModelManager,
    private val scope: CoroutineScope,
) {
    private val _state = MutableStateFlow(DictationState())
    val state: StateFlow<DictationState> = _state.asStateFlow()

    /** Set by the IME while the keyboard service is connected. */
    @Volatile
    var imeInserter: TranscriptInserter? = null

    private var pipeline: Job? = null
    private var capture: AudioCapture? = null

    @Volatile
    private var activeSource: DictationSource? = null

    @Volatile
    private var finishSignal = CompletableDeferred<Unit>()

    @Volatile
    private var cancelRequested = false

    init {
        scope.launch {
            state
                .map { it.phase }
                .distinctUntilChanged()
                .collect { phase ->
                    diagnostics.recordState(phase.name, activeSource?.name)
                }
        }
    }

    /**
     * Starts a dictation unless one is already running. Missing permissions or
     * gateway settings surface as a repair state rather than a failure.
     */
    fun start(source: DictationSource) {
        if (pipeline?.isActive == true) return
        activeSource = source
        diagnostics.recordAction("start", source.name)
        finishSignal = CompletableDeferred()
        cancelRequested = false
        pipeline = scope.launch {
            val configuration = settings.current()
            val missing = missingPermissions(configuration)
            if (missing.isNotEmpty()) {
                diagnostics.recordError("setup", source.name)
                _state.value = DictationState(
                    phase = DictationPhase.PERMISSION_REPAIR,
                    missingPermissions = missing,
                )
                return@launch
            }
            val token = if (configuration.localTranscriptionEnabled) null else settings.token()
            if (!configuration.localTranscriptionEnabled && token.isNullOrEmpty()) {
                diagnostics.recordError("setup", source.name)
                _state.value = DictationState(
                    phase = DictationPhase.PERMISSION_REPAIR,
                    missingPermissions = setOf(MissingPermission.GATEWAY_NOT_CONFIGURED),
                )
                return@launch
            }
            runDictation(source, configuration, token, UUID.randomUUID())
        }
    }

    fun finish() {
        finishSignal.complete(Unit)
        diagnostics.recordTiming("finish_requested", activeSource?.name)
    }

    fun cancel() {
        diagnostics.recordAction("cancel", activeSource?.name)
        cancelRequested = true
        finishSignal.complete(Unit)
        capture?.stop()
        if (_state.value.phase != DictationPhase.LISTENING) {
            pipeline?.cancel()
            reset()
        }
    }

    /** Re-sends audio that was preserved for a recoverable failure. */
    fun retry(sessionId: String) {
        if (pipeline?.isActive == true) return
        pipeline = scope.launch {
            val record = history.find(sessionId) ?: return@launch
            val audio = record.audioPath?.let(::File)
            if (audio == null || !audio.exists()) {
                _state.value = _state.value.copy(
                    phase = DictationPhase.FAILED,
                    failure = DictationFailure(
                        "audio_expired",
                        "The recording for this dictation is no longer stored.",
                        recoverable = false,
                    ),
                )
                return@launch
            }
            val configuration = settings.current()
            _state.value = DictationState(
                sessionId = UUID.fromString(sessionId),
                phase = DictationPhase.UPLOADING,
                language = configuration.effectiveLanguage,
                style = configuration.style,
            )
            if (configuration.localTranscriptionEnabled) {
                deliverLocal(
                    sessionId = UUID.fromString(sessionId),
                    wavFile = audio,
                    language = record.language,
                    configuration = configuration,
                    source = DictationSource.COMPANION_APP,
                )
            } else {
                val token = settings.token() ?: return@launch
                deliverBatch(
                    client = GatewayClient(configuration.gatewayUrl, token),
                    sessionId = UUID.fromString(sessionId),
                    wavFile = audio,
                    language = record.language,
                    style = record.style,
                    configuration = configuration,
                    source = DictationSource.COMPANION_APP,
                )
            }
        }
    }

    fun clearTransient() {
        if (!_state.value.phase.isBusy) reset()
    }

    fun missingPermissions(configuration: VocaPhoneSettings): Set<MissingPermission> = buildSet {
        if (!hasPermission(Manifest.permission.RECORD_AUDIO)) add(MissingPermission.MICROPHONE)
        if (!hasPermission(Manifest.permission.POST_NOTIFICATIONS)) add(MissingPermission.NOTIFICATIONS)
        if (!configuration.isConfigured && !configuration.localTranscriptionEnabled) {
            add(MissingPermission.GATEWAY_NOT_CONFIGURED)
        }
    }

    private fun hasPermission(permission: String) =
        ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED

    // ------------------------------------------------------------- pipeline

    // `start` refuses to reach here until RECORD_AUDIO has been granted.
    @SuppressLint("MissingPermission")
    private suspend fun runDictation(
        source: DictationSource,
        configuration: VocaPhoneSettings,
        token: String?,
        sessionId: UUID,
    ) {
        audioDirectory.mkdirs()
        val wavFile = File(audioDirectory, "$sessionId.wav")
        val client = token?.let { GatewayClient(configuration.gatewayUrl, it) }
        val sessionFinishSignal = finishSignal
        val frames = Channel<ShortArray>(capacity = FILE_FRAME_BUFFER_CAPACITY)
        val selectedLocalModelID = configuration.localModelId.takeIf { it.isNotEmpty() }
        val incrementalSession = if (configuration.localTranscriptionEnabled) {
            selectedLocalModelID?.let { modelID ->
                localModels.startIncrementalSession(
                    modelID = modelID,
                    language = configuration.effectiveLanguage.wireValue,
                    scope = scope,
                )
            }
        } else {
            null
        }
        val incrementalReference = AtomicReference<SherpaIncrementalSession?>(incrementalSession)
        val incrementalFallback = AtomicBoolean(false)
        if (incrementalSession != null) {
            diagnostics.recordTiming("local_incremental_started", source.name)
        }
        val shouldAttemptStreaming = client != null && GatewayStreamingPolicy.shouldAttemptStreaming(
            supported = configuration.lastStreamingSupported,
            checkedAtMillis = configuration.lastEngineCheckedAtMillis,
        )
        val streamFrames = if (shouldAttemptStreaming) {
            Channel<ShortArray>(capacity = STREAM_FRAME_BUFFER_CAPACITY)
        } else {
            null
        }
        val writer = WavWriter(wavFile)
        val captureError = AtomicReference<Throwable?>()
        val streamReference = AtomicReference<GatewayAudioStream?>()
        val streamAcceptingFrames = AtomicBoolean(streamFrames != null)
        val droppedStreamFrames = AtomicInteger()
        val batchFallbackRecorded = AtomicBoolean()
        fun recordBatchFallback() {
            if (batchFallbackRecorded.compareAndSet(false, true)) {
                diagnostics.recordTiming("batch_fallback", source.name)
            }
        }

        val recorder = AudioCapture(
            context = context,
            preference = configuration.microphone,
            onFrame = { samples, count ->
                val frame = samples.copyOf(count)
                if (frames.trySend(frame).isFailure) {
                    captureError.compareAndSet(
                        null,
                        IllegalStateException("Audio processing could not keep up."),
                    )
                    sessionFinishSignal.complete(Unit)
                }
                if (streamAcceptingFrames.get() && streamFrames?.trySend(frame)?.isFailure == true) {
                    droppedStreamFrames.incrementAndGet()
                    streamAcceptingFrames.set(false)
                    streamFrames.cancel()
                }
            },
            onError = { error ->
                captureError.compareAndSet(null, error)
                sessionFinishSignal.complete(Unit)
            },
        )
        capture = recorder
        if (!recorder.start()) {
            incrementalReference.getAndSet(null)?.cancel()
            frames.close()
            streamFrames?.close()
            writer.close()
            wavFile.delete()
            // Nothing was captured, so there is nothing for Retry to re-send.
            // The user's next step is to start again, not to resend silence.
            fail(
                sessionId,
                GatewayException(
                    "microphone_unavailable",
                    captureError.get()?.message ?: "The microphone is not available right now.",
                    recoverable = false,
                ),
                wavFile = null,
                configuration = configuration,
            )
            return
        }

        val captureStartedAt = SystemClock.elapsedRealtime()
        _state.value = DictationState(
            sessionId = sessionId,
            phase = DictationPhase.LISTENING,
            language = configuration.effectiveLanguage,
            style = configuration.style,
            startedAtElapsedMillis = captureStartedAt,
        )

        // Frames are drained off the capture thread: file writes and socket sends
        // must never stall the AudioRecord read loop.
        val heardSomething = AtomicBoolean(false)
        val drain = scope.launch(Dispatchers.IO) {
            for (frame in frames) {
                writer.write(frame, frame.size)
                // Only until the first real sample arrives: past that the
                // recording is known to contain audio and the scan is waste.
                if (!heardSomething.get() &&
                    SilentCapture.heardSomething(PcmConversion.peak(frame, frame.size))
                ) {
                    heardSomething.set(true)
                }
                incrementalReference.get()?.let { session ->
                    if (!session.offer(frame) && incrementalReference.compareAndSet(session, null)) {
                        incrementalFallback.set(true)
                        session.cancel()
                    }
                }
                val level = PcmConversion.level(frame, frame.size)
                _state.update { current ->
                    if (current.phase != DictationPhase.LISTENING) {
                        current
                    } else {
                        current.copy(
                            level = level,
                            recordedMillis = writer.durationMillis,
                            partialTranscript = streamReference.get()?.latestPartial()
                                ?: current.partialTranscript,
                            inputRouteLabel = recorder.currentRouteLabel() ?: current.inputRouteLabel,
                        )
                    }
                }
            }
        }

        val streamPump = streamFrames?.let { channel ->
            scope.launch(Dispatchers.IO) {
                val candidate = client!!.openStream(
                    sessionId = sessionId,
                    language = configuration.effectiveLanguage.wireValue,
                    style = configuration.style.wireValue,
                    sampleRate = CaptureFormat.SAMPLE_RATE,
                )
                var ready = false
                try {
                    diagnostics.recordTiming("stream_handshake_started", source.name)
                    candidate.connect()
                    if (!currentCoroutineContext().isActive) return@launch
                    ready = true
                    streamReference.set(candidate)
                    diagnostics.recordTiming("stream_ready", source.name)
                    _state.update { it.copy(streaming = true) }

                    var scratch = ByteArray(0)
                    for (frame in channel) {
                        if (scratch.size < frame.size * 4) scratch = ByteArray(frame.size * 4)
                        PcmConversion.pcm16ToFloat32LittleEndian(frame, frame.size, scratch)
                        if (!candidate.sendFrames(scratch, frame.size * 4)) {
                            droppedStreamFrames.incrementAndGet()
                            streamAcceptingFrames.set(false)
                            break
                        }
                    }
                } catch (_: StreamingUnavailableException) {
                    streamAcceptingFrames.set(false)
                    channel.cancel()
                    recordBatchFallback()
                } catch (_: GatewayException) {
                    // Streaming is an optimization. The complete WAV remains the
                    // authoritative retry path for reachability and auth errors.
                    streamAcceptingFrames.set(false)
                    channel.cancel()
                    recordBatchFallback()
                } finally {
                    if (!ready || !currentCoroutineContext().isActive) {
                        candidate.cancel()
                        streamReference.compareAndSet(candidate, null)
                    }
                }
            }
        }
        if (streamFrames == null) recordBatchFallback()

        awaitFinish(sessionFinishSignal)
        recorder.stop()
        diagnostics.recordTiming("capture_stopped", source.name)
        capture = null
        frames.close()
        streamAcceptingFrames.set(false)
        streamFrames?.close()
        drain.join()
        writer.close()

        var stream = streamReference.get()
        if (stream == null) {
            streamPump?.cancel()
            streamPump?.join()
            recordBatchFallback()
        } else {
            streamPump?.join()
            stream = streamReference.get()
        }

        if (cancelRequested) {
            incrementalReference.getAndSet(null)?.cancel()
            stream?.cancel()
            wavFile.delete()
            reset()
            return
        }

        captureError.get()?.let { error ->
            diagnostics.recordError(audioErrorCategory(error), source.name)
            // Another app taking the microphone does not invalidate the audio
            // recorded before it did. A sentence the user already finished
            // saying is transcribed rather than thrown away; only a capture
            // that produced nothing usable is reported as a failure.
            val salvageable = error is MicrophoneInterruptedException &&
                heardSomething.get() &&
                writer.durationMillis >= MINIMUM_RECORDING_MILLIS
            if (!salvageable) {
                incrementalReference.getAndSet(null)?.cancel()
                stream?.cancel()
                wavFile.delete()
                fail(
                    sessionId,
                    GatewayException(
                        "audio_interrupted",
                        error.message ?: "Microphone access was interrupted. Try again.",
                        recoverable = false,
                    ),
                    wavFile = null,
                    configuration = configuration,
                )
                return
            }
        }

        _state.update { it.copy(phase = DictationPhase.FINALIZING, level = 0f) }

        if (writer.durationMillis < MINIMUM_RECORDING_MILLIS) {
            incrementalReference.getAndSet(null)?.cancel()
            stream?.cancel()
            wavFile.delete()
            fail(
                sessionId,
                GatewayException("audio_empty", "That was too short to transcribe.", recoverable = false),
                wavFile = null,
                configuration = configuration,
            )
            return
        }

        // A recording of exact digital zeros is what Android gives an app whose
        // microphone another app holds. Transcribing it would spend the wait to
        // report an empty transcript, which says nothing the user can act on.
        if (!heardSomething.get()) {
            incrementalReference.getAndSet(null)?.cancel()
            stream?.cancel()
            wavFile.delete()
            fail(
                sessionId,
                GatewayException(
                    "microphone_silenced",
                    "Another app was using the microphone, so VocaPhone recorded silence. " +
                        "Stop that recording and try again.",
                    recoverable = false,
                ),
                wavFile = null,
                configuration = configuration,
            )
            return
        }

        if (configuration.localTranscriptionEnabled) {
            val session = incrementalReference.getAndSet(null)
            var preparedTranscript: String? = null
            var timingRecorded = false
            if (session != null) {
                _state.update { it.copy(phase = DictationPhase.TRANSCRIBING, streaming = false) }
                diagnostics.recordTiming("local_transcription_started", source.name)
                timingRecorded = true
                preparedTranscript = try {
                    session.finish().takeIf(String::isNotBlank)?.also {
                        diagnostics.recordTiming("local_incremental_ready", source.name)
                    } ?: run {
                        incrementalFallback.set(true)
                        null
                    }
                } catch (_: Throwable) {
                    session.cancel()
                    incrementalFallback.set(true)
                    null
                }
            }
            if (incrementalSession != null && incrementalFallback.get()) {
                diagnostics.recordTiming("local_incremental_fallback", source.name)
            }
            deliverLocal(
                sessionId = sessionId,
                wavFile = wavFile,
                language = configuration.effectiveLanguage.wireValue,
                configuration = configuration,
                source = source,
                preparedTranscript = preparedTranscript,
                transcriptionTimingRecorded = timingRecorded,
            )
            return
        }

        if (stream != null && droppedStreamFrames.get() == 0) {
            _state.update { it.copy(phase = DictationPhase.TRANSCRIBING) }
            val transcript = try {
                diagnostics.recordTiming("transcription_started", source.name)
                stream.finish()
            } catch (_: StreamingUnavailableException) {
                recordBatchFallback()
                null
            } catch (error: GatewayException) {
                if (!error.recoverable) {
                    wavFile.delete()
                    fail(sessionId, error, wavFile = null, configuration = configuration)
                    return
                }
                recordBatchFallback()
                null
            }
            // The gateway has already applied the requested writing style to
            // streamed output. Local inference is styled in deliverLocal below;
            // applying it here would style gateway text twice.
            val cleaned = TranscriptSanitizer.clean(transcript)
            if (transcript != null && cleaned.isEmpty()) {
                wavFile.delete()
                fail(sessionId, GatewayException.emptyTranscript(), null, configuration)
                return
            }
            if (cleaned.isNotEmpty()) {
                wavFile.delete()
                deliver(cleaned, sessionId, configuration, source)
                return
            }
            // The stream failed after audio was captured; the complete WAV on disk
            // is exactly what the batch endpoints need.
        } else {
            stream?.cancel()
            recordBatchFallback()
        }

        deliverBatch(
            checkNotNull(client),
            sessionId,
            wavFile,
            configuration.effectiveLanguage.wireValue,
            configuration.style.wireValue,
            configuration,
            source,
        )
    }

    /**
     * Recording follows the user across apps until they press Finish, warning a
     * minute before the cap and stopping at it rather than recording forever.
     */
    private suspend fun awaitFinish(signal: CompletableDeferred<Unit>) {
        val startedAt = _state.value.startedAtElapsedMillis
        if (awaitSignalUntil(
                signal,
                startedAt + DictationState.RECORDING_WARNING_MILLIS,
            )
        ) {
            return
        }
        _state.update { it.copy(approachingLimit = true) }
        awaitSignalUntil(signal, startedAt + DictationState.MAXIMUM_RECORDING_MILLIS)
    }

    private suspend fun awaitSignalUntil(
        signal: CompletableDeferred<Unit>,
        deadlineElapsedMillis: Long,
    ): Boolean {
        if (signal.isCompleted) return true
        val remaining = deadlineElapsedMillis - SystemClock.elapsedRealtime()
        if (remaining <= 0) return signal.isCompleted
        return withTimeoutOrNull(remaining) {
            signal.await()
            true
        } ?: false
    }

    private suspend fun deliverBatch(
        client: GatewayClient,
        sessionId: UUID,
        wavFile: File,
        language: String,
        style: String,
        configuration: VocaPhoneSettings,
        source: DictationSource,
    ) {
        try {
            _state.update { it.copy(phase = DictationPhase.UPLOADING) }
            client.createSession(sessionId, language, style)
            diagnostics.recordTiming("upload_started", source.name)
            client.uploadAudio(sessionId, wavFile)
            diagnostics.recordTiming("upload_completed", source.name)
            _state.update { it.copy(phase = DictationPhase.TRANSCRIBING) }
            diagnostics.recordTiming("transcription_started", source.name)
            val session = client.finish(sessionId)
            // Marker-only output means the model heard nothing worth writing.
            val transcript = TranscriptSanitizer.clean(session.transcript)
            if (transcript.isEmpty()) {
                throw GatewayException(
                    session.errorCode ?: "empty_transcript",
                    "Nothing was transcribed. Try dictating again.",
                    recoverable = false,
                )
            }
            wavFile.delete()
            deliver(transcript, sessionId, configuration, source)
        } catch (error: GatewayException) {
            fail(sessionId, error, wavFile, configuration)
        }
    }

    private suspend fun deliverLocal(
        sessionId: UUID,
        wavFile: File,
        language: String,
        configuration: VocaPhoneSettings,
        source: DictationSource,
        preparedTranscript: String? = null,
        transcriptionTimingRecorded: Boolean = false,
    ) {
        try {
            _state.update { it.copy(phase = DictationPhase.TRANSCRIBING, streaming = false) }
            if (!transcriptionTimingRecorded) {
                diagnostics.recordTiming("local_transcription_started", source.name)
            }
            val modelID = configuration.localModelId.takeIf { it.isNotEmpty() }
                ?: error("Choose and download an on-device model first.")
            val transcript = styleLocalTranscript(
                preparedTranscript ?: localModels.transcribe(wavFile, modelID, language),
                configuration,
            )
            if (transcript.isEmpty()) {
                throw GatewayException.emptyTranscript()
            }
            wavFile.delete()
            deliver(transcript, sessionId, configuration, source)
        } catch (error: Throwable) {
            fail(
                sessionId,
                GatewayException(
                    code = if (error is com.vocahq.vocaphone.local.LocalModelIntegrityException) {
                        "local_model_integrity"
                    } else {
                        "local_transcription_failed"
                    },
                    userMessage = error.message ?: "On-device transcription failed. Download the model again and retry.",
                    recoverable = true,
                ),
                wavFile,
                configuration,
            )
        }
    }

    private fun styleLocalTranscript(
        transcript: String?,
        configuration: VocaPhoneSettings,
    ): String = TranscriptStyler.apply(
        TranscriptSanitizer.clean(transcript),
        configuration.style,
        configuration.effectiveLanguage.wireValue,
    )

    private suspend fun deliver(
        transcript: String,
        sessionId: UUID,
        configuration: VocaPhoneSettings,
        source: DictationSource,
    ) {
        diagnostics.recordTiming("transcript_ready", source.name)
        val target = when (source) {
            DictationSource.IME -> imeInserter
            DictationSource.COMPANION_APP -> null
        }
        val shouldInsert = target != null

        if (!shouldInsert) {
            _state.value = _state.value.copy(
                phase = DictationPhase.READY_TO_INSERT,
                transcript = transcript,
                level = 0f,
            )
            history.recordSuccess(
                sessionId = sessionId.toString(),
                language = configuration.effectiveLanguage.wireValue,
                style = configuration.style.wireValue,
                transcript = transcript,
                targetPackage = target?.currentTargetPackage(),
                insertedIntoField = false,
            )
            diagnostics.recordAction("ready_to_insert", source.name)
            return
        }

        _state.update { it.copy(phase = DictationPhase.INSERTING, transcript = transcript) }
        diagnostics.recordTiming("insertion_started", source.name)
        // The IME connection is reacquired here rather than at Start, so the
        // transcript is committed to the editor still owned by the keyboard.
        val report = target.insert(transcript)
        history.recordSuccess(
            sessionId = sessionId.toString(),
            language = configuration.effectiveLanguage.wireValue,
            style = configuration.style.wireValue,
            transcript = transcript,
            targetPackage = report.applied?.packageName ?: target.currentTargetPackage(),
            insertedIntoField = report.outcome == InsertionOutcome.INSERTED,
        )
        diagnostics.recordAction(
            if (report.outcome == InsertionOutcome.INSERTED) "inserted" else "insertion_failed",
            source.name,
        )
        if (report.outcome == InsertionOutcome.INSERTED) {
            diagnostics.recordTiming("insertion_completed", source.name)
        }
        _state.value = _state.value.copy(
            phase = if (report.outcome == InsertionOutcome.INSERTED) {
                DictationPhase.INSERTED
            } else {
                DictationPhase.READY_TO_INSERT
            },
            transcript = transcript,
            level = 0f,
        )
        if (report.outcome == InsertionOutcome.INSERTED) {
            // "Inserted" is a confirmation, not a state the user acts on: after a
            // moment the keyboard returns to its idle mic on its own.
            scope.launch {
                delay(INSERTED_LINGER_MILLIS)
                _state.update { current ->
                    if (current.sessionId == sessionId && current.phase == DictationPhase.INSERTED) {
                        DictationState()
                    } else {
                        current
                    }
                }
            }
        }
    }

    private suspend fun fail(
        sessionId: UUID,
        error: GatewayException,
        wavFile: File?,
        configuration: VocaPhoneSettings,
    ) = withContext(NonCancellable) {
        diagnostics.recordError(errorCategory(error), activeSource?.name)
        history.recordFailure(
            sessionId = sessionId.toString(),
            language = configuration.effectiveLanguage.wireValue,
            style = configuration.style.wireValue,
            errorCode = error.code,
            errorMessage = error.userMessage,
            recoverable = error.recoverable,
            audioFile = wavFile,
            retentionHours = configuration.audioRetention.hours,
            targetPackage = null,
        )
        _state.value = _state.value.copy(
            phase = DictationPhase.FAILED,
            level = 0f,
            failure = DictationFailure(error.code, error.userMessage, error.recoverable),
        )
    }

    private fun reset() {
        _state.value = DictationState()
    }

    private fun errorCategory(error: GatewayException): String = when {
        error.code == "microphone_silenced" -> "audio_silenced"
        error.code.startsWith("audio") -> "audio"
        error.code.startsWith("microphone") -> "audio"
        error.code.startsWith("insert") -> "insertion"
        error.code == "permission_repair" -> "setup"
        else -> "gateway"
    }

    /**
     * Which microphone failure this was. The on-device log is the only record
     * that survives the call or the screen recording that caused it, so the
     * cause is kept rather than flattened into a single "audio" category.
     */
    private fun audioErrorCategory(error: Throwable): String =
        if (error !is MicrophoneInterruptedException) {
            "audio"
        } else {
            when (error.interruption) {
                MicrophoneInterruption.FOCUS_LOST -> "audio_focus_lost"
                MicrophoneInterruption.SILENCED -> "audio_silenced"
                MicrophoneInterruption.CAPTURE_LOST -> "audio_capture_lost"
            }
        }

    private companion object {
        /** Below this, there is nothing a model could usefully transcribe. */
        const val MINIMUM_RECORDING_MILLIS = 300L

        /** How long the "Inserted" confirmation stays before the keyboard goes idle. */
        const val INSERTED_LINGER_MILLIS = 2_000L

        /** File writing should stay far ahead of this six-second safety buffer. */
        const val FILE_FRAME_BUFFER_CAPACITY = 64

        /** Covers the eight-second socket timeout without unbounded PCM growth. */
        const val STREAM_FRAME_BUFFER_CAPACITY = 96
    }
}
