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
            .joinToString("\n") { line -> line.replace(Regex("""[ \t]{2,}"""), " ").trim() }
            .trim()
            .trim('\n')
    }
}
