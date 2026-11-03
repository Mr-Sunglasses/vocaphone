package com.vocahq.vocaphone.core

import java.util.Locale
import org.json.JSONArray
import org.json.JSONObject

/**
 * A spelling the user fixed after a dictation, offered under Suggested until
 * they add or dismiss it. Mirrors `CorrectionSuggestion` in
 * `CorrectionSuggestions.swift`.
 */
data class CorrectionSuggestion(
    val heard: String,
    val corrected: String,
    /** Times the user made this fix. */
    val occurrences: Int = 1,
    /** Milliseconds since the epoch. */
    val lastSeen: Long = 0,
    val heardIsWord: Boolean = false,
    val namesTerm: Boolean = true,
) {
    val key: String get() = key(heard, corrected)

    private fun toJson(): JSONObject = JSONObject().apply {
        put("heard", heard)
        put("corrected", corrected)
        put("occurrences", occurrences)
        put("lastSeen", lastSeen)
        put("heardIsWord", heardIsWord)
        put("namesTerm", namesTerm)
    }

    companion object {
        /** One fix, whatever case the engine heard it in. */
        fun key(heard: String, corrected: String) = "${heard.lowercase(Locale.ROOT)}→$corrected"

        fun encode(suggestions: List<CorrectionSuggestion>): String =
            JSONArray(suggestions.map { it.toJson() }).toString()

        /** Unreadable storage is no suggestions. */
        fun decode(stored: String?): List<CorrectionSuggestion> {
            if (stored.isNullOrBlank()) return emptyList()
            return runCatching {
                val array = JSONArray(stored)
                List(array.length()) { index ->
                    val entry = array.getJSONObject(index)
                    CorrectionSuggestion(
                        heard = entry.getString("heard"),
                        corrected = entry.getString("corrected"),
                        occurrences = entry.optInt("occurrences", 1),
                        lastSeen = entry.optLong("lastSeen", 0),
                        heardIsWord = entry.optBoolean("heardIsWord", false),
                        namesTerm = entry.optBoolean("namesTerm", true),
                    )
                }
            }.getOrDefault(emptyList())
        }

        fun encodeKeys(keys: List<String>): String = JSONArray(keys).toString()

        fun decodeKeys(stored: String?): List<String> {
            if (stored.isNullOrBlank()) return emptyList()
            return runCatching {
                val array = JSONArray(stored)
                List(array.length()) { array.getString(it) }
            }.getOrDefault(emptyList())
        }
    }
}

/**
 * What happens to the spellings the keyboard learns ([CorrectionWatch]):
 * suggested, added, or dismissed for good. Pure, so both apps' storage
 * stays a thin wrapper. Mirrors `CorrectionSuggestions` in
 * `CorrectionSuggestions.swift`.
 *
 * VocaMac adds a fixed name the first time, with Undo on screen. A phone has
 * no such moment, so this is more careful: a fix is suggested, and added
 * without asking only once the user has made the same fix
 * [REPEATS_BEFORE_ADDING] times and it names something ([LearnedCorrection.namesTerm]).
 */
object CorrectionSuggestions {
    const val CAPACITY = 50
    const val DISMISSED_CAPACITY = 200
    const val REPEATS_BEFORE_ADDING = 2

    data class Received(
        val suggestions: List<CorrectionSuggestion>,
        /** Fixes made often enough to add without asking; see [learn]. */
        val added: List<CorrectionSuggestion>,
    )

    /**
     * [suggestions] with [found] counted in. A dismissed fix, or one the
     * lists already make ([isListed]), is skipped; one seen before moves to
     * the top with its count raised, and comes out in [Received.added] once
     * it is due. The newest [CAPACITY] are kept.
     */
    fun receive(
        found: List<LearnedCorrection>,
        suggestions: List<CorrectionSuggestion>,
        dismissed: Collection<String>,
        now: Long,
        isListed: (heard: String, corrected: String) -> Boolean,
    ): Received {
        val list = suggestions.toMutableList()
        val added = mutableListOf<CorrectionSuggestion>()
        for (correction in found) {
            val key = CorrectionSuggestion.key(correction.heard, correction.corrected)
            if (key in dismissed || isListed(correction.heard, correction.corrected)) continue
            val index = list.indexOfFirst { it.key == key }
            val seen = if (index >= 0) list.removeAt(index) else null
            val suggestion = CorrectionSuggestion(
                heard = correction.heard,
                corrected = correction.corrected,
                occurrences = (seen?.occurrences ?: 0) + 1,
                lastSeen = now,
                heardIsWord = correction.heardIsWord,
                namesTerm = correction.namesTerm,
            )
            if (suggestion.namesTerm && suggestion.occurrences >= REPEATS_BEFORE_ADDING) {
                added += suggestion
            } else {
                list.add(0, suggestion)
            }
        }
        return Received(list.take(CAPACITY), added)
    }

    /** What adding a fix changes: the replacements, and a word for the vocabulary. */
    data class Learned(val replacements: List<WordReplacement>, val term: String)

    /**
     * Adding [suggestion]: [CorrectionSuggestion.corrected] becomes a custom
     * word, so close spellings are fixed and the engines listen for it. When
     * the engine heard different letters, or several words for one, it also
     * becomes a replacement — unless what was heard is one ordinary word:
     * fixing "cloud" to "Claude" once must not rewrite every cloud.
     */
    fun learn(suggestion: CorrectionSuggestion, replacements: List<WordReplacement>): Learned {
        val heardKey = VocabularyCorrection.key(suggestion.heard)
        val sameLetters = heardKey == VocabularyCorrection.key(suggestion.corrected)
        val joinsWords = suggestion.heard.trim().contains(' ')
        val replaces = !suggestion.heardIsWord && (!sameLetters || joinsWords)
        val updated = if (replaces) {
            WordReplacements.adding(suggestion.heard, suggestion.corrected, replacements)
        } else {
            replacements
        }
        return Learned(updated, suggestion.corrected)
    }

    /** Where an added fix's corrected word goes. */
    enum class Destination { PERSONAL_DICTIONARY, CUSTOM_WORDS, REPLACEMENT, NOT_YET }

    /**
     * Where [suggestion]'s corrected word goes. While dictation reads the
     * personal dictionary ([synced]) the custom words are not read at all, and
     * the dictionary only takes plain words ([savable]): "GPT4" or "Claude
     * Code" becomes a replacement from what was heard instead, which
     * dictation reads. One ordinary word heard ("cloud" → "Claude Code") is
     * only made one when the user asked ([explicit]); added on its own, it
     * would rewrite every "cloud", so it waits as a suggestion.
     */
    fun destination(suggestion: CorrectionSuggestion, synced: Boolean, savable: Boolean, explicit: Boolean): Destination {
        if (!synced) return Destination.CUSTOM_WORDS
        if (savable) return Destination.PERSONAL_DICTIONARY
        val oneOrdinaryWord = suggestion.heardIsWord && !suggestion.heard.trim().contains(' ')
        return if (oneOrdinaryWord && !explicit) Destination.NOT_YET else Destination.REPLACEMENT
    }

    /** Whether the lists already make this fix: the word is a custom word, or a replacement writes it from what was heard. */
    fun isListed(
        heard: String,
        corrected: String,
        replacements: List<WordReplacement>,
        vocabulary: List<String>,
    ): Boolean {
        if (vocabulary.any { it == corrected }) return true
        val lowered = heard.lowercase(Locale.ROOT)
        return replacements.any { row ->
            row.written == corrected && row.heardForms.any { it.lowercase(Locale.ROOT) == lowered }
        }
    }

    /**
     * [vocabulary] (the stored custom-words text) with [term] added on its
     * own line; a differently cased copy gives way, since the fix is the
     * spelling wanted. Unchanged when the term is already there.
     */
    fun vocabulary(vocabulary: String, term: String): String {
        val word = term.trim()
        val terms = CustomVocabulary.terms(vocabulary)
        if (word.isEmpty() || word in terms) return vocabulary
        if (terms.none { it.equals(word, ignoreCase = true) }) {
            val trimmed = vocabulary.trim()
            return if (trimmed.isEmpty()) word else "$trimmed\n$word"
        }
        return (terms.filterNot { it.equals(word, ignoreCase = true) } + word).joinToString("\n")
    }

    /** [dismissed] with [key] added, newest last, the oldest dropped past [DISMISSED_CAPACITY]. */
    fun dismissing(key: String, dismissed: List<String>): List<String> =
        (dismissed.filter { it != key } + key).takeLast(DISMISSED_CAPACITY)
}
