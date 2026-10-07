package com.vocahq.vocaphone.local

import java.util.Locale
import kotlin.math.abs
import kotlin.math.sqrt

/** A half-open range of 16 kHz samples sent to one offline decode call. */
internal data class SherpaAudioChunk(
    val start: Int,
    val endExclusive: Int,
    val overlapsPrevious: Boolean,
)

/** A stable prefix that can be decoded while the microphone keeps recording. */
internal data class SherpaStreamingSplit(
    val endExclusive: Int,
    val nextStart: Int,
)

/**
 * Keeps sherpa offline models away from unbounded encoder/decoder sequences.
 *
 * Offline recognizers accept one complete waveform per stream. That is a good
 * fast path for a sentence, but attention-based models become disproportionately
 * expensive as the waveform grows. The boundary search prefers a sustained
 * 300 ms quiet run around the target so normal speech is not cut in half. Every
 * boundary retains context either way, because deleting it on a classification
 * was enough to lose a boundary word; how much depends on how well the boundary
 * is evidenced. The transcript merger removes the repeated words back out.
 */
internal object SherpaLongAudio {
    const val SAMPLE_RATE = 16_000
    const val LONG_AUDIO_THRESHOLD_SECONDS = 12
    const val TARGET_CHUNK_SECONDS = 10
    const val MAX_CHUNK_SECONDS = 14

    /**
     * Retained across a boundary the search had to guess at. A low-energy
     * phoneme can sit where the audio looks quiet, so a guessed cut keeps
     * enough of the previous window to decode a word it may have split.
     */
    const val OVERLAP_MILLIS = 500

    /**
     * Retained across a boundary a sustained quiet run was actually found at.
     * The cut lands in the middle of that run, so 150 ms of measured silence
     * already sits on each side of it and a word cannot be straddling it. This
     * still keeps that silence plus a margin, and every 300 ms saved here is
     * audio the model does not decode twice.
     */
    const val SILENCE_OVERLAP_MILLIS = 200

    const val STREAMING_WINDOW_SECONDS = TARGET_CHUNK_SECONDS + 2

    /**
     * How much has to be buffered before a pause is worth decoding at.
     *
     * Below it the prefix is a few words, and a decode that short buys little
     * latency while adding a seam and a gain decided on almost nothing.
     */
    const val PAUSE_SPLIT_MIN_SECONDS = 3

    /**
     * How long the quiet at the end of the buffer has to last to be a pause.
     *
     * Longer than any gap inside a word or between words -- a stop consonant
     * is tens of milliseconds, a breath between phrases a few hundred -- so
     * the cut never lands in the middle of one.
     */
    const val PAUSE_SPLIT_QUIET_MILLIS = 700

    /**
     * The bar above which a window answering with no tokens is suspicious.
     *
     * Below it an empty answer is ordinary rather than a loss: the half second
     * of retained overlap a recording ending just after a boundary leaves
     * behind, or a fragment of a word. Both callers need the same bar --
     * [SherpaEmptyChunkRecovery] before it spends two more decodes on a retry,
     * and the streaming session before it sends the caller to the whole-file
     * decode -- because both are asking the same question about the same
     * window.
     */
    const val MIN_SUSPECT_CHUNK_SECONDS = 6

    private const val SILENCE_FRAME_MILLIS = 100
    private const val SILENCE_RUN_FRAMES = 3
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
        val guessedOverlapSamples = OVERLAP_MILLIS * SAMPLE_RATE / 1_000
        val foundOverlapSamples = SILENCE_OVERLAP_MILLIS * SAMPLE_RATE / 1_000
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
            chunks += SherpaAudioChunk(start, end, overlapsPrevious)
            // Boundary classification is deliberately not trusted with audio
            // ownership: a quiet consonant can satisfy an RMS threshold, and
            // dropping the overlap on that guess loses the word. It is trusted
            // with how much to retain, which is only a question of cost.
            //
            // This holds while translating too, and it is worth saying why,
            // because the retained audio is what a translator cannot merge back
            // out. Almost all of it is the measured quiet run itself, which
            // translates to nothing and duplicates nothing. What is left is the
            // case the classification got wrong — and there the choice is
            // between a word said twice and a word not said at all.
            val retainedSamples =
                if (silence != null) foundOverlapSamples else guessedOverlapSamples
            start = (end - retainedSamples).coerceAtLeast(start + 1)
            overlapsPrevious = true
        }
        return chunks
    }

    /**
     * Returns one bounded prefix after enough future audio exists to inspect a
     * complete silence-search window. The caller retains [nextStart] onward.
     */
    fun nextStreamingSplit(samples: FloatArray): SherpaStreamingSplit? {
        val targetSamples = TARGET_CHUNK_SECONDS * SAMPLE_RATE
        if (samples.size < STREAMING_WINDOW_SECONDS * SAMPLE_RATE) return null

        val silence = findSilenceBoundary(
            samples = samples,
            start = 0,
            idealEnd = targetSamples,
            minEnd = MIN_CHUNK_SECONDS * SAMPLE_RATE,
            maxEnd = STREAMING_WINDOW_SECONDS * SAMPLE_RATE,
        )
        val end = silence ?: targetSamples
        // Retain context on the same terms as the authoritative finish-time
        // path, including at a boundary that looks quiet: a low-energy phoneme
        // can sit inside an RMS silence run. A found run needs less of it.
        val retainedSamples =
            (if (silence != null) SILENCE_OVERLAP_MILLIS else OVERLAP_MILLIS) * SAMPLE_RATE / 1_000
        return SherpaStreamingSplit(
            endExclusive = end,
            nextStart = (end - retainedSamples).coerceAtLeast(1),
        )
    }

    /**
     * The prefix to decode now because the speaker has paused, or null.
     *
     * [nextStreamingSplit] only lets go of audio once twelve seconds are
     * buffered, and almost every dictation is shorter than that, so the whole
     * of it used to be decoded after Finish. A pause is the other point at
     * which a prefix is stable: whatever comes next starts a new phrase. The
     * cut is made in the middle of the trailing quiet, so measured silence
     * sits on both sides of it, and the context retained after it -- the same
     * amount a found silence keeps at a twelve-second split -- lies wholly
     * inside that quiet.
     *
     * Quiet is judged against the loudest frame buffered, as the boundary
     * search judges it, and is also never louder than the level that search
     * always counts as silence. The ratio alone took someone carrying on
     * softly after a loud passage -- 0.02 after 0.2 -- for a pause, and cut
     * inside their words at a seam that is deliberately not de-duplicated.
     * A missed pause costs only latency, since the twelve-second split and
     * Finish still decode it; a pause found inside speech can cut or double a
     * word in a result that looks complete. So a room loud enough to sit over
     * that level gets no pause splits at all. A buffer with nothing above the
     * bar has nothing to decode.
     *
     * Levels are judged at [gain], the gain the decoded window will be
     * levelled with, as the streaming silence check judges them. A quiet
     * speaker -- a phone on the desk -- talks under that absolute level raw,
     * so judged raw their whole recording read as one long pause and was cut
     * every few seconds inside their words.
     *
     * Only the first [size] samples are read, so a caller can ask of a growing
     * buffer every frame without copying it.
     */
    fun nextPauseSplit(
        samples: FloatArray,
        size: Int = samples.size,
        gain: Float = 1f,
    ): SherpaStreamingSplit? {
        if (size < PAUSE_SPLIT_MIN_SECONDS * SAMPLE_RATE) return null
        val frameSamples = SILENCE_FRAME_MILLIS * SAMPLE_RATE / 1_000
        val frames = size / frameSamples
        val quietFramesNeeded = PAUSE_SPLIT_QUIET_MILLIS / SILENCE_FRAME_MILLIS
        if (frames <= quietFramesNeeded) return null

        val levels = DoubleArray(frames) { frame ->
            rms(samples, frame * frameSamples, (frame + 1) * frameSamples) * gain
        }
        val threshold = maxOf(
            SILENT_CHUNK_RMS,
            minOf(levels.max() * SILENCE_RMS_RATIO, MIN_SILENCE_RMS),
        )
        // Frames past the last whole one are too short to judge; they are
        // part of the retained audio either way.
        var quietFrames = 0
        while (quietFrames < frames && levels[frames - 1 - quietFrames] <= threshold) {
            quietFrames++
        }
        if (quietFrames < quietFramesNeeded || quietFrames == frames) return null

        val quietStart = (frames - quietFrames) * frameSamples
        val end = quietStart + quietFrames * frameSamples / 2
        val retained = SILENCE_OVERLAP_MILLIS * SAMPLE_RATE / 1_000
        return SherpaStreamingSplit(
            endExclusive = end,
            nextStart = (end - retained).coerceAtLeast(1),
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

        val levels = mutableListOf<Pair<Int, Double>>()
        var peakRms = 0.0
        var frame = firstFrame
        while (frame <= lastFrame) {
            val rms = rms(samples, frame, (frame + frameSamples).coerceAtMost(samples.size))
            peakRms = peakRms.coerceAtLeast(rms)
            levels += frame to rms
            frame += frameSamples
        }

        val threshold = maxOf(MIN_SILENCE_RMS, peakRms * SILENCE_RMS_RATIO)
        return levels.windowed(SILENCE_RUN_FRAMES)
            .asSequence()
            .filter { run -> run.all { (_, rms) -> rms <= threshold } }
            .map { run -> run.first().first + frameSamples * SILENCE_RUN_FRAMES / 2 }
            .minByOrNull { boundary -> abs(boundary - idealEnd) }
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

    /** Whether a silent decode is suspicious compared with earlier speech. */
    fun carriesSpeech(loudestFrame: Double, loudestFrameSoFar: Double): Boolean =
        loudestFrame >= maxOf(SILENT_CHUNK_RMS, loudestFrameSoFar * SILENCE_RMS_RATIO)

    /**
     * The part of [chunk] that is not inherited from the window before it.
     *
     * A chunk that overlaps its predecessor begins with audio that predecessor
     * already decoded. Everything a later window can *lose* is what comes after
     * that, so it is what the emptiness of its answer has to be judged on.
     */
    fun newRegion(samples: FloatArray, chunk: SherpaAudioChunk, previousEnd: Int): FloatArray {
        val start = maxOf(chunk.start, previousEnd).coerceAtMost(chunk.endExclusive)
        return samples.copyOfRange(start, chunk.endExclusive)
    }

    /**
     * Whether an empty answer for [newRegion] is a loss worth spending decodes
     * on, rather than the ordinary silence at the end of a recording.
     *
     * It must carry speech next to what the recording has already been heard to
     * contain, so a trailing pause is not amplified into a retry.
     *
     * [inheritsAudio] is what the length bar is for, and why it does not always
     * apply. A window that begins inside the one before it has to be told apart
     * from that retained overlap, and below the widest overlap the chunker ever
     * retains it cannot be -- a recording ending just after a boundary leaves
     * exactly such a tail, a fragment of a word at best. A window that inherited
     * nothing has no overlap to be confused with: it is the whole of what the
     * user has said, and a two-word dictation is short precisely because that is
     * all there was to say. Applying the bar there was what stopped "yes" from
     * ever being retried.
     */
    fun carriesRecoverableSpeech(
        newRegion: FloatArray,
        inheritsAudio: Boolean,
        loudestFrame: Double,
        loudestFrameSoFar: Double,
    ): Boolean {
        if (inheritsAudio && newRegion.size <= OVERLAP_MILLIS * SAMPLE_RATE / 1_000) return false
        return carriesSpeech(loudestFrame, loudestFrameSoFar)
    }

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
    // The audio overlap is half a second at most. A much wider text match can
    // only be a phrase the speaker genuinely repeated, not duplicated audio.
    private const val MAX_OVERLAP_WORDS = 4

    /**
     * The same bound for scripts written without spaces, where half a second of
     * speech is a few characters rather than a few words.
     *
     * Without this path a Chinese or Japanese transcript is one "word" on each
     * side of the seam, nothing ever matches, and the overlap is written twice
     * with a space wedged between it -- in a script that does not use spaces.
     * iOS has had this branch; matching it is what keeps the two transcripts of
     * one recording the same transcript.
     */
    private const val MAX_OVERLAP_CHARACTERS = 6

    fun append(existing: String, next: String, deduplicateOverlap: Boolean = true): String {
        val left = existing.trim()
        val right = next.trim()
        if (left.isEmpty()) return right
        if (right.isEmpty()) return left
        // Keeping a seam verbatim means not deleting anything at it, not adding
        // a space the script does not use.
        if (!deduplicateOverlap) return if (meetsUnspaced(left, right)) left + right else join(left, right)

        if (!left.any(Char::isWhitespace) && !right.any(Char::isWhitespace)) {
            return appendUnspaced(left, right)
        }

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

    /**
     * Joins two segments of a script that does not separate words with spaces.
     *
     * The longest suffix of [left] that opens [right] is the repeat, bounded the
     * same way the word path is bounded and joined without a separator.
     */
    private fun appendUnspaced(left: String, right: String): String {
        val maxOverlap = minOf(MAX_OVERLAP_CHARACTERS, left.length, right.length)
        val overlap = (maxOverlap downTo 1).firstOrNull { count ->
            left.regionMatches(left.length - count, right, 0, count)
        } ?: 0
        return left + right.substring(overlap)
    }

    /**
     * Whether the letters either side of the seam are both of a script written
     * without spaces between words. Asked of the letters rather than of the
     * whole text, so "Okay." and "Thanks." are still two words.
     */
    private fun meetsUnspaced(left: String, right: String): Boolean {
        val before = left.lastOrNull(::hasOwnScript) ?: return false
        val after = right.firstOrNull(::hasOwnScript) ?: return false
        return Character.UnicodeScript.of(before.code) in UNSPACED_SCRIPTS &&
            Character.UnicodeScript.of(after.code) in UNSPACED_SCRIPTS
    }

    /** A letter that says which script it is: not the shared Katakana-Hiragana long-vowel mark, say. */
    private fun hasOwnScript(character: Char): Boolean = character.isLetter() &&
        Character.UnicodeScript.of(character.code) != Character.UnicodeScript.COMMON &&
        Character.UnicodeScript.of(character.code) != Character.UnicodeScript.INHERITED

    private val UNSPACED_SCRIPTS = setOf(
        Character.UnicodeScript.HAN,
        Character.UnicodeScript.HIRAGANA,
        Character.UnicodeScript.KATAKANA,
        Character.UnicodeScript.THAI,
        Character.UnicodeScript.LAO,
        Character.UnicodeScript.KHMER,
        Character.UnicodeScript.MYANMAR,
    )

    private fun wordKey(word: String): String = word
        .lowercase(Locale.ROOT)
        .filter(Char::isLetterOrDigit)

    private fun join(left: String, right: String): String =
        if (right.firstOrNull()?.let(::isClosingPunctuation) == true) left + right else "$left $right"

    private fun isClosingPunctuation(character: Char): Boolean =
        character in ".,!?;:%)]}"
}
