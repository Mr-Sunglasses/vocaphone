package com.vocahq.vocaphone.ime

import android.content.res.AssetManager

internal class SuggestionDictionary(
    private val words: List<String>,
    private val bigrams: Map<String, List<String>>,
) {
    fun complete(prefix: String, limit: Int = 3): List<String> {
        if (prefix.isEmpty()) return emptyList()
        val lower = prefix.lowercase()
        return words.asSequence()
            .filter { it.startsWith(lower) && it.length > lower.length }
            .take(limit)
            .map { SuggestionEngine.matchCase(prefix, it) }
            .toList()
    }

    fun next(previousWord: String, limit: Int = 3): List<String> {
        if (previousWord.isEmpty()) return emptyList()
        return bigrams[previousWord.lowercase()].orEmpty().take(limit)
    }

    companion object {
        fun load(assets: AssetManager) = SuggestionDictionary(
            words = assets.open("suggestions/en.txt").bufferedReader().readLines()
                .map { it.trim() }
                .filter { it.isNotEmpty() },
            bigrams = parseBigrams(
                assets.open("suggestions/en-bigrams.txt").bufferedReader().readLines(),
            ),
        )

        fun parseBigrams(lines: List<String>): Map<String, List<String>> = buildMap {
            for (line in lines) {
                val trimmed = line.trim()
                if (trimmed.isEmpty() || trimmed.startsWith("#")) continue
                val tab = trimmed.indexOf('\t')
                if (tab <= 0) continue
                val word = trimmed.substring(0, tab)
                val continuations = trimmed.substring(tab + 1)
                    .split(',')
                    .map { it.trim() }
                    .filter { it.isNotEmpty() }
                if (continuations.isNotEmpty()) put(word, continuations)
            }
        }
    }
}

internal object SuggestionEngine {
    fun lastWord(textBeforeCursor: CharSequence): String? {
        val trimmed = textBeforeCursor.trimEnd()
        if (trimmed.isEmpty()) return null
        var start = trimmed.length
        while (start > 0) {
            val character = trimmed[start - 1]
            if (!character.isLetterOrDigit() && character != '\'') break
            start--
        }
        val word = trimmed.substring(start).replace("'", "").lowercase()
        return word.takeIf { it.any(Char::isLetter) }
    }

    internal fun matchCase(prefix: String, word: String): String = when {
        prefix.all { it.isUpperCase() } -> word.uppercase()
        prefix.first().isUpperCase() -> word.replaceFirstChar { it.uppercase() }
        else -> word
    }
}
