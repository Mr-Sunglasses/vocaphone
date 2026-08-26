package com.vocahq.vocaphone.core

/**
 * Devanagari to Latin, in the spelling people actually type.
 *
 * This is not IAST and deliberately not reversible. IAST would give "ājˈ mujhe"
 * where a Hinglish speaker writes "Aaj mujhe", and a transcript that reads like
 * a linguistics paper is not the feature. The scheme is documented in
 * `docs/hinglish-roman.md`; the rules that make it look natural are the three
 * below, and each is here because the naive answer is visibly wrong.
 *
 * **Schwa deletion.** Every Devanagari consonant carries an implicit `a` that
 * Hindi does not always pronounce. Rendering it always gives "gharaa" for घर and
 * "karanaa" for करना. The rule applied here drops the implicit vowel at the end
 * of a word, and drops it mid-word when the next syllable carries a written
 * vowel of its own — करना becomes "karna" while समझ stays "samajh", because in
 * समझ the following syllable has no written vowel either. The mid-word case
 * never fires on the first syllable: without that guard पता collapses to "pta".
 *
 * **Long vowels shorten at the end.** आ is "aa" in आज ("aaj") and "a" in करना
 * ("karna"); ई is "ee" in ठीक ("theek") and "i" in कभी ("kabhi"). Writing "aa"
 * and "ee" everywhere produces "karnaa" and "kabhee", which nobody types.
 * Finality is judged after schwa deletion and ignores a trailing nasal, so नहीं
 * is "nahin" rather than "naheen".
 *
 * **Anusvara is `n`, except before a lip consonant.** संभव is "sambhav" and
 * अंदर is "andar"; one letter, two sounds, and the following consonant is what
 * decides.
 *
 * Nothing outside the Devanagari block is touched. Latin runs pass through byte
 * for byte, which is what keeps the English half of a code-switched sentence
 * spelled the way it was spoken.
 */
object DevanagariRomanizer {

    private const val DEVANAGARI_START = 'ऀ'
    private const val DEVANAGARI_END = 'ॿ'
    private const val VIRAMA = '्'
    private const val NUKTA = '़'
    private const val ANUSVARA = 'ं'
    private const val CHANDRABINDU = 'ँ'
    private const val VISARGA = 'ः'
    private const val ZWJ = '‍'
    private const val ZWNJ = '‌'

    /** Whether [text] contains anything this romanizer would rewrite. */
    fun containsDevanagari(text: String): Boolean = text.any(::isDevanagari)

    private fun isDevanagari(character: Char): Boolean =
        character in DEVANAGARI_START..DEVANAGARI_END

    /**
     * Part of a Devanagari word rather than a separator between two of them.
     *
     * A danda and a Devanagari digit are in the same Unicode block as the
     * letters but are not part of the akshara model, and swallowing them into
     * the word breaks the rule that decides where a word ends: with the danda
     * counted, ठीक। has a syllable after क and the implicit vowel survives as
     * "theeka.".
     */
    private fun isWordCharacter(character: Char): Boolean =
        (isDevanagari(character) && character !in STANDALONE) ||
            character == ZWJ ||
            character == ZWNJ

    /**
     * Romanizes every Devanagari run in [text], leaving everything else exactly
     * as it arrived.
     */
    fun romanize(text: String): String {
        if (!containsDevanagari(text)) return text
        val out = StringBuilder(text.length + text.length / 2)
        var index = 0
        while (index < text.length) {
            val character = text[index]
            if (!isDevanagari(character)) {
                out.append(character)
                index++
                continue
            }
            val standalone = STANDALONE[character]
            if (standalone != null) {
                out.append(standalone)
                index++
                continue
            }
            var end = index
            while (end < text.length && isWordCharacter(text[end])) end++
            out.append(romanizeWord(text.substring(index, end)))
            index = end
        }
        return out.toString()
    }

    /** One written vowel, or the implicit one a bare consonant carries. */
    private enum class Vowel(val long: String, val short: String = long) {
        A("a"),
        AA("aa", "a"),
        I("i"),
        II("ee", "i"),
        U("u"),
        UU("oo", "u"),
        RI("ri"),
        E("e"),
        AI("ai"),
        O("o"),
        AU("au"),
        ;

        /** The final-position spelling; only the long vowels differ. */
        fun render(final: Boolean): String = if (final) short else long
    }

    /**
     * One syllable: an onset, the vowel that follows it, and any nasal or
     * visarga hanging off the end.
     *
     * [implicit] is the whole reason this is a data class rather than a string:
     * an `a` that was written (अ, ा) and an `a` that is merely implied look the
     * same once rendered, and only the implied one may be deleted.
     */
    private data class Syllable(
        val onset: String,
        val vowel: Vowel?,
        val implicit: Boolean,
        val nasal: String = "",
    )

    private fun romanizeWord(word: String): String {
        val syllables = parse(word)
        applySchwaDeletion(syllables)
        return render(syllables)
    }

    private fun parse(word: String): MutableList<Syllable> {
        val syllables = mutableListOf<Syllable>()
        var index = 0
        while (index < word.length) {
            val character = word[index]
            when {
                character == ZWJ || character == ZWNJ -> index++

                character in INDEPENDENT_VOWELS -> {
                    syllables += Syllable("", INDEPENDENT_VOWELS.getValue(character), implicit = false)
                    index++
                }

                character in CONSONANTS -> {
                    var onset = CONSONANTS.getValue(character)
                    index++
                    if (index < word.length && word[index] == NUKTA) {
                        onset = NUKTA_FORMS[character] ?: onset
                        index++
                    }
                    var vowel: Vowel? = Vowel.A
                    var implicit = true
                    if (index < word.length) {
                        when {
                            word[index] == VIRAMA -> {
                                vowel = null
                                implicit = false
                                index++
                            }
                            word[index] in MATRAS -> {
                                vowel = MATRAS.getValue(word[index])
                                implicit = false
                                index++
                            }
                        }
                    }
                    syllables += Syllable(onset, vowel, implicit)
                }

                // Accents and rare editorial signs. They have no Latin spelling
                // worth guessing at, so they are dropped rather than passed
                // through as a character nobody can read. Digits and the danda
                // never reach here: they end the word instead.
                else -> index++
            }
            // A nasal or visarga binds to the syllable it follows, whatever
            // produced that syllable. With nothing to bind to — a word that
            // opens with a stray sign — it is dropped.
            while (index < word.length && word[index] in NASAL_SIGNS) {
                val sign = if (word[index] == VISARGA) "h" else "n"
                if (syllables.isNotEmpty()) {
                    syllables[syllables.lastIndex] = syllables.last().copy(nasal = sign)
                }
                index++
            }
        }
        return syllables
    }

    /**
     * Drops the implicit `a` where Hindi does not pronounce it.
     *
     * Word-finally, always. Mid-word, only when the next syllable carries a
     * written vowel — and never on the first syllable, which is what keeps पता
     * from becoming "pta".
     */
    private fun applySchwaDeletion(syllables: MutableList<Syllable>) {
        for (index in syllables.indices) {
            val syllable = syllables[index]
            if (!syllable.implicit || syllable.onset.isEmpty()) continue
            val isLast = index == syllables.lastIndex
            val nextHasWrittenVowel = !isLast &&
                syllables[index + 1].let { it.vowel != null && !it.implicit }
            if (isLast || (index > 0 && nextHasWrittenVowel)) {
                syllables[index] = syllable.copy(vowel = null, implicit = false)
            }
        }
    }

    private fun render(syllables: List<Syllable>): String {
        // Which syllable is last for the purpose of shortening a long vowel.
        //
        // "Last vowel" is not the test and getting that wrong turns आज into
        // "aj": schwa deletion leaves ज carrying no vowel at all, so the ā
        // before it looks final while a whole consonant still follows. What
        // counts is whether any letter comes after — onset or vowel. A trailing
        // nasal is transparent, which is why नहीं is "nahin" and not "naheen".
        val lastLetterIndex = syllables.indexOfLast { it.onset.isNotEmpty() || it.vowel != null }
        return buildString {
            syllables.forEachIndexed { index, syllable ->
                append(syllable.onset)
                syllable.vowel?.let { append(it.render(final = index == lastLetterIndex)) }
                if (syllable.nasal == "n") {
                    // One letter, two sounds: संभव is "sambhav", अंदर is "andar".
                    val next = syllables.getOrNull(index + 1)?.onset.orEmpty()
                    append(if (next.firstOrNull() in LABIALS) "m" else "n")
                } else {
                    append(syllable.nasal)
                }
            }
        }
    }

    private val LABIALS = setOf('p', 'b', 'm')

    private val NASAL_SIGNS = setOf(ANUSVARA, CHANDRABINDU, VISARGA)

    private val INDEPENDENT_VOWELS = mapOf(
        'अ' to Vowel.A, 'आ' to Vowel.AA,
        'इ' to Vowel.I, 'ई' to Vowel.II,
        'उ' to Vowel.U, 'ऊ' to Vowel.UU,
        'ऋ' to Vowel.RI, 'ॠ' to Vowel.RI,
        'ऍ' to Vowel.E, 'ए' to Vowel.E,
        'ऎ' to Vowel.E, 'ऐ' to Vowel.AI,
        'ऑ' to Vowel.O, 'ओ' to Vowel.O,
        'ऒ' to Vowel.O, 'औ' to Vowel.AU,
    )

    private val MATRAS = mapOf(
        'ा' to Vowel.AA,
        'ि' to Vowel.I, 'ी' to Vowel.II,
        'ु' to Vowel.U, 'ू' to Vowel.UU,
        'ृ' to Vowel.RI, 'ॄ' to Vowel.RI,
        'ॅ' to Vowel.E, 'ॆ' to Vowel.E,
        'े' to Vowel.E, 'ै' to Vowel.AI,
        'ॉ' to Vowel.O, 'ॊ' to Vowel.O,
        'ो' to Vowel.O, 'ौ' to Vowel.AU,
    )

    private val CONSONANTS = mapOf(
        'क' to "k", 'ख' to "kh", 'ग' to "g", 'घ' to "gh", 'ङ' to "n",
        'च' to "ch", 'छ' to "chh", 'ज' to "j", 'झ' to "jh", 'ञ' to "n",
        'ट' to "t", 'ठ' to "th", 'ड' to "d", 'ढ' to "dh", 'ण' to "n",
        'त' to "t", 'थ' to "th", 'द' to "d", 'ध' to "dh", 'न' to "n",
        'प' to "p", 'फ' to "ph", 'ब' to "b", 'भ' to "bh", 'म' to "m",
        'य' to "y", 'र' to "r", 'ऱ' to "r", 'ल' to "l", 'ळ' to "l",
        'व' to "v",
        'श' to "sh", 'ष' to "sh", 'स' to "s", 'ह' to "h",
        // The precomposed nukta letters, which arrive as one code point rather
        // than as a base plus U+093C.
        'क़' to "q", 'ख़' to "kh", 'ग़' to "gh", 'ज़' to "z",
        'ड़' to "r", 'ढ़' to "rh", 'फ़' to "f", 'य़' to "y",
    )

    /** What a following U+093C turns the base consonant into. */
    private val NUKTA_FORMS = mapOf(
        'क' to "q", 'ख' to "kh", 'ग' to "gh", 'ज' to "z",
        'ड' to "r", 'ढ' to "rh", 'फ' to "f", 'य' to "y",
    )

    /** Devanagari that is not part of a syllable: digits, danda, om. */
    private val STANDALONE = mapOf(
        '।' to ".", '॥' to ".",
        '०' to "0", '१' to "1", '२' to "2", '३' to "3", '४' to "4",
        '५' to "5", '६' to "6", '७' to "7", '८' to "8", '९' to "9",
        'ॐ' to "om", 'ऽ' to "",
    )
}
