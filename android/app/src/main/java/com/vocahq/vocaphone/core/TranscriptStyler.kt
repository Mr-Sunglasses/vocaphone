package com.vocahq.vocaphone.core

/**
 * Applies the same presentation-only contract as the gateway to a local
 * transcript. It deliberately never adds, removes, or substitutes words.
 *
 * Dropping a filler or inserting a missing sentence break would both break that
 * contract, which is why they are [TranscriptRepair]'s job and run before this
 * stage under a switch of their own.
 */
object TranscriptStyler {

    fun apply(text: String?, style: WritingStyle, language: String = "auto"): String {
        val source = text.orEmpty()
        if (style == WritingStyle.RAW) return source.trim()
        if (source.isBlank()) return ""

        val punctuation = SentencePunctuation.resolve(language, source)
        val spans = ProtectedSpans.mask(source)
        val normalized = normalizeSentenceTerminators(normalizeSpacing(spans.text), punctuation)
        // Whisper and Parakeet Title-Case content words ("the Keyboard Is Ready").
        // Flatten those before Clean/Formal/Casual so mid-sentence capitals are
        // not left as-is. Mixed-case names and ALL-CAPS acronyms stay.
        val flattened = when (style) {
            WritingStyle.RAW, WritingStyle.VERY_CASUAL -> normalized
            else -> flattenModelCaps(normalized)
        }
        val result = when (style) {
            WritingStyle.CLEAN -> ensureTerminator(flattened, punctuation)
            WritingStyle.FORMAL -> ensureTerminator(
                capitalizeSentenceStarts(flattened, punctuation),
                punctuation,
            )
            WritingStyle.CASUAL -> casual(flattened, punctuation)
            WritingStyle.VERY_CASUAL -> veryCasual(
                segments(normalized, punctuation),
                punctuation,
            )
            WritingStyle.EXCITED -> excited(
                segments(flattened, punctuation),
                punctuation,
            )
            WritingStyle.RAW -> normalized
        }
        val lowered = if (style == WritingStyle.VERY_CASUAL) {
            ProtectedSpans.mapOutsidePlaceholders(result) { it.lowercase() }
        } else {
            result
        }
        return spans.restore(lowered)
    }

    private fun normalizeSpacing(text: String): String = text
        .replace(Regex("\\s+"), " ")
        .trim()
        .replace(Regex("\\s+([.!?。！？।۔،,;:])"), "$1")

    /**
     * Models often emit an ASCII full stop for correctly decoded Hindi. Once
     * the script is known, normalize sentence boundaries while masked URLs,
     * decimals, abbreviations, and ellipses remain untouched.
     */
    private fun normalizeSentenceTerminators(
        text: String,
        punctuation: SentencePunctuation,
    ): String {
        if (punctuation.terminator != "।") return text
        return buildString(text.length) {
            text.forEachIndexed { index, character ->
                if (character != '.') {
                    append(character)
                    return@forEachIndexed
                }
                val previous = text.getOrNull(index - 1)
                val next = text.getOrNull(index + 1)
                val isEllipsis = previous == '.' || next == '.'
                val isSentenceBoundary = next == null || next.isWhitespace()
                append(if (isSentenceBoundary && !isEllipsis) '।' else character)
            }
        }
    }

    private fun ensureTerminator(text: String, punctuation: SentencePunctuation): String {
        if (text.isEmpty() || punctuation.terminator.isEmpty()) return text
        return if (text.last() in punctuation.terminators) text
        else text + punctuation.terminator
    }

    /**
     * Drop Title Case the model invented, keep tokens that look like names.
     *
     * "Keyboard" in the middle of a sentence becomes "keyboard". "VocaPhone",
     * "GraphQL", "iPhone", "NASA", and the pronoun "I" are left alone.
     */
    private fun flattenModelCaps(text: String): String {
        val result = StringBuilder(text.length)
        var index = 0
        while (index < text.length) {
            // Copy a protected span whole: flatten would lowercase the digits
            // inside it, and restore could not match the placeholder afterwards.
            if (text[index] == ProtectedSpans.OPEN) {
                val end = text.indexOf(ProtectedSpans.CLOSE, index)
                if (end >= 0) {
                    result.append(text, index, end + 1)
                    index = end + 1
                    continue
                }
            }
            if (text[index].isLetter()) {
                val start = index
                index++
                while (index < text.length &&
                    (text[index].isLetter() || text[index] == '\'' || text[index] == '’')
                ) {
                    index++
                }
                result.append(softenToken(text.substring(start, index)))
            } else {
                result.append(text[index])
                index++
            }
        }
        return result.toString()
    }

    private fun softenToken(token: String): String {
        if (isPronounI(token)) {
            val body = token.dropWhile { !it.isLetter() }
            return token.take(token.length - body.length) + "I" + body.drop(1)
        }
        val letters = token.filter { it.isLetter() }
        if (letters.isEmpty()) return token
        val hasLower = letters.any { it.isLowerCase() }
        val hasUpper = letters.any { it.isUpperCase() }
        // Short ALL-CAPS is an acronym (NASA, CPU). Longer shouts are the
        // model yelling a content word; flatten those.
        if (!hasLower && letters.length in 2..4) return token
        if (!hasLower && letters.length > 4) return token.lowercase()
        if (hasLower && hasUpper) {
            val body = token.dropWhile { !it.isLetter() }
            val titleCase = body.first().isUpperCase() && body.drop(1).none { it.isUpperCase() }
            if (!titleCase) return token
        }
        return token.lowercase()
    }

    /** "I", "I'm", "I’ve", "I'd", "I'll". Not "is" or "it". */
    private fun isPronounI(token: String): Boolean {
        val letters = token.filter { it.isLetter() }
        if (letters.isEmpty() || letters.first().lowercaseChar() != 'i') return false
        val rest = letters.drop(1).lowercase()
        if (rest.isEmpty()) return true
        val contracted = token.any { it == '\'' || it == '’' }
        return contracted && rest in setOf("m", "ll", "d", "ve", "re", "s")
    }

    private fun capitalizeSentenceStarts(
        text: String,
        punctuation: SentencePunctuation,
    ): String {
        val result = StringBuilder(text.length)
        var capitalize = true
        text.forEach { character ->
            if (capitalize && character.isLetter()) {
                result.append(character.uppercaseChar())
                capitalize = false
            } else {
                result.append(character)
            }
            if (character in punctuation.terminators) capitalize = true
        }
        return result.toString()
    }

    private fun casual(text: String, punctuation: SentencePunctuation): String {
        val capitalized = capitalizeSentenceStarts(text, punctuation)
        if (punctuation.terminator.isEmpty() || capitalized.endsWith("..")) return capitalized
        return if (capitalized.endsWith(punctuation.terminator)) {
            capitalized.dropLast(punctuation.terminator.length)
        } else {
            capitalized
        }
    }

    private fun segments(text: String, punctuation: SentencePunctuation): List<String> {
        if (text.isEmpty()) return emptyList()
        val result = mutableListOf<String>()
        var start = 0
        var index = 0
        while (index < text.length) {
            val character = text[index]
            val ellipsis = character == '.' && (
                index > 0 && text[index - 1] == '.' ||
                    index + 1 < text.length && text[index + 1] == '.'
                )
            val next = text.getOrNull(index + 1)
            val boundary = character in punctuation.terminators &&
                !ellipsis && (next == null || next.isWhitespace() || punctuation.join.isEmpty())
            if (boundary) {
                result += text.substring(start, index + 1)
                start = index + 1
                while (start < text.length && text[start].isWhitespace()) start++
                index = start
            } else {
                index++
            }
        }
        if (start < text.length) result += text.substring(start)
        return result.ifEmpty { listOf(text) }
    }

    private fun splitTerminator(
        sentence: String,
        punctuation: SentencePunctuation,
    ): Pair<String, String> {
        val body = sentence.trim()
        if (body.isEmpty()) return "" to ""
        val last = body.last()
        if (last in punctuation.terminators && !(last == '.' && body.endsWith(".."))) {
            return body.dropLast(1) to last.toString()
        }
        return body to ""
    }

    private fun veryCasual(
        sentences: List<String>,
        punctuation: SentencePunctuation,
    ): String {
        val parts = sentences.mapIndexedNotNull { index, sentence ->
            val (body, terminator) = splitTerminator(sentence, punctuation)
            if (body.isEmpty()) return@mapIndexedNotNull null
            if (index == sentences.lastIndex) body
            else if (terminator.isEmpty() || terminator == punctuation.terminator) {
                body + punctuation.separator
            } else {
                body + terminator
            }
        }
        return parts.joinToString(punctuation.join)
    }

    private fun excited(sentences: List<String>, punctuation: SentencePunctuation): String {
        val parts = sentences.mapNotNull { sentence ->
            val (body, terminator) = splitTerminator(sentence, punctuation)
            if (body.isEmpty()) null
            else if (terminator == punctuation.question) {
                capitalizeSentenceStarts(body, punctuation) + terminator
            } else {
                capitalizeSentenceStarts(body, punctuation) + punctuation.exclamation
            }
        }
        return parts.joinToString(punctuation.join)
    }
}
