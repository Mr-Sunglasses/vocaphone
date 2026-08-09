package com.vocahq.vocaphone.dictation

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.os.SystemClock
import androidx.core.content.ContextCompat
import com.vocahq.vocaphone.audio.AudioCapture
import com.vocahq.vocaphone.audio.CaptureFormat
import com.vocahq.vocaphone.audio.PcmConversion
import com.vocahq.vocaphone.audio.WavWriter
import com.vocahq.vocaphone.core.DictationFailure
import com.vocahq.vocaphone.core.DictationPhase
import com.vocahq.vocaphone.core.DictationState
import com.vocahq.vocaphone.core.MissingPermission
import com.vocahq.vocaphone.core.TranscriptSanitizer
import com.vocahq.vocaphone.data.HistoryRepository
import com.vocahq.vocaphone.gateway.GatewayClient
import com.vocahq.vocaphone.gateway.GatewayException
import com.vocahq.vocaphone.gateway.StreamingUnavailableException
import com.vocahq.vocaphone.settings.VocaPhoneSettings
import com.vocahq.vocaphone.settings.SettingsRepository
import java.io.File
import java.util.UUID
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

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
    private val audioDirectory: File,
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
    private var finishRequested = false

    @Volatile
    private var cancelRequested = false

    /**
     * Starts a dictation unless one is already running. Missing permissions or
     * gateway settings surface as a repair state rather than a failure.
     */
    fun start(source: DictationSource) {
        if (pipeline?.isActive == true) return
        finishRequested = false
        cancelRequested = false
        pipeline = scope.launch {
            val configuration = settings.current()
            val missing = missingPermissions(configuration)
            if (missing.isNotEmpty()) {
                _state.value = DictationState(
                    phase = DictationPhase.PERMISSION_REPAIR,
                    missingPermissions = missing,
                )
                return@launch
            }
            val token = settings.token()
            if (token.isNullOrEmpty()) {
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
        finishRequested = true
    }

    fun cancel() {
        cancelRequested = true
        finishRequested = true
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
            val token = settings.token() ?: return@launch
            val client = GatewayClient(configuration.gatewayUrl, token)
            _state.value = DictationState(
                sessionId = UUID.fromString(sessionId),
                phase = DictationPhase.UPLOADING,
                language = configuration.effectiveLanguage,
                style = configuration.style,
            )
            deliverBatch(
                client = client,
                sessionId = UUID.fromString(sessionId),
                wavFile = audio,
                language = record.language,
                style = record.style,
                configuration = configuration,
                source = DictationSource.COMPANION_APP,
            )
        }
    }

    fun clearTransient() {
        if (!_state.value.phase.isBusy) reset()
    }

    fun missingPermissions(configuration: VocaPhoneSettings): Set<MissingPermission> = buildSet {
        if (!hasPermission(Manifest.permission.RECORD_AUDIO)) add(MissingPermission.MICROPHONE)
        if (!hasPermission(Manifest.permission.POST_NOTIFICATIONS)) add(MissingPermission.NOTIFICATIONS)
        if (!configuration.isConfigured) add(MissingPermission.GATEWAY_NOT_CONFIGURED)
    }

    private fun hasPermission(permission: String) =
        ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED

    // ------------------------------------------------------------- pipeline

    // `start` refuses to reach here until RECORD_AUDIO has been granted.
    @SuppressLint("MissingPermission")
    private suspend fun runDictation(
        source: DictationSource,
        configuration: VocaPhoneSettings,
        token: String,
        sessionId: UUID,
    ) {
        audioDirectory.mkdirs()
        val wavFile = File(audioDirectory, "$sessionId.wav")
        val client = GatewayClient(configuration.gatewayUrl, token)

        _state.value = DictationState(
            sessionId = sessionId,
            phase = DictationPhase.LISTENING,
            language = configuration.effectiveLanguage,
            style = configuration.style,
            startedAtElapsedMillis = SystemClock.elapsedRealtime(),
        )

        // Streaming is preferred but never required: a gateway whose engine has no
        // streaming support answers the handshake and we fall back to batch.
        val stream = try {
            client.openStream(
                sessionId = sessionId,
                language = configuration.effectiveLanguage.wireValue,
                style = configuration.style.wireValue,
                sampleRate = CaptureFormat.SAMPLE_RATE,
            ).also { it.connect() }
        } catch (_: StreamingUnavailableException) {
            null
        } catch (error: GatewayException) {
            fail(sessionId, error, wavFile = null, configuration = configuration)
            return
        }
        _state.update { it.copy(streaming = stream != null) }

        val frames = Channel<ShortArray>(capacity = 64, onBufferOverflow = BufferOverflow.DROP_OLDEST)
        val writer = WavWriter(wavFile)
        var captureError: Throwable? = null

        val recorder = AudioCapture(
            context = context,
            preference = configuration.microphone,
            onFrame = { samples, count -> frames.trySend(samples.copyOf(count)) },
            onError = { error ->
                captureError = error
                finishRequested = true
            },
        )
        capture = recorder
        if (!recorder.start()) {
            frames.close()
            writer.close()
            wavFile.delete()
            stream?.cancel()
            fail(
                sessionId,
                GatewayException(
                    "microphone_unavailable",
                    captureError?.message ?: "The microphone is not available right now.",
                    recoverable = true,
                ),
                wavFile = null,
                configuration = configuration,
            )
            return
        }

        // Frames are drained off the capture thread: file writes and socket sends
        // must never stall the AudioRecord read loop.
        val drain = scope.launch(Dispatchers.IO) {
            var scratch = ByteArray(0)
            for (frame in frames) {
                writer.write(frame, frame.size)
                if (stream != null) {
                    if (scratch.size < frame.size * 4) scratch = ByteArray(frame.size * 4)
                    PcmConversion.pcm16ToFloat32LittleEndian(frame, frame.size, scratch)
                    stream.sendFrames(scratch, frame.size * 4)
                }
                val level = PcmConversion.level(frame, frame.size)
                _state.update { current ->
                    if (current.phase != DictationPhase.LISTENING) {
                        current
                    } else {
                        current.copy(
                            level = level,
                            recordedMillis = writer.durationMillis,
                            partialTranscript = stream?.latestPartial() ?: current.partialTranscript,
                            inputRouteLabel = recorder.currentRouteLabel() ?: current.inputRouteLabel,
                        )
                    }
                }
            }
        }

        awaitFinish()
        recorder.stop()
        capture = null
        frames.close()
        drain.join()
        writer.close()

        if (cancelRequested) {
            stream?.cancel()
            wavFile.delete()
            reset()
            return
        }

        captureError?.let { error ->
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

        _state.update { it.copy(phase = DictationPhase.FINALIZING, level = 0f) }

        if (writer.durationMillis < MINIMUM_RECORDING_MILLIS) {
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

        if (stream != null) {
            _state.update { it.copy(phase = DictationPhase.TRANSCRIBING) }
            val transcript = try {
                stream.finish()
            } catch (_: StreamingUnavailableException) {
                null
            } catch (error: GatewayException) {
                if (!error.recoverable) {
                    wavFile.delete()
                    fail(sessionId, error, wavFile = null, configuration = configuration)
                    return
                }
                null
            }
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
        }

        deliverBatch(
            client,
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
    private suspend fun awaitFinish() {
        var warned = false
        while (!finishRequested) {
            val elapsed = SystemClock.elapsedRealtime() - _state.value.startedAtElapsedMillis
            if (!warned && elapsed >= DictationState.RECORDING_WARNING_MILLIS) {
                warned = true
                _state.update { it.copy(approachingLimit = true) }
            }
            if (elapsed >= DictationState.MAXIMUM_RECORDING_MILLIS) return
            delay(100)
        }
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
            client.uploadAudio(sessionId, wavFile)
            _state.update { it.copy(phase = DictationPhase.TRANSCRIBING) }
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

    private suspend fun deliver(
        transcript: String,
        sessionId: UUID,
        configuration: VocaPhoneSettings,
        source: DictationSource,
    ) {
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
            return
        }

        _state.update { it.copy(phase = DictationPhase.INSERTING, transcript = transcript) }
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

    private companion object {
        /** Below this, there is nothing a model could usefully transcribe. */
        const val MINIMUM_RECORDING_MILLIS = 300L

        /** How long the "Inserted" confirmation stays before the keyboard goes idle. */
        const val INSERTED_LINGER_MILLIS = 2_000L
    }
}
