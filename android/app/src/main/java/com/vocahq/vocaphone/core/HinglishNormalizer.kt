package com.vocahq.vocaphone.core

import java.util.Locale

/**
 * The last pass on a Roman Hinglish transcript, and the only thing standing
 * between a good decode and Devanagari in a text field.
 *
 * The Hinglish model writes Latin nearly all of the time. Nearly is the problem:
 * on an unfamiliar proper noun, or a stretch of clean Hindi with no English in
 * it, it can fall back to the script it was fine-tuned away from. Deleting that
 * would silently lose words the user said, so it is transliterated instead —
 * [DevanagariRomanizer] turns "में" into text rather than into nothing.
 *
 * Everything else here is deliberately small. This is not a corrector: it does
 * not repair grammar, does not second-guess word choice, and never rewrites a
 * word that is spelled like English. Over-correction on a dictation transcript
 * is worse than an inconsistent spelling, because the user cannot tell it
 * happened.
 *
 * Runs entirely on the device. No model, no network, no lookup service — the
 * whole layer is the tables below. The spelling convention they encode is
 * written down in `docs/hinglish-roman.md`.
 */
object HinglishNormalizer {

    /**
     * Which passes to run.
     *
     * Configurable because the two spelling passes are conventions rather than
     * facts. Someone who writes "kyon" is not wrong, and a build that wanted to
     * leave their spelling alone should be able to say so without also giving up
     * transliteration, which is not a preference at all.
     */
    data class Options(
        /** Rewrite Devanagari as Latin rather than leaving or dropping it. */
        val transliterateDevanagari: Boolean = true,
        /** Settle transliterator output on one spelling per word. */
        val applyRomanizedConventions: Boolean = true,
        /** Settle the handful of Hindi spellings that are never English words. */
        val applyGlobalConventions: Boolean = true,
        /** Collapse whitespace and turn a danda into a full stop. */
        val normalizePunctuation: Boolean = true,
    ) {
        companion object {
            val DEFAULT = Options()
        }
    }

    fun containsDevanagari(text: String): Boolean = DevanagariRomanizer.containsDevanagari(text)

    fun normalize(text: String, options: Options = Options.DEFAULT): String {
        if (text.isBlank()) return ""
        val masked = mask(text)
        var result = masked.text
        if (options.transliterateDevanagari) {
            result = transliterateWithConventions(result, options.applyRomanizedConventions)
        }
        if (options.applyGlobalConventions) {
            result = applyGlobalConventions(result)
        }
        if (options.normalizePunctuation) {
            result = normalizePunctuation(result)
        }
        return restore(result, masked.tokens).trim()
    }

    // ---------------------------------------------------------------- masking

    /**
     * Spans that must survive every pass below untouched.
     *
     * A URL, an email address, a file path, a shell command, an @handle: none of
     * them are language, and all of them break if a spelling rule reaches
     * inside. Replaced with a placeholder no rule can match, then put back
     * verbatim at the end — the same device [TranscriptStyler] uses, for the
     * same reason.
     *
     * Devanagari inside such a span stays Devanagari on purpose. A URL is not
     * prose, and a transliterated host name is a broken link rather than a
     * readable one.
     */
    private data class Masked(val text: String, val tokens: List<String>)

    /**
     * Case sensitivity is load-bearing here, which is why there is no
     * `IGNORE_CASE` on the whole pattern: the last alternative is what makes
     * `API` and `HTTP` survive, and case-folding it would match every ordinary
     * two-to-eight-letter word in the transcript and mask the entire sentence.
     */
    private val PROTECTED = Regex(
        listOf(
            // A URL or a bare host.
            """(?i:\b(?:[a-z][a-z0-9+.-]*://|www\.)\S+)""",
            // An email address.
            """(?i:\b[\w.+-]+@[\w-]+\.[\w.-]+\b)""",
            // A path or a command: anything with an internal slash.
            """\S*[/\\]\S*""",
            // A filename or a dotted identifier.
            """(?i:\b\w+\.[a-z0-9]{1,8}\b)""",
            // A handle or a hashtag.
            """[@#][\w.-]+""",
            // An abbreviation the model wrote in capitals: API, GPU, HTTP.
            """\b[A-Z][A-Z0-9]{1,7}\b""",
        ).joinToString("|"),
    )

    private const val PLACEHOLDER_OPEN = '\u0001'
    private const val PLACEHOLDER_CLOSE = '\u0002'

    private val PLACEHOLDER = Regex("$PLACEHOLDER_OPEN(\\d+)$PLACEHOLDER_CLOSE")

    private fun mask(text: String): Masked {
        val tokens = mutableListOf<String>()
        val masked = PROTECTED.replace(text) { match ->
            tokens += match.value
            "$PLACEHOLDER_OPEN${tokens.size - 1}$PLACEHOLDER_CLOSE"
        }
        return Masked(masked, tokens)
    }

    private fun restore(text: String, tokens: List<String>): String =
        PLACEHOLDER.replace(text) { match ->
            Regex.escapeReplacement(tokens[match.groupValues[1].toInt()])
        }

    // -------------------------------------------------------- transliteration

    /**
     * Transliterates each Devanagari run and settles its spelling immediately.
     *
     * Doing it here rather than over the finished string is what makes
     * [ROMANIZED_CONVENTIONS] safe. "men" out of the transliterator is में;
     * "men" that arrived already in Latin is the English word, and rewriting
     * that to "mein" is exactly the over-correction this layer must not do.
     * Provenance is only knowable at this moment, so the rule is applied at this
     * moment.
     */
    private fun transliterateWithConventions(text: String, applyConventions: Boolean): String {
        if (!DevanagariRomanizer.containsDevanagari(text)) return text
        val romanized = DevanagariRomanizer.romanize(text)
        if (!applyConventions) return romanized
        // A word that was already in the source cannot have come out of the
        // transliterator, so it is left alone whatever the table says.
        val original = WORD.findAll(text).map { it.value }.toSet()
        return WORD.replace(romanized) { match ->
            val word = match.value
            if (word in original) {
                word
            } else {
                ROMANIZED_CONVENTIONS[word.lowercase(Locale.ROOT)]
                    ?.let { matchCase(word, it) }
                    ?: word
            }
        }
    }

    private val WORD = Regex("""\p{L}+""")

    /**
     * One spelling per word for transliterator output, where the mechanical
     * answer is not the one people type.
     *
     * Short by design. The romanizer's own rules already produce "mujhe",
     * "nahin", "hai" and "theek"; these are the leftovers where a Devanagari
     * spelling maps to a Roman one convention has moved away from. में is the
     * clearest: it is म + े + ं, mechanically "men", and every Hinglish speaker
     * writes "mein".
     */
    private val ROMANIZED_CONVENTIONS = mapOf(
        "men" to "mein",
        "kyon" to "kyun",
        "kyonki" to "kyunki",
        "hon" to "hoon",
        "hun" to "hoon",
        "jaen" to "jayen",
    )

    // ----------------------------------------------------- global conventions

    /**
     * Spellings settled across the whole transcript, including text the model
     * already wrote in Latin.
     *
     * Every key here has to be a form that is *not* an English word, because by
     * this point provenance is gone and a collision would rewrite English. That
     * rules out the tempting ones — "to", "the", "is", "men" — and leaves a
     * short list where the rewrite is unambiguous.
     */
    private val GLOBAL_CONVENTIONS = mapOf(
        "muje" to "mujhe",
        "mujey" to "mujhe",
        "mujhy" to "mujhe",
        "kyu" to "kyun",
        "kyoon" to "kyun",
        "kyuki" to "kyunki",
        "kyunke" to "kyunki",
        "nahi" to "nahin",
        "nhi" to "nahin",
        "thik" to "theek",
        "thk" to "theek",
        "acha" to "accha",
        "achha" to "accha",
        "bahot" to "bahut",
        "bhot" to "bahut",
        "kese" to "kaise",
        "krna" to "karna",
        "krke" to "karke",
        "smjh" to "samajh",
    )

    private fun applyGlobalConventions(text: String): String {
        val settled = WORD.replace(text) { match ->
            GLOBAL_CONVENTIONS[match.value.lowercase(Locale.ROOT)]
                ?.let { matchCase(match.value, it) }
                ?: match.value
        }
        return HEY.replace(settled, "hai")
    }

    /**
     * "theek hey" is "theek hai"; "Hey, ..." is English and stays.
     *
     * The one rule that needs a guard rather than a table, because "hey" is a
     * real English word. It is only rewritten mid-sentence and lowercase:
     * English "hey" is an opener, and an opener is capitalized or followed by a
     * comma. Wrong in the safe direction leaves a spelling slightly off; wrong
     * in the other direction rewrites what someone said.
     */
    private val HEY = Regex("""(?<=\S )hey\b(?![,!])""")

    /** Keeps a rewritten word in the case it arrived in. */
    private fun matchCase(original: String, replacement: String): String = when {
        original.length > 1 && original.all { it.isUpperCase() } ->
            replacement.uppercase(Locale.ROOT)
        original.first().isUpperCase() ->
            replacement.replaceFirstChar { it.uppercase(Locale.ROOT) }
        else -> replacement
    }

    // ------------------------------------------------------------ punctuation

    /**
     * Whitespace and the two marks the script change leaves behind.
     *
     * The danda is a Devanagari full stop with no business in a Latin sentence;
     * [DevanagariRomanizer] already converts the ones attached to a word, and
     * this catches a free-standing one. Capitalization and sentence terminators
     * are deliberately absent — [TranscriptStyler] runs after this and owns them
     * for every language.
     */
    private fun normalizePunctuation(text: String): String = text
        .replace('।', '.')
        .replace('॥', '.')
        .replace(Regex("""[ \t]{2,}"""), " ")
        .replace(Regex(""" +([,.!?;:])"""), "$1")
        .replace(Regex("""([,.!?;:])(?=[^\s\d,.!?;:])"""), "$1 ")
        .split('\n')
        .joinToString("\n") { it.trim() }
}
