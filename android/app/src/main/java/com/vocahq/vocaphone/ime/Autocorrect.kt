package com.vocahq.vocaphone.ime

import android.text.InputType
import com.vocahq.vocaphone.core.EmojiTable
import com.vocahq.vocaphone.settings.AutocorrectStrength
import java.util.Locale
import kotlin.math.log10

/** A word list entry within two edits of what was typed; [rank] is its place in the frequency list. */
internal data class AutocorrectCandidate(val word: String, val rank: Int, val edits: Int)

/**
 * How sure space has to be. [maxEdits] bounds how far the fix may be from the
 * typed word, [maxCost] how unlikely it may be ([Autocorrect.cost]), and
 * [minMargin] how far ahead of the next reading it has to stand.
 */
internal data class AutocorrectTuning(val maxEdits: Int, val maxCost: Float, val minMargin: Float) {
    /** [maxCost] for a word of [length]: a long word has room for more slips and still reads as itself. */
    fun maxCostFor(length: Int): Float = maxCost + LONG_WORD_ALLOWANCE * (length - 5).coerceAtLeast(0)

    companion object {
        private const val LONG_WORD_ALLOWANCE = 0.06f

        val MILD = AutocorrectTuning(maxEdits = 1, maxCost = 1.1f, minMargin = 0.5f)

        /**
         * The default, measured against a hundred common typos and chat words
         * on the shipped list (`AutocorrectTest`). A swapped pair or a
         * neighbouring key on a common word costs 0.6 to 0.9, so 1.5 admits one
         * slip on almost any listed word, or two cheap ones on a common word,
         * and a little more on long words. A lead of 0.25 over the runner-up is
         * about what separates the top two hundred words from the bottom
         * thousand, so a correction is never a coin toss between two equally
         * near spellings: "helo" (help or hello) and "wierd" (weird or wired)
         * stand, "realy" becomes "really".
         */
        val NORMAL = AutocorrectTuning(maxEdits = 2, maxCost = 1.5f, minMargin = 0.25f)
        val AGGRESSIVE = AutocorrectTuning(maxEdits = 2, maxCost = 2.1f, minMargin = 0.15f)

        fun of(strength: AutocorrectStrength): AutocorrectTuning = when (strength) {
            AutocorrectStrength.MILD -> MILD
            AutocorrectStrength.NORMAL -> NORMAL
            AutocorrectStrength.AGGRESSIVE -> AGGRESSIVE
        }
    }
}

/** Everything one decision depends on, so a test can vary exactly one fact. */
internal class AutocorrectContext(
    val typed: String,
    /**
     * What sits between the last whitespace and [typed]: `www.` in front of
     * `goggle`, `@` in front of a handle. Opening brackets and quotes are fine;
     * anything else makes the token an address, a handle or a number.
     */
    val tokenBefore: String = "",
    /** The word starts a sentence, so a capital on it says nothing. */
    val atSentenceStart: Boolean = true,
    /** The cursor sits inside a longer word: only a prefix of it is in hand. */
    val midWord: Boolean = false,
    /** The word list knows [typed]. */
    val isKnown: Boolean = false,
    /** The personal dictionary has [typed]. */
    val isPersonal: Boolean = false,
    /** The user put this spelling back after a correction in this field. */
    val asserted: Boolean = false,
    /** A word the keyboard never offers, typed in full: left as typed. */
    val heldBack: Boolean = false,
    /** Already gated: no held-back, blocked or twice-undone fixes. */
    val candidates: List<AutocorrectCandidate> = emptyList(),
    /** What the bigram table predicts after the previous word, lowercase. */
    val followers: Set<String> = emptySet(),
    val tuning: AutocorrectTuning = AutocorrectTuning.NORMAL,
)

internal sealed interface AutocorrectDecision {
    data class Apply(val word: String) : AutocorrectDecision
    data class Refused(val reason: String) : AutocorrectDecision

    val replacement: String? get() = (this as? Apply)?.word
}

/**
 * Whether space (or `.,!?;:`) should replace the word just typed, and with what.
 *
 * Every refusal here exists because a correction that fires wrongly is worse
 * than none: it rewrites a word the user meant after they stopped looking.
 * The order follows the iOS keyboard's `TypingCandidates.autocorrectDecision`,
 * minus its system spell checker: the candidates here are the shipped word
 * list's, ranked by [cost].
 *
 * Pure. The candidate scan that feeds it walks the word list, so it runs where
 * the strip runs, off the composition thread, and space only applies a
 * decision already made for the word in hand.
 */
internal object Autocorrect {
    const val MIN_LENGTH = 3

    /** Lowercase letters that make a word pronounceable; a token without any is an acronym or a sound. */
    private const val VOWELS = "aeiouy"

    /** Opening punctuation that may sit in front of a word without making it something else. */
    private const val OPENERS = "(\"'[{“‘"

    fun decide(context: AutocorrectContext): AutocorrectDecision {
        val typed = context.typed
        if (typed.isEmpty()) return refused("nothing typed")
        if (context.midWord) return refused("mid-word")
        // The user's own answer outranks everything below, the curated table included.
        if (context.asserted) return refused("restored in this field")
        if (context.isPersonal) return refused("in the personal dictionary")
        // A handle, an address, a number with letters on it, a path.
        if (context.tokenBefore.any { it !in OPENERS }) return refused("not a word token")
        if (typed.any { !it.isLetter() && it != '\'' && it != '’' }) return refused("not a word token")
        if (context.heldBack) return refused("a word the keyboard does not offer")
        // "WIP" is not a misspelling of "wip"; caps lock has chosen its letters.
        if (typed.length > 1 && isAllCaps(typed)) return refused("shouted")

        ShortWordCorrections.replacement(typed)?.let { replacement ->
            if (replacement != typed) return AutocorrectDecision.Apply(replacement)
        }

        if (typed.length < MIN_LENGTH) return refused("shorter than three letters")
        // A capital in the middle of a sentence is a name the list does not know.
        if (!context.atSentenceStart && typed.first().isUpperCase()) return refused("capitalised mid-sentence")
        if (context.isKnown) return refused("already a word")
        val lower = typed.lowercase(Locale.ROOT)
        // "omg", "lol": a word with an emoji of its own is typed on purpose.
        if (EmojiTable.glyphForKey(lower) != null) return refused("a word with an emoji of its own")
        if (lower.none { it in VOWELS }) return refused("no vowels")

        val scored = context.candidates
            .filter { it.word.lowercase(Locale.ROOT) != lower }
            .map { it to cost(lower, it, context.followers) }
            .sortedBy { it.second }
        val (best, bestCost) = scored.firstOrNull() ?: return refused("nothing near")
        val allowedEdits = minOf(context.tuning.maxEdits, editsFor(lower.length))
        if (best.edits > allowedEdits) return refused("too far: ${best.edits} edits to ${best.word}")
        if (bestCost > context.tuning.maxCostFor(lower.length)) return refused("too unlikely: ${best.word}")
        val runnerUp = scored.getOrNull(1)
        // Two keys swapped is explained by nothing else, unless the runner-up is a swap too.
        val swapped = isTransposition(lower, best.word.lowercase(Locale.ROOT)) &&
            runnerUp?.let { isTransposition(lower, it.first.word.lowercase(Locale.ROOT)) } != true
        if (runnerUp != null && !swapped && runnerUp.second - bestCost < context.tuning.minMargin) {
            return refused("ambiguous: ${best.word} and ${runnerUp.first.word} both fit")
        }
        return AutocorrectDecision.Apply(cased(typed, best.word))
    }

    /** Two edits only once a word is long enough that two edits still leave it recognisable. */
    private fun editsFor(length: Int): Int = if (length >= 5) 2 else 1

    /**
     * How reluctant the keyboard is to read [typed] as [candidate]. Lower is
     * better; the unit is roughly one plain edit. Spelling ([editCost]), how
     * common the word is, and whether the sentence predicts it.
     */
    fun cost(typed: String, candidate: AutocorrectCandidate, followers: Set<String>): Float {
        var cost = editCost(typed, candidate.word.lowercase(Locale.ROOT)) + frequencyCost(candidate.rank)
        if (candidate.word.lowercase(Locale.ROOT) in followers) cost -= CONTEXT_BONUS
        return cost
    }

    /** 0.15 for the most common word, 0.6 for the ten thousandth. */
    fun frequencyCost(rank: Int): Float = FREQUENCY_WEIGHT * log10(rank.coerceAtLeast(0) + 10f)

    /**
     * Damerau-Levenshtein, priced the way fingers miss: a neighbouring key and a
     * key tapped twice cost about half of a plain edit, a letter of a double
     * left out the same, and two keys in the wrong order less than either —
     * nothing else explains a swap.
     */
    fun editCost(typed: String, intended: String): Float {
        val a = typed.lowercase(Locale.ROOT)
        val b = intended.lowercase(Locale.ROOT)
        val rows = Array(a.length + 1) { FloatArray(b.length + 1) }
        for (j in 1..b.length) rows[0][j] = rows[0][j - 1] + deletion(b, j - 1)
        for (i in 1..a.length) {
            rows[i][0] = rows[i - 1][0] + insertion(a, i - 1, b, 0)
            for (j in 1..b.length) {
                val substitution = when {
                    a[i - 1] == b[j - 1] -> 0f
                    b[j - 1] in SuggestionEngine.nearbyLetters(a[i - 1]) -> NEIGHBOUR
                    else -> 1f
                }
                var value = minOf(
                    rows[i - 1][j] + insertion(a, i - 1, b, j),
                    rows[i][j - 1] + deletion(b, j - 1),
                    rows[i - 1][j - 1] + substitution,
                )
                if (i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1] && a[i - 1] != a[i - 2]) {
                    value = minOf(value, rows[i - 2][j - 2] + TRANSPOSITION)
                }
                rows[i][j] = value
            }
        }
        return rows[a.length][b.length]
    }

    /** [typed] has a letter at [index] the word does not, where the word's next letter is at [at]. */
    private fun insertion(typed: String, index: Int, intended: String, at: Int): Float {
        val letter = typed[index]
        if (index > 0 && typed[index - 1] == letter) return DOUBLED
        val near = SuggestionEngine.nearbyLetters(letter)
        if ((at > 0 && intended[at - 1] in near) || (at < intended.length && intended[at] in near)) return NEIGHBOUR
        return 1f
    }

    /** The word's letter at [index] is missing from what was typed. */
    private fun deletion(intended: String, index: Int): Float =
        if (index > 0 && intended[index - 1] == intended[index]) MISSED_DOUBLE else OMISSION

    /** [right] is [left] with exactly one adjacent pair swapped. */
    fun isTransposition(left: String, right: String): Boolean {
        if (left.length != right.length || left.length < 2) return false
        val differences = left.indices.filter { left[it] != right[it] }
        if (differences.size != 2) return false
        val (first, second) = differences
        return second == first + 1 && left[first] == right[second] && left[second] == right[first]
    }

    fun isAllCaps(word: String): Boolean {
        val letters = word.filter(Char::isLetter)
        return letters.isNotEmpty() && letters.all(Char::isUpperCase)
    }

    /** [replacement] cased like [typed], unless it carries its own capitals ("I'm"). */
    fun cased(typed: String, replacement: String): String {
        if (typed.isEmpty() || replacement.any { it.isUpperCase() || it.isWhitespace() }) return replacement
        return SuggestionEngine.matchCase(typed, replacement)
    }

    /**
     * Fields Gboard would not correct in: passwords, addresses, links, names,
     * search filters, a web editor that did not ask for it, and any field that
     * asked for no suggestions or shows completions of its own.
     */
    fun allowedIn(inputType: Int): Boolean {
        if (inputType and InputType.TYPE_MASK_CLASS != InputType.TYPE_CLASS_TEXT) return false
        if (inputType and InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS != 0) return false
        if (inputType and InputType.TYPE_TEXT_FLAG_AUTO_COMPLETE != 0) return false
        return when (inputType and InputType.TYPE_MASK_VARIATION) {
            InputType.TYPE_TEXT_VARIATION_PASSWORD,
            InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD,
            InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD,
            InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS,
            InputType.TYPE_TEXT_VARIATION_WEB_EMAIL_ADDRESS,
            InputType.TYPE_TEXT_VARIATION_URI,
            InputType.TYPE_TEXT_VARIATION_FILTER,
            InputType.TYPE_TEXT_VARIATION_PERSON_NAME,
            InputType.TYPE_TEXT_VARIATION_PHONETIC,
            -> false
            InputType.TYPE_TEXT_VARIATION_WEB_EDIT_TEXT ->
                inputType and InputType.TYPE_TEXT_FLAG_AUTO_CORRECT != 0
            else -> true
        }
    }

    private fun refused(reason: String) = AutocorrectDecision.Refused(reason)

    private const val NEIGHBOUR = 0.5f
    private const val DOUBLED = 0.5f
    /** One letter of a double left out: "realy", "tomorow". */
    private const val MISSED_DOUBLE = 0.35f
    /** Any other letter left out, usually a vowel: "happend", "probaly". */
    private const val OMISSION = 0.75f
    private const val TRANSPOSITION = 0.4f
    private const val FREQUENCY_WEIGHT = 0.2f

    /** The previous word predicts this one: about half an edit, enough to settle a tie. */
    private const val CONTEXT_BONUS = 0.5f
}

/**
 * The corrections a word list never makes, because nothing is misspelled:
 * "i" is a word, and "im", "dont" and "cant" are in the shipped list. Applied
 * ahead of the general path. A port of the iOS keyboard's table, with its
 * reasons: "its", "were", "well", "hell", "shell", "wed", "shes" and "hes"
 * are all real words often enough to leave alone.
 */
internal object ShortWordCorrections {
    private val TABLE: Map<String, String> = mapOf(
        "i" to "I",
        "im" to "I'm",
        "id" to "I'd",
        "ill" to "I'll",
        "ive" to "I've",
        "dont" to "don't",
        "doesnt" to "doesn't",
        "didnt" to "didn't",
        "cant" to "can't",
        "couldnt" to "couldn't",
        "shouldnt" to "shouldn't",
        "wouldnt" to "wouldn't",
        "wont" to "won't",
        "isnt" to "isn't",
        "arent" to "aren't",
        "wasnt" to "wasn't",
        "werent" to "weren't",
        "hasnt" to "hasn't",
        "havent" to "haven't",
        "hadnt" to "hadn't",
        "youre" to "you're",
        "youve" to "you've",
        "youll" to "you'll",
        "youd" to "you'd",
        "theyre" to "they're",
        "theyve" to "they've",
        "theyll" to "they'll",
        "theyd" to "they'd",
        "weve" to "we've",
        "whats" to "what's",
        "thats" to "that's",
        "wheres" to "where's",
        "hows" to "how's",
        "whos" to "who's",
        "lets" to "let's",
        "aint" to "ain't",
        "oclock" to "o'clock",
    )

    /** The replacement for [typed], cased like it unless it carries its own capitals; null when there is none. */
    fun replacement(typed: String): String? {
        val found = TABLE[typed.lowercase(Locale.ROOT)] ?: return null
        return Autocorrect.cased(typed, found)
    }

    /**
     * An apostrophe right after a lone "i" can only be "I'm", "I'll", "I've"
     * or "I'd", so the "i" is capitalised there and then.
     */
    fun beforeApostrophe(typed: String): String? = if (typed == "i") "I" else null
}
