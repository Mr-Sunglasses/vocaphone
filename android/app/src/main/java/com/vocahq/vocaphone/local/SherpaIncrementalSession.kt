package com.vocahq.vocaphone.local

import com.vocahq.vocaphone.audio.SpeechAudioConditioning
import java.util.concurrent.atomic.AtomicBoolean
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
 * A window is let go at twelve seconds, which bounds a long dictation's wait,
 * and at any pause after the first three, which is what most dictations --
 * shorter than twelve seconds -- have instead: what was said before the pause
 * is decoded while the speaker is still recording, and Finish waits only for
 * what came after it.
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
        // The lowest and highest gains any decoded window was levelled with.
        // The running level a gain derives from can move either way -- up as
        // the speaker gets louder, down as more speech lets a transient be set
        // aside -- so the drift is the spread of every gain used, not one step.
        var lowestGain = 0f
        var highestGain = 0f
        // The loudest frame of everything decoded so far, as the microphone
        // heard it. Raw because each window can be levelled with a slightly
        // different gain, and a level stored at one gain compared with a level
        // measured at another misjudges how loud this window is next to the
        // speech before it. The current gain is applied when comparing, which
        // is what the complete-WAV path's single gain amounts to.
        var loudestFrame = 0.0

        suspend fun consume(chunk: FloatArray) {
            // Silence is judged at the level the model will hear, as the
            // complete-WAV path judges it after levelling the whole recording.
            // The raw level of a quiet speaker -- a phone on the desk -- can sit
            // under the silence floor while the same window, at the gain the
            // WAV decode would give it, is plainly speech. Judging it raw
            // skipped that window without a decode or a fallback, and its
            // words were missing from a result that still looked complete.
            // Below the limiter's knee, which the floor is far under, a frame
            // levelled by `gain` measures `gain` times its raw level.
            val speechLevel = audio.runningLevel.level
            val gain = SpeechAudioConditioning.gainFor(speechLevel)
            val level = SherpaLongAudio.loudestFrame(chunk)
            if (SherpaLongAudio.isEffectivelySilent(level * gain)) return

            // What the model actually hears is the gain, which mostly does not
            // move even while the level it comes from does, so that is what is
            // compared. Past the tolerance the complete-WAV path takes over and
            // every word is levelled once.
            lowestGain = if (lowestGain == 0f) gain else minOf(lowestGain, gain)
            highestGain = maxOf(highestGain, gain)
            if (highestGain / lowestGain > MAX_GAIN_DRIFT) conditioningChanged = true

            // Judged on what this window did not inherit from the one before
            // it. A window that is mostly retained overlap can be six seconds
            // long and carry half a second of new speech, and asking whether
            // the *chunk* was long enough is what let that half second vanish
            // without the file ever being re-read. Measured before levelling,
            // which happens in place.
            val newRegion = chunk.copyOfRange(retainedHead.coerceAtMost(chunk.size), chunk.size)
            val newRegionLevel = SherpaLongAudio.loudestFrame(newRegion)
            val levelled = SpeechAudioConditioning.conditionStreaming(chunk, speechLevel)
            val decoded = decode(levelled)
            if (decoded.text.isEmpty() &&
                SherpaLongAudio.carriesRecoverableSpeech(
                    newRegion = newRegion,
                    inheritsAudio = retainedHead > 0,
                    loudestFrame = newRegionLevel * gain,
                    loudestFrameSoFar = loudestFrame * gain,
                )
            ) {
                droppedAudibleChunk = true
            }
            loudestFrame = maxOf(loudestFrame, level)
            transcript = transcript.append(decoded, deduplicateOverlap = overlapsPrevious)
        }

        fun commit(split: SherpaStreamingSplit, retainsOnlyQuiet: Boolean = false) {
            audio.discardPrefix(split.nextStart)
            // A pause split's retained audio lies inside the quiet it was cut
            // in, so no word can be heard on both sides of it, and matching
            // repeated words back out there could only delete a word the
            // speaker really said twice -- "bravo. Bravo".
            overlapsPrevious = !retainsOnlyQuiet && split.nextStart < split.endExclusive
            retainedHead = split.endExclusive - split.nextStart
        }

        for (frame in frames) {
            audio.append(frame)
            var split = false
            while (true) {
                if (audio.size < SherpaLongAudio.STREAMING_WINDOW_SECONDS * SherpaLongAudio.SAMPLE_RATE) {
                    break
                }
                val available = audio.toFloatArray()
                val next = SherpaLongAudio.nextStreamingSplit(available) ?: break
                consume(available.copyOfRange(0, next.endExclusive))
                commit(next)
                split = true
            }
            // A pause decodes what came before it now, while the speaker is
            // still recording, instead of after Finish. If they finish during
            // it, what is left is the pause, and Finish has almost nothing to
            // wait for.
            if (!split) {
                audio.pauseSplit()?.let { next ->
                    consume(audio.prefix(next.endExclusive))
                    commit(next, retainsOnlyQuiet = true)
                }
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
        /** Of everything captured, including what has been discarded. */
        val runningLevel = SpeechAudioConditioning.RunningLevel()

        fun append(frame: ShortArray) {
            ensureCapacity(size + frame.size)
            for (sample in frame) {
                val value = sample / 32_768f
                runningLevel.append(value)
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

        fun prefix(count: Int): FloatArray = samples.copyOf(count.coerceAtMost(size))

        /**
         * Asked of the live buffer, so the frames between pauses copy nothing,
         * and judged at the gain this audio will be decoded with.
         */
        fun pauseSplit(): SherpaStreamingSplit? = SherpaLongAudio.nextPauseSplit(
            samples,
            size,
            gain = SpeechAudioConditioning.gainFor(runningLevel.level),
        )

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
