package com.vocahq.vocaphone.writing

/**
 * The checks that need to know which word is a verb's subject: "The kids
 * plays", "My sister live", "Each of the boys have", "Where is my keys",
 * "I go to the gym yesterday". [PosTagger] finds the finite verbs and the noun
 * phrase before each; closed word lists say whether that subject is singular
 * or plural. The same tags place the comma after an opening clause ("If you
 * need anything, let me know") and the base form after a modal or "to" for
 * any verb ("can sings", "want to goes"). Precision first: a subject that is unusual in any way (a
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
        /** Text typed in lower case on purpose: casual, so no commas are pressed on it. */
        casual: Boolean = false,
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
                subject.number == Number.SINGULAR -> if (verb == Number.PLURAL && !hypothetical(s, v)) toSingular(s, v) else null
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
        out += afterModal(text, s, ::free)
        if (!casual) clauseComma(text, s, ::free)?.let { out += it }
        return out
    }

    // ── the base form after a modal or "to" ──────────────────────────────

    /**
     * "She can sings", "I want to goes", "you should went": a modal or "to",
     * maybe an adverb, then a verb the tagger reads as inflected. The rules
     * already do this for the verbs they list; this reaches every verb the
     * dictionary knows. Not after "to" that is a preposition ("close to
     * leaves"): the word must be tagged a verb.
     */
    private fun afterModal(text: String, s: Tagged, free: (Int) -> Boolean): List<WritingSuggestion> {
        val out = ArrayList<WritingSuggestion>()
        for (v in s.sentence.first + 1..s.sentence.last) {
            val tag = s.tag(v)
            if (tag != "VBZ" && tag != "VBD") continue
            // Past "really" or "not": "can really sings", "should not went".
            var m = v - 1
            if (s.tag(m) in ADVERB_TAGS && s.key(m) != "not" && s.inside(m - 1)) m--
            if (s.key(m) == "not" && s.inside(m - 1)) m--
            if (s.tag(m) != "MD" && !(s.key(m) == "to" && s.tag(m) == "TO")) continue
            if (!free(v)) continue
            val key = s.key(v)
            val base = when (tag) {
                "VBZ" -> baseOf(key)
                else -> rules.verbs.lemma(key)?.takeIf { it != key } ?: pastBase(key)
            } ?: continue
            if (base == key) continue
            // "to" is also a preposition ("allergic to peanuts"): after it, only a verb the tables know.
            if (s.tag(m) == "TO" && !rules.verbs.isBase(base)) continue
            out += suggestion(
                text, s, v, base, kind = "verb_form",
                message = rules.messages["verb_form.after"] ?: rules.kind("verb_form").message,
                values = mapOf("previous" to s.tokens[v - 1].text),
                rule = "base-after-modal",
            )
        }
        return out
    }

    /** The base of a regular past ("walked" → "walk"), when the dictionary knows it and it makes that past. */
    private fun pastBase(past: String): String? {
        val dictionary = spelling ?: return null
        if (!past.endsWith("ed")) return null
        val candidates = listOf(past.dropLast(2), past.dropLast(1), past.dropLast(3), past.dropLast(3) + "y")
        return candidates.firstOrNull { it.length >= 2 && dictionary.isKnown(it) && rules.verbs.past(it) == past }
    }

    // ── a comma after an opening clause ──────────────────────────────────

    /**
     * "If you need anything let me know", "When I get home I'll call": a
     * sentence that opens with "if", "when" and the like, has a subject and a
     * verb, and then starts its main clause with a subject or an order, wants
     * a comma between the two. Only where nothing else could be meant: no
     * comma anywhere in the sentence yet, the word before the boundary ends a
     * phrase (a noun, an object pronoun, an adverb, a particle), and a verb
     * follows the boundary.
     */
    private fun clauseComma(text: String, s: Tagged, free: (Int) -> Boolean): WritingSuggestion? {
        val first = s.sentence.first
        if (s.key(first) !in OPENING_CLAUSES) return null
        if ((first..s.sentence.last).any { s.tokens[it].text in CLAUSE_PUNCTUATION }) return null
        if (!s.inside(first + 1) || !(s.tag(first + 1) in SUBJECT_TAGS || s.key(first + 1) in SUBJECT_WORDS)) return null
        var verbSeen = false
        for (i in first + 2..s.sentence.last) {
            val tag = s.tag(i)
            val verbAfter = s.tag(i).startsWith("VB") ||
                (i + 1..minOf(s.sentence.last, i + 3)).any { s.tag(it).startsWith("VB") || s.tag(it) == "MD" }
            // "If you can go then go": "then" opens the main clause, whatever comes before it,
            // unless it ends a phrase of its own ("by then", "until then").
            val then = s.key(i) == "then" && !thenEndsPhrase(s, i)
            if (verbSeen && i - 1 > first + 1 && (then || (startsMainClause(s, i) && endsPhrase(s, i - 1) && verbAfter))) {
                if (!free(i - 1)) return null
                val k = rules.kind("comma")
                val anchor = s.tokens[i - 1]
                val edit = WritingEdits.build(text, s.tokens, first, i, i, ",")
                return WritingSuggestion(
                    start = edit.start, end = edit.end, original = text.substring(edit.start, edit.end),
                    replacement = edit.replacement, markStart = edit.markStart, markEnd = edit.markEnd,
                    kind = k.id, category = k.category, title = k.title,
                    message = WritingEdits.format(
                        "Add a comma after the opening “{opening} …” part, before “{next}”.",
                        mapOf("opening" to s.tokens[first].text, "next" to s.tokens[i].text, "previous" to anchor.text),
                    ),
                    mechanical = false, source = WritingSuggestion.Source.RULE, rule = "comma-clause",
                )
            }
            if (tag.startsWith("VB") || tag == "MD") verbSeen = true
        }
        return null
    }

    /** A main clause can start at [i]: a subject pronoun, or an order ("let", "call", "please"). */
    private fun startsMainClause(s: Tagged, i: Int): Boolean {
        val key = s.key(i)
        return key in MAIN_CLAUSE_SUBJECTS || (s.tag(i) == "VB" && key in ORDERS) || key == "please" ||
            key in CONTRACTED_SUBJECTS
    }

    /** The word at [i] can end the opening clause: not a word that needs something after it. */
    private fun endsPhrase(s: Tagged, i: Int): Boolean {
        val tag = s.tag(i)
        return (tag in PHRASE_END_TAGS || s.key(i) in OBJECT_PRONOUNS) && s.key(i) !in SUBJECT_WORDS &&
            (s.key(i) != "then" || thenEndsPhrase(s, i))
    }

    /** "by then", "until then": "then" after a preposition is a time, not the start of the main clause. */
    private fun thenEndsPhrase(s: Tagged, i: Int): Boolean = s.inside(i - 1) && s.key(i - 1) in BEFORE_THEN

    // ── the verb ─────────────────────────────────────────────────────────

    /** "If she were here", "I wish he were": "were" with a singular subject, after a word that makes it hypothetical. */
    private fun hypothetical(s: Tagged, v: Int): Boolean =
        s.key(v) in HYPOTHETICAL_FORMS && (s.sentence.first until v).any { s.key(it) in HYPOTHETICAL_CUES }

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
            // "my mom and dad", "Sam and I". Not owners joined before the head:
            // in "my mom and dad's car is", the subject is the one car.
            if (s.inside(start - 2) && s.key(start - 1) == "and" && s.tag(start - 1) == "CC" && nounish(s, start - 2) &&
                !possessed(s, start, head)
            ) {
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

    /** Whether a possessive ("dad's") comes in `[start, head)`: the phrase from [start] owns the head. */
    private fun possessed(s: Tagged, start: Int, head: Int): Boolean =
        (start until head).any { s.tag(it).endsWith("+POS") || s.key(it).endsWith("'s") || s.key(it).endsWith("s'") }

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
        // "better than yesterday", "the same as yesterday": a comparison, not when it happened.
        // Past the amount of "two days ago" to what comes before it.
        var before = markerStart - 1
        if (s.key(last) == "ago") {
            var k = 0
            while (k < 2 && s.inside(before) && (s.tag(before) in AGO_AMOUNT_TAGS)) {
                before--
                k++
            }
        }
        if (s.inside(before) && s.key(before) in BEFORE_TIME_COMPARED) return null
        if ((s.sentence.first until markerStart).any { s.key(it) in NOT_SIMPLE_PAST }) return null
        val verbs = (s.sentence.first until markerStart).filter { verbNumber(s, it) != null }
        val v = verbs.singleOrNull() ?: return null
        // Another verb may be the one the time is about: "I think she went yesterday".
        if ((s.sentence.first until markerStart).any { it != v && s.tag(it) in FINITE_TAGS }) return null
        if (!free(v)) return null
        val key = s.key(v)
        // "I lay on the couch yesterday": "lay" is also the past of "lie".
        if (key in rules.classes["past_too"].orEmpty()) return null
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
        val BEFORE_TIME_COMPARED = setOf(
            "than", "as", "like", "unlike", "from", "of", "about", "versus", "vs", "to", "with", "over",
        )
        val AGO_AMOUNT_TAGS = setOf("CD", "DT", "NN", "NNS")
        val NOT_SIMPLE_PAST = setOf("since", "will", "won't", "every", "usually", "always", "often", "sometimes", "until", "if")
        val PERFECT_AUXILIARIES = setOf("have", "has")
        val FINITE_TAGS = setOf("VBD", "VBP", "VBZ", "MD")
        val HYPOTHETICAL_FORMS = setOf("were", "weren't")
        val HYPOTHETICAL_CUES = setOf("if", "wish", "wished", "wishes", "though", "suppose", "supposing", "imagine", "rather", "unless")
        val OPENING_CLAUSES = setOf(
            "if", "when", "whenever", "although", "though", "while", "once", "after", "before", "unless", "until", "because",
        )
        val SUBJECT_TAGS = setOf("PRP", "DT", "NN", "NNS", "NNP", "NNPS", "PRP$")
        val SUBJECT_WORDS = setOf("i", "you", "he", "she", "we", "they", "it")
        val MAIN_CLAUSE_SUBJECTS = setOf("i", "you", "he", "she", "we", "they")
        val CONTRACTED_SUBJECTS = setOf(
            "i'll", "i'm", "i've", "i'd", "you'll", "you're", "we'll", "we're", "they'll", "they're",
            "he'll", "she'll", "it'll", "let's", "lets",
        )
        val ORDERS = setOf(
            "let", "call", "text", "send", "tell", "give", "feel", "make", "check", "come", "bring", "take",
            "remember", "ask", "try", "keep", "stop", "go", "wait", "email", "ping", "message",
        )
        val PHRASE_END_TAGS = setOf("NN", "NNS", "NNP", "NNPS", "RB", "RP", "CD", "JJ", "VBN")
        val BEFORE_THEN = setOf("by", "until", "till", "since", "from", "before", "after", "around")
    }
}
