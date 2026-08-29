package com.vocahq.vocaphone.core

import java.util.regex.Pattern

/**
 * Expands snippet triggers into their literal expansion text.
 *
 * Runs after [DictatedTranscript.finished], never before: the writing style
 * capitalizes sentence starts and would otherwise rewrite a snippet's literal
 * expansion (an email trigger must not come out "Me@example.com"). Matching
 * itself is case-insensitive, so capitalizing the source text first does not
 * break it.
 *
 * One combined regex over every trigger rather than a snippet-by-snippet
 * loop, so an expansion that happens to contain another trigger is never
 * re-expanded. Matches are applied in reverse order so an earlier match's
 * range stays valid while a later one is replaced.
 */
object SnippetExpander {

    fun expand(text: String, snippets: List<Snippet>): String {
        // A blank expansion is skipped rather than applied: settings will not
        // save one, and a stored one would quietly delete its trigger from
        // every transcript, which is never what an empty field meant.
        val active = snippets
            .map { it.copy(trigger = it.trigger.trim()) }
            .filter { it.trigger.isNotEmpty() && it.expansion.isNotBlank() }
            // Longer, more specific triggers win over a shorter one that could
            // be a substring of it ("my email" before "email").
            .sortedByDescending { it.trigger.length }
        if (active.isEmpty()) return text

        // A trigger that cannot be compiled must cost the user the expansion,
        // not the dictation: without this the throw propagates out of deliver()
        // and the transcript is never inserted at all.
        val pattern = runCatching {
            Pattern.compile(
                active.joinToString("|") { "(${boundaryPattern(it.trigger)})" },
                Pattern.CASE_INSENSITIVE or Pattern.UNICODE_CASE,
            )
        }.getOrNull() ?: return text
        val matcher = pattern.matcher(text)
        val matches = mutableListOf<Triple<Int, Int, Int>>()
        while (matcher.find()) {
            // Exactly one branch of the alternation can have matched, but skip
            // rather than throw if that ever stops holding: this runs inside
            // delivery, where an exception costs the whole transcript.
            val groupIndex = (1..active.size).firstOrNull { matcher.group(it) != null } ?: continue
            matches += Triple(matcher.start(), matcher.end(), groupIndex - 1)
        }
        if (matches.isEmpty()) return text

        val result = StringBuilder(text)
        for ((start, end, index) in matches.asReversed()) {
            result.replace(start, end, active[index].expansion)
        }
        return result.toString()
    }

    /**
     * A word-character edge is bounded by [WORD] spelled out rather than by
     * `\b`. `\b` is not portable here: it resolves against ASCII-only `\w` on
     * the desktop JVM the unit tests run on, but against Unicode `\w` in the
     * ICU engine Android ships, so a trigger like "büro" would pass a test and
     * still fail on a phone. Naming the class keeps both engines in step.
     * `UNICODE_CHARACTER_CLASS` would do the same on the JVM but throws on
     * Android, which is the other half of the same trap.
     *
     * A punctuation-only trigger like "->" has no word character to bound, so
     * it takes a non-whitespace lookaround, which also lets it match at the
     * very start and end of the string.
     */
    private fun boundaryPattern(trigger: String): String {
        val prefix = if (trigger.first().isWordChar()) "(?<!$WORD)" else "(?<!\\S)"
        val suffix = if (trigger.last().isWordChar()) "(?!$WORD)" else "(?!\\S)"
        return prefix + Pattern.quote(trigger) + suffix
    }

    private fun Char.isWordChar(): Boolean = isLetterOrDigit() || this == '_'

    /** Letters and digits in any script, plus the underscore. */
    private const val WORD = "[\\p{L}\\p{N}_]"
}
