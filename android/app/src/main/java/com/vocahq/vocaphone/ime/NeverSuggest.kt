package com.vocahq.vocaphone.ime

import android.content.res.AssetManager
import java.util.Locale

/**
 * Words the keyboard never offers on its own: `assets/keyboard/never-suggest.tsv`.
 *
 * A slur is never suggested, completed, predicted, swiped, fixed to or learned
 * as a fix. A swear word is held back the same way unless "Suggest swear
 * words" is on. Either one the user typed in full stays as typed: it is never
 * "corrected" into something else. A two-word expression blocks only its
 * second word after its first.
 *
 * Words in the user's personal dictionary are theirs and always allowed; the
 * caller applies that, since only it holds the dictionary.
 */
internal class NeverSuggest(
    private val slurs: Set<String>,
    private val swears: Set<String>,
    private val slurPairs: Map<String, Set<String>> = emptyMap(),
    private val swearPairs: Map<String, Set<String>> = emptyMap(),
) {
    /** [word] on its own is held back. */
    fun blocks(word: String, allowSwears: Boolean): Boolean {
        if (word.isEmpty()) return false
        val key = word.lowercase(Locale.ROOT)
        return key in slurs || (!allowSwears && key in swears)
    }

    /** [word] right after [previous] completes a held-back expression. */
    fun blocksAfter(previous: String?, word: String, allowSwears: Boolean): Boolean {
        if (previous.isNullOrEmpty() || word.isEmpty()) return false
        val first = previous.lowercase(Locale.ROOT)
        val second = word.lowercase(Locale.ROOT)
        return slurPairs[first]?.contains(second) == true ||
            (!allowSwears && swearPairs[first]?.contains(second) == true)
    }

    fun blocks(word: String, previous: String?, allowSwears: Boolean): Boolean =
        blocks(word, allowSwears) || blocksAfter(previous, word, allowSwears)

    companion object {
        val EMPTY = NeverSuggest(emptySet(), emptySet())

        /** The rows for every layout (`*`) and for English, which is the only typing layout. */
        private val LAYOUTS = setOf("*", "en")

        fun parse(lines: List<String>): NeverSuggest {
            val slurs = HashSet<String>()
            val swears = HashSet<String>()
            val slurPairs = HashMap<String, MutableSet<String>>()
            val swearPairs = HashMap<String, MutableSet<String>>()
            for (line in lines) {
                if (line.isBlank() || line.startsWith("#")) continue
                val fields = line.split('\t')
                if (fields.size < 3 || fields[0].trim() !in LAYOUTS) continue
                val text = fields[2].trim().lowercase(Locale.ROOT)
                if (text.isEmpty()) continue
                val slur = when (fields[1].trim()) {
                    "slur" -> true
                    "swear" -> false
                    else -> continue
                }
                val words = text.split(' ').filter { it.isNotEmpty() }
                when (words.size) {
                    1 -> (if (slur) slurs else swears).add(words[0])
                    2 -> (if (slur) slurPairs else swearPairs).getOrPut(words[0]) { HashSet() }.add(words[1])
                }
            }
            return NeverSuggest(slurs, swears, slurPairs, swearPairs)
        }

        fun load(assets: AssetManager): NeverSuggest =
            parse(assets.open("never-suggest.tsv").bufferedReader().readLines())
    }
}
