package com.vocahq.vocaphone.writing

import org.json.JSONObject

/**
 * One line of `writing-rules.json`, compiled.
 *
 * A pattern is tokens separated by spaces, matched against consecutive tokens
 * of one sentence: a literal word or mark (case-insensitive, apostrophes
 * straight), alternatives `a|b|c`, a class `{name}` from the file's `classes`
 * or a built-in one, `^` first for "starts the sentence" and `$` last for
 * "nothing but punctuation follows, to the end of the sentence". A rule may
 * also say which word must (`after`, or the sentence start) or must not
 * (`notAfter`) come right before the match, words or marks that must not
 * come right after it (`notBefore`), and words that must not come anywhere
 * after it in the sentence (`unlessLater`); that the sentence is a
 * question (`question`: a "?" follows the match); and openers it must not
 * follow (`notAfterOpening`: the sentence starts with one of these words and
 * no comma comes before the match, as in "After lunch, Sam and Alex"). A
 * class written `{!name}` is any word not in `name`, and `{a&b}` a word in
 * both. A rule with `optIn` runs
 * only when the user turned that option on. A match never takes part of a
 * hyphenated compound ("name" in "name-calling"). A replacement is words and
 * `$n` (the nth matched token as typed) or `${fn:n}` (base, ing, participle,
 * past, third, any, subject, capital). Built-in classes beside the file's:
 * word, same, name, number, clock_time, vowel_sound, consonant_sound,
 * verb_base, verb_inflected, verb_ing, simple_past, participle. Mirrors
 * `WritingRule.swift`.
 */
class WritingRule private constructor(
    val id: String,
    private val elements: List<Element>,
    private val atStart: Boolean,
    private val atEnd: Boolean,
    private val notAtStart: Boolean,
    private val after: Set<String>?,
    private val notAfter: Set<String>,
    private val unlessLater: Set<String>,
    private val notBefore: Set<String>,
    private val question: Boolean,
    private val notAfterOpening: Set<String>,
    val replace: String?,
    val kind: String,
    val message: String?,
    /** The option that turns this rule on ([WritingCheck.Options.optIn]); null runs always. */
    val optIn: String?,
) {
    internal sealed interface Element {
        data class Words(val options: Set<String>) : Element
        data class Class(val name: String) : Element
    }

    /** The words the pattern can start with, or null when it starts with a class. */
    internal val firstWords: Set<String>? get() = (elements.firstOrNull() as? Element.Words)?.options

    /** How many tokens match from [index], or 0. [start]: whether [index] opens the sentence. */
    internal fun match(
        tokens: List<WritingToken>,
        sentence: WritingSentence,
        index: Int,
        rules: WritingRules,
        start: Boolean,
    ): Int {
        if (atStart && !start) return 0
        if (notAtStart && start) return 0
        val before = if (index > sentence.first) tokens[index - 1] else null
        if (before != null && before.key in notAfter) return 0
        if (notAfterOpening.isNotEmpty() && index > sentence.first && tokens[sentence.first].key in notAfterOpening &&
            (sentence.first until index).none { tokens[it].text == "," }
        ) {
            return 0
        }
        if (after != null && !start && (before == null || before.key !in after)) return 0
        if (before != null && isHyphen(before) && before.end == tokens[index].start) return 0
        var i = index
        for (element in elements) {
            if (i > sentence.last) return 0
            val token = tokens[i]
            val previous = if (i > index) tokens[i - 1] else null
            val ok = when (element) {
                is Element.Words -> token.key in element.options
                is Element.Class -> matchesClass(element.name, token, previous, rules)
            }
            if (!ok) return 0
            i++
        }
        if (i <= sentence.last && isHyphen(tokens[i]) && tokens[i - 1].end == tokens[i].start) return 0
        if (atEnd && (i..sentence.last).any { tokens[it].isWord }) return 0
        if (unlessLater.isNotEmpty() && (i..sentence.last).any { tokens[it].key in unlessLater }) return 0
        if (question && (i..sentence.last).none { tokens[it].text == "?" }) return 0
        if (notBefore.isNotEmpty() && i <= sentence.last && tokens[i].key in notBefore) return 0
        return i - index
    }

    private fun isHyphen(token: WritingToken) = token.text in HYPHENS

    private fun matchesClass(name: String, token: WritingToken, previous: WritingToken?, rules: WritingRules): Boolean {
        if (!token.isWord) return false
        if ('&' in name) return name.split('&').all { matchesClass(it, token, previous, rules) }
        if (name.startsWith("!")) return token.hasLetter && !matchesClass(name.substring(1), token, previous, rules)
        val key = token.key
        return when (name) {
            "word" -> token.hasLetter
            "same" -> token.hasLetter && previous != null && previous.key == key &&
                key !in rules.classes["allowed_double"].orEmpty()
            "name" -> token.text.length >= 2 && token.text[0].isUpperCase() && key !in PRONOUN_I &&
                token.text.all { it.isLetter() || it == '\'' || it == '’' }
            "number" -> key.all { it in '0'..'9' }
            "clock_time" -> CLOCK.matches(key)
            "vowel_sound" -> startsWithVowelSound(token, rules) == true
            "consonant_sound" -> startsWithVowelSound(token, rules) == false
            "verb_base" -> rules.verbs.isBase(key)
            "verb_inflected" -> rules.verbs.lemma(key)?.let { it != key } == true
            "verb_ing" -> key.endsWith("ing") && rules.verbs.lemma(key)?.let { it != key } == true
            "simple_past" -> rules.verbs.isSimplePastOnly(key)
            "participle" -> rules.verbs.isParticiple(key)
            else -> key in rules.classes[name].orEmpty()
        }
    }

    /**
     * Whether [token] starts with a vowel sound, for "a" or "an"; null when
     * that cannot be told or the word is not one an article goes before.
     * Short acronyms go by their letters' names ("an FBI", "a URL"), "u" that
     * sounds like "you" and "one" take "a", and a silent "h" takes "an".
     */
    private fun startsWithVowelSound(token: WritingToken, rules: WritingRules): Boolean? {
        val text = token.text
        val key = token.key
        if (key in rules.stopwords || !text.all { it in 'a'..'z' || it in 'A'..'Z' }) return null
        if (text.length == 1) return key[0] in LETTER_NAME_VOWELS
        if (text.all { it in 'A'..'Z' }) return if (text.length <= 3) key[0] in LETTER_NAME_VOWELS else null
        if (SILENT_H.any { key.startsWith(it) }) return true
        if (YOU_SOUND_LONG.none { key.startsWith(it) } && UN_PREFIXED.any { key.startsWith(it) }) return true
        if (key in ONE_SOUND) return false
        if (YOU_SOUND.any { key.startsWith(it) }) return false
        // "u", a consonant, then a vowel is often "you" ("utopia", "utensil")
        // and sometimes not ("umami"): unsure, unless the "un-" of "unable".
        if (key.length >= 3 && key[0] == 'u' && key[1] !in "aeiouy" && key[2] in "aeiouy" && !key.startsWith("un")) return null
        return key[0] in "aeiou"
    }

    /** The replacement for [matched] tokens, or null for an information-only rule. */
    internal fun expand(matched: List<WritingToken>, rules: WritingRules): String? {
        val template = replace ?: return null
        val parts = template.split(' ').filter { it.isNotEmpty() }.map { part ->
            REFERENCE.matchEntire(part)?.let { m ->
                val token = matched[m.groupValues[2].toInt() - 1]
                val fn = m.groupValues[1]
                if (fn.isEmpty()) token.text else apply(fn, token.key, rules)
            } ?: part
        }
        return WritingText.join(parts)
    }

    private fun apply(fn: String, word: String, rules: WritingRules): String {
        val verbs = rules.verbs
        return when (fn) {
            "base" -> verbs.lemma(word) ?: word
            "ing" -> verbs.ing(verbs.lemma(word) ?: word)
            "participle" -> verbs.participle(verbs.lemma(word) ?: word)
            "past" -> verbs.past(verbs.lemma(word) ?: word)
            "third" -> verbs.third(verbs.lemma(word) ?: word)
            "any" -> ANY[word] ?: word
            "subject" -> SUBJECT[word] ?: word
            "capital" -> word.replaceFirstChar(Char::uppercaseChar)
            else -> word
        }
    }

    companion object {
        internal fun compile(o: JSONObject): WritingRule {
            val raw = o.getString("match").split(' ').filter { it.isNotEmpty() }
            val atStart = raw.firstOrNull() == "^"
            val atEnd = raw.lastOrNull() == "$"
            val body = raw.drop(if (atStart) 1 else 0).dropLast(if (atEnd) 1 else 0)
            val elements = body.flatMap { part ->
                when {
                    part.startsWith("{") && part.endsWith("}") -> listOf(Element.Class(part.substring(1, part.length - 1)))
                    '|' in part -> listOf(Element.Words(part.split('|').map(WritingToken::normalize).toSet()))
                    else -> WritingText.tokenize(part).map { Element.Words(setOf(it.key)) }
                }
            }
            return WritingRule(
                id = o.getString("id"),
                elements = elements,
                atStart = atStart,
                atEnd = atEnd,
                notAtStart = o.optBoolean("notAtStart", false),
                after = o.optJSONArray("after")?.let { a -> List(a.length()) { WritingToken.normalize(a.getString(it)) }.toSet() },
                notAfter = o.optJSONArray("notAfter")?.let { a -> List(a.length()) { WritingToken.normalize(a.getString(it)) }.toSet() }
                    .orEmpty(),
                unlessLater = o.optJSONArray("unlessLater")?.let { a -> List(a.length()) { WritingToken.normalize(a.getString(it)) }.toSet() }
                    .orEmpty(),
                notBefore = o.optJSONArray("notBefore")?.let { a -> List(a.length()) { WritingToken.normalize(a.getString(it)) }.toSet() }
                    .orEmpty(),
                question = o.optBoolean("question", false),
                notAfterOpening = o.optJSONArray("notAfterOpening")
                    ?.let { a -> List(a.length()) { WritingToken.normalize(a.getString(it)) }.toSet() }
                    .orEmpty(),
                replace = if (o.isNull("replace")) null else o.getString("replace"),
                kind = o.getString("kind"),
                message = o.optString("message").takeIf { o.has("message") },
                optIn = o.optString("optIn").takeIf { o.has("optIn") },
            )
        }

        private val REFERENCE = Regex("\\$(?:\\{(\\w+):)?(\\d+)\\}?")
        private val HYPHENS = setOf("-", "‐", "‑")
        private val PRONOUN_I = setOf("i", "i'm", "i've", "i'll", "i'd")
        private val ANY = mapOf("nothing" to "anything", "nobody" to "anybody", "nowhere" to "anywhere", "none" to "any", "no" to "any")
        private val SUBJECT = mapOf(
            "me" to "I", "him" to "he", "her" to "she", "us" to "we", "them" to "they",
            // A contraction's subject: "I'm agree" → "I agree".
            "i'm" to "I", "im" to "I", "we're" to "we", "they're" to "they", "you're" to "you", "he's" to "he", "she's" to "she",
        )
        /** Letters whose names start with a vowel sound: "an F", "an MBA". */
        private const val LETTER_NAME_VOWELS = "aefhilmnorsx"
        private val SILENT_H = listOf("hour", "honest", "honor", "honour", "heir")
        /** "un-" before a word that starts "i…": "an unidentified caller", "an unimportant detail". */
        private val UN_PREFIXED = listOf("unid", "unim", "unin", "unil", "unir")
        /** "uni-" words that still sound like "you": "a unidirectional road", "a unilateral decision". */
        private val YOU_SOUND_LONG = listOf("unidirection", "unilateral", "unilingual", "unimodal")
        private val YOU_SOUND = listOf(
            "uni", "use", "usu", "uti", "ure", "uro", "uk", "ufo", "ubiq", "ukulele", "unanim", "uri", "ura",
            "eu", "ewe", "ute", "uto", "uvu",
        )
        /** Words said with a "w": "a one-off", "a once-great team". Whole words, not "onerous". */
        private val ONE_SOUND = setOf("one", "ones", "oneself", "once", "onesie")

        /** "3pm", "11am": a time typed as one word. */
        private val CLOCK = Regex("[0-9]{1,2}(am|pm)")
    }
}
