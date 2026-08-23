package com.vocahq.vocaphone.core

/**
 * Applies the same presentation-only contract as the gateway to a local
 * transcript. It deliberately never adds, removes, or substitutes words.
 */
object TranscriptStyler {
    private data class Punctuation(
        val terminator: String,
        val separator: String,
        val exclamation: String,
        val question: String,
        val terminators: String,
        val join: String,
    )

    private data class Masked(val text: String, val tokens: List<String>)

    private val universalTerminators = ".!?。！？।۔။។།؟"
    private val latin = Punctuation(".", ",", "!", "?", ".!?", " ")
    private val cjk = Punctuation("。", "、", "！", "？", "。！？.!?", "")
    private val arabic = Punctuation(".", "،", "!", "؟", ".!?؟", " ")
    private val urdu = Punctuation("۔", "،", "!", "؟", "۔.!?؟", " ")
    private val danda = Punctuation("।", ",", "!", "?", "।.!?", " ")
    private val indicLatin = Punctuation(".", ",", "!", "?", "।.!?", " ")
    private val unterminated = Punctuation("", " ", "!", "?", "!?", " ")
    private val burmese = Punctuation("။", "၊", "!", "?", "။.!?", " ")
    private val khmer = Punctuation("។", ",", "!", "?", "။.!?", " ")
    private val tibetan = Punctuation("།", "།", "!", "?", "།.!?", " ")

    private val protectedSpans = Regex(
        """(?i)(https?://[^\s]+[^\s.,;:!?\"“”'\)\]]|[\w.+-]+@(?:[\w-]+\.)+[A-Za-z]{2,}|"""
            + """(?:[\w-]+\.)+[A-Za-z]{2,}(?:/[^\s.,;:!?\"“”'\)\]]*)?|\d+(?:[.,:/]\d+)+|"""
            + """\d+(?:st|nd|rd|th)\b|(?:[A-Za-z]\.){2,})""",
    )
    private val placeholder = Regex("\\uE000(\\d+)\\uE001")

    fun apply(text: String?, style: WritingStyle, language: String = "auto"): String {
        val source = text.orEmpty()
        if (style == WritingStyle.RAW) return source.trim()
        if (source.isBlank()) return ""

        val punctuation = punctuation(language, source)
        val masked = mask(source)
        val normalized = normalizeSentenceTerminators(normalizeSpacing(masked.text), punctuation)
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
        val lowered = if (style == WritingStyle.VERY_CASUAL) lowerOutsidePlaceholders(result) else result
        return restore(lowered, masked.tokens)
    }

    private fun punctuation(language: String, text: String): Punctuation {
        val code = language.lowercase().substringBefore('-')
        return when (code) {
            "ja", "zh" -> cjk
            "ar", "fa", "ps" -> arabic
            "ur", "sd", "ks" -> urdu
            "hi", "mr", "ne", "bn", "as", "pa" -> danda
            "ta", "te", "kn", "ml", "gu", "si" -> indicLatin
            "th", "lo" -> unterminated
            "my" -> burmese
            "km" -> khmer
            "bo" -> tibetan
            else -> when {
                text.any { it in "。、！？" } -> cjk
                text.any { it in "،؟" } -> arabic
                text.contains('۔') -> urdu
                text.contains('।') || containsDandaScript(text) -> danda
                else -> latin
            }
        }.copy(terminators = universalTerminators + terminatorsFor(language, text))
    }

    /** Automatic-language fallback for scripts that conventionally use danda. */
    private fun containsDandaScript(text: String): Boolean = text.any { character ->
        character.code in 0x0900..0x097F ||
            character.code in 0x0980..0x09FF ||
            character.code in 0x0A00..0x0A7F
    }

    private fun terminatorsFor(language: String, text: String): String = when {
        language.lowercase().startsWith("ja") || language.lowercase().startsWith("zh") -> cjk.terminators
        language.lowercase().startsWith("ur") -> urdu.terminators
        language.lowercase().startsWith("hi") -> danda.terminators
        else -> ""
    }

    private fun mask(text: String): Masked {
        val matches = protectedSpans.findAll(text).toList()
        var result = text
        for (index in matches.indices.reversed()) {
            result = result.replaceRange(
                matches[index].range,
                "\uE000$index\uE001",
            )
        }
        return Masked(result, matches.map { it.value })
    }

    private fun restore(text: String, tokens: List<String>): String =
        placeholder.replace(text) { match ->
            tokens.getOrNull(match.groupValues[1].toInt()) ?: match.value
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
    private fun normalizeSentenceTerminators(text: String, punctuation: Punctuation): String {
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

    private fun ensureTerminator(text: String, punctuation: Punctuation): String {
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
            if (text[index] == '\uE000') {
                val end = text.indexOf('\uE001', index)
                if (end >= 0) {
                    result.append(text, index, end + 1)
                    index = end + 1
                    continue
                }
            }
            if (text[index].isLetter()) {
                val start = index
                index++
                while (index < text.length && (text[index].isLetter() || text[index] == '\'' || text[index] == '’')) {
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

    private fun capitalizeSentenceStarts(text: String, punctuation: Punctuation): String {
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

    private fun casual(text: String, punctuation: Punctuation): String {
        val capitalized = capitalizeSentenceStarts(text, punctuation)
        if (punctuation.terminator.isEmpty() || capitalized.endsWith("..")) return capitalized
        return if (capitalized.endsWith(punctuation.terminator)) {
            capitalized.dropLast(punctuation.terminator.length)
        } else {
            capitalized
        }
    }

    private fun segments(text: String, punctuation: Punctuation): List<String> {
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
        punctuation: Punctuation,
    ): Pair<String, String> {
        val body = sentence.trim()
        if (body.isEmpty()) return "" to ""
        val last = body.last()
        if (last in punctuation.terminators && !(last == '.' && body.endsWith(".."))) {
            return body.dropLast(1) to last.toString()
        }
        return body to ""
    }

    private fun veryCasual(sentences: List<String>, punctuation: Punctuation): String {
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

    private fun excited(sentences: List<String>, punctuation: Punctuation): String {
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

    private fun lowerOutsidePlaceholders(text: String): String {
        val result = StringBuilder(text.length)
        var end = 0
        placeholder.findAll(text).forEach { match ->
            result.append(text.substring(end, match.range.first).lowercase())
            result.append(match.value)
            end = match.range.last + 1
        }
        result.append(text.substring(end).lowercase())
        return result.toString()
    }
}
