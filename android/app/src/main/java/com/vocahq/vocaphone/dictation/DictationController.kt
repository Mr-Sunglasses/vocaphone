package com.vocahq.vocaphone.dictation

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.os.SystemClock
import androidx.core.content.ContextCompat
import com.vocahq.vocaphone.audio.AudioCapture
import com.vocahq.vocaphone.audio.CaptureFormat
import com.vocahq.vocaphone.audio.DictationTonePlayer
import com.vocahq.vocaphone.audio.MicrophoneInterruptedException
import com.vocahq.vocaphone.audio.MicrophoneInterruption
import com.vocahq.vocaphone.audio.PcmConversion
import com.vocahq.vocaphone.audio.SilentCapture
import com.vocahq.vocaphone.audio.WavWriter
import com.vocahq.vocaphone.core.DictationFailure
import com.vocahq.vocaphone.core.DictationPhase
import com.vocahq.vocaphone.core.DictationState
import com.vocahq.vocaphone.core.DictationTone
import com.vocahq.vocaphone.core.MissingPermission
import com.vocahq.vocaphone.core.ModelLanguageSupport
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
import com.vocahq.vocaphone.local.LocalTranscription
import com.vocahq.vocaphone.local.SherpaIncrementalResult
import com.vocahq.vocaphone.local.SherpaIncrementalSession
import com.vocahq.vocaphone.settings.VocaPhoneSettings
import com.vocahq.vocaphone.settings.SettingsRepository
import com.vocahq.vocaphone.telemetry.Telemetry
import com.vocahq.vocaphone.telemetry.TelemetryDurationBucket
import com.vocahq.vocaphone.telemetry.TelemetryReason
import com.vocahq.vocaphone.telemetry.TelemetryStage
import com.vocahq.vocaphone.telemetry.telemetryModel
import com.vocahq.vocaphone.telemetry.telemetrySource
import java.io.File
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.CancellationException
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
    private val telemetry: Telemetry,
    private val cues: DictationTonePlayer,
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

    /**
     * Which dictation owns [state]. `fail` finishes its history write under
     * `NonCancellable`, so a cancel — or the dictation the user starts straight
     * after one — can land while a failure is still being reported. The late
     * write then put a FAILED phase on top of a session that was recording
     * perfectly well. Every start, retry and reset takes the next generation,
     * and a write from an older one is dropped.
     */
    private val generation = AtomicInteger()

    /**
     * How long the last completed capture ran, for the telemetry duration
     * bucket. Written once the WAV is closed and read at delivery, because the
     * writer is scoped to `runDictation` and the outcome is reported from
     * `deliver`/`fail` further down.
     */
    /**
     * Cleared on retry, because a retry re-transcribes a stored WAV without
     * recording anything: the previous live capture's length would otherwise be
     * reported as this dictation's, and after a process restart a retried
     * 90-second dictation would report `under_10s`. Null means "no duration to
     * report", and the outcome is sent without a bucket rather than with a
     * wrong one.
     */
    @Volatile
    private var lastRecordingMillis: Long? = null

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
        val generation = nextGeneration()
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
            runDictation(source, configuration, token, UUID.randomUUID(), generation)
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
        // Nothing is recorded on this path, so the previous capture's length is
        // not this dictation's.
        lastRecordingMillis = null
        val generation = nextGeneration()
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
                    generation = generation,
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
                    generation = generation,
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
        generation: Int,
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
                    quality = configuration.transcriptionQuality,
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
        // The mark at which the opening cue stops sounding. Frames before it
        // are the speaker, not the speaker's voice.
        val cueQuietAt = AtomicLong(0L)
        fun recordBatchFallback() {
            if (batchFallbackRecorded.compareAndSet(false, true)) {
                diagnostics.recordTiming("batch_fallback", source.name)
            }
        }

        val recorder = AudioCapture(
            context = context,
            preference = configuration.microphone,
            onFrame = { samples, count ->
                if (SystemClock.elapsedRealtime() >= cueQuietAt.get()) {
                    val frame = samples.copyOf(count)
                    if (frames.trySend(frame).isFailure) {
                        captureError.compareAndSet(
                            null,
                            IllegalStateException("Audio processing could not keep up."),
                        )
                        sessionFinishSignal.complete(Unit)
                    }
                    if (streamAcceptingFrames.get() &&
                        streamFrames?.trySend(frame)?.isFailure == true
                    ) {
                        droppedStreamFrames.incrementAndGet()
                        streamAcceptingFrames.set(false)
                        streamFrames.cancel()
                    }
                }
            },
            onError = { error ->
                captureError.compareAndSet(null, error)
                sessionFinishSignal.complete(Unit)
            },
        )
        capture = recorder
        // The cue sounds while AudioRecord warms up rather than before it, and
        // onFrame drops whatever the microphone hears until it is done. Waiting
        // the cue out first put its whole length in front of every dictation --
        // 600 ms of it for Lift -- to buy the same guarantee.
        cueQuietAt.set(announceListening(configuration.dictationTone))
        if (!recorder.start()) {
            announceStopped(configuration.dictationTone)
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
                generation = generation,
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
        announceStopped(configuration.dictationTone)
        diagnostics.recordTiming("capture_stopped", source.name)
        capture = null
        frames.close()
        streamAcceptingFrames.set(false)
        streamFrames?.close()
        drain.join()
        writer.close()
        lastRecordingMillis = writer.durationMillis

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
                    generation = generation,
                )
                return
            }
        }

        _state.update { it.copy(phase = DictationPhase.FINALIZING, level = 0f) }

        if (writer.durationMillis < MINIMUM_RECORDING_MILLIS) {
            incrementalReference.getAndSet(null)?.cancel()
            stream?.cancel()
            wavFile.delete()
            // A tap that captured nothing is not a failure the user has to
            // dismiss. The next mic tap should start a fresh dictation.
            if (this.generation.get() == generation) reset()
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
                generation = generation,
            )
            return
        }

        if (configuration.localTranscriptionEnabled) {
            val session = incrementalReference.getAndSet(null)
            var preparedTranscript: LocalTranscription? = null
            var partialTranscript: LocalTranscription? = null
            var incrementalOutcome: SherpaIncrementalResult? = null
            var timingRecorded = false
            if (session != null) {
                _state.update { it.copy(phase = DictationPhase.TRANSCRIBING, streaming = false) }
                diagnostics.recordTiming("local_transcription_started", source.name)
                timingRecorded = true
                try {
                    val incremental = session.finish()
                    incrementalOutcome = incremental
                    partialTranscript = incremental.transcript
                        .takeIf { it.text.isNotBlank() }
                        ?.let { LocalTranscription(it.text, it.language) }
                    if (incremental.droppedAudibleChunk) {
                        // A chunk that decoded to nothing is seconds of speech
                        // missing from the middle of an otherwise fluent
                        // transcript, which nothing downstream can see. The
                        // whole-file decode levels the gain over the whole
                        // recording and splits on different boundaries, so it
                        // is the one that recovers them.
                        diagnostics.recordTiming("local_incremental_dropped_chunk", source.name)
                    } else {
                        preparedTranscript = partialTranscript
                            ?.also {
                                diagnostics.recordTiming("local_incremental_ready", source.name)
                            }
                    }
                    if (preparedTranscript == null) incrementalFallback.set(true)
                } catch (error: CancellationException) {
                    throw error
                } catch (_: Throwable) {
                    session.cancel()
                    incrementalFallback.set(true)
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
                generation = generation,
                preparedTranscript = preparedTranscript,
                partialTranscript = partialTranscript,
                incrementalOutcome = incrementalOutcome,
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
                    fail(sessionId, error, wavFile = null, configuration = configuration, generation = generation)
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
                fail(sessionId, GatewayException.emptyTranscript(), null, configuration, generation)
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
            generation,
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
        generation: Int,
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
            fail(sessionId, error, wavFile, configuration, generation)
        }
    }

    private suspend fun deliverLocal(
        sessionId: UUID,
        wavFile: File,
        language: String,
        configuration: VocaPhoneSettings,
        source: DictationSource,
        generation: Int,
        preparedTranscript: LocalTranscription? = null,
        partialTranscript: LocalTranscription? = null,
        incrementalOutcome: SherpaIncrementalResult? = null,
        transcriptionTimingRecorded: Boolean = false,
    ) {
        // Loading a model is seconds of silence with nothing on screen to explain
        // it, and changing the accuracy setting makes it happen again. Mirroring
        // it into the status line is the difference between a wait and a hang.
        val preparingJob = scope.launch {
            localModels.state.collect { models ->
                _state.update { state ->
                    state.copy(
                        statusDetail = models.preparing?.let { "Loading $it… Please wait." }
                            ?: "Transcribing on this phone… Please wait.",
                    )
                }
            }
        }
        try {
            _state.update { it.copy(phase = DictationPhase.TRANSCRIBING, streaming = false) }
            if (!transcriptionTimingRecorded) {
                diagnostics.recordTiming("local_transcription_started", source.name)
            }
            val modelID = configuration.localModelId.takeIf { it.isNotEmpty() }
                ?: error("Choose and download an on-device model first.")
            val local = preparedTranscript ?: try {
                val wholeFile = localModels.transcribe(
                    wavFile,
                    modelID,
                    language,
                    configuration.transcriptionQuality,
                    configuration.customVocabulary,
                )
                // Taken only when it recovered something. A second pass that
                // came back with less than the streaming one already had has
                // dropped a chunk of its own, and shipping it would cut a
                // sentence the user watched being said.
                if (incrementalOutcome?.supersededBy(wholeFile.text) == false) {
                    partialTranscript ?: wholeFile
                } else {
                    wholeFile
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                // Incomplete beats nothing. When the streaming path lost a
                // chunk, this decode was the attempt to recover it; if the
                // attempt cannot run at all, the text it did produce is still
                // more use to the user than a failure.
                partialTranscript ?: throw error
            }
            val transcript = styleLocalTranscript(local, configuration)
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
                generation,
            )
        } finally {
            preparingJob.cancel()
            _state.update { it.copy(statusDetail = null) }
        }
    }

    /**
     * The styles punctuate by script, so the language they are given has to be
     * the one that was actually spoken. With Automatic selected the request only
     * says "auto", and a model that detected Hindi would otherwise have its
     * Devanagari finished with a Latin full stop.
     */
    private fun styleLocalTranscript(
        local: LocalTranscription,
        configuration: VocaPhoneSettings,
    ): String = TranscriptStyler.apply(
        TranscriptSanitizer.clean(local.text),
        configuration.style,
        ModelLanguageSupport.transcriptLanguage(
            requested = configuration.effectiveLanguage.wireValue,
            reported = local.language,
        ),
    )

    private suspend fun deliver(
        transcript: String,
        sessionId: UUID,
        configuration: VocaPhoneSettings,
        source: DictationSource,
    ) {
        diagnostics.recordTiming("transcript_ready", source.name)
        // Reported here rather than after insertion: the transcript exists and
        // is correct at this point, and whether the keyboard managed to commit
        // it is a separate question with its own failure path.
        telemetry.firstDictationEver()
        lastRecordingMillis?.let { millis ->
            telemetry.dictationSucceeded(
                source = configuration.telemetrySource,
                duration = TelemetryDurationBucket.of(millis / 1_000.0),
                model = configuration.telemetryModel,
                quality = configuration.transcriptionQuality,
            )
        }
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
        generation: Int,
    ) = withContext(NonCancellable) {
        diagnostics.recordError(errorCategory(error), activeSource?.name)
        telemetry.dictationFailed(
            stage = telemetryStage(error),
            reason = telemetryReason(error),
            source = configuration.telemetrySource,
            model = configuration.telemetryModel,
            quality = configuration.transcriptionQuality,
        )
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
        // The history write above is the durable half and always runs: the audio
        // is preserved and Retry has to find it. Reporting the failure on screen
        // is the half that can arrive too late — this block is `NonCancellable`,
        // so a cancel, or the dictation started right after it, can have taken
        // the state over while the write was in flight.
        if (this@DictationController.generation.get() != generation) return@withContext
        _state.value = _state.value.copy(
            phase = DictationPhase.FAILED,
            level = 0f,
            failure = DictationFailure(error.code, error.userMessage, error.recoverable),
        )
    }

    /** Taps the phone, sounds the cue, and reports when the cue falls quiet. */
    private fun announceListening(tone: DictationTone): Long {
        cues.haptic()
        return cues.startCue(tone)
    }

    private fun announceStopped(tone: DictationTone) {
        cues.haptic()
        cues.stopCue(tone)
    }

    /** Retires whatever owned the state, so nothing older can write to it. */
    private fun nextGeneration(): Int = generation.incrementAndGet()

    private fun reset() {
        nextGeneration()
        _state.value = DictationState()
    }

    /**
     * How far the dictation got, from the error that ended it.
     *
     * Deliberately derived from `error.code` — a closed set the gateway client
     * defines — and never from `error.userMessage`, which is free text and can
     * name a host, a path, or whatever a server chose to return.
     */
    private fun telemetryStage(error: GatewayException): TelemetryStage = when {
        error.code.startsWith("audio") || error.code.startsWith("microphone") -> {
            TelemetryStage.CAPTURE
        }
        error.code.startsWith("insert") -> TelemetryStage.INSERTION
        error.code.startsWith("upload") || error.code == "unreachable" -> TelemetryStage.UPLOAD
        else -> TelemetryStage.TRANSCRIPTION
    }

    private fun telemetryReason(error: GatewayException): TelemetryReason = when (error.code) {
        "microphone_silenced" -> TelemetryReason.AUDIO_SILENCED
        "microphone_focus_lost" -> TelemetryReason.AUDIO_FOCUS_LOST
        "microphone_capture_lost" -> TelemetryReason.AUDIO_CAPTURE_LOST
        "permission_repair" -> TelemetryReason.PERMISSION
        "unreachable" -> TelemetryReason.GATEWAY_UNREACHABLE
        "unauthorized", "forbidden" -> TelemetryReason.GATEWAY_REJECTED
        "engine_not_ready" -> TelemetryReason.ENGINE_NOT_READY
        "model_missing" -> TelemetryReason.MODEL_MISSING
        "empty_transcript" -> TelemetryReason.TRANSCRIPT_EMPTY
        else -> when {
            error.code.startsWith("audio") || error.code.startsWith("microphone") -> {
                TelemetryReason.AUDIO
            }
            error.code.startsWith("insert") -> TelemetryReason.INSERTION_REJECTED
            // Unknown rather than the raw code. A code this mapper has not seen
            // is exactly the case where passing it through would put an
            // unreviewed string on the wire.
            else -> TelemetryReason.UNKNOWN
        }
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
