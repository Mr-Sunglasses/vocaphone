package com.vocahq.vocaphone.ime

import java.util.Locale

/**
 * Words this user taught the suggestion strip: names, project names, anything
 * the shipped English list misses.
 *
 * Separate from [com.vocahq.vocaphone.core.CustomVocabulary], which only biases
 * Whisper. These words complete on the strip. Nothing here is logged or sent.
 *
 * The stored text is what the settings field shows. Parsing accepts commas
 * or new lines; saving always writes a comma-separated list, which is how
 * the field is meant to be edited.
 */
internal object PersonalDictionary {
    const val CAPACITY = 2_000
    const val MIN_LENGTH = 3
    private const val SEPARATOR = ", "

    fun terms(raw: String?): List<String> {
        if (raw.isNullOrBlank()) return emptyList()
        val seen = mutableSetOf<String>()
        return raw.split('\n', ',')
            .map { it.trim() }
            .filter { isSavable(it) && seen.add(it.lowercase(Locale.ROOT)) }
            .take(CAPACITY)
    }

    fun normalize(raw: String?): String = terms(raw).joinToString(SEPARATOR)

    fun contains(raw: String?, word: String): Boolean {
        val key = word.lowercase(Locale.ROOT)
        if (key.isEmpty()) return false
        return terms(raw).any { it.lowercase(Locale.ROOT) == key }
    }

    fun completions(raw: String?, prefix: String, limit: Int = 3): List<String> {
        if (prefix.isEmpty() || limit <= 0) return emptyList()
        val lower = prefix.lowercase(Locale.ROOT)
        return terms(raw)
            .filter { it.length > lower.length && it.lowercase(Locale.ROOT).startsWith(lower) }
            .take(limit)
            .map { present(prefix, it) }
    }

    fun add(raw: String?, word: String): String {
        val cleaned = word.trim()
        if (!isSavable(cleaned)) return normalize(raw)
        val existing = terms(raw).filter { !it.equals(cleaned, ignoreCase = true) }
        return (listOf(cleaned) + existing).take(CAPACITY).joinToString(SEPARATOR)
    }

    fun isSavable(word: String): Boolean {
        val trimmed = word.trim()
        return trimmed.length >= MIN_LENGTH &&
            trimmed.any { it.isLetter() } &&
            trimmed.all { it.isLetter() || it == '\'' }
    }

    /**
     * Keep the stored spelling when the user typed in lowercase — that capital
     * letter is why they saved the word. Honour caps lock / a leading capital
     * the same way the word list does.
     */
    fun present(prefix: String, stored: String): String {
        if (prefix.all { !it.isLetter() || it.isLowerCase() }) return stored
        return SuggestionEngine.matchCase(prefix, stored)
    }
}
