package com.vocahq.vocaphone.local

import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.channels.Channel

/**
 * Decodes completed Sherpa chunks while AudioRecord is still capturing.
 *
 * The input queue can hold the app's full five-minute recording limit. That
 * keeps this optimization off the capture thread even when inference is slower
 * than real time; the WAV writer remains the authoritative fallback.
 */
internal class SherpaIncrementalSession(
    scope: CoroutineScope,
    private val prepare: suspend () -> Unit,
    private val decode: suspend (FloatArray) -> SherpaTranscript,
) {
    private val accepting = AtomicBoolean(true)
    private val frames = Channel<ShortArray>(capacity = MAX_RECORDING_FRAMES)
    private val result: Deferred<SherpaTranscript> =
        scope.async(Dispatchers.Default) { transcribe() }

    init {
        result.invokeOnCompletion { accepting.set(false) }
    }

    /** Non-blocking because this is called from the file-drain pipeline. */
    fun offer(frame: ShortArray): Boolean =
        accepting.get() && frames.trySend(frame).isSuccess

    suspend fun finish(): SherpaTranscript {
        accepting.set(false)
        frames.close()
        return result.await()
    }

    fun cancel() {
        accepting.set(false)
        frames.cancel()
        result.cancel()
    }

    private suspend fun transcribe(): SherpaTranscript {
        prepare()
        val audio = FloatSampleBuffer(
            initialCapacity = SherpaLongAudio.STREAMING_WINDOW_SECONDS * SherpaLongAudio.SAMPLE_RATE,
        )
        var transcript = SherpaTranscript.EMPTY
        var overlapsPrevious = false

        for (frame in frames) {
            audio.append(frame)
            while (true) {
                if (audio.size < STREAMING_WINDOW_SAMPLES) break
                val available = audio.toFloatArray()
                val split = SherpaLongAudio.nextStreamingSplit(available) ?: break
                transcript = transcript.append(
                    decode(available.copyOfRange(0, split.endExclusive)),
                    deduplicateOverlap = overlapsPrevious,
                )
                audio.discardPrefix(split.nextStart)
                overlapsPrevious = split.nextStart < split.endExclusive
            }
        }

        if (audio.size > 0) {
            transcript = transcript.append(
                decode(audio.toFloatArray()),
                deduplicateOverlap = overlapsPrevious,
            )
        }
        return transcript.copy(text = transcript.text.trim())
    }

    private class FloatSampleBuffer(initialCapacity: Int) {
        private var samples = FloatArray(initialCapacity)
        var size: Int = 0
            private set

        fun append(frame: ShortArray) {
            ensureCapacity(size + frame.size)
            for (sample in frame) samples[size++] = sample / 32_768f
        }

        fun discardPrefix(count: Int) {
            require(count in 0..size)
            samples.copyInto(
                destination = samples,
                destinationOffset = 0,
                startIndex = count,
                endIndex = size,
            )
            size -= count
        }

        fun toFloatArray(): FloatArray = samples.copyOf(size)

        private fun ensureCapacity(required: Int) {
            if (required <= samples.size) return
            samples = samples.copyOf(maxOf(required, samples.size * 2))
        }
    }

    private companion object {
        // AudioCapture emits one 100 ms frame. The app stops at five minutes.
        const val MAX_RECORDING_FRAMES = 3_100
        const val STREAMING_WINDOW_SAMPLES =
            SherpaLongAudio.STREAMING_WINDOW_SECONDS * SherpaLongAudio.SAMPLE_RATE
    }
}
