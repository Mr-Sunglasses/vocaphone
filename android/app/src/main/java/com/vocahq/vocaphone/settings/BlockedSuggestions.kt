package com.vocahq.vocaphone.settings

import java.util.Locale

/**
 * Words the user long-pressed off the suggestion strip, stored like the
 * personal dictionary: one comma-separated string, lowercase, newest first.
 * The keyboard never suggests, predicts, swipes or corrects to them. Words
 * only, on this phone; Settings shows how many there are and can clear them.
 */
object BlockedSuggestions {
    const val CAPACITY = 1_000
    private const val SEPARATOR = ", "

    fun words(raw: String?): Set<String> {
        if (raw.isNullOrBlank()) return emptySet()
        return raw.split(',', '\n')
            .map { it.trim().lowercase(Locale.ROOT) }
            .filterTo(LinkedHashSet()) { it.isNotEmpty() }
    }

    fun count(raw: String?): Int = words(raw).size

    fun add(raw: String?, word: String): String {
        val key = word.trim().lowercase(Locale.ROOT)
        val existing = words(raw)
        if (key.isEmpty() || key.contains(',')) return existing.joinToString(SEPARATOR)
        return (listOf(key) + (existing - key)).take(CAPACITY).joinToString(SEPARATOR)
    }
}
