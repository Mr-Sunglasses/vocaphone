package com.vocahq.vocaphone.core

/**
 * The runs of a transcript that no text stage may edit: URLs, email addresses,
 * bare domains, decimals and times, ordinals, and dotted initialisms.
 *
 * Every stage that rewrites punctuation has the same problem — `example.com`
 * ends in a full stop that is not a sentence, `3.5` contains one that is not a
 * mark at all — so they all mask first, work on the masked text, and restore
 * last. The placeholder is a private-use character pair rather than a word, so
 * a stage that lowercases or capitalizes cannot damage it and a stage that
 * splits on letters cannot split it.
 */
class ProtectedSpans private constructor(
    val text: String,
    private val tokens: List<String>,
) {
    /**
     * Puts the original spans back. Takes the text rather than reading [text],
     * because the caller has rewritten everything around them.
     */
    fun restore(masked: String): String = PLACEHOLDER.replace(masked) { match ->
        tokens.getOrNull(match.groupValues[1].toInt()) ?: match.value
    }

    companion object {
        const val OPEN = '\uE000'
        const val CLOSE = '\uE001'

        /**
         * A bare hostname, recognized by the case of its last label rather than
         * by a list of top-level domains.
         *
         * An allowlist cannot work: there are roughly 1,500 top-level domains,
         * and every one left off it — `example.museum` — gets its dot read as
         * sentence punctuation and the address split in half. Matching *any*
         * dotted pair instead has the opposite fault: it masks `report.Then` in
         * "I finished the report.Then I left", and the missing space can never
         * be repaired.
         *
         * The whole signal is in the label **after** the final dot. A top-level
         * domain is written in lowercase; a full stop that ended a sentence is
         * followed by a capital. Nothing before that dot carries information —
         * requiring the name to be lowercase too only loses `Example.museum` —
         * so this asks about the last label and nothing else. The leading `\b`
         * keeps it from matching the tail of a longer word.
         *
         * All caps counts too, so `NASA.GOV` survives. What that cannot be is a
         * sentence boundary: an engine that shouts the word after a full stop
         * shouted the one before it as well, and `report.THEN` is not a shape
         * any of them produce. Title Case is the one that stays out —
         * `report.Then` is the sentence boundary this whole clause exists to
         * preserve.
         *
         * One thing is left over: `report.then`, an all-lowercase run-on from an
         * engine that emits a full stop but no capital, is masked as though it
         * were a hostname. That shape is genuinely ambiguous, and a missing
         * space is a blemish where a broken address is data loss.
         */
        private const val HOSTNAME = """\b(?:[\w-]+\.)+(?:[a-z]{2,24}|[A-Z]{2,24})\b"""

        /**
         * A path may contain dots; it may not end on the full stop that ends
         * the sentence the address is sitting in.
         */
        private const val PATH = """(?:/[^\s]*[^\s.,;:!?"“”'\)\]])?"""

        private val SPANS = Regex(
            """((?i:https?)://[^\s]+[^\s.,;:!?"“”'\)\]]""" +
                """|[\w.+-]+@(?:[\w-]+\.)+[A-Za-z]{2,}""" +
                """|$HOSTNAME$PATH""" +
                """|\d+(?:[.,:/]\d+)+""" +
                """|\d+(?i:st|nd|rd|th)\b""" +
                """|(?:[A-Za-z]\.){2,})""",
        )

        private val PLACEHOLDER = Regex("$OPEN(\\d+)$CLOSE")

        fun mask(text: String): ProtectedSpans {
            val matches = SPANS.findAll(text).toList()
            var result = text
            for (index in matches.indices.reversed()) {
                result = result.replaceRange(matches[index].range, "$OPEN$index$CLOSE")
            }
            return ProtectedSpans(result, matches.map { it.value })
        }

        /**
         * Applies [transform] to everything that is not a placeholder. Case
         * changes have to skip them: the digits inside would survive, but the
         * characters are the only thing [restore] can match on.
         */
        fun mapOutsidePlaceholders(text: String, transform: (String) -> String): String {
            val result = StringBuilder(text.length)
            var end = 0
            PLACEHOLDER.findAll(text).forEach { match ->
                result.append(transform(text.substring(end, match.range.first)))
                result.append(match.value)
                end = match.range.last + 1
            }
            result.append(transform(text.substring(end)))
            return result.toString()
        }
    }
}
