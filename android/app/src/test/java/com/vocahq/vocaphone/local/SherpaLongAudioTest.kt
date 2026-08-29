package com.vocahq.vocaphone.local

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SherpaLongAudioTest {
    @Test
    fun `short audio keeps one no-copy decode range`() {
        val chunks = SherpaLongAudio.chunks(FloatArray(12 * SherpaLongAudio.SAMPLE_RATE))

        assertEquals(listOf(SherpaAudioChunk(0, 192_000, false)), chunks)
    }

    @Test
    fun `continuous long audio is bounded and overlaps every boundary`() {
        val samples = FloatArray(52 * SherpaLongAudio.SAMPLE_RATE) { 0.2f }

        val chunks = SherpaLongAudio.chunks(samples)

        assertTrue(chunks.size >= 3)
        assertTrue(chunks.all { it.endExclusive - it.start <= 14 * SherpaLongAudio.SAMPLE_RATE })
        assertTrue(chunks.drop(1).all { it.overlapsPrevious })
        assertTrue(chunks.zipWithNext().all { (left, right) -> right.start < left.endExclusive })
        assertEquals(samples.size, chunks.last().endExclusive)
    }

    @Test
    fun `streaming split releases a bounded prefix with overlap`() {
        val split = SherpaLongAudio.nextStreamingSplit(
            FloatArray(SherpaLongAudio.STREAMING_WINDOW_SECONDS * SherpaLongAudio.SAMPLE_RATE) { 0.2f },
        )

        assertEquals(10 * SherpaLongAudio.SAMPLE_RATE, split?.endExclusive)
        assertEquals(
            9 * SherpaLongAudio.SAMPLE_RATE + 500 * SherpaLongAudio.SAMPLE_RATE / 1_000,
            split?.nextStart,
        )
    }

    @Test
    fun `the physical-device eighteen second regression is never one decode`() {
        val samples = FloatArray(18 * SherpaLongAudio.SAMPLE_RATE) { 0.2f }

        val chunks = SherpaLongAudio.chunks(samples)

        assertTrue(chunks.size >= 2)
        assertTrue(chunks.all { it.endExclusive - it.start <= 12 * SherpaLongAudio.SAMPLE_RATE })
        assertEquals(samples.size, chunks.last().endExclusive)
    }

    @Test
    fun `a quiet boundary is preferred without surrendering overlap`() {
        val samples = FloatArray(52 * SherpaLongAudio.SAMPLE_RATE) { 0.2f }
        val silenceStart = 9 * SherpaLongAudio.SAMPLE_RATE
        val silenceEnd = silenceStart + SherpaLongAudio.SAMPLE_RATE
        java.util.Arrays.fill(samples, silenceStart, silenceEnd, 0f)

        val chunks = SherpaLongAudio.chunks(samples)
        val first = chunks.first()
        val second = chunks[1]

        assertFalse(first.overlapsPrevious)
        assertTrue(first.endExclusive in silenceStart..silenceEnd)
        assertTrue(second.overlapsPrevious)
        // A found quiet run still hands context to the next chunk, just less of
        // it than a guessed boundary needs.
        assertEquals(
            first.endExclusive -
                SherpaLongAudio.SILENCE_OVERLAP_MILLIS * SherpaLongAudio.SAMPLE_RATE / 1_000,
            second.start,
        )
    }

    @Test
    fun `a guessed boundary keeps the wider overlap`() {
        val samples = FloatArray(52 * SherpaLongAudio.SAMPLE_RATE) { 0.2f }

        val chunks = SherpaLongAudio.chunks(samples)

        assertEquals(
            chunks.first().endExclusive -
                SherpaLongAudio.OVERLAP_MILLIS * SherpaLongAudio.SAMPLE_RATE / 1_000,
            chunks[1].start,
        )
    }

    @Test
    fun `one quiet frame inside speech is not trusted as a boundary`() {
        val samples = FloatArray(30 * SherpaLongAudio.SAMPLE_RATE) { 0.2f }
        java.util.Arrays.fill(
            samples,
            10 * SherpaLongAudio.SAMPLE_RATE,
            10 * SherpaLongAudio.SAMPLE_RATE + SherpaLongAudio.SAMPLE_RATE / 10,
            0f,
        )

        val first = SherpaLongAudio.chunks(samples).first()

        assertEquals(10 * SherpaLongAudio.SAMPLE_RATE, first.endExclusive)
    }

    @Test
    fun `an empty long chunk retries as overlapping short decodes`() {
        val decodedSizes = mutableListOf<Int>()
        var shortResult = 0
        val transcript = SherpaEmptyChunkRecovery.decode(
            samples = FloatArray(10 * SherpaLongAudio.SAMPLE_RATE) { 0.2f },
            decodeOnce = { samples ->
                decodedSizes += samples.size
                SherpaTranscript(
                    if (samples.size > 6 * SherpaLongAudio.SAMPLE_RATE) {
                        ""
                    } else if (shortResult++ == 0) {
                        "first half"
                    } else {
                        "second half"
                    },
                )
            },
        )

        assertEquals("first half second half", transcript.text)
        assertEquals(listOf(160_000, 84_000, 84_000), decodedSizes)
    }

    @Test
    fun `an empty short chunk is not worth a retry`() {
        val decodedSizes = mutableListOf<Int>()
        SherpaEmptyChunkRecovery.decode(
            samples = FloatArray(5 * SherpaLongAudio.SAMPLE_RATE) { 0.2f },
            decodeOnce = { samples ->
                decodedSizes += samples.size
                SherpaTranscript.EMPTY
            },
        )

        // Below the suspect bar an empty answer is ordinary -- a fragment of a
        // word, or the retained overlap a recording ending just after a
        // boundary leaves -- and length is not what dropped it.
        assertEquals(listOf(80_000), decodedSizes)
    }

    @Test
    fun `an audible complete short recording gets a bounded fresh-stream retry`() {
        val decodedSizes = mutableListOf<Int>()
        var attempts = 0
        val transcript = SherpaEmptyChunkRecovery.decode(
            samples = FloatArray(5 * SherpaLongAudio.SAMPLE_RATE) { 0.2f },
            recoverAudibleShortInput = true,
            decodeOnce = { samples ->
                decodedSizes += samples.size
                SherpaTranscript(if (attempts++ == 1) "recovered" else "")
            },
        )

        assertEquals("recovered", transcript.text)
        assertEquals(listOf(80_000, 80_000), decodedSizes)
    }

    @Test
    fun `a silent chunk is never decoded at all`() {
        val decodedSizes = mutableListOf<Int>()
        SherpaEmptyChunkRecovery.decode(
            samples = FloatArray(10 * SherpaLongAudio.SAMPLE_RATE),
            recoverAudibleShortInput = true,
            decodeOnce = { samples ->
                decodedSizes += samples.size
                SherpaTranscript.EMPTY
            },
        )

        // Room tone answering with nothing is the correct answer, and the scan
        // that says so is cheaper than the decode that would agree with it.
        assertTrue(decodedSizes.isEmpty())
    }

    @Test
    fun `a short recording still empty on a fresh stream is padded then split`() {
        val decodedSizes = mutableListOf<Int>()
        SherpaEmptyChunkRecovery.decode(
            samples = FloatArray(3 * SherpaLongAudio.SAMPLE_RATE) { 0.2f },
            recoverAudibleShortInput = true,
            decodeOnce = { samples ->
                decodedSizes += samples.size
                SherpaTranscript.EMPTY
            },
        )

        // Whole, whole again, padded half a second either side, then the two
        // halves. The ladder is fixed-length: it never subdivides again.
        assertEquals(listOf(48_000, 48_000, 64_000, 28_000, 28_000), decodedSizes)
    }

    /**
     * The extra rungs are for short speech. A long first chunk with nothing
     * decoded ahead of it is still a long window: repeating it and padding it
     * costs two whole further decodes and recovers what the split already does.
     */
    @Test
    fun `a long window keeps the split ladder even with nothing decoded before it`() {
        val decodedSizes = mutableListOf<Int>()
        SherpaEmptyChunkRecovery.decode(
            samples = FloatArray(10 * SherpaLongAudio.SAMPLE_RATE) { 0.2f },
            recoverAudibleShortInput = true,
            decodeOnce = { samples ->
                decodedSizes += samples.size
                SherpaTranscript.EMPTY
            },
        )

        assertEquals(listOf(160_000, 84_000, 84_000), decodedSizes)
    }

    @Test
    fun `the recovery split never decodes the whole waveform twice`() {
        val decodedSizes = mutableListOf<Int>()
        SherpaEmptyChunkRecovery.decode(
            samples = FloatArray(SherpaLongAudio.SAMPLE_RATE / 4) { 0.2f },
            recoverAudibleShortInput = true,
            decodeOnce = { samples ->
                decodedSizes += samples.size
                SherpaTranscript.EMPTY
            },
        )

        assertTrue(decodedSizes.takeLast(2).all { it < SherpaLongAudio.SAMPLE_RATE / 4 })
    }

    /**
     * Translated windows are joined verbatim: the same audio does not come back
     * as the same words, so nothing can pair the repeat the split creates.
     */
    @Test
    fun `a translated recovery split is never text deduplicated`() {
        val transcript = SherpaEmptyChunkRecovery.decode(
            samples = FloatArray(10 * SherpaLongAudio.SAMPLE_RATE) { 0.2f },
            deduplicateOverlap = false,
            decodeOnce = { samples ->
                if (samples.size > 6 * SherpaLongAudio.SAMPLE_RATE) {
                    SherpaTranscript.EMPTY
                } else {
                    SherpaTranscript("to the shop")
                }
            },
        )

        assertEquals("to the shop to the shop", transcript.text)
    }

    @Test
    fun `a half that is still empty is not subdivided again`() {
        val decodedSizes = mutableListOf<Int>()
        SherpaEmptyChunkRecovery.decode(
            samples = FloatArray(14 * SherpaLongAudio.SAMPLE_RATE) { 0.2f },
            decodeOnce = { samples ->
                decodedSizes += samples.size
                SherpaTranscript.EMPTY
            },
        )

        assertEquals(listOf(224_000, 116_000, 116_000), decodedSizes)
    }

    /**
     * The tail that stays ignorable, and the one that never was. A window can be
     * well under the suspect length and still be the last seconds of the
     * recording; asking whether the *chunk* was long enough let a closing
     * sentence vanish behind a successful opening one.
     */
    @Test
    fun `only new audio past the retained overlap is worth recovering`() {
        val overlapSamples = SherpaLongAudio.OVERLAP_MILLIS * SherpaLongAudio.SAMPLE_RATE / 1_000
        val overlapOnly = FloatArray(overlapSamples) { 0.4f }
        val newSpeech = FloatArray(2 * SherpaLongAudio.SAMPLE_RATE) { 0.4f }
        val roomTone = FloatArray(2 * SherpaLongAudio.SAMPLE_RATE) { 0.01f }

        assertFalse(
            SherpaLongAudio.carriesRecoverableSpeech(
                overlapOnly, true, SherpaLongAudio.loudestFrame(overlapOnly), 0.4,
            ),
        )
        assertTrue(
            SherpaLongAudio.carriesRecoverableSpeech(
                newSpeech, true, SherpaLongAudio.loudestFrame(newSpeech), 0.4,
            ),
        )
        // Past the overlap but not speech next to what has already been heard.
        assertFalse(
            SherpaLongAudio.carriesRecoverableSpeech(
                roomTone, true, SherpaLongAudio.loudestFrame(roomTone), 0.4,
            ),
        )
    }

    /**
     * The length bar is for telling new audio apart from retained overlap, so it
     * cannot apply where nothing was retained. A one-word dictation is short
     * because that is all there was to say, and it was never decoded before.
     */
    @Test
    fun `a sole window shorter than the overlap is still recoverable`() {
        val oneWord = FloatArray(SherpaLongAudio.SAMPLE_RATE / 4) { 0.4f }

        assertTrue(
            SherpaLongAudio.carriesRecoverableSpeech(
                oneWord, false, SherpaLongAudio.loudestFrame(oneWord), 0.0,
            ),
        )
        // The same audio arriving as a tail behind a decoded window is not.
        assertFalse(
            SherpaLongAudio.carriesRecoverableSpeech(
                oneWord, true, SherpaLongAudio.loudestFrame(oneWord), 0.4,
            ),
        )
    }

    @Test
    fun `a new region is what the window did not inherit from the one before it`() {
        val samples = FloatArray(20 * SherpaLongAudio.SAMPLE_RATE) { 0.2f }
        val chunk = SherpaAudioChunk(
            start = 9 * SherpaLongAudio.SAMPLE_RATE,
            endExclusive = 20 * SherpaLongAudio.SAMPLE_RATE,
            overlapsPrevious = true,
        )

        val newRegion = SherpaLongAudio.newRegion(
            samples, chunk, previousEnd = 10 * SherpaLongAudio.SAMPLE_RATE,
        )

        // The second onward, not the eleven seconds the window covers.
        assertEquals(10 * SherpaLongAudio.SAMPLE_RATE, newRegion.size)
    }

    /**
     * Scripts written without spaces. Every transcript is one "word" on each
     * side of the seam, so the word matcher never fires: the overlap is written
     * twice with a space wedged into a script that does not use spaces. iOS has
     * had a bounded character path; this is Android's.
     */
    @Test
    fun `an unspaced script has its overlap removed without a separator`() {
        assertEquals(
            "你好世界再见",
            SherpaTranscriptMerger.append("你好世界", "世界再见"),
        )
        assertEquals(
            "こんにちは世界",
            SherpaTranscriptMerger.append("こんにちは", "にちは世界"),
        )
    }

    @Test
    fun `an unspaced repeat wider than the audio overlap is preserved`() {
        // Seven characters is more than half a second of speech can hold, so it
        // is repetition the speaker produced rather than duplicated audio.
        assertEquals(
            "一二三四五六七一二三四五六七",
            SherpaTranscriptMerger.append("一二三四五六七", "一二三四五六七"),
        )
    }

    @Test
    fun `a translated unspaced seam is never deduplicated`() {
        assertEquals(
            "你好世界 世界再见",
            SherpaTranscriptMerger.append("你好世界", "世界再见", deduplicateOverlap = false),
        )
    }

    @Test
    fun `overlapped words are merged once`() {
        assertEquals(
            "hello world again",
            SherpaTranscriptMerger.append("hello world", "world again"),
        )
        assertEquals(
            "Hello, there.",
            SherpaTranscriptMerger.append("Hello", "Hello, there."),
        )
        assertEquals(
            "yes yes",
            SherpaTranscriptMerger.append("yes", "yes", deduplicateOverlap = false),
        )
    }

    @Test
    fun `a phrase wider than the audio overlap is preserved as repetition`() {
        assertEquals(
            "start one two three four five one two three four five end",
            SherpaTranscriptMerger.append(
                "start one two three four five",
                "one two three four five end",
            ),
        )
    }

    /**
     * Why translating turns deduplication off rather than trusting it to do
     * nothing. The merger cannot tell a repeat caused by overlapped audio from
     * one the speaker actually said, so on text it was never able to align it
     * deletes words that belong in the transcript.
     */
    @Test
    fun `deduplication removes a repetition that translating must keep`() {
        // Two windows of translated text that happen to meet on the same words.
        val left = "I went to the shop"
        val right = "to the shop and then home"

        assertEquals(
            "I went to the shop and then home",
            SherpaTranscriptMerger.append(left, right, deduplicateOverlap = true),
        )
        // A translator gives no way to know whether that was one phrase or two,
        // so the seam is kept verbatim instead of guessed at.
        assertEquals(
            "I went to the shop to the shop and then home",
            SherpaTranscriptMerger.append(left, right, deduplicateOverlap = false),
        )
    }

}
