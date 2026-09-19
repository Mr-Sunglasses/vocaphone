package com.vocahq.vocaphone.core

/**
 * Turns what a speech model heard into what the speaker meant to write:
 * hesitation sounds dropped, false starts collapsed, and the punctuation the
 * model left out put in.
 *
 * This is deliberately **not** part of [TranscriptStyler]. That stage documents
 * a contract it has to keep — no style adds, removes, or substitutes a word —
 * and this stage exists precisely to break it, under a switch of its own.
 * Keeping them apart is what lets the styles still be described honestly.
 *
 * Everything here is rule-based. There is no model, no network call, and no
 * language understanding: the rules are the conservative subset where a mistake
 * is nearly impossible to make, and anything needing judgement about what the
 * speaker meant is left alone on purpose. The order of the stages is
 * load-bearing and is documented at each one.
 *
 * Mirrors the iOS client's `TranscriptRepair`; the two are expected to produce
 * the same text for the same transcript.
 */
object TranscriptRepair {

    /**
     * @param text a transcript that has already been through [TranscriptSanitizer].
     * @param language the language the finished text is written in, or `"auto"`.
     */
    fun apply(text: String?, language: String = "auto"): String {
        val source = text.orEmpty().trim()
        if (source.isEmpty()) return ""

        val punctuation = SentencePunctuation.resolve(language, source)
        val code = language.lowercase().substringBefore('-')
        val spans = ProtectedSpans.mask(source)

        // 1. Fillers first: they are the noise every later rule would otherwise
        //    have to reason around. "we should um we should ship" is not a
        //    stutter until the "um" between the copies is gone.
        var working = removeFillers(spans.text, code)
        // 2. Stutters, on the text the fillers left behind.
        working = collapseStutters(working, punctuation)
        // 3. Normalize the marks that are there before inferring the ones that
        //    are not, so inference counts real sentence boundaries.
        working = repairMarks(working, punctuation)
        // 4. Inference is written against how English builds a sentence. In a
        //    script that spaces or terminates differently it would do damage,
        //    and in another Latin language its trigger words never match.
        if (punctuation.usesLatinLayout) working = infer(working, punctuation)

        val repaired = spans.restore(working).trim()
        // A transcript that repaired down to nothing is a rule misfiring, not a
        // silent recording — the sanitizer has already had its say about those.
        // Hand back what came in rather than an empty text field.
        return if (repaired.any { it.isLetterOrDigit() }) repaired else source
    }

    // region Words

    /**
     * A whitespace-delimited chunk split into the punctuation around it and the
     * word inside, so a rule can drop a word without losing the comma attached
     * to it, or match a word without its full stop getting in the way.
     */
    private data class Word(
        var leading: String,
        var text: String,
        var trailing: String,
    ) {
        val isEmpty: Boolean get() = leading.isEmpty() && text.isEmpty() && trailing.isEmpty()

        val rendered: String get() = leading + text + trailing

        /**
         * Lowercased letters and digits only. Apostrophes go, so `don't` and
         * `dont` match, and the placeholder characters stay so a masked URL can
         * never compare equal to a bare number.
         */
        val key: String
            get() = text.lowercase().filter {
                it.isLetterOrDigit() || it == ProtectedSpans.OPEN || it == ProtectedSpans.CLOSE
            }

        val isProtected: Boolean get() = text.contains(ProtectedSpans.OPEN)

        val startsUppercase: Boolean
            get() = text.firstOrNull { it.isLetter() }?.isUpperCase() == true
    }

    private fun isWordCharacter(character: Char): Boolean =
        character.isLetterOrDigit() || character == '\'' || character == '’' ||
            character == '-' || character == ProtectedSpans.OPEN || character == ProtectedSpans.CLOSE

    private fun split(text: String): MutableList<Word> =
        text.split(Regex("\\s+")).filter { it.isNotEmpty() }.map { chunk ->
            var start = 0
            while (start < chunk.length && !isWordCharacter(chunk[start])) start++
            var end = chunk.length
            while (end > start && !isWordCharacter(chunk[end - 1])) end--
            Word(chunk.substring(0, start), chunk.substring(start, end), chunk.substring(end))
        }.toMutableList()

    private fun joined(words: List<Word>): String =
        words.filterNot { it.isEmpty }.joinToString(" ") { it.rendered }

    // endregion

    // region Fillers

    /**
     * Hesitation sounds that are not a word in any language this app
     * transcribes, so they can go whatever was spoken.
     *
     * Every one is non-lexical: there is no sentence in which it carries
     * meaning, which is the whole reason removing it is safe. That is also why
     * `like`, `you know`, `I mean` and `actually` are **not** here. Each is a
     * real word often enough that dropping it needs judgement about what the
     * speaker meant, and this stage does not have any.
     */
    private val ALWAYS_SAFE_FILLERS = setOf("uh", "uhm", "umh", "erm", "hm")

    /**
     * English hesitation sounds that are ordinary words somewhere else.
     *
     * `um` is German for "at" — "um acht Uhr" — and `er` is German for "he" and
     * Dutch for "there". Dropping them from a German transcript deletes
     * content, so they go only when the transcript is English, or when
     * Automatic was selected and [looksEnglish] recognizes the sentence around
     * them.
     */
    private val ENGLISH_FILLERS = setOf("um", "er")

    /**
     * Sounds that mean *yes* or *no*, and must survive. `mhm` and `uh-huh` are
     * answers to a question, and a transcript that drops them says the opposite
     * of what was said. They are listed rather than merely absent so that
     * widening the filler sets cannot quietly swallow one.
     */
    private val AFFIRMATIONS = setOf("mhm", "mhmm", "mmhm", "uhuh", "uhhuh", "nuhuh", "huh", "hu")

    /**
     * Words that reach a filler spelling only because [canonical] flattens
     * repeated letters, and so have to be caught before it runs. "Err on the
     * side of caution" is the verb; a model writing a hesitation as `err`
     * rather than `uh` is rare enough that keeping the word wins.
     */
    private val LITERAL_EXCEPTIONS = setOf("err")

    /**
     * How many markers a transcript needs before Automatic will treat it as
     * English.
     *
     * One is not enough. A German sentence only has to brush against a single
     * English-looking word to lose its "er", and "er kommt her" did exactly
     * that. Two independent markers is a far higher bar for an accident to
     * clear, and English prose of any length clears it easily.
     */
    private const val ENGLISH_MARKERS_NEEDED = 2

    /**
     * High-frequency English words that are **not** also words in the other
     * Latin-script languages this app transcribes. That exclusion is the whole
     * point of the list, so it is much shorter than a frequency table would be:
     * `is` is Dutch, `was` and `will` are German, `for` is Danish, `of` is
     * Dutch for "or", `i` is Danish for "in", `her` is German for "hither",
     * `over` is Dutch, `want` is Dutch for "because", and `come` is Italian for
     * "how". Any of those would call a foreign sentence English and cost it a
     * word.
     */
    private val ENGLISH_MARKERS = setOf(
        "the", "and", "you", "your", "yours", "with", "that", "thats", "this",
        "these", "those", "what", "whats", "which", "when", "where", "who",
        "how", "have", "has", "had", "are", "were", "been", "being",
        "not", "dont", "doesnt", "didnt", "isnt", "arent", "cant", "wont",
        "wouldnt", "couldnt", "shouldnt", "havent", "hasnt",
        "it", "its", "they", "them", "their", "theyre", "theres", "wheres",
        "she", "his", "there", "would", "could", "should", "about", "because",
        "know", "knew", "think", "thought", "going", "please", "thanks",
        "very", "again", "only", "some", "than", "then", "through",
        "need", "make", "made", "take", "took", "from", "more", "most",
        "much", "many", "something", "anything", "everything", "nothing",
        "yeah", "gonna", "wanna", "gotta", "ive", "youre", "youve",
        "today", "tomorrow", "yesterday", "here", "there", "everyone",
        "people", "thing", "things", "time", "good", "great", "sure",
        "right", "wrong", "back", "down", "off", "got", "getting",
        "said", "told", "asked", "does", "did", "doing", "actually",
        "probably", "really", "always", "never", "maybe",
    )

    /**
     * Letters that belong to another Latin alphabet. A transcript carrying one
     * is not English whatever else it contains, and this is the cheapest hard
     * veto available before counting anything.
     */
    private const val FOREIGN_LETTERS = "äöüßåæøœçñõãêôîûàèìòùáéíóúýðþğışłżźćęą"

    /**
     * Only the non-lexical hesitation sounds, same bar as [UNIVERSAL_FILLERS].
     * A language is absent here because nobody has checked it, not because it
     * has no fillers.
     */
    private val LOCAL_FILLERS = mapOf(
        "de" to setOf("äh", "ähm", "öh", "öhm"),
        "nl" to setOf("eh", "ehm", "uh"),
        "fr" to setOf("euh", "heu"),
        "es" to setOf("eh", "em"),
        "it" to setOf("ehm", "eh"),
    )

    /**
     * Fillers in the scripts that are written without spaces, where there are
     * no words to walk. Removed as plain substrings, which is only safe because
     * each of these carries a length mark that a content word does not.
     */
    private val UNSPACED_FILLERS = mapOf(
        "ja" to listOf("えーと", "えっと", "ええと", "あのー", "あのう"),
        "zh" to listOf("呃"),
        "yue" to listOf("呃"),
    )

    private const val QUOTES = "\"'“”‘’«»„"

    /**
     * Collapses a run of one repeated letter, so however long the model drew
     * the sound out it lands on the same key: `ummmm` and `uhhh` become `um`
     * and `uh`. `uh-huh` arrives with its hyphen already gone — [Word.key]
     * keeps only letters and digits — and so reaches [AFFIRMATIONS] intact.
     */
    private fun canonical(key: String): String {
        val result = StringBuilder(key.length)
        var previous: Char? = null
        for (character in key) {
            if (character != previous) result.append(character)
            previous = character
        }
        return result.toString()
    }

    /**
     * Whether the English filler set applies.
     *
     * An explicit `en` always qualifies, and so does a language the engine
     * detected as English. On Automatic nothing has said what the language is,
     * so the sentence has to say it itself — twice over, and without a letter
     * from another alphabet in it.
     *
     * The cost is a filler left in a short English fragment that carries fewer
     * than two markers. That is the right direction to be wrong in: leaving an
     * "um" is a blemish, and deleting the subject of a German sentence is not.
     */
    private fun looksEnglish(code: String, words: List<Word>): Boolean {
        if (code == "en") return true
        if (code.isNotEmpty() && code != "auto") return false
        val seen = mutableSetOf<String>()
        for (word in words) {
            if (word.text.lowercase().any { it in FOREIGN_LETTERS }) return false
            if (word.key in ENGLISH_MARKERS) seen += word.key
        }
        return seen.size >= ENGLISH_MARKERS_NEEDED
    }

    private fun isFiller(word: Word, code: String, english: Boolean): Boolean {
        if (word.isProtected) return false
        // A quoted filler is being talked about rather than said: someone
        // dictating `he said "um" a lot` means the word to be there.
        if (word.leading.any { it in QUOTES } || word.trailing.any { it in QUOTES }) return false
        val raw = word.key
        if (raw.isEmpty() || raw in LITERAL_EXCEPTIONS) return false
        val key = canonical(raw)
        if (key in AFFIRMATIONS) return false
        if (key in ALWAYS_SAFE_FILLERS) return true
        if (english && key in ENGLISH_FILLERS) return true
        return LOCAL_FILLERS[code]?.contains(key) == true
    }

    private fun removeFillers(text: String, code: String): String {
        var result = text
        UNSPACED_FILLERS[code]?.forEach { filler -> result = result.replace(filler, "") }

        val words = split(result)
        val english = looksEnglish(code, words)
        val kept = mutableListOf<Word>()
        for (word in words) {
            if (!isFiller(word, code, english)) {
                kept += word
                continue
            }
            // The filler goes, but a sentence it happened to end does not:
            // "I was thinking. Um. We should ship" keeps both full stops.
            val terminators = word.trailing.filter { it in "!?.。！？।۔" }
            val previous = kept.lastOrNull()
            if (terminators.isNotEmpty() && previous != null) {
                if (previous.trailing.none { it in terminators }) {
                    previous.trailing += terminators
                }
            } else if (word.trailing.contains(',') && previous?.trailing?.endsWith(",") == true) {
                // A filler set off by commas on both sides takes both with it:
                // "I think, um, we should" is "I think we should", not
                // "I think, we should".
                previous.trailing = previous.trailing.dropLast(1)
            }
        }
        return joined(kept)
    }

    // endregion

    // region False starts

    /**
     * Words whose immediate repeat is a stutter and essentially never grammar:
     * determiners, prepositions, conjunctions and subject pronouns. A repeated
     * content word ("very very") is emphasis the speaker meant, and is not here.
     *
     * Deliberately narrower than "closed class". A copula, an auxiliary or a
     * possessive or a modal doubles legitimately far too often to guess at —
     * "what it is is a problem", "the things I have have value", "I gave her
     * her coat", "I can can peaches", "there, there" — so none of those are
     * here either. The cost of leaving a real stutter in is a duplicated word;
     * the cost of being wrong is a deleted one.
     */
    private val FUNCTION_WORDS = setOf(
        "the", "a", "an", "and", "but", "or", "to", "of", "in", "on", "at",
        "for", "with", "from", "by", "as", "if", "than",
        "i", "you", "we", "they", "he", "she", "it", "this", "these", "those",
        "what", "when", "where", "why", "who", "how",
    )

    /**
     * Doubles that are ordinary English even though the word is on the list
     * above. "The thing that that man said" is correct, and looks exactly like
     * a stutter to a rule that only compares two words.
     */
    private val LEGITIMATE_DOUBLES = setOf("that")

    /**
     * Longest false start collapsed. Beyond this it is a repeated sentence,
     * which [TranscriptSanitizer] already has thresholds for.
     */
    private const val MAX_STUTTER_WORDS = 4

    /**
     * Collapses a phrase said twice in a row — "we should we should probably".
     *
     * Only an immediate repeat, and only the second copy is kept, because it is
     * the copy the speaker carried on from: "we should, we should probably
     * ship" has the comma on the abandoned half and the sentence on the other.
     *
     * A multi-word repeat also has to be followed by something. That is what
     * separates a false start from a phrase said twice on purpose: the speaker
     * who restarts goes on to finish the sentence, where "I love you I love
     * you" and "no no no no" end where they end.
     */
    private fun collapseStutters(text: String, punctuation: SentencePunctuation): String {
        val words = split(text)
        if (words.size < 2) return text

        val result = mutableListOf<Word>()
        var index = 0
        while (index < words.size) {
            // Longest first, so "we should we should" is one phrase twice over
            // rather than two separate doubled words.
            val length = (minOf(MAX_STUTTER_WORDS, (words.size - index) / 2) downTo 1)
                .firstOrNull { matchesRepeat(words, index, it, punctuation) }
            if (length == null) {
                result += words[index]
                index++
                continue
            }
            val leading = words[index].leading
            val second = words.subList(index + length, index + length * 2).map { it.copy() }
            if (leading.isNotEmpty() && second.first().leading.isEmpty()) {
                second.first().leading = leading
            }
            result += second
            index += length * 2
        }
        return joined(result)
    }

    private fun matchesRepeat(
        words: List<Word>,
        index: Int,
        length: Int,
        punctuation: SentencePunctuation,
    ): Boolean {
        if (index + length * 2 > words.size) return false
        // A repeat with nothing after it was said twice on purpose. A false
        // start is the beginning of a sentence the speaker then finishes.
        if (length > 1 && index + length * 2 >= words.size) return false
        // Neither is a repeat containing [SpokenEmoji]'s trigger. Nobody
        // abandons a sentence on the one word this app treats as a command, so
        // "crying emoji crying emoji crying emoji" is three emoji — and unlike
        // the guard above, those copies *are* followed by more of themselves.
        //
        // Anywhere in the unit, not just the end, because this walk advances a
        // word at a time and re-enters the middle of a run it declined: three
        // "crying emoji" read from index one are two "emoji crying", and that
        // rotation puts the trigger first.
        if (length > 1 && (0 until length).any { words[index + it].key in SpokenEmoji.TRIGGER_WORDS }) {
            return false
        }
        for (offset in 0 until length) {
            val first = words[index + offset]
            val second = words[index + length + offset]
            if (first.isProtected || first.key.isEmpty() || first.key != second.key) return false
            // A sentence ended between the copies, so the second one starts a
            // new thought: "I went home. Home is quiet."
            if (ends(first, punctuation)) return false
        }
        if (length == 1) {
            val key = words[index].key
            if (key !in FUNCTION_WORDS || key in LEGITIMATE_DOUBLES) return false
        }
        return true
    }

    private fun ends(word: Word, punctuation: SentencePunctuation): Boolean =
        word.trailing.any { it in punctuation.terminators }

    // endregion

    // region Marks that are already there

    /**
     * Normalizes the punctuation the model emitted: spacing around it, runs of
     * it, and pairs of marks that cannot both be right. Nothing here decides
     * where a sentence ends; it only tidies the decisions already made.
     */
    private fun repairMarks(text: String, punctuation: SentencePunctuation): String {
        var result = text.replace(Regex("\\s+"), " ").trim()
        // Built from the shared sets rather than a literal per rule, so the
        // Swift original cannot quietly cover a different set of scripts.
        val marks = "[${SentencePunctuation.UNIVERSAL_MARKS}]"
        val terminators = "[${SentencePunctuation.UNIVERSAL_TERMINATORS}]"
        val separators = "[${SentencePunctuation.UNIVERSAL_SEPARATORS}]"

        // Never a space before a mark.
        result = result.replace(Regex("\\s+($marks)"), "$1")
        // A run of one separator is one separator.
        result = result.replace(Regex("($separators)\\1+"), "$1")
        // A separator touching a terminator: the terminator wins, whichever
        // order the model put them in.
        result = result.replace(Regex("$separators\\s*($terminators)"), "$1")
        result = result.replace(Regex("($terminators)\\s*$separators"), "$1")
        // Shouting and stammering. Four or more stops is an ellipsis that got
        // away; three stays an ellipsis.
        result = result.replace(Regex("!{2,}"), "!")
        result = result.replace(Regex("\\?{2,}"), "?")
        result = result.replace(Regex("\\.{4,}"), "...")
        result = result.replace(Regex("([!?])\\.+"), "$1")
        result = result.replace(Regex("\\.([!?])"), "$1")

        if (punctuation.join == " ") {
            // Always a space after a mark, unless another mark follows it —
            // that is an ellipsis or a quoted close, not two sentences.
            result = result.replace(
                Regex("($separators)(?=[^\\s${SentencePunctuation.UNIVERSAL_MARKS}\\)\\]\"”’])"),
                "$1 ",
            )
            result = result.replace(
                Regex("($terminators)(?=[\\p{L}\\p{N}${ProtectedSpans.OPEN}])"),
                "$1 ",
            )
        }

        // A mark with nothing in front of it, and a separator with nothing
        // after it, are both left over from something that was removed.
        result = result.replace(Regex("^[\\s${SentencePunctuation.UNIVERSAL_MARKS}]+"), "")
        result = result.replace(Regex("($separators)+\\s*$"), "")
        return result.trim()
    }

    // endregion

    // region Marks that are missing

    /**
     * Phrases that start a new thought when they turn up mid-flow. Each is a
     * discourse marker with no other job, which is what makes a sentence break
     * in front of it safe.
     */
    private val SENTENCE_STARTERS = listOf(
        listOf("okay"), listOf("ok"), listOf("alright"), listOf("all", "right"),
        listOf("anyway"), listOf("anyhow"), listOf("by", "the", "way"),
        listOf("in", "any", "case"),
    )

    /**
     * Markers that take a comma when they open a sentence. `so` and `well` are
     * missing on purpose: both open a sentence far more often without one.
     */
    private val OPENERS_TAKING_COMMA = listOf(
        listOf("okay"), listOf("ok"), listOf("alright"), listOf("all", "right"),
        listOf("anyway"), listOf("anyhow"), listOf("however"), listOf("actually"),
        listOf("by", "the", "way"), listOf("in", "fact"), listOf("of", "course"),
        listOf("for", "example"),
    )

    /** Conjunctions that take a comma when they join two full clauses. */
    private val CLAUSE_CONJUNCTIONS = setOf("but", "so", "yet", "however")

    /**
     * Words that can open a clause of their own. The test for "is a full clause
     * coming" is "does a subject start right here", which these are the common
     * ones for.
     */
    private val CLAUSE_STARTERS = setOf(
        "i", "im", "ive", "ill", "id", "you", "youre", "youve", "youll", "youd",
        "we", "weve", "well", "wed", "were", "they", "theyre", "theyve", "theyll",
        "he", "hes", "hed", "she", "shes", "shed", "it", "its", "thats", "this",
        "there", "theres", "my", "your", "our", "their", "his", "her",
        "the", "a", "an", "nobody", "everyone", "someone", "people", "lets",
        "maybe", "now", "then", "today", "tomorrow", "yesterday",
    )

    /**
     * After a conjunction these continue the phrase rather than opening a
     * clause: "so that", "so much", "but as".
     */
    private val PHRASE_FOLLOWERS = setOf("that", "much", "many", "far", "long", "as")

    private val DETERMINERS = setOf("the", "a", "an")

    /**
     * Openers that are neither a subject nor an auxiliary but still start a
     * sentence often enough to count as one beginning.
     */
    private val CLAUSE_OPENERS = setOf("so", "well", "just", "first", "next")

    /**
     * After one of these, `okay` and `alright` are describing something — "the
     * results came back okay" — rather than somebody starting a new sentence.
     * Copulas and the particles that finish a phrasal verb, which is the other
     * position an adjective lands in.
     */
    private val ADJECTIVE_PREDECESSORS = setOf(
        "is", "are", "was", "were", "am", "be", "been", "being",
        "seem", "seems", "seemed", "look", "looks", "looked",
        "feel", "feels", "felt", "sound", "sounds", "sounded",
        "went", "goes", "going", "gone", "doing", "does", "works", "worked",
        "turned", "came", "back", "out", "up", "fine", "along",
        "not", "quite", "pretty", "totally", "perfectly", "really",
        "its", "thats", "everything", "anything", "something", "nothing",
        "all", "more", "less", "about", "mostly", "otherwise", "apparently",
    )

    /**
     * Quantifiers that turn an opener into a phrase. "However many people
     * come" means "no matter how many", and the comma would say the opposite.
     */
    private val QUANTIFIER_FOLLOWERS = setOf(
        "many", "much", "long", "far", "little", "few", "often", "else",
    )

    private val AUXILIARIES = setOf(
        "do", "does", "did", "dont", "doesnt", "didnt",
        "is", "are", "was", "were", "isnt", "arent", "wasnt", "werent",
        "can", "cant", "could", "couldnt", "will", "wont", "would", "wouldnt",
        "should", "shouldnt", "shall", "may", "might", "must",
        "have", "has", "had", "havent", "hasnt", "hadnt", "am",
    )

    /**
     * Modals that turn an inverted `had`/`were` opening into a condition rather
     * than a question: "Had I known that, I would have called."
     */
    private val CONDITIONAL_MODALS = setOf(
        "would", "could", "should", "might", "wouldve", "couldve", "shouldve",
    )

    private val QUESTION_WORDS = setOf(
        "what", "whats", "when", "whens", "where", "wheres",
        "why", "whys", "who", "whos", "whom", "whose", "how", "hows",
    )

    /**
     * A `how` question may put a quantifier and its noun in front of the
     * auxiliary: "How many people are coming?". That is a question shape, not
     * the noun-clause shape that makes "what the problem is remains unclear" a
     * statement.
     */
    private val HOW_QUANTIFIERS = setOf("many", "much")

    private val SUBJECT_PRONOUNS = setOf(
        "i", "you", "we", "they", "he", "she", "it", "there",
        "that", "this", "anyone", "anybody", "someone", "somebody", "everyone",
    )

    /**
     * Longest sentence still short enough for the question test to be worth
     * trusting. Past this a wh-word is far more often opening a noun clause.
     */
    private const val MAX_QUESTION_WORDS = 12

    private fun infer(text: String, punctuation: SentencePunctuation): String {
        val words = split(text)
        if (words.isEmpty()) return text
        splitAtStarters(words, punctuation)
        commaAfterOpeners(words, punctuation)
        commaBeforeConjunctions(words, punctuation)
        markQuestions(words, punctuation)
        return joined(words)
    }

    /**
     * Ends the sentence in front of a discourse marker that has clearly started
     * a new one. Requires a substantial unpunctuated clause behind it and a
     * clause of its own in front, so a marker inside a sentence is left alone.
     */
    private fun splitAtStarters(words: MutableList<Word>, punctuation: SentencePunctuation) {
        var index = 1
        while (index < words.size) {
            val length = match(SENTENCE_STARTERS, words, index)
            // A marker only ends the previous sentence when a clause of its own
            // follows. "The results came back okay and we shipped" is one
            // sentence; "…came back okay lets ship" is two, and the difference
            // is entirely the next word.
            if (length == null ||
                index + length + 2 > words.size ||
                wordsSinceMark(words, index) < 4 ||
                words[index - 1].trailing.isNotEmpty() ||
                words[index - 1].key in ADJECTIVE_PREDECESSORS ||
                !startsClause(words[index + length].key)
            ) {
                index++
                continue
            }
            words[index - 1].trailing = punctuation.terminator
            matchCaseOfSentence(words, index)
            index += length
        }
    }

    /**
     * "Okay we should ship" — the marker opens the sentence and the rest of it
     * follows, which in writing takes a comma.
     */
    private fun commaAfterOpeners(words: MutableList<Word>, punctuation: SentencePunctuation) {
        for (index in words.indices) {
            if (!opensSentence(words, index, punctuation)) continue
            val length = match(OPENERS_TAKING_COMMA, words, index) ?: continue
            if (words[index + length - 1].trailing.isNotEmpty()) continue
            if (index + length + 2 > words.size) continue
            if (words[index + length].key in QUANTIFIER_FOLLOWERS) continue
            words[index + length - 1].trailing = punctuation.separator
        }
    }

    /**
     * "…ship it on Friday but I don't know…" — a conjunction joining two full
     * clauses takes a comma in front of it.
     */
    private fun commaBeforeConjunctions(
        words: MutableList<Word>,
        punctuation: SentencePunctuation,
    ) {
        for (index in words.indices) {
            if (index < 4 || index + 2 >= words.size) continue
            if (words[index].key !in CLAUSE_CONJUNCTIONS) continue
            if (words[index].leading.isNotEmpty() || words[index].trailing.isNotEmpty()) continue
            if (words[index - 1].trailing.isNotEmpty()) continue
            if (wordsSinceMark(words, index) < 4) continue
            val next = words[index + 1].key
            if (next !in CLAUSE_STARTERS || next in PHRASE_FOLLOWERS) continue
            // A determiner is the ambiguous case: "…but the tests are failing"
            // is a clause, "…but the truth" is an object. Only the first has
            // room for a verb after it.
            if (next in DETERMINERS && index + 4 > words.size) continue
            words[index - 1].trailing = punctuation.separator
        }
    }

    /**
     * Puts a question mark on a sentence that asks something. Applies to a
     * sentence with no terminator at all and to one the model closed with a
     * plain full stop; `!` is left alone, because someone chose it.
     */
    private fun markQuestions(words: MutableList<Word>, punctuation: SentencePunctuation) {
        for (sentence in sentences(words, punctuation)) {
            val existing = words[sentence.last].trailing.lastOrNull {
                it in punctuation.terminators
            }
            // A sentence the model closed with `!` was a choice. One it closed
            // with the plain terminator, or did not close at all, was not.
            if (existing != null && existing.toString() != punctuation.terminator) continue
            if (sentence.count() > MAX_QUESTION_WORDS) continue
            if (!isQuestion(words, sentence)) continue
            close(words[sentence.last], punctuation.question, punctuation)
        }
    }

    /**
     * Closes a word with [mark], replacing the terminator it already carries
     * rather than doubling it, and going *inside* any quote or bracket. A
     * question that reached the model in quotes ends `it?"`, never `it."?`.
     */
    private fun close(word: Word, mark: String, punctuation: SentencePunctuation) {
        val existing = word.trailing.indexOfLast { it in punctuation.terminators }
        if (existing >= 0) word.trailing = word.trailing.removeRange(existing, existing + 1)
        val wrapper = word.trailing.indexOfFirst { it in QUOTES || it in ")]}»" }
        val at = if (wrapper >= 0) wrapper else word.trailing.length
        word.trailing = word.trailing.substring(0, at) + mark + word.trailing.substring(at)
    }

    private fun isQuestion(words: List<Word>, sentence: IntRange): Boolean {
        val keys = sentence.map { words[it].key }
        if (keys.size < 2) return false
        if (keys[0] in QUESTION_WORDS) {
            // "What time is it" asks; "What I meant was simple" and "what the
            // problem is remains unclear" state. A question inverts the
            // auxiliary to the front, so it turns up within a word or two of
            // the wh-word; an embedded noun clause puts a whole subject there
            // first and pushes the auxiliary back.
            //
            // Two words of room is the normal allowance. "How many people are
            // coming" has a quantifier and its noun in front of the auxiliary,
            // so it gets one extra explicitly-recognized shape. Reading "what
            // john said was wrong" as a question is not worth that wider rule.
            for (offset in 1 until minOf(keys.size, 3)) {
                if (keys[offset] in SUBJECT_PRONOUNS) return false
                if (keys[offset] in DETERMINERS) return false
                if (keys[offset] in AUXILIARIES) return true
            }
            if (keys.size >= 4 &&
                keys[0] == "how" &&
                keys[1] in HOW_QUANTIFIERS &&
                keys[3] in AUXILIARIES
            ) {
                return true
            }
            return false
        }
        if (keys[0] !in AUXILIARIES || keys[1] !in SUBJECT_PRONOUNS) return false
        // "Had I known" and "Were it up to me" invert the same way a question
        // does; the modal further along is what tells them apart.
        if (keys[0] == "had" || keys[0] == "were") {
            return keys.drop(2).none { it in CONDITIONAL_MODALS }
        }
        return true
    }

    // endregion

    // region Inference helpers

    /** Whether the phrase at [index] is one of [phrases], and how long it is. */
    private fun match(phrases: List<List<String>>, words: List<Word>, index: Int): Int? {
        for (phrase in phrases) {
            if (index + phrase.size > words.size) continue
            if (phrase.withIndex().any { (offset, key) -> words[index + offset].key != key }) {
                continue
            }
            // A mark inside the phrase means it is not being said as one.
            if ((0 until phrase.size - 1).any { words[index + it].trailing.isNotEmpty() }) continue
            return phrase.size
        }
        return null
    }

    /**
     * Whether a clause could start at this word. The question a split has to
     * answer is "is a new sentence beginning here", and a subject, an
     * auxiliary, or a question word is what one begins with.
     */
    private fun startsClause(key: String): Boolean =
        key in CLAUSE_STARTERS || key in AUXILIARIES || key in QUESTION_WORDS ||
            key in CLAUSE_OPENERS

    private fun opensSentence(
        words: List<Word>,
        index: Int,
        punctuation: SentencePunctuation,
    ): Boolean = index == 0 || ends(words[index - 1], punctuation)

    /**
     * How many words back to the last punctuation of any kind. This is the
     * stand-in for "is there a whole clause behind me": a rule that would add a
     * mark four words after the last one is guessing, not repairing.
     */
    private fun wordsSinceMark(words: List<Word>, index: Int): Int {
        var count = 0
        var cursor = index - 1
        while (cursor >= 0) {
            count++
            if (words[cursor].trailing.isNotEmpty()) break
            cursor--
        }
        return count
    }

    private fun sentences(words: List<Word>, punctuation: SentencePunctuation): List<IntRange> {
        val result = mutableListOf<IntRange>()
        var start = 0
        for (index in words.indices) {
            if (!ends(words[index], punctuation)) continue
            result += start..index
            start = index + 1
        }
        if (start < words.size) result += start..words.lastIndex
        return result
    }

    /**
     * Capitalizes a sentence this stage just created, but only when the
     * sentence it was split out of was capitalized too.
     *
     * The alternative — always capitalizing — puts a stray capital in the
     * middle of `clean` style output, which exists to flatten exactly that.
     * Following the text's own convention is right on both routes: a gateway
     * transcript arrives already cased and gets a capital, a raw local one
     * arrives lowercase and is left for [TranscriptStyler] to decide about.
     */
    private fun matchCaseOfSentence(words: MutableList<Word>, index: Int) {
        var cursor = index - 1
        var sentenceStart = index
        while (cursor >= 0) {
            if (words[cursor].trailing.isNotEmpty() && cursor != index - 1) break
            sentenceStart = cursor
            cursor--
        }
        if (!words[sentenceStart].startsUppercase) return
        val text = words[index].text
        val position = text.indexOfFirst { it.isLetter() }
        if (position < 0 || !text[position].isLowerCase()) return
        words[index].text = text.replaceRange(
            position,
            position + 1,
            text[position].uppercaseChar().toString(),
        )
    }

    // endregion
}
