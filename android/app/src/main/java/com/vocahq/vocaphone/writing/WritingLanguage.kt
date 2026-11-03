package com.vocahq.vocaphone.writing

import com.vocahq.vocaphone.core.TranscriptRepair

/**
 * Whether Writing check's English rules should look at [text] at all, asked of
 * the text rather than of a keyboard or spell-checker locale: someone with the
 * English checker selected still writes French to some people, and "dont" is a
 * word there, not a missing apostrophe.
 *
 * Text with no letters has nothing to check. Under [SHORT] words it is checked
 * anyway, because a fragment that short says too little about its language and
 * a lone misspelling is exactly what should be caught. From [SHORT] words on it
 * is checked only when [isEnglish] says it is English. A word here is a
 * whitespace-separated piece with a letter in it, so "—" and "42" do not count.
 */
object WritingLanguage {
    const val SHORT = 6

    /** At most one word in this many may be spelled outside a–z for text to still be English. */
    const val BORROWED = 4

    private val whitespace = Regex("\\s+")

    fun applies(text: String, isEnglish: (String) -> Boolean): Boolean {
        if (text.none(Char::isLetter)) return false
        val words = text.split(whitespace).count { piece -> piece.any(Char::isLetter) }
        return words < SHORT || isEnglish(text, isEnglish)
    }

    /**
     * [isEnglish] (the transcript test, which calls any text with an accented
     * letter foreign) asked of [text] without its borrowed words. English
     * borrows "café", "naïve" and "résumé", and one of them in a sentence
     * should not switch off every check in it. So when no more than one word
     * in [BORROWED] has a letter outside a–z, those words are left out and the
     * rest decides; more than that and the text is not English.
     *
     * An accent is still evidence of another language, and dropping it leaves
     * the dictionary half of [isEnglish] easy to fool: "le", "tu", "as" and
     * "menu" are all English words, so "C'est le café dont tu as le menu."
     * would pass on its other words. The rest must also carry an English
     * marker word ([TranscriptRepair.englishMarkers]) other than "dont",
     * which is French as well and is the very word the rules would "correct",
     * or at least no word of [FOREIGN_FUNCTION_WORDS] ("le", "tu").
     */
    fun isEnglish(text: String, isEnglish: (String) -> Boolean): Boolean {
        val words = text.split(whitespace).filter { piece -> piece.any(Char::isLetter) }
        val borrowed = words.filter(::isBorrowed)
        if (borrowed.isEmpty()) return isEnglish(text)
        if (borrowed.size * BORROWED > words.size) return false
        val rest = words.filterNot(::isBorrowed).joinToString(" ")
        // A marker, or at least none of another language's commonest words:
        // "My flight to São Paulo leaves at 11:50 pm." has no marker at all.
        return isEnglish(rest) && (
            (TranscriptRepair.englishMarkers(rest) - SHARED_MARKERS).isNotEmpty() ||
                TranscriptRepair.wordKeys(rest).none { it in FOREIGN_FUNCTION_WORDS }
            )
    }

    /**
     * [TranscriptRepair.isEnglish] for text someone typed, where the words
     * that would tell it apart are the very ones misspelled. The transcript
     * test wants two marker words or two thirds of the words in
     * [isDictionaryWord], and counts "teh" and "aiport" as foreign, so
     * "Teh aiport wil be busy tomorow" failed it and was never checked: the
     * more mistakes, the surer the test was that the text was not English.
     *
     * Two things change here. A slip of a marker word (one swapped pair of
     * letters, or one letter doubled or undoubled: "teh", "adn", "becuase",
     * "thier") counts as that marker, since another language does not
     * produce the English word's own misspelling. And once the text has a
     * marker, a word [spelling] knows or can correct counts as English too.
     * A French or Hindi sentence written in Latin letters has no marker, so
     * it still fails, however many of its words sit near an English one.
     */
    fun typedEnglish(text: String, isDictionaryWord: (String) -> Boolean, spelling: WritingSpelling?): Boolean {
        val keys = TranscriptRepair.wordKeys(text)
        val markers = keys.mapNotNullTo(HashSet()) { key ->
            if (TranscriptRepair.isEnglishMarker(key)) key else markerSlip(key)
        }
        // More distinct words of another language's commonest than English markers:
        // "kal milte hai, tu aa jana time pe" has "time", and "je ne sais pas"
        // is all words the English list happens to hold.
        if (keys.filterTo(HashSet()) { it in FOREIGN_FUNCTION_WORDS }.size.let { it >= 2 && it > markers.size }) return false
        if (TranscriptRepair.isEnglish(text, "auto", isDictionaryWord)) return true
        // As the transcript test: an accented letter is another alphabet.
        if (text.lowercase().any { it in FOREIGN_LETTERS }) return false
        if (keys.size < 2) return false
        if (markers.size >= 2) return true
        if (markers.isEmpty() || spelling == null) return false
        val english = keys.count { key ->
            isDictionaryWord(key) || markerSlip(key) != null || spelling.isKnown(key) || spelling.suggest(key) != null
        }
        return english * 3 >= keys.size * 2
    }

    /** The marker [key] is one slip of, if any: a swapped pair, or one letter doubled or undoubled. */
    internal fun markerSlip(key: String): String? {
        if (key.length < 3 || TranscriptRepair.isEnglishMarker(key)) return null
        val chars = key.toCharArray()
        for (i in 0 until chars.size - 1) {
            if (chars[i] == chars[i + 1]) {
                // Undoubled: "tthe" → "the".
                val undoubled = key.removeRange(i, i + 1)
                if (TranscriptRepair.isEnglishMarker(undoubled)) return undoubled
                continue
            }
            val swapped = String(chars.copyOf().also { it[i] = chars[i + 1]; it[i + 1] = chars[i] })
            if (TranscriptRepair.isEnglishMarker(swapped)) return swapped
        }
        for (i in chars.indices) {
            // A dropped double letter: "realy" → "really", "anythng" is not one.
            val doubled = key.substring(0, i + 1) + key.substring(i)
            if (TranscriptRepair.isEnglishMarker(doubled)) return doubled
        }
        return null
    }

    /**
     * The commonest function words of the other languages people type in
     * Latin letters here (French, Spanish, German, Italian, Portuguese and
     * Hindi as typed in chat), less any that are English words too. As
     * `foreignFunctionWords` in ios/VocaPhoneShared/Writing/WritingCheckInApp.swift.
     */
    internal val FOREIGN_FUNCTION_WORDS = setOf(
        "je", "ne", "le", "cest", "pas", "que", "qui", "est", "et", "les", "des", "une", "il", "elle",
        "nous", "vous", "sont", "avec", "dans", "mais", "ce", "cette", "sur", "oui", "merci", "suis", "sais", "fait",
        "bien", "toi", "aux", "du", "es", "uno", "una", "por", "pero", "muy", "mi", "tu", "su", "esta",
        "este", "se", "hola", "gracias", "bueno", "nada", "todo", "tengo", "quiero", "hacer", "ahora", "der", "das", "und",
        "ist", "nicht", "ich", "wir", "sie", "auf", "ein", "eine", "auch", "noch", "sehr", "aber", "wie", "wo",
        "ja", "nein", "danke", "sono", "molto", "grazie", "muito", "obrigado", "hai", "hain", "kya", "nahi", "nahin", "aur",
        "mein", "tum", "kar", "raha", "rahe", "rahi", "aap", "bhi", "ka", "ki", "ke", "yeh", "woh", "kal",
        "abhi", "acha", "accha", "bhai", "yaar", "kaise", "kaisa", "kab", "kahan", "kyun", "kyu", "haan", "theek", "thik",
        "mujhe", "tujhe", "hoga", "hogi", "karna", "karenge", "jaana", "chal", "chalo", "liye", "wala", "wali", "bahut", "bohot",
        "voici", "parle", "souvent", "aussi", "toujours", "rien", "beaucoup", "comme", "peut", "veux", "vais", "avoir", "faire", "quoi",
        "alors", "pourquoi", "como", "donde", "quien", "porque", "tambien", "siempre", "estoy", "eres", "bitte", "heute", "keine", "habe",
        "zeit", "kaha", "kuch", "sab", "kyunki", "lekin", "toh", "aaj",
    )

    /** As `TranscriptRepair`'s veto: letters of another Latin alphabet. */
    private const val FOREIGN_LETTERS = "äöüßåæøœçñõãêôîûàèìòùáéíóúýðþğışłżźćęą"

    /** English marker words that are words in French too. */
    private val SHARED_MARKERS = setOf("dont")

    private fun isBorrowed(word: String): Boolean =
        word.any { it.isLetter() && it.lowercaseChar() !in 'a'..'z' }
}
