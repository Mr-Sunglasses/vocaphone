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
        // A model can Title-Case a whole sentence ("The Keyboard Is Ready"), and
        // a chunk join capitalizes the word it lands on. Flatten those before
        // Clean/Formal/Casual, while names, mixed-case words and ALL-CAPS
        // acronyms stay.
        val flattened = when (style) {
            WritingStyle.RAW, WritingStyle.VERY_CASUAL -> normalized
            else -> flattenModelCaps(normalized, punctuation)
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

    private enum class Shape { LOWER, TITLE, ACRONYM, SHOUT, MIXED, PRONOUN_I }

    private class Token(
        val text: String,
        val sentence: Int,
        val isWord: Boolean = false,
        val shape: Shape = Shape.LOWER,
        val opensSentence: Boolean = false,
    )

    /**
     * Closed-class words a chunk join or a Title-Casing model capitalizes and a
     * name almost never is. "will", "may" and "a" are left out on purpose:
     * "Will", "May" and "Plan A" are names as often as not.
     */
    private val FUNCTION_WORDS = setOf(
        "the", "an", "and", "or", "but", "so", "if", "then", "than", "because",
        "of", "to", "in", "on", "at", "by", "for", "with", "from", "as", "into",
        "about", "over", "after", "before",
        "is", "are", "was", "were", "be", "been", "am", "it's", "that's",
        "do", "does", "did", "have", "has", "had", "would", "could", "should", "can",
        "it", "its", "this", "that", "these", "those", "there", "here",
        "we", "you", "he", "she", "they", "me", "him", "her", "them",
        "my", "your", "his", "our", "their",
        "what", "when", "where", "why", "how", "who", "which",
        "not", "just", "also", "very", "yes", "no",
    )

    /**
     * Drop Title Case the model invented, keep tokens that look like names.
     *
     * Some models Title-Case a whole sentence ("The Keyboard Is Ready"). When a
     * sentence shows that — nearly every word after the first capitalized —
     * every Title-Case word in it is the model's and is flattened. Anywhere
     * else a capital is far more likely a name someone said ("I met Sarah in
     * Paris on Monday"), so the only thing flattened is a function word a chunk
     * join capitalized ("hello there How are you"), and not even that next to
     * another capitalized word, where it may be part of a name. "VocaPhone",
     * "GraphQL", "iPhone", "NASA", and the pronoun "I" always stay; a longer
     * ALL-CAPS word is the model shouting and is flattened.
     */
    private fun flattenModelCaps(text: String, punctuation: SentencePunctuation): String {
        val tokens = tokenize(text, punctuation)
        val sentenceCount = (tokens.lastOrNull()?.sentence ?: 0) + 1
        val eligible = IntArray(sentenceCount)
        val titled = IntArray(sentenceCount)
        val titledFunctionWords = IntArray(sentenceCount)
        for (token in tokens) {
            if (!token.isWord || token.opensSentence) continue
            if (token.shape != Shape.LOWER && token.shape != Shape.TITLE) continue
            eligible[token.sentence]++
            if (token.shape != Shape.TITLE) continue
            titled[token.sentence]++
            if (functionKey(token.text) in FUNCTION_WORDS) titledFunctionWords[token.sentence]++
        }
        // Three in four is well clear of a sentence that is simply full of
        // names ("meet Sarah and John in Paris on Monday" is four in seven). A
        // sentence too short for a ratio is the model's only when every word is
        // capitalized and one of them is a function word: "Do It", not "Call Sarah".
        val titleCased = BooleanArray(sentenceCount) { sentence ->
            (eligible[sentence] >= 3 && titled[sentence] * 4 >= eligible[sentence] * 3) ||
                (titled[sentence] == eligible[sentence] && titledFunctionWords[sentence] > 0)
        }

        val words = tokens.filter { it.isWord }
        var wordPosition = -1
        val result = StringBuilder(text.length)
        for (token in tokens) {
            if (!token.isWord) {
                result.append(token.text)
                continue
            }
            wordPosition++
            when (token.shape) {
                Shape.PRONOUN_I -> {
                    val body = token.text.dropWhile { !it.isLetter() }
                    result.append(token.text.take(token.text.length - body.length))
                        .append('I')
                        .append(body.drop(1))
                }
                Shape.SHOUT -> result.append(token.text.lowercase())
                Shape.LOWER, Shape.ACRONYM, Shape.MIXED -> result.append(token.text)
                Shape.TITLE -> {
                    val flatten = when {
                        titleCased[token.sentence] -> true
                        token.opensSentence -> false
                        functionKey(token.text) !in FUNCTION_WORDS -> false
                        else -> listOf(wordPosition - 1, wordPosition + 1)
                            .mapNotNull { words.getOrNull(it) }
                            .none { neighbour ->
                                neighbour.sentence == token.sentence &&
                                    !neighbour.opensSentence &&
                                    neighbour.shape in CAPITALIZED_SHAPES
                            }
                    }
                    result.append(if (flatten) token.text.lowercase() else token.text)
                }
            }
        }
        return result.toString()
    }

    private val CAPITALIZED_SHAPES = setOf(Shape.TITLE, Shape.ACRONYM, Shape.MIXED)

    private fun functionKey(token: String): String = token.lowercase().replace('’', '\'')

    private fun tokenize(text: String, punctuation: SentencePunctuation): List<Token> {
        val tokens = mutableListOf<Token>()
        var sentence = 0
        var opensSentence = true
        var index = 0
        while (index < text.length) {
            // Copy a protected span whole: flatten would lowercase the digits
            // inside it, and restore could not match the placeholder afterwards.
            if (text[index] == ProtectedSpans.OPEN) {
                val end = text.indexOf(ProtectedSpans.CLOSE, index)
                if (end >= 0) {
                    tokens += Token(text.substring(index, end + 1), sentence)
                    opensSentence = false
                    index = end + 1
                    continue
                }
            }
            val character = text[index]
            if (character.isLetter()) {
                val start = index
                index++
                while (index < text.length &&
                    (text[index].isLetter() || text[index] == '\'' || text[index] == '’')
                ) {
                    index++
                }
                val word = text.substring(start, index)
                tokens += Token(
                    word,
                    sentence,
                    isWord = true,
                    shape = shapeOf(word),
                    opensSentence = opensSentence,
                )
                opensSentence = false
            } else {
                tokens += Token(character.toString(), sentence)
                if (character in punctuation.terminators) {
                    sentence++
                    opensSentence = true
                }
                index++
            }
        }
        return tokens
    }

    private fun shapeOf(token: String): Shape {
        if (isPronounI(token)) return Shape.PRONOUN_I
        val letters = token.filter { it.isLetter() }
        if (letters.isEmpty()) return Shape.LOWER
        val hasLower = letters.any { it.isLowerCase() }
        val hasUpper = letters.any { it.isUpperCase() }
        if (!hasUpper) return Shape.LOWER
        // Short ALL-CAPS is an acronym (NASA, CPU). Longer shouts are the
        // model yelling a content word; flatten those.
        if (!hasLower && letters.length in 2..4) return Shape.ACRONYM
        if (!hasLower && letters.length > 4) return Shape.SHOUT
        val titleCase = letters.first().isUpperCase() && letters.drop(1).none { it.isUpperCase() }
        return if (titleCase) Shape.TITLE else Shape.MIXED
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
