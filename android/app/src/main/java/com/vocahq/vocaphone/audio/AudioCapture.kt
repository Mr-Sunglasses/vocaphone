package com.vocahq.vocaphone.audio

import android.Manifest
import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioRecordingConfiguration
import android.media.MediaRecorder
import android.os.Process
import androidx.annotation.RequiresPermission
import com.vocahq.vocaphone.core.MicrophonePreference
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.delay

/**
 * Why a capture ended without the user asking it to. Android surfaces all of
 * these as an ordinary failure, but each one means another app took the input
 * rather than that recording is broken — so whatever was captured first is
 * still the user's words.
 */
enum class MicrophoneInterruption {
    /** A call, an assistant, or another exclusive user took audio focus. */
    FOCUS_LOST,

    /** Android is feeding this capture zeros because another app holds the input. */
    SILENCED,

    /** The capture session was torn down underneath the read loop. */
    CAPTURE_LOST,
}

/**
 * A microphone another app is holding, as opposed to one that does not work.
 * The distinction is what lets an interrupted dictation keep its audio instead
 * of discarding a sentence the user already finished saying.
 */
class MicrophoneInterruptedException(
    val interruption: MicrophoneInterruption,
    message: String,
) : IllegalStateException(message)

/**
 * Microphone capture on its own high-priority thread. The read loop only copies
 * samples and hands them to [onFrame]; every slow operation — file writes,
 * network sends — happens on the caller's side of that callback.
 *
 * [preference] is a request, not a guarantee: Android may still route elsewhere,
 * and a preference whose hardware is not attached falls back to automatic rather
 * than refusing to record.
 */
class AudioCapture(
    private val context: Context,
    private val preference: MicrophonePreference = MicrophonePreference.DEFAULT,
    private val onFrame: (samples: ShortArray, count: Int) -> Unit,
    private val onError: (Throwable) -> Unit,
) {
    /** 100 ms of audio: small enough for responsive streaming partials. */
    private val frameSamples = CaptureFormat.SAMPLE_RATE / 10

    private val running = AtomicBoolean(false)

    @Volatile
    private var record: AudioRecord? = null

    @Volatile
    private var thread: Thread? = null

    /** Set only when this capture took over the communication route, so only it clears it. */
    @Volatile
    private var heldCommunicationDevice = false

    @Volatile
    private var audioFocusRequest: AudioFocusRequest? = null

    /**
     * The first reason capture ended. Focus loss, silencing and a dead recorder
     * arrive together when another app takes the microphone, and only the one
     * that arrived first explains anything.
     */
    private val reported = AtomicReference<Throwable?>(null)

    @Volatile
    private var watchdog: ScheduledExecutorService? = null

    @Volatile
    private var silenceCallback: AudioManager.AudioRecordingCallback? = null

    private val audioManager: AudioManager? get() = context.getSystemService(AudioManager::class.java)

    @RequiresPermission(Manifest.permission.RECORD_AUDIO)
    suspend fun start(): Boolean {
        if (!running.compareAndSet(false, true)) return true
        reported.set(null)

        val minimum = AudioRecord.getMinBufferSize(
            CaptureFormat.SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        if (minimum <= 0) {
            running.set(false)
            onError(IllegalStateException("This device cannot record 16 kHz mono audio."))
            return false
        }
        // Comfortably above the platform minimum so a scheduling hiccup does not
        // overrun the buffer and drop the middle of a sentence.
        val bufferBytes = maxOf(minimum * 4, frameSamples * CaptureFormat.BYTES_PER_SAMPLE * 8)

        // Focus is how a call announces itself mid-dictation, not permission to
        // record. Refusing to start without it would fail dictations that would
        // have worked, so a refusal is noted and capture is attempted anyway.
        requestAudioFocus()

        // Another app letting go of the microphone — a call ending, a screen
        // recorder handing it back — is not instantaneous, and Android reports
        // that gap as an ordinary failure. Retrying across it turns a lost
        // dictation into a slightly delayed one.
        repeat(START_ATTEMPTS) { attempt ->
            if (attempt > 0) delay(START_RETRY_MILLIS)
            // `stop` during the wait means the dictation is already over; a
            // later attempt would open a recorder nothing would ever close.
            if (!running.get()) return false
            if (openRecorder(bufferBytes)) return true
        }

        running.set(false)
        releaseCommunicationDevice()
        abandonAudioFocus()
        onError(unavailableMicrophone())
        return false
    }

    @Synchronized
    fun stop() {
        running.set(false)
        val recorder = record
        stopSilenceWatch(recorder)
        // Give the read loop a moment to notice and drain what the hardware has
        // already buffered, because `AudioRecord.stop` throws that away.
        //
        // Stopping first and joining afterwards is what cut the last syllable
        // off a dictation: `read` is blocking, so stopping does wake it, but it
        // wakes it into a stopped recorder with the tail still inside. A read
        // returns within a frame while audio is flowing, so this join almost
        // always completes well inside its bound; the hard stop below is what
        // happens when the microphone has already stalled and there is nothing
        // to wait for anyway.
        val drained = thread
            ?.takeIf { it !== Thread.currentThread() }
            ?.let { runCatching { it.join(DRAIN_JOIN_MILLIS); !it.isAlive }.getOrDefault(false) }
            ?: true
        recorder?.let {
            runCatching {
                if (it.state == AudioRecord.STATE_INITIALIZED &&
                    it.recordingState == AudioRecord.RECORDSTATE_RECORDING
                ) {
                    it.stop()
                }
            }
        }
        if (!drained) {
            thread?.takeIf { it !== Thread.currentThread() }?.let { runCatching { it.join(500) } }
        }
        thread = null
        recorder?.let {
            runCatching { it.release() }
        }
        record = null
        releaseCommunicationDevice()
        abandonAudioFocus()
    }

    /**
     * One attempt at owning the input. Returns false — having cleaned up after
     * itself — when the microphone was not available this time round.
     */
    @Synchronized
    @RequiresPermission(Manifest.permission.RECORD_AUDIO)
    private fun openRecorder(bufferBytes: Int): Boolean {
        val recorder = try {
            AudioRecord(
                MediaRecorder.AudioSource.VOICE_RECOGNITION,
                CaptureFormat.SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                bufferBytes,
            )
        } catch (_: Throwable) {
            return false
        }
        if (recorder.state != AudioRecord.STATE_INITIALIZED) {
            runCatching { recorder.release() }
            return false
        }

        return try {
            applyPreference(recorder)
            recorder.startRecording()
            if (recorder.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
                throw IllegalStateException("The microphone did not start.")
            }
            record = recorder
            watchForSilencing(recorder)
            thread = Thread({ readLoop(recorder) }, "vocaphone-capture").apply {
                priority = Thread.MAX_PRIORITY
                start()
            }
            true
        } catch (_: Throwable) {
            record = null
            stopSilenceWatch(recorder)
            runCatching { recorder.stop() }
            runCatching { recorder.release() }
            releaseCommunicationDevice()
            false
        }
    }

    /**
     * "Could not start" means different things to the user depending on who else
     * is holding the input, so the cause is read once here rather than guessed
     * at by every surface that shows the message.
     */
    private fun unavailableMicrophone(): MicrophoneInterruptedException {
        val mode = runCatching { audioManager?.mode }.getOrNull()
        val inCall = mode == AudioManager.MODE_IN_CALL || mode == AudioManager.MODE_IN_COMMUNICATION
        return MicrophoneInterruptedException(
            MicrophoneInterruption.SILENCED,
            if (inCall) {
                "The microphone is busy with a call. Try again once the call ends."
            } else {
                "Another app is using the microphone. Stop that recording and try again."
            },
        )
    }

    /**
     * Capturing speech asks for transient exclusive focus, which is how a call
     * or a voice assistant announces itself mid-dictation. Whether the request
     * is granted is deliberately not acted on: focus is advisory, and the
     * microphone is frequently usable without it.
     */
    private fun requestAudioFocus() {
        val manager = audioManager ?: return
        val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE)
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build(),
            )
            .setOnAudioFocusChangeListener { change ->
                when (change) {
                    // The user's attention has moved to a call or an assistant,
                    // so capture ends here and says why it did.
                    AudioManager.AUDIOFOCUS_LOSS,
                    AudioManager.AUDIOFOCUS_LOSS_TRANSIENT,
                    -> interrupt(
                        MicrophoneInterruption.FOCUS_LOST,
                        "Something else needed the microphone. Try dictating again.",
                    )
                    // Ducking asks a player to turn itself down. A recording has
                    // no volume to turn down, so a notification chime or a
                    // navigation prompt must not end a dictation.
                    else -> Unit
                }
            }
            .build()
        audioFocusRequest = request
        manager.requestAudioFocus(request)
    }

    private fun abandonAudioFocus() {
        val request = audioFocusRequest ?: return
        audioFocusRequest = null
        runCatching { audioManager?.abandonAudioFocusRequest(request) }
    }

    /**
     * Android 10 and later let two apps hold the microphone at once and simply
     * feed the loser digital silence, reporting no error anywhere. Without this
     * the dictation looks healthy for its whole length and then produces an
     * empty transcript, so the silencing is turned into the interruption it is.
     */
    private fun watchForSilencing(recorder: AudioRecord) {
        val executor = Executors.newSingleThreadScheduledExecutor { runnable ->
            Thread(runnable, "vocaphone-capture-watch")
        }
        val callback = object : AudioManager.AudioRecordingCallback() {
            override fun onRecordingConfigChanged(configs: List<AudioRecordingConfiguration>) {
                if (!running.get() || configs.none { it.isClientSilenced }) return
                // A route change can silence a capture for a few frames on its
                // way somewhere else. Only silence that is still there a moment
                // later is another app holding the input.
                runCatching {
                    executor.schedule(
                        ::confirmSilenced,
                        SILENCE_CONFIRMATION_MILLIS,
                        TimeUnit.MILLISECONDS,
                    )
                }
            }
        }
        watchdog = executor
        silenceCallback = callback
        runCatching { recorder.registerAudioRecordingCallback(executor, callback) }
    }

    private fun confirmSilenced() {
        if (!running.get()) return
        val silenced = runCatching {
            record?.activeRecordingConfiguration?.isClientSilenced
        }.getOrNull() ?: return
        if (!silenced) return
        interrupt(
            MicrophoneInterruption.SILENCED,
            "Another app took the microphone. Try again once it has finished.",
        )
    }

    private fun stopSilenceWatch(recorder: AudioRecord?) {
        silenceCallback?.let { callback ->
            silenceCallback = null
            runCatching { recorder?.unregisterAudioRecordingCallback(callback) }
        }
        watchdog?.let { executor ->
            watchdog = null
            runCatching { executor.shutdownNow() }
        }
    }

    /**
     * Ends capture for a reason that is not the user's doing. Only the first
     * reason is reported: everything after it is a consequence of it.
     */
    private fun interrupt(reason: MicrophoneInterruption, message: String) {
        val error = MicrophoneInterruptedException(reason, message)
        if (!reported.compareAndSet(null, error)) return
        running.set(false)
        onError(error)
    }

    /**
     * Asks for the selected input. Android may honour none of this — the route is
     * confirmed afterwards by [currentRouteLabel], never assumed from here — and a
     * preference with nothing attached deliberately leaves the recorder on
     * automatic instead of failing a dictation the user already started.
     */
    private fun applyPreference(recorder: AudioRecord) {
        val manager = audioManager ?: return
        // Reaching a Bluetooth microphone means putting the headset into call
        // mode; setPreferredDevice alone does not do that.
        val communication = InputDevices.communicationMatch(manager, preference)
        if (communication == null) {
            // A Bluetooth headset selected earlier keeps the communication route
            // until something gives it back — and a process killed mid-dictation
            // gives nothing back — so every other preference reclaims it first.
            runCatching { manager.clearCommunicationDevice() }
        } else {
            heldCommunicationDevice = runCatching {
                manager.setCommunicationDevice(communication)
            }.getOrDefault(false)
        }
        InputDevices.match(manager, preference)?.let { device ->
            runCatching { recorder.setPreferredDevice(device) }
        }
    }

    private fun releaseCommunicationDevice() {
        if (!heldCommunicationDevice) return
        heldCommunicationDevice = false
        runCatching { audioManager?.clearCommunicationDevice() }
    }

    /**
     * Android chooses the input route and may change it mid-recording, so this is
     * reported rather than requested. Returns null before the route is known.
     */
    fun currentRouteLabel(): String? = record?.routedDevice?.let(InputDevices::describe)

    private fun readLoop(recorder: AudioRecord) {
        Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO)
        val samples = ShortArray(frameSamples)
        while (running.get()) {
            val count = recorder.read(samples, 0, samples.size)
            if (count > 0) {
                onFrame(samples, count)
                continue
            }
            when (count) {
                0 -> continue
                // A dead object is the microphone being reclaimed, which is an
                // interruption rather than a fault in this recording.
                AudioRecord.ERROR_DEAD_OBJECT -> {
                    interrupt(
                        MicrophoneInterruption.CAPTURE_LOST,
                        "Another app took the microphone. Try again once it has finished.",
                    )
                    return
                }

                AudioRecord.ERROR_INVALID_OPERATION, AudioRecord.ERROR_BAD_VALUE,
                AudioRecord.ERROR,
                -> {
                    if (running.get()) {
                        interrupt(
                            MicrophoneInterruption.CAPTURE_LOST,
                            "Microphone capture stopped unexpectedly. Try dictating again.",
                        )
                    }
                    return
                }
            }
        }
        drainBufferedFrames(recorder)
    }

    /**
     * Hands over whatever the hardware buffered while the loop was being asked
     * to stop.
     *
     * `READ_NON_BLOCKING` so a microphone that has already gone quiet returns 0
     * straight away rather than holding `stop` open for a frame that is never
     * coming. Bounded because this runs while the user is waiting for their
     * words: a tail worth keeping is milliseconds long, and anything larger is
     * a backlog that the recording is better off without.
     */
    private fun drainBufferedFrames(recorder: AudioRecord) {
        val samples = ShortArray(frameSamples)
        repeat(MAX_DRAIN_FRAMES) {
            val count = runCatching {
                recorder.read(samples, 0, samples.size, AudioRecord.READ_NON_BLOCKING)
            }.getOrDefault(0)
            if (count <= 0) return
            onFrame(samples, count)
        }
    }

    private companion object {
        /** Attempts at a microphone another app is in the middle of releasing. */
        const val START_ATTEMPTS = 3

        /** Long enough for a call teardown or a recorder handoff to complete. */
        const val START_RETRY_MILLIS = 150L

        /** Silence still present after this is another app, not a route change. */
        const val SILENCE_CONFIRMATION_MILLIS = 400L

        /**
         * How long `stop` waits for the read loop to hand back the tail. A
         * blocking read returns within a frame while audio is flowing, so this
         * is roughly two of them: enough for the common case, short enough that
         * a stalled microphone does not hold up Finish.
         */
        const val DRAIN_JOIN_MILLIS = 250L

        /** Two frames of tail. More than this is a backlog, not a last word. */
        const val MAX_DRAIN_FRAMES = 2
    }
}
