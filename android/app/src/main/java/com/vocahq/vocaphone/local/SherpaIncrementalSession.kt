package com.vocahq.vocaphone.local

import com.vocahq.vocaphone.audio.SpeechAudioConditioning
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.abs
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.channels.Channel

/**
 * What an incremental session decoded, and whether any of the recording is
 * missing from it.
 *
 * A chunk that decodes to nothing takes its seconds out of the transcript
 * without leaving a trace: the merge joins the chunks either side into text
 * that reads as a whole sentence which happens to begin ten seconds in. The
 * attention families drop a long chunk often enough for this to be the
 * difference between a transcript and a plausible-looking lie, so the caller
 * re-decodes the file rather than shipping the hole.
 */
internal data class SherpaIncrementalResult(
    val transcript: SherpaTranscript,
    val droppedAudibleChunk: Boolean,
) {
    /**
     * Whether a whole-file re-decode is worth taking over this result.
     *
     * The re-decode exists to recover seconds the streaming pass lost, and it
     * is only evidence of that if it came back with more. The same model that
     * dropped a chunk in one pass drops one in the other -- over a recording
     * with a long pause in it, routinely -- so taking the second pass on faith
     * trades a hole for a bigger one, and the user watches a finished sentence
     * lose its opening half.
     */
    fun supersededBy(wholeFile: String): Boolean = wholeFile.length > transcript.text.length
}

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
    private val result: Deferred<SherpaIncrementalResult> =
        scope.async(Dispatchers.Default) { transcribe() }

    init {
        result.invokeOnCompletion { accepting.set(false) }
    }

    /** Non-blocking because this is called from the file-drain pipeline. */
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

    private suspend fun transcribe(): SherpaIncrementalResult {
        prepare()
        val audio = FloatSampleBuffer(
            initialCapacity = SherpaLongAudio.STREAMING_WINDOW_SECONDS * SherpaLongAudio.SAMPLE_RATE,
        )
        var transcript = SherpaTranscript.EMPTY
        var overlapsPrevious = false
        var droppedAudibleChunk = false
        // The loudest frame of everything decoded so far, which is what a later
        // chunk's level is judged against. Read before this chunk contributes
        // to it, so a pause is compared with the speech around it and never
        // with itself.
        var loudestFrame = 0.0

        suspend fun consume(chunk: FloatArray) {
            // Silence is judged on the capture as it arrived, and so has to be
            // measured before `condition` levels the array in place. That gain
            // multiplies a quiet recording by as much as eight, and a floor
            // meant for microphone levels reads amplified room tone as speech
            // -- which buys a decode, the two more the empty-chunk recovery
            // adds on top, and then the whole-file re-run the flag below asks
            // the caller for. All to transcribe a pause.
            val level = SherpaLongAudio.loudestFrame(chunk)
            if (SherpaLongAudio.isEffectivelySilent(level)) return

            // The gain a chunk is levelled with has to come from more than the
            // chunk itself: one gain per chunk moves the level at every
            // boundary, and a chunk that is all pause would be amplified into
            // noise the model transcribes as words. The peak over everything
            // captured so far is the closest a streaming chunk gets to the
            // single gain the whole-file path applies, and it only ever grows,
            // so the gain only ever settles.
            val levelled = SpeechAudioConditioning.condition(chunk, audio.peak)
            val decoded = decode(levelled)

            // Only a chunk long enough that the recovery has already tried and
            // failed, and loud enough next to the rest of the recording to have
            // held speech, is a hole worth re-reading the file for. Below those
            // bars an empty answer is routine -- the retained overlap, the
            // fragment of a word a recording ending just after a boundary
            // leaves, the room tone while someone pauses to think -- and
            // treating it as a loss spends a second pass over the whole
            // recording to find out it was right the first time.
            if (decoded.text.isEmpty() &&
                chunk.size >
                SherpaLongAudio.MIN_SUSPECT_CHUNK_SECONDS * SherpaLongAudio.SAMPLE_RATE &&
                SherpaLongAudio.carriesSpeech(level, loudestFrame)
            ) {
                droppedAudibleChunk = true
            }
            loudestFrame = maxOf(loudestFrame, level)
            transcript = transcript.append(decoded, deduplicateOverlap = overlapsPrevious)
        }

        for (frame in frames) {
            audio.append(frame)
            while (true) {
                if (audio.size < STREAMING_WINDOW_SAMPLES) break
                val available = audio.toFloatArray()
                val split = SherpaLongAudio.nextStreamingSplit(available) ?: break
                consume(available.copyOfRange(0, split.endExclusive))
                audio.discardPrefix(split.nextStart)
                overlapsPrevious = split.nextStart < split.endExclusive
            }
        }

        if (audio.size > 0) consume(audio.toFloatArray())
        return SherpaIncrementalResult(
            transcript = transcript.copy(text = transcript.text.trim()),
            droppedAudibleChunk = droppedAudibleChunk,
        )
    }

    private class FloatSampleBuffer(initialCapacity: Int) {
        private var samples = FloatArray(initialCapacity)
        var size: Int = 0
            private set

        /** The loudest sample of everything appended, not only what is retained. */
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
        // AudioCapture emits one 100 ms frame. The app stops at five minutes.
        const val MAX_RECORDING_FRAMES = 3_100
        const val STREAMING_WINDOW_SAMPLES =
            SherpaLongAudio.STREAMING_WINDOW_SECONDS * SherpaLongAudio.SAMPLE_RATE
    }
}
