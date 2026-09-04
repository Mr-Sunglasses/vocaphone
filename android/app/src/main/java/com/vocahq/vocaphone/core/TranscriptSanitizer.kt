package com.vocahq.vocaphone.core

/**
 * Speech models annotate non-speech with bracketed markers — `whisper.cpp`
 * emits `[BLANK_AUDIO]` for silence, others emit `[MUSIC]` or `(inaudible)`.
 * They are diagnostics, not something the user dictated, so they never belong
 * in a text field. A transcript that is nothing but markers is treated as
 * nothing having been transcribed at all.
 */
object TranscriptSanitizer {

    /**
     * Deliberately a fixed list rather than "anything in brackets": a user can
     * legitimately dictate "[1,200]" or "(see below)", and swallowing that would
     * be worse than leaving a marker in.
     */
    private val MARKER_WORDS = setOf(
        "blank_audio", "blankaudio", "blank audio",
        "silence", "silent", "no speech", "no_speech", "nospeech",
        "music", "musique", "sound", "sounds",
        "noise", "background noise", "static",
        "inaudible", "unintelligible", "indistinct",
        "laughter", "laughs", "laughing", "applause", "coughing", "sighs",
        "pause", "beep", "clears throat",
    )

    private val BRACKETED = Regex("""[\[(<]\s*([^\[\]()<>]{1,32}?)\s*[\])>]""")

    fun clean(transcript: String?): String {
        if (transcript.isNullOrBlank()) return ""

        val withoutMarkers = BRACKETED.replace(transcript) { match ->
            val inner = match.groupValues[1].trim().lowercase().trim('*', '.', '!', '-', '_')
            if (inner.replace('_', ' ') in MARKER_WORDS || inner in MARKER_WORDS) "" else match.value
        }
        // Collapse the spacing the removal leaves behind, without touching the
        // line breaks the writing style may have produced.
        return withoutMarkers
            .split('\n')
            .joinToString("\n") { line ->
                collapseRepetition(line.replace(Regex("""[ \t]{2,}"""), " ").trim())
            }
            .trim()
            .trim('\n')
    }

    /** Longest run treated as a loop. Beyond this it is prose, not a stutter. */
    private const val MAX_PHRASE_WORDS = 8

    /**
     * Collapses the repetition loop an attention model falls into when it runs
     * out of audio it can make sense of — a phrase emitted over and over until
     * the window ends. It is the single most recognizable way a transcript goes
     * wrong, and unlike a bracketed marker there is no token to look for.
     *
     * The thresholds differ by length on purpose. A repeated phrase of two or
     * more words is almost never something a person said three times running,
     * so one copy is kept. A single word genuinely is — "no no no no" is a
     * sentence — so it takes more repeats to look like a loop, and two copies
     * survive to record that the emphasis was there.
     *
     * [SpokenEmoji] is the one exception to that first claim, and it has to be
     * made here rather than in the stage that reads it: by the time the
     * substitution runs this has already thrown the copies away.
     */
    private fun collapseRepetition(line: String): String {
        if (line.isEmpty()) return line
        val words = line.split(' ').filter { it.isNotEmpty() }
        if (words.size < 4) return line

        val result = mutableListOf<String>()
        var index = 0
        while (index < words.size) {
            var phrase = 0
            var repeats = 0
            // Ascending, keeping the last match, so the longest repeating unit
            // wins: "thank you thank you thank you" is one phrase three times
            // over, not six unrelated words.
            for (length in 1..minOf(MAX_PHRASE_WORDS, (words.size - index) / 2)) {
                val count = countRepeats(words, index, length)
                if (count >= if (length == 1) 4 else 3) {
                    phrase = length
                    repeats = count
                }
            }
            // "crying emoji crying emoji crying emoji" is three emoji, not a
            // model stuck in a loop. Nobody says "emoji" three times running by
            // accident — it is the one word this app treats as a command, so a
            // unit ending on it was chosen deliberately and all the copies are
            // meant. Exempted whether or not the setting is on: the user still
            // said it three times, and a model looping on this exact phrase is
            // not a failure anyone has seen.
            if (phrase >= 2 && wordKey(words[index + phrase - 1]) in SpokenEmoji.TRIGGER_WORDS) {
                // Skip the whole run, not one word. Resuming inside it would
                // find the same repetition rotated by a word — "fire emoji"
                // four times over reads as "emoji fire" three times from index
                // one, and that unit does not end on the trigger.
                for (offset in 0 until phrase * repeats) result += words[index + offset]
                index += phrase * repeats
                continue
            }
            if (phrase == 0) {
                result += words[index]
                index++
                continue
            }
            // Taken from the source rather than the first copy repeated, so the
            // survivors keep the punctuation they arrived with.
            val kept = if (phrase == 1) 2 else 1
            for (offset in 0 until phrase * kept) result += words[index + offset]
            index += phrase * repeats
        }
        return result.joinToString(" ")
    }

    /** How many times the [length]-word unit at [start] repeats back to back. */
    private fun countRepeats(words: List<String>, start: Int, length: Int): Int {
        var repeats = 1
        var next = start + length
        while (next + length <= words.size) {
            for (offset in 0 until length) {
                if (wordKey(words[start + offset]) != wordKey(words[next + offset])) return repeats
            }
            repeats++
            next += length
        }
        return repeats
    }

    /**
     * Case and punctuation are exactly what differ between the copies in a loop
     * — "Thank you." then "thank you," — so neither can take part in matching.
     */
    private fun wordKey(word: String): String = word.lowercase().filter(Char::isLetterOrDigit)
}
