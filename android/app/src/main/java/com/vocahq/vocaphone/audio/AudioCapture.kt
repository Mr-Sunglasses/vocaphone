package com.vocahq.vocaphone.audio

import android.Manifest
import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Process
import androidx.annotation.RequiresPermission
import com.vocahq.vocaphone.core.MicrophonePreference
import java.util.concurrent.atomic.AtomicBoolean

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

    private val audioManager: AudioManager? get() = context.getSystemService(AudioManager::class.java)

    @RequiresPermission(Manifest.permission.RECORD_AUDIO)
    fun start(): Boolean {
        if (!running.compareAndSet(false, true)) return true

        if (!requestAudioFocus()) {
            running.set(false)
            onError(IllegalStateException("Another app is using the microphone."))
            return false
        }

        val minimum = AudioRecord.getMinBufferSize(
            CaptureFormat.SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        if (minimum <= 0) {
            running.set(false)
            abandonAudioFocus()
            onError(IllegalStateException("This device cannot record 16 kHz mono audio."))
            return false
        }
        // Comfortably above the platform minimum so a scheduling hiccup does not
        // overrun the buffer and drop the middle of a sentence.
        val bufferBytes = maxOf(minimum * 4, frameSamples * CaptureFormat.BYTES_PER_SAMPLE * 8)

        val recorder = try {
            AudioRecord(
                MediaRecorder.AudioSource.VOICE_RECOGNITION,
                CaptureFormat.SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                bufferBytes,
            )
        } catch (error: Throwable) {
            running.set(false)
            abandonAudioFocus()
            onError(error)
            return false
        }

        if (recorder.state != AudioRecord.STATE_INITIALIZED) {
            recorder.release()
            running.set(false)
            abandonAudioFocus()
            onError(IllegalStateException("The microphone is not available right now."))
            return false
        }

        record = recorder
        return try {
            applyPreference(recorder)
            recorder.startRecording()
            if (recorder.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
                throw IllegalStateException("Another app is using the microphone.")
            }
            thread = Thread({ readLoop(recorder) }, "vocaphone-capture").apply {
                priority = Thread.MAX_PRIORITY
                start()
            }
            true
        } catch (error: Throwable) {
            stop()
            onError(error)
            false
        }
    }

    fun stop() {
        running.set(false)
        thread?.let { runCatching { it.join(500) } }
        thread = null
        record?.let { recorder ->
            runCatching { if (recorder.state == AudioRecord.STATE_INITIALIZED) recorder.stop() }
            runCatching { recorder.release() }
        }
        record = null
        releaseCommunicationDevice()
        abandonAudioFocus()
    }

    /**
     * Capturing speech owns transient audio focus. A call, Siri or another
     * exclusive microphone user therefore turns this dictation into an explicit
     * interruption instead of leaving a foreground service that appears alive.
     */
    private fun requestAudioFocus(): Boolean {
        val manager = audioManager ?: return true
        val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE)
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build(),
            )
            .setOnAudioFocusChangeListener { change ->
                if (change == AudioManager.AUDIOFOCUS_LOSS ||
                    change == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT ||
                    change == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK
                ) {
                    if (running.get()) {
                        onError(IllegalStateException("Microphone access was interrupted."))
                        running.set(false)
                    }
                }
            }
            .build()
        audioFocusRequest = request
        return manager.requestAudioFocus(request) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
    }

    private fun abandonAudioFocus() {
        val request = audioFocusRequest ?: return
        audioFocusRequest = null
        runCatching { audioManager?.abandonAudioFocusRequest(request) }
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
                AudioRecord.ERROR_INVALID_OPERATION, AudioRecord.ERROR_BAD_VALUE,
                AudioRecord.ERROR_DEAD_OBJECT, AudioRecord.ERROR,
                -> {
                    if (running.get()) onError(IllegalStateException("Microphone capture stopped."))
                    return
                }
            }
        }
    }
}
