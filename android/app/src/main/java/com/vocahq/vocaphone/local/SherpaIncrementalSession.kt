package com.vocahq.vocaphone.local

import com.vocahq.vocaphone.audio.SpeechAudioConditioning
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.abs
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.channels.Channel

/** The streaming result and the evidence required before it can be trusted. */
internal data class SherpaIncrementalResult(
    val transcript: SherpaTranscript,
    val droppedAudibleChunk: Boolean,
    val conditioningChanged: Boolean,
    val processingError: Throwable? = null,
) {
    /** A complete, stable result can bypass the post-capture WAV decode. */
    val isSafe: Boolean
        get() = processingError == null &&
            !droppedAudibleChunk &&
            !conditioningChanged &&
            transcript.text.isNotBlank()
}

/**
 * Decodes bounded Sherpa windows while AudioRecord continues capturing.
 *
 * This is a latency optimization, not a second source of truth. Every frame
 * is retained in the WAV as well. A changed running gain, an empty audible
 * chunk, a failed offer, or any native exception makes the caller use that
 * complete WAV instead.
 */
internal class SherpaIncrementalSession(
    scope: CoroutineScope,
    private val prepare: suspend () -> Unit,
    private val decode: suspend (FloatArray) -> SherpaTranscript,
) {
    private val accepting = AtomicBoolean(true)
    private val frames = Channel<ShortArray>(capacity = MAX_RECORDING_FRAMES)
    private val result: Deferred<SherpaIncrementalResult> =
        scope.async(Dispatchers.Default) { runSafely() }

    init {
        result.invokeOnCompletion { accepting.set(false) }
    }

    /** Non-blocking: this is called from the AudioRecord callback. */
    fun offer(frame: ShortArray): Boolean =
        accepting.get() && frames.trySend(frame).isSuccess

    suspend fun finish(): SherpaIncrementalResult {
        accepting.set(false)
        frames.close()
        return result.await()
    }

    fun cancel() {
        accepting.set(false)
        frames.cancel()
        result.cancel()
    }

    private suspend fun runSafely(): SherpaIncrementalResult = try {
        transcribe()
    } catch (error: CancellationException) {
        throw error
    } catch (error: Throwable) {
        SherpaIncrementalResult(
            transcript = SherpaTranscript.EMPTY,
            droppedAudibleChunk = true,
            conditioningChanged = true,
            processingError = error,
        )
    }

    private suspend fun transcribe(): SherpaIncrementalResult {
        prepare()
        val audio = FloatSampleBuffer(
            initialCapacity = SherpaLongAudio.STREAMING_WINDOW_SECONDS * SherpaLongAudio.SAMPLE_RATE,
        )
        var transcript = SherpaTranscript.EMPTY
        var overlapsPrevious = false
        // How much of the front of the next chunk the previous split already
        // decoded. Everything a window can lose sits after it, so it is what
        // the emptiness of its answer is judged on.
        var retainedHead = 0
        var droppedAudibleChunk = false
        var conditioningChanged = false
        // The gain the first decoded window was levelled with. `gainFor` is
        // monotonically non-increasing in the running peak, so comparing every
        // later window against this one measures the total drift rather than
        // one step of it.
        var firstAppliedGain = 0f
        var loudestFrame = 0.0

        suspend fun consume(chunk: FloatArray) {
            val level = SherpaLongAudio.loudestFrame(chunk)
            if (SherpaLongAudio.isEffectivelySilent(level)) return

            // A running peak is the closest safe approximation to the
            // recording-wide gain, and it moves on almost every recording:
            // anyone who gets louder as they go raises it. What the model
            // actually hears is the gain, which mostly does not move, so that
            // is what is compared. Past the tolerance the complete-WAV path
            // takes over and every word is levelled once.
            val gain = SpeechAudioConditioning.gainFor(audio.peak)
            if (firstAppliedGain > 0f &&
                maxOf(firstAppliedGain, gain) / minOf(firstAppliedGain, gain) > MAX_GAIN_DRIFT
            ) {
                conditioningChanged = true
            }
            val levelled = SpeechAudioConditioning.conditionStreaming(chunk, audio.peak)
            val decoded = decode(levelled)
            // Judged on what this window did not inherit from the one before
            // it. A window that is mostly retained overlap can be six seconds
            // long and carry half a second of new speech, and asking whether
            // the *chunk* was long enough is what let that half second vanish
            // without the file ever being re-read.
            val newRegion = chunk.copyOfRange(retainedHead.coerceAtMost(chunk.size), chunk.size)
            if (decoded.text.isEmpty() &&
                SherpaLongAudio.carriesRecoverableSpeech(
                    newRegion = newRegion,
                    inheritsAudio = retainedHead > 0,
                    loudestFrame = SherpaLongAudio.loudestFrame(newRegion),
                    loudestFrameSoFar = loudestFrame,
                )
            ) {
                droppedAudibleChunk = true
            }
            if (firstAppliedGain == 0f) firstAppliedGain = gain
            loudestFrame = maxOf(loudestFrame, level)
            transcript = transcript.append(decoded, deduplicateOverlap = overlapsPrevious)
        }

        for (frame in frames) {
            audio.append(frame)
            while (true) {
                if (audio.size < SherpaLongAudio.STREAMING_WINDOW_SECONDS * SherpaLongAudio.SAMPLE_RATE) {
                    break
                }
                val available = audio.toFloatArray()
                val split = SherpaLongAudio.nextStreamingSplit(available) ?: break
                consume(available.copyOfRange(0, split.endExclusive))
                audio.discardPrefix(split.nextStart)
                overlapsPrevious = split.nextStart < split.endExclusive
                retainedHead = split.endExclusive - split.nextStart
            }
        }

        if (audio.size > 0) consume(audio.toFloatArray())
        return SherpaIncrementalResult(
            transcript = transcript.copy(text = transcript.text.trim()),
            droppedAudibleChunk = droppedAudibleChunk,
            conditioningChanged = conditioningChanged,
        )
    }

    private class FloatSampleBuffer(initialCapacity: Int) {
        private var samples = FloatArray(initialCapacity)
        var size: Int = 0
            private set
        var peak: Float = 0f
            private set

        fun append(frame: ShortArray) {
            ensureCapacity(size + frame.size)
            for (sample in frame) {
                val value = sample / 32_768f
                if (abs(value) > peak) peak = abs(value)
                samples[size++] = value
            }
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
        // AudioCapture emits one 100 ms frame; the app stops at five minutes.
        const val MAX_RECORDING_FRAMES = 3_100

        /**
         * How far the streaming gain may drift before the complete WAV has to
         * take over.
         *
         * Two is 6 dB. A gain is a constant offset in every log-mel channel,
         * which per-feature normalization mostly removes and volume
         * augmentation trains through, so 6 dB across a transcript is not what
         * makes one window read differently from the next. What this is
         * guarding against is the eight-fold spread the gain ceiling allows
         * between a whisper and a shout, and that still trips it. Tighter than
         * this and ordinary speech dynamics -- anyone who warms up as they talk
         * -- send every recording to the slow path.
         */
        const val MAX_GAIN_DRIFT = 2f
    }
}
