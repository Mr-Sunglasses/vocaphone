package com.vocahq.vocaphone.local

import java.util.Locale
import kotlin.math.sqrt

/** A half-open range of 16 kHz samples sent to one offline decode call. */
internal data class SherpaAudioChunk(
    val start: Int,
    val endExclusive: Int,
    val overlapsPrevious: Boolean,
)

/** A completed streaming chunk and the first sample retained for the next one. */
internal data class SherpaStreamingSplit(
    val endExclusive: Int,
    val nextStart: Int,
)

/**
 * Keeps sherpa offline models away from unbounded encoder/decoder sequences.
 *
 * Offline recognizers accept one complete waveform per stream. That is a good
 * fast path for a sentence, but attention-based models become disproportionately
 * expensive as the waveform grows. The boundary search prefers a quiet 100 ms
 * frame around the target so normal speech is not cut in half. Continuous speech
 * falls back to a 500 ms overlap; the transcript merger removes repeated words.
 */
internal object SherpaLongAudio {
    const val SAMPLE_RATE = 16_000
    const val LONG_AUDIO_THRESHOLD_SECONDS = 12
    const val TARGET_CHUNK_SECONDS = 10
    const val MAX_CHUNK_SECONDS = 14
    const val OVERLAP_MILLIS = 500
    const val STREAMING_WINDOW_SECONDS = TARGET_CHUNK_SECONDS + 2

    /**
     * A chunk shorter than this answering with no tokens is ordinary rather
     * than a loss: it is the half second of retained overlap a recording that
     * ends just after a boundary leaves behind, or a fragment of a word. Longer
     * than this and an empty answer is suspicious -- which is why it is also the
     * bar [SherpaEmptyChunkRecovery] uses before it bothers retrying a chunk as
     * two halves.
     */
    const val MIN_SUSPECT_CHUNK_SECONDS = 6

    private const val SILENCE_FRAME_MILLIS = 100
    private const val SILENCE_SEARCH_MILLIS = 2_000
    private const val MIN_CHUNK_SECONDS = 4
    private const val MIN_SILENCE_RMS = 0.0125
    private const val SILENCE_RMS_RATIO = 0.18
    private const val SILENT_CHUNK_RMS = 0.006

    fun chunks(samples: FloatArray): List<SherpaAudioChunk> {
        if (samples.size <= LONG_AUDIO_THRESHOLD_SECONDS * SAMPLE_RATE) {
            return listOf(SherpaAudioChunk(0, samples.size, overlapsPrevious = false))
        }

        val targetSamples = TARGET_CHUNK_SECONDS * SAMPLE_RATE
        val maxSamples = MAX_CHUNK_SECONDS * SAMPLE_RATE
        val overlapSamples = OVERLAP_MILLIS * SAMPLE_RATE / 1_000
        val minChunkSamples = MIN_CHUNK_SECONDS * SAMPLE_RATE
        val chunks = mutableListOf<SherpaAudioChunk>()
        var start = 0
        var overlapsPrevious = false

        while (start < samples.size) {
            val remaining = samples.size - start
            if (remaining <= targetSamples) {
                chunks += SherpaAudioChunk(start, samples.size, overlapsPrevious)
                break
            }

            val idealEnd = (start + targetSamples).coerceAtMost(samples.size)
            val silence = findSilenceBoundary(
                samples = samples,
                start = start,
                idealEnd = idealEnd,
                minEnd = start + minChunkSamples,
                maxEnd = (start + maxSamples).coerceAtMost(samples.size - minChunkSamples),
            )
            val end = silence ?: idealEnd
            val useOverlap = silence == null
            chunks += SherpaAudioChunk(start, end, overlapsPrevious)
            start = if (useOverlap) {
                (end - overlapSamples).coerceAtLeast(start + 1)
            } else {
                end
            }
            overlapsPrevious = useOverlap
        }
        return chunks
    }

    /**
     * Returns one stable boundary once enough future audio exists to inspect
     * the full silence-search window. The caller retains [SherpaStreamingSplit.nextStart]
     * onward while the completed prefix is decoded in the background.
     */
    fun nextStreamingSplit(samples: FloatArray): SherpaStreamingSplit? {
        val targetSamples = TARGET_CHUNK_SECONDS * SAMPLE_RATE
        if (samples.size < STREAMING_WINDOW_SECONDS * SAMPLE_RATE) return null

        val overlapSamples = OVERLAP_MILLIS * SAMPLE_RATE / 1_000
        val silence = findSilenceBoundary(
            samples = samples,
            start = 0,
            idealEnd = targetSamples,
            minEnd = MIN_CHUNK_SECONDS * SAMPLE_RATE,
            maxEnd = STREAMING_WINDOW_SECONDS * SAMPLE_RATE,
        )
        val end = silence ?: targetSamples
        return SherpaStreamingSplit(
            endExclusive = end,
            nextStart = if (silence == null) end - overlapSamples else end,
        )
    }

    private fun findSilenceBoundary(
        samples: FloatArray,
        start: Int,
        idealEnd: Int,
        minEnd: Int,
        maxEnd: Int,
    ): Int? {
        val frameSamples = SILENCE_FRAME_MILLIS * SAMPLE_RATE / 1_000
        val searchSamples = SILENCE_SEARCH_MILLIS * SAMPLE_RATE / 1_000
        val firstFrame = ((idealEnd - searchSamples).coerceAtLeast(minEnd) / frameSamples) * frameSamples
        val lastFrame = (
            (idealEnd + searchSamples)
                .coerceAtMost(maxEnd)
                .coerceAtMost(samples.size - frameSamples) / frameSamples
            ) * frameSamples
        if (firstFrame > lastFrame) return null

        var peakRms = 0.0
        var lowestRms = Double.MAX_VALUE
        var quietStart = -1
        var frame = firstFrame
        while (frame <= lastFrame) {
            val rms = rms(samples, frame, (frame + frameSamples).coerceAtMost(samples.size))
            peakRms = peakRms.coerceAtLeast(rms)
            if (rms < lowestRms) {
                lowestRms = rms
                quietStart = frame
            }
            frame += frameSamples
        }

        val threshold = maxOf(MIN_SILENCE_RMS, peakRms * SILENCE_RMS_RATIO)
        return quietStart.takeIf { it >= 0 && lowestRms <= threshold }
            ?.plus(frameSamples / 2)
            ?.coerceIn(minEnd, maxEnd)
    }

    /** The loudest 100 ms frame in [samples], as RMS. */
    fun loudestFrame(samples: FloatArray): Double {
        val frameSamples = SILENCE_FRAME_MILLIS * SAMPLE_RATE / 1_000
        var loudest = 0.0
        var start = 0
        while (start < samples.size) {
            loudest = maxOf(
                loudest,
                rms(samples, start, (start + frameSamples).coerceAtMost(samples.size)),
            )
            start += frameSamples
        }
        return loudest
    }

    /**
     * Whether there is nothing here worth handing to a model.
     *
     * The floor is deliberately below the boundary-search silence threshold: it
     * skips only near-digital-silence and keeps quiet speech. Erring this way
     * costs a decode of a pause; erring the other way drops speech, which is
     * the whole failure this file exists to avoid.
     */
    fun isEffectivelySilent(samples: FloatArray): Boolean =
        samples.isEmpty() || isEffectivelySilent(loudestFrame(samples))

    fun isEffectivelySilent(loudestFrame: Double): Boolean = loudestFrame < SILENT_CHUNK_RMS

    /**
     * Whether a chunk carries speech rather than the room between sentences.
     *
     * [loudestFrameSoFar] is the loudest frame heard earlier in the same
     * recording. No absolute floor separates a quiet room from quiet speech --
     * one room's noise sits above another room's whisper -- but the distance
     * between a pause and the speech around it holds across recordings, which
     * is why the boundary search scales its own threshold the same way.
     *
     * Only asked about a chunk that already decoded to nothing, and only to
     * decide whether that is worth re-reading the whole file over. Room tone
     * answering with no tokens is not a loss; it is the correct answer.
     */
    fun carriesSpeech(loudestFrame: Double, loudestFrameSoFar: Double): Boolean =
        loudestFrame >= maxOf(SILENT_CHUNK_RMS, loudestFrameSoFar * SILENCE_RMS_RATIO)

    private fun rms(samples: FloatArray, start: Int, endExclusive: Int): Double {
        if (endExclusive <= start) return 0.0
        var sum = 0.0
        for (index in start until endExclusive) {
            val sample = samples[index].toDouble()
            sum += sample * sample
        }
        return sqrt(sum / (endExclusive - start))
    }
}

/** Joins text from overlapped chunks without writing the repeated boundary words. */
internal object SherpaTranscriptMerger {
    private const val MAX_OVERLAP_WORDS = 12

    fun append(existing: String, next: String, deduplicateOverlap: Boolean = true): String {
        val left = existing.trim()
        val right = next.trim()
        if (left.isEmpty()) return right
        if (right.isEmpty()) return left
        if (!deduplicateOverlap) return join(left, right)

        val leftWords = left.split(Regex("\\s+"))
        val rightWords = right.split(Regex("\\s+"))
        val maxOverlap = minOf(MAX_OVERLAP_WORDS, leftWords.size, rightWords.size)
        val overlap = (maxOverlap downTo 1).firstOrNull { count ->
            leftWords.takeLast(count).zip(rightWords.take(count)).all { (a, b) ->
                wordKey(a).isNotEmpty() && wordKey(a) == wordKey(b)
            }
        } ?: 0
        // Keep the second chunk's spelling and punctuation for the overlap.
        // E.g. `Hello` + `Hello, there` should retain the comma.
        val prefix = leftWords.dropLast(overlap).joinToString(" ")
        val suffix = rightWords.joinToString(" ")
        if (prefix.isEmpty()) return suffix
        return join(prefix, suffix)
    }

    private fun wordKey(word: String): String = word
        .lowercase(Locale.ROOT)
        .filter(Char::isLetterOrDigit)

    private fun join(left: String, right: String): String =
        if (right.firstOrNull()?.let(::isClosingPunctuation) == true) left + right else "$left $right"

    private fun isClosingPunctuation(character: Char): Boolean =
        character in ".,!?;:%)]}"
}
