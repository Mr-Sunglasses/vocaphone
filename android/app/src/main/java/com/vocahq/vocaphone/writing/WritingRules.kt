package com.vocahq.vocaphone.writing

import org.json.JSONArray
import org.json.JSONObject

/** Grammarly's four groups: red, blue, green, purple. */
enum class WritingCategory(val id: String) {
    CORRECTNESS("correctness"),
    CLARITY("clarity"),
    ENGAGEMENT("engagement"),
    DELIVERY("delivery"),
    ;

    companion object {
        fun of(id: String): WritingCategory = entries.firstOrNull { it.id == id } ?: CORRECTNESS
    }
}

/**
 * `assets/keyboard/writing-rules.json`, parsed: the kinds of suggestion and
 * their messages, the word tables, the rules and the tone lexicon. Parsing
 * costs a few milliseconds, so callers build one off the main thread and keep
 * it. Mirrors `ios/VocaPhoneShared/Writing/WritingRules.swift`.
 */
class WritingRules private constructor(json: JSONObject) {
    data class Kind(val id: String, val category: WritingCategory, val title: String, val mechanical: Boolean, val message: String)

    data class Tone(val id: String, val label: String, val emoji: String, val words: Set<String>, val phrases: List<String>)

    val kinds: Map<String, Kind>
    val messages: Map<String, String>
    val glosses: Map<String, String>
    private val confusionSet: Map<String, Int>
    val subjectPronouns: Set<String>
    val objectPronouns: Set<String>
    val articles: Set<String>
    val prepositions: Set<String>
    val determiners: Set<String>
    val stopwords: Set<String>
    val verbs: Verbs
    val classes: Map<String, Set<String>>
    val rules: List<WritingRule>
    /** Rule indices by the word their pattern starts with, so a token is tried against only those. */
    internal val rulesByFirstWord: Map<String, IntArray>
    /** Rule indices whose pattern starts with a class: tried at every token. */
    internal val rulesStartingWithClass: IntArray
    val tones: List<Tone>
    val toneMinimumCharacters: Int
    val toneMinimumScore: Int
    val readingWordsPerMinute: Int
    val speakingWordsPerMinute: Int
    val longSentenceWords: Int
    val overusedWordCount: Int
    val scoreWeights: Map<WritingCategory, Double>
    val scoreMinimumWords: Int

    init {
        kinds = json.getJSONObject("kinds").let { o ->
            o.keys().asSequence().associateWith { id ->
                val k = o.getJSONObject(id)
                Kind(id, WritingCategory.of(k.getString("category")), k.getString("title"), k.getBoolean("mechanical"), k.getString("message"))
            }
        }
        messages = json.getJSONObject("messages").strings()
        glosses = json.getJSONObject("glosses").strings()
        confusionSet = HashMap<String, Int>().also { map ->
            json.getJSONArray("confusions").forEachArray { i, set -> set.stringList().forEach { map[it] = i } }
        }
        json.getJSONObject("pronouns").let {
            subjectPronouns = it.getJSONArray("subject").stringList().toSet()
            objectPronouns = it.getJSONArray("object").stringList().toSet()
        }
        articles = json.getJSONArray("articles").stringList().toSet()
        prepositions = json.getJSONArray("prepositions").stringList().toSet()
        determiners = json.getJSONArray("determiners").stringList().toSet()
        stopwords = json.getJSONArray("stopwords").stringList().toSet()
        verbs = Verbs(
            json.getJSONArray("verbs").stringList(),
            json.getJSONArray("irregularVerbs").let { a -> List(a.length()) { i -> a.getJSONArray(i).let { r -> List(r.length()) { j -> if (r.isNull(j)) null else r.getString(j) } } } },
        )
        classes = json.getJSONObject("classes").let { o ->
            o.keys().asSequence().associateWith { o.getJSONArray(it).stringList().map(WritingToken::normalize).toSet() }
        }
        rules = json.getJSONArray("rules").let { a -> List(a.length()) { WritingRule.compile(a.getJSONObject(it)) } }
        val byWord = HashMap<String, MutableList<Int>>()
        val byClass = ArrayList<Int>()
        rules.forEachIndexed { i, rule ->
            val words = rule.firstWords
            if (words == null) byClass.add(i) else words.forEach { byWord.getOrPut(it) { ArrayList() }.add(i) }
        }
        rulesByFirstWord = byWord.mapValues { it.value.toIntArray() }
        rulesStartingWithClass = byClass.toIntArray()
        json.getJSONObject("tone").let { t ->
            toneMinimumCharacters = t.getInt("minimumCharacters")
            toneMinimumScore = t.getInt("minimumScore")
            tones = t.getJSONArray("tones").let { a ->
                List(a.length()) { i ->
                    val o = a.getJSONObject(i)
                    Tone(o.getString("id"), o.getString("label"), o.getString("emoji"), o.getJSONArray("words").stringList().toSet(), o.getJSONArray("phrases").stringList())
                }
            }
        }
        json.getJSONObject("readability").let {
            readingWordsPerMinute = it.getInt("wordsPerMinuteReading")
            speakingWordsPerMinute = it.getInt("wordsPerMinuteSpeaking")
            longSentenceWords = it.getInt("longSentenceWords")
            overusedWordCount = it.getInt("overusedWordCount")
        }
        json.getJSONObject("score").let { s ->
            val w = s.getJSONObject("weights")
            scoreWeights = WritingCategory.entries.associateWith { w.optDouble(it.id, 1.0) }
            scoreMinimumWords = s.getInt("minimumWords")
        }
    }

    fun kind(id: String): Kind = kinds[id] ?: kinds.getValue("word_choice")

    /** Whether [a] and [b] are in one confusion set ("their", "there", "they're"). */
    fun confusable(a: String, b: String): Boolean {
        val x = confusionSet[a] ?: return false
        return x == confusionSet[b]
    }

    companion object {
        fun parse(json: String) = WritingRules(JSONObject(json))

        private fun JSONObject.strings(): Map<String, String> = keys().asSequence().associateWith { getString(it) }

        private fun JSONArray.stringList(): List<String> = List(length()) { getString(it) }

        private inline fun JSONArray.forEachArray(block: (Int, JSONArray) -> Unit) {
            for (i in 0 until length()) block(i, getJSONArray(i))
        }
    }
}

/**
 * Verb forms from a list of regular verbs and a table of irregular ones, enough
 * to tell "sings" from "sing" and to write "seeing" from "see". Nothing here
 * guesses at a word that is in neither list. Mirrors `Verbs.swift`.
 */
class Verbs(regular: List<String>, irregular: List<List<String?>>) {
    private val bases = HashSet<String>()
    /** Every irregular form to its base; a word that is itself a base maps to itself. */
    private val irregularBase = HashMap<String, String>()
    private val irregularPast = HashMap<String, String>()
    private val irregularParticiple = HashMap<String, String>()
    private val irregularThird = HashMap<String, String>()
    private val irregularIng = HashMap<String, String>()
    private val participles = HashSet<String>()
    private val pastOnly = HashSet<String>()

    init {
        bases.addAll(regular)
        irregular.forEach { row -> bases.add(row[0]!!) }
        irregular.forEach { row ->
            val base = row[0]!!
            val past = row[1]!!
            val participle = row[2]!!
            irregularPast[base] = past
            irregularParticiple[base] = participle
            row.getOrNull(3)?.let { irregularThird[base] = it }
            row.getOrNull(4)?.let { irregularIng[base] = it }
            listOfNotNull(past, participle, row.getOrNull(3), row.getOrNull(4)).forEach { form ->
                if (form !in bases && form !in irregularBase) irregularBase[form] = base
            }
            participles.add(participle)
            if (past != participle && past !in bases) pastOnly.add(past)
        }
    }

    fun isBase(word: String) = word in bases

    /** The base form of [word], or null when it is no verb this knows. */
    fun lemma(word: String): String? {
        if (word in bases) return word
        irregularBase[word]?.let { return it }
        // A candidate counts only if the verb's own forms produce the word, so
        // "stopping" finds "stop" but "hoping" does not find "hop".
        return candidates(word).firstOrNull { base ->
            base in bases && (third(base) == word || past(base) == word || participle(base) == word || ing(base) == word)
        }
    }

    private fun candidates(word: String): List<String> {
        val out = ArrayList<String>()
        fun add(s: String) { if (s.length >= 2) out.add(s) }
        when {
            word.endsWith("ies") -> add(word.dropLast(3) + "y")
            word.endsWith("es") -> { add(word.dropLast(2)); add(word.dropLast(1)) }
            word.endsWith("s") && !word.endsWith("ss") -> add(word.dropLast(1))
        }
        when {
            word.endsWith("ied") -> add(word.dropLast(3) + "y")
            word.endsWith("ed") -> {
                add(word.dropLast(2))
                add(word.dropLast(1))
                if (word.length > 4 && word[word.length - 3] == word[word.length - 4]) add(word.dropLast(3))
            }
        }
        if (word.endsWith("ing")) {
            val stem = word.dropLast(3)
            if (stem.endsWith("y")) add(stem.dropLast(1) + "ie")
            add(stem)
            add(stem + "e")
            if (stem.length > 2 && stem[stem.length - 1] == stem[stem.length - 2]) add(stem.dropLast(1))
        }
        return out
    }

    fun third(base: String): String = irregularThird[base] ?: when {
        base.endsWith("y") && base.length > 1 && base[base.length - 2] !in VOWELS -> base.dropLast(1) + "ies"
        base.endsWith("s") || base.endsWith("x") || base.endsWith("z") || base.endsWith("ch") ||
            base.endsWith("sh") || base.endsWith("o") -> base + "es"
        else -> base + "s"
    }

    fun past(base: String): String = irregularPast[base] ?: when {
        base.endsWith("e") -> base + "d"
        base.endsWith("y") && base.length > 1 && base[base.length - 2] !in VOWELS -> base.dropLast(1) + "ied"
        doubles(base) -> base + base.last() + "ed"
        else -> base + "ed"
    }

    fun participle(base: String): String = irregularParticiple[base] ?: past(base)

    fun ing(base: String): String = irregularIng[base] ?: when {
        base.endsWith("ie") -> base.dropLast(2) + "ying"
        base.endsWith("e") && !base.endsWith("ee") && !base.endsWith("ye") && !base.endsWith("oe") -> base.dropLast(1) + "ing"
        doubles(base) -> base + base.last() + "ing"
        else -> base + "ing"
    }

    /** An irregular past that is not also the participle or a base: "went", "ate", "knew". */
    fun isSimplePastOnly(word: String) = word in pastOnly

    /** A past participle: an irregular one, or "-ed" on a known regular verb. */
    fun isParticiple(word: String): Boolean {
        if (word in participles) return true
        val base = lemma(word) ?: return false
        return irregularParticiple[base] == null && word == past(base) && word != base
    }

    /** One vowel group, ending consonant–vowel–consonant: "stop" → "stopped", but "visit" → "visited". */
    private fun doubles(base: String): Boolean {
        if (base.length < 3) return false
        val a = base[base.length - 3]
        val b = base[base.length - 2]
        val c = base[base.length - 1]
        if (c in "wxy" || c in VOWELS || b !in VOWELS || a in VOWELS) return false
        var groups = 0
        var inGroup = false
        for (ch in base) {
            val vowel = ch in VOWELS
            if (vowel && !inGroup) groups++
            inGroup = vowel
        }
        return groups == 1
    }

    private companion object {
        const val VOWELS = "aeiou"
    }
}
