package com.example.localflow.android.audio

import android.Manifest
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Process
import androidx.annotation.RequiresPermission
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Microphone capture on its own high-priority thread. The read loop only copies
 * samples and hands them to [onFrame]; every slow operation — file writes,
 * network sends — happens on the caller's side of that callback.
 */
class AudioCapture(
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

    @RequiresPermission(Manifest.permission.RECORD_AUDIO)
    fun start(): Boolean {
        if (!running.compareAndSet(false, true)) return true

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
            onError(error)
            return false
        }

        if (recorder.state != AudioRecord.STATE_INITIALIZED) {
            recorder.release()
            running.set(false)
            onError(IllegalStateException("The microphone is not available right now."))
            return false
        }

        record = recorder
        return try {
            recorder.startRecording()
            if (recorder.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
                throw IllegalStateException("Another app is using the microphone.")
            }
            thread = Thread({ readLoop(recorder) }, "localflow-capture").apply {
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
        if (!running.compareAndSet(true, false)) return
        thread?.let { runCatching { it.join(500) } }
        thread = null
        record?.let { recorder ->
            runCatching { if (recorder.state == AudioRecord.STATE_INITIALIZED) recorder.stop() }
            runCatching { recorder.release() }
        }
        record = null
    }

    /**
     * Android chooses the input route and may change it mid-recording, so this is
     * reported rather than requested. Returns null before the route is known.
     */
    fun currentRouteLabel(): String? = record?.routedDevice?.let(::describe)

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

    private fun describe(device: AudioDeviceInfo): String {
        val kind = when (device.type) {
            AudioDeviceInfo.TYPE_BUILTIN_MIC -> "Phone microphone"
            AudioDeviceInfo.TYPE_BLUETOOTH_SCO, AudioDeviceInfo.TYPE_BLE_HEADSET -> "Bluetooth headset"
            AudioDeviceInfo.TYPE_WIRED_HEADSET -> "Wired headset"
            AudioDeviceInfo.TYPE_USB_HEADSET, AudioDeviceInfo.TYPE_USB_DEVICE -> "USB microphone"
            AudioDeviceInfo.TYPE_REMOTE_SUBMIX -> "System audio"
            else -> "External microphone"
        }
        val name = device.productName?.toString()?.trim().orEmpty()
        return if (name.isEmpty() || name.equals(kind, ignoreCase = true)) kind else "$kind — $name"
    }
}
