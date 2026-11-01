package com.vocahq.vocaphone.writing

/**
 * The checks that need to know which word is a verb's subject: "The kids
 * plays", "My sister live", "Each of the boys have", "Where is my keys",
 * "I go to the gym yesterday". [PosTagger] finds the finite verbs and the noun
 * phrase before each; closed word lists say whether that subject is singular
 * or plural. Precision first: a subject that is unusual in any way (a
 * collective noun, a relative clause, a name ending in "s", a quantifier
 * without "of") leaves its verb alone. Mirrors `WritingAgreement.swift`.
 */
internal class WritingAgreement(
    private val rules: WritingRules,
    private val tagger: PosTagger,
    private val spelling: WritingSpelling?,
) {
    private enum class Number { SINGULAR, PLURAL, FIRST }

    /** The subject's head word, its number, and how a message names it ("mom and dad"). */
    private class Subject(val head: Int, val number: Number, val label: String)

    /** The tokens of one sentence with their tags. */
    private class Tagged(val tokens: List<WritingToken>, val sentence: WritingSentence, private val tags: List<String>) {
        fun tag(i: Int): String = tags[i - sentence.first]
        fun key(i: Int): String = tokens[i].key
        fun inside(i: Int) = i >= sentence.first && i <= sentence.last
    }

    fun suggestions(
        text: String,
        tokens: List<WritingToken>,
        sentence: WritingSentence,
        protected: List<IntRange>,
        keep: Set<String>,
        fixed: List<WritingSuggestion>,
    ): List<WritingSuggestion> {
        val s = Tagged(tokens, sentence, tagger.tag((sentence.first..sentence.last).map { tokens[it].text }))
        val out = ArrayList<WritingSuggestion>()
        fun free(i: Int): Boolean {
            val t = tokens[i]
            return t.key !in keep && protected.none { t.start <= it.last && it.first < t.end } &&
                fixed.none { it.start < t.end && t.start < it.end }
        }
        for (v in sentence.first..sentence.last) {
            if (!tokens[v].isWord || !free(v)) continue
            val verb = verbNumber(s, v) ?: continue
            val there = inverted(s, v)
            val subject = there ?: subject(s, v) ?: continue
            if (!free(subject.head)) continue
            val replacement = when {
                subject.number == verb -> null
                subject.number == Number.FIRST -> toFirst(s, v)
                subject.number == Number.SINGULAR -> if (verb == Number.PLURAL) toSingular(s, v) else null
                else -> if (verb == Number.SINGULAR) toPlural(s, v) else null
            } ?: continue
            out += suggestion(
                text, s, v, replacement, kind = "agreement",
                message = rules.messages["agreement.subject"] ?: rules.kind("agreement").message,
                values = mapOf("subject" to subject.label),
                rule = if (there != null) "agreement-there" else "agreement-subject",
            )
        }
        pastTime(text, s, ::free)?.let { out += it }
        return out
    }

    // ── the verb ─────────────────────────────────────────────────────────

    /** Whether token [v] is a present (or "was"/"were") verb that agrees, and how. */
    private fun verbNumber(s: Tagged, v: Int): Number? {
        val key = s.key(v)
        val tag = s.tag(v)
        if (!tag.startsWith("VB") || tag == "VB" || tag == "VBN" || tag == "VBG") return null
        return when {
            key == "am" -> Number.FIRST
            key in SINGULAR_FORMS -> Number.SINGULAR
            key in PLURAL_FORMS -> Number.PLURAL
            tag == "VBZ" && key.endsWith("s") -> Number.SINGULAR
            tag == "VBP" -> Number.PLURAL
            else -> null
        }
    }

    private fun toSingular(s: Tagged, v: Int): String? {
        val key = s.key(v)
        SINGULAR_OF[key]?.let { return it }
        if (s.tag(v) != "VBP" || !isVerbBase(key)) return null
        return rules.verbs.third(key)
    }

    private fun toPlural(s: Tagged, v: Int): String? {
        val key = s.key(v)
        PLURAL_OF[key]?.let { return it }
        if (s.tag(v) != "VBZ") return null
        return baseOf(key)
    }

    /** "I goes" → "go", "I is" → "am". */
    private fun toFirst(s: Tagged, v: Int): String? {
        val key = s.key(v)
        if (key in FIRST_OF) return FIRST_OF[key]
        if (s.tag(v) != "VBZ") return null
        return baseOf(key)
    }

    private fun isVerbBase(word: String): Boolean = rules.verbs.isBase(word) ||
        (spelling != null && spelling.isKnown(word) && spelling.isKnown(rules.verbs.third(word)))

    /** The base of a third-person form: from the verb tables, or else the stem the dictionary knows. */
    private fun baseOf(third: String): String? {
        rules.verbs.lemma(third)?.let { if (it != third) return it }
        val dictionary = spelling ?: return null
        val candidates = when {
            third.endsWith("ies") -> listOf(third.dropLast(3) + "y")
            third.endsWith("es") -> listOf(third.dropLast(2), third.dropLast(1))
            third.endsWith("s") && !third.endsWith("ss") -> listOf(third.dropLast(1))
            else -> emptyList()
        }
        return candidates.firstOrNull { it.length >= 2 && dictionary.isKnown(it) && rules.verbs.third(it) == third }
    }

    // ── the subject ──────────────────────────────────────────────────────

    /**
     * The subject of verb [v]: the noun phrase right before it (past an
     * adverb or two), through "of …" and other prepositional phrases to their
     * head ("the price of the tickets"), with "X and Y" plural, and only where
     * that phrase starts a clause.
     */
    private fun subject(s: Tagged, v: Int): Subject? {
        var j = v - 1
        var skipped = 0
        while (s.inside(j) && s.tag(j) in ADVERB_TAGS && s.key(j) !in THERE_HERE && skipped < 2) {
            j--
            skipped++
        }
        if (!s.inside(j) || !nounish(s, j)) return null
        var head = j
        var label = s.tokens[j].text
        var number = headNumber(s, j)
        var start = phraseStart(s, j)
        var hops = 0
        while (true) {
            // "my mom and dad", "Sam and I"
            if (s.inside(start - 2) && s.key(start - 1) == "and" && s.tag(start - 1) == "CC" && nounish(s, start - 2)) {
                val left = phraseStart(s, start - 2)
                if (s.key(left) in EACH_EVERY) return null
                number = Number.PLURAL
                label = s.tokens[start - 2].text + " and " + label
                start = left
            }
            val preposition = start - 1
            if (!s.inside(preposition - 1) || s.key(preposition) !in PP_PREPOSITIONS || hops >= 3) break
            val left = preposition - 1
            if (!nounish(s, left)) return null
            // "most of the cake is", "a lot of people are": the number, and the name, are the object's.
            if (!(s.key(preposition) == "of" && s.key(left) in FROM_OBJECT)) {
                number = headNumber(s, left)
                head = left
                label = s.tokens[left].text
            }
            start = phraseStart(s, left)
            hops++
        }
        if (number == null || !opensClause(s, start)) return null
        return Subject(head, number, label)
    }

    /** "There is two cars", "Where is my keys": the noun after the verb decides. */
    private fun inverted(s: Tagged, v: Int): Subject? {
        if (s.key(v) != "is" && s.key(v) != "was") return null
        val before = v - 1
        if (!s.inside(before) || s.key(before) !in THERE_HERE_WHERE) return null
        if (!WritingText.isSentenceStart(s.tokens, s.sentence, before) && !opensClause(s, before)) return null
        var k = v + 1
        while (s.inside(k) && (s.tag(k) in NOUN_MODIFIER_TAGS || s.tag(k) in ADVERB_TAGS)) {
            if (s.key(k) in SINGULAR_DETERMINERS) return null
            k++
        }
        if (!s.inside(k) || s.tag(k) !in PLURAL_NOUN_TAGS || s.key(k) in SINGULAR_S || s.key(k) in UNSURE_S) return null
        return Subject(k, Number.PLURAL, s.tokens[k].text)
    }

    private fun nounish(s: Tagged, i: Int): Boolean {
        val tag = s.tag(i)
        val key = s.key(i)
        return tag in NOUN_TAGS || key in PRONOUN_NUMBER || key in SINGULAR_WORDS || key in PLURAL_WORDS ||
            key in FROM_OBJECT || (tag == "CD" && key.any(Char::isLetter))
    }

    /** Whether the noun at [i] is singular or plural, or null when that is not certain. */
    private fun headNumber(s: Tagged, i: Int): Number? {
        val key = s.key(i)
        // "Who'd", "that's": a contraction is not a noun, whatever the tagger thinks.
        if ('\'' in key && !s.tag(i).endsWith("+POS")) return null
        PRONOUN_NUMBER[key]?.let { return it }
        if (key in OBJECT_PRONOUNS) return null
        if (key in SINGULAR_WORDS) return Number.SINGULAR
        if (key in PLURAL_WORDS) return Number.PLURAL
        if (key in FROM_OBJECT || key in UNSURE) return null
        return when (s.tag(i)) {
            "CD" -> if (key == "one") Number.SINGULAR else Number.PLURAL
            "NNS", "NNPS" -> when {
                key in SINGULAR_S -> Number.SINGULAR
                key in UNSURE_S -> null
                // "Ten dollars is too much": an amount is one thing.
                key in UNITS && s.inside(i - 1) && s.tag(i - 1) in AMOUNT_TAGS -> null
                else -> Number.PLURAL
            }
            // A singular noun ending in "s" ("docs") is more likely a plural the tagger missed.
            "NN" -> if (key.endsWith("s") && !key.endsWith("ss") && !key.endsWith("us") && !key.endsWith("is")) null else Number.SINGULAR
            "NNP" -> if (key.endsWith("s")) null else Number.SINGULAR
            else -> null
        }
    }

    /** The first word of the noun phrase whose head is [head]: back over determiners, adjectives and nouns. */
    private fun phraseStart(s: Tagged, head: Int): Int {
        var i = head
        while (s.inside(i - 1) && s.tag(i - 1) in NOUN_MODIFIER_TAGS && s.key(i - 1) !in STOP_PHRASE) i--
        return i
    }

    /** Whether a clause can start at [start]: the sentence start, after a comma or a conjunction, or after "I think". */
    private fun opensClause(s: Tagged, start: Int): Boolean {
        if (WritingText.isSentenceStart(s.tokens, s.sentence, start)) return true
        val p = start - 1
        val key = s.key(p)
        return when {
            s.tokens[p].text in CLAUSE_PUNCTUATION -> true
            s.tag(p) == "CC" -> true
            key in SUBORDINATORS || key in CLAUSE_VERBS -> true
            // "Today the kids plays", "Now my sister live"
            WritingText.isSentenceStart(s.tokens, s.sentence, p) && s.tag(p) in OPENING_TAGS -> true
            else -> false
        }
    }

    // ── a time in the past, said in the present ──────────────────────────

    /**
     * "I go to the gym yesterday": a sentence that ends on a past time and
     * has one present verb, with its subject, gets that verb in the past.
     * Not the present perfect ("since yesterday", "have been"), which is right.
     */
    private fun pastTime(text: String, s: Tagged, free: (Int) -> Boolean): WritingSuggestion? {
        var last = s.sentence.last
        while (s.inside(last) && !s.tokens[last].isWord) last--
        if (!s.inside(last)) return null
        val marker = when {
            s.key(last) == "yesterday" -> 1
            s.key(last) == "ago" -> 1
            s.inside(last - 1) && s.key(last - 1) == "last" && s.key(last) in PAST_UNITS -> 2
            else -> return null
        }
        val markerStart = last - marker + 1
        if ((s.sentence.first until markerStart).any { s.key(it) in NOT_SIMPLE_PAST }) return null
        val verbs = (s.sentence.first until markerStart).filter { verbNumber(s, it) != null }
        val v = verbs.singleOrNull() ?: return null
        if (!free(v)) return null
        val key = s.key(v)
        if (key in PERFECT_AUXILIARIES && s.inside(v + 1) && (s.tag(v + 1) == "VBN" || s.key(v + 1) == "been")) return null
        if (subject(s, v) == null) return null
        val past = PAST_OF[key] ?: when (s.tag(v)) {
            "VBP" -> if (isVerbBase(key)) rules.verbs.past(key) else null
            "VBZ" -> baseOf(key)?.let { rules.verbs.past(it) }
            else -> null
        } ?: return null
        if (past == key) return null
        val phrase = (markerStart..last).joinToString(" ") { s.tokens[it].text }
        return suggestion(
            text, s, v, past, kind = "verb_form",
            message = "“{marker}” is in the past, so use “{replacement}”.",
            values = mapOf("marker" to phrase),
            rule = "tense-past-time",
        )
    }

    private fun suggestion(
        text: String,
        s: Tagged,
        v: Int,
        replacement: String,
        kind: String,
        message: String,
        values: Map<String, String>,
        rule: String,
    ): WritingSuggestion {
        val k = rules.kind(kind)
        val typed = s.tokens[v].text
        val shown = if (typed.firstOrNull()?.isUpperCase() == true) replacement.replaceFirstChar(Char::uppercaseChar) else replacement
        val edit = WritingEdits.build(text, s.tokens, s.sentence.first, v, v + 1, shown)
        val all = values + mapOf("original" to typed, "replacement" to shown)
        return WritingSuggestion(
            start = edit.start, end = edit.end, original = text.substring(edit.start, edit.end),
            replacement = edit.replacement, markStart = edit.markStart, markEnd = edit.markEnd,
            kind = k.id, category = k.category, title = k.title,
            message = WritingEdits.format(message, all),
            mechanical = k.mechanical, source = WritingSuggestion.Source.RULE, rule = rule,
        )
    }

    private companion object {
        val ADVERB_TAGS = setOf("RB", "RBR", "RBS")
        val NOUN_TAGS = setOf("NN", "NNS", "NNP", "NNPS", "PRP")
        val PLURAL_NOUN_TAGS = setOf("NNS", "NNPS")
        val AMOUNT_TAGS = setOf("CD", "$", "DT")
        /** Units an amount is counted in: "ten dollars is", "five miles is". */
        val UNITS = setOf(
            "dollars", "bucks", "cents", "euros", "pounds", "pence", "rupees", "yen", "miles", "kilometers",
            "kilometres", "km", "meters", "metres", "feet", "inches", "yards", "hours", "minutes", "seconds",
            "days", "weeks", "months", "years", "percent", "kilos", "kilograms", "grams", "liters", "litres", "gallons",
        )
        val NOUN_MODIFIER_TAGS = setOf(
            "DT", "PDT", "PRP$", "JJ", "JJR", "JJS", "CD", "NN", "NNP", "HYPH",
            "NN+POS", "NNP+POS", "NNS+POS", "NNPS+POS",
        )
        val OPENING_TAGS = setOf("RB", "NN", "NNP", "UH")
        val CLAUSE_PUNCTUATION = setOf(",", ";", ":", "—", "–")
        val THERE_HERE = setOf("there", "here")
        val THERE_HERE_WHERE = setOf("there", "here", "where")
        val STOP_PHRASE = setOf("and", "or", "but", "nor", "than")
        val SINGULAR_DETERMINERS = setOf("a", "an", "one", "each", "every", "this", "that", "another")

        val SINGULAR_FORMS = setOf("is", "was", "has", "does", "doesn't", "isn't", "wasn't", "hasn't")
        val PLURAL_FORMS = setOf("are", "were", "have", "do", "don't", "aren't", "weren't", "haven't")
        val SINGULAR_OF = mapOf(
            "are" to "is", "were" to "was", "have" to "has", "do" to "does",
            "don't" to "doesn't", "aren't" to "isn't", "weren't" to "wasn't", "haven't" to "hasn't",
        )
        val PLURAL_OF = mapOf(
            "is" to "are", "was" to "were", "has" to "have", "does" to "do",
            "doesn't" to "don't", "isn't" to "aren't", "wasn't" to "weren't", "hasn't" to "haven't",
        )
        /** "I" with a singular form: what it takes instead. Null is "leave it": "I were" may be "if I were". */
        val FIRST_OF = mapOf(
            "is" to "am", "has" to "have", "does" to "do", "doesn't" to "don't", "hasn't" to "haven't",
            "are" to "am", "isn't" to null, "aren't" to null, "were" to null, "weren't" to null, "was" to null,
            "wasn't" to null, "have" to null, "do" to null, "don't" to null, "haven't" to null,
        )
        val PAST_OF = mapOf(
            "am" to "was", "is" to "was", "are" to "were", "has" to "had", "have" to "had", "do" to "did", "does" to "did",
            "don't" to "didn't", "doesn't" to "didn't", "isn't" to "wasn't", "aren't" to "weren't",
            "was" to "was", "were" to "were", "wasn't" to "wasn't", "weren't" to "weren't",
        )

        val PRONOUN_NUMBER = mapOf(
            "i" to Number.FIRST, "you" to Number.PLURAL, "we" to Number.PLURAL, "they" to Number.PLURAL,
            "he" to Number.SINGULAR, "she" to Number.SINGULAR, "it" to Number.SINGULAR,
        )
        val OBJECT_PRONOUNS = setOf("me", "him", "her", "us", "them")
        val SINGULAR_WORDS = setOf(
            "everyone", "everybody", "someone", "somebody", "anyone", "anybody", "nobody", "everything",
            "something", "anything", "nothing", "each", "one", "either", "neither", "another", "this", "that",
        )
        val PLURAL_WORDS = setOf("these", "those", "both", "few", "many", "several", "people", "police")
        /** Quantifiers whose number is their object's: "most of the cake is", "most of the kids are". */
        val FROM_OBJECT = setOf("all", "some", "most", "none", "half", "any", "lot", "lots", "plenty", "rest", "majority", "part", "percent")
        val EACH_EVERY = setOf("each", "every")
        /** Nouns that take either number, or whose number depends on what is meant. */
        val UNSURE = setOf(
            "team", "staff", "family", "group", "government", "company", "crew", "audience", "committee", "couple",
            "class", "band", "data", "media", "number", "total", "pair", "jury", "public",
            "management", "board", "faculty", "army", "personnel", "who", "which", "what", "that",
        )
        val SINGULAR_S = setOf(
            "news", "physics", "mathematics", "maths", "economics", "athletics", "ethics", "gymnastics",
            "linguistics", "measles", "diabetes", "electronics", "genetics", "aerobics",
        )
        val UNSURE_S = setOf("series", "species", "means", "headquarters", "politics", "statistics", "crossroads", "whereabouts", "thanks", "glasses", "pants", "scissors")
        val PP_PREPOSITIONS = setOf(
            "of", "in", "on", "at", "with", "for", "from", "near", "behind", "by", "about", "under", "over",
            "between", "among", "without", "inside", "outside", "around", "like", "across", "beside",
        )
        val SUBORDINATORS = setOf(
            "because", "if", "when", "whenever", "although", "though", "while", "since", "unless", "until",
            "after", "before", "once", "that", "so", "whether", "cause", "cuz", "coz",
        )
        val CLAUSE_VERBS = setOf(
            "think", "thought", "know", "knew", "guess", "hope", "believe", "say", "said", "says", "feel", "felt",
            "mean", "heard", "hear", "see", "saw", "bet", "swear", "noticed", "notice", "realize", "realized",
            "realise", "realised", "figure", "suppose", "reckon", "wish",
        )
        val PAST_UNITS = setOf(
            "night", "week", "month", "year", "weekend", "summer", "winter", "spring", "fall", "autumn", "time",
            "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        )
        /** Words that make a sentence with a past time something other than a simple past. */
        val NOT_SIMPLE_PAST = setOf("since", "will", "won't", "every", "usually", "always", "often", "sometimes", "until", "if")
        val PERFECT_AUXILIARIES = setOf("have", "has")
    }
}
