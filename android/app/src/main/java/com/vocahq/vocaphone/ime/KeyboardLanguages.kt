package com.vocahq.vocaphone.ime

import com.vocahq.vocaphone.settings.VocaPhoneSettings

/**
 * One typing layout: the three letter rows and what a hold on a letter
 * offers in that language. The same seven as iOS's `TypingLayout.catalogue`
 * (ios/VocaPhoneShared/KeyboardPreferences.swift), with the same rows.
 */
internal data class TypingLayout(
    val id: String,
    /** On the language key and in compact places: EN, РУ. */
    val shortName: String,
    /** On the space bar and in Settings, in its own language. */
    val displayName: String,
    /** Unshifted letter rows, top to bottom. */
    val rows: List<String>,
    /**
     * Accents a hold on a letter offers first in this language, before the
     * general Latin table. Cyrillic letters that have no key of their own
     * (ё, ъ, ґ) are here too: for them a hold is the only way to type them.
     */
    val accents: Map<String, List<String>> = emptyMap(),
) {
    /**
     * The English word list, swipe typing, autocorrect and the suggestion
     * strip only make sense on the English layout. Correction code reads
     * this (or [KeyboardLanguages.isEnglishLayout]) rather than guessing
     * from the text.
     */
    val isEnglish: Boolean get() = id == KeyboardLanguages.ENGLISH.id

    /**
     * Hold-for-symbols by position, so AZERTY's `a` (top row, first key)
     * offers 1 just as QWERTY's `q` does: top row 1-0, home row `@#$_&-+()`,
     * bottom row `*"':;!?`, matching the `?123` page under them.
     */
    val positionalSymbols: Map<String, String> by lazy {
        buildMap {
            rows.getOrNull(0)?.forEachIndexed { index, letter -> TOP_SYMBOLS.getOrNull(index)?.let { put(letter.toString(), it) } }
            rows.getOrNull(1)?.forEachIndexed { index, letter -> HOME_SYMBOLS.getOrNull(index)?.let { put(letter.toString(), it) } }
            rows.getOrNull(2)?.forEachIndexed { index, letter -> BOTTOM_SYMBOLS.getOrNull(index)?.let { put(letter.toString(), it) } }
        }
    }

    /** The top row's symbols when the number row already shows 1-0: the first `#+=` row. */
    val positionalSymbolsWithNumberRow: Map<String, String> by lazy {
        buildMap {
            rows.getOrNull(0)?.forEachIndexed { index, letter ->
                NUMBER_ROW_TOP_SYMBOLS.getOrNull(index)?.let { put(letter.toString(), it) }
            }
        }
    }

    private companion object {
        val TOP_SYMBOLS = listOf("1", "2", "3", "4", "5", "6", "7", "8", "9", "0")
        val HOME_SYMBOLS = listOf("@", "#", "$", "_", "&", "-", "+", "(", ")")
        val BOTTOM_SYMBOLS = listOf("*", "\"", "'", ":", ";", "!", "?")
        val NUMBER_ROW_TOP_SYMBOLS = listOf("[", "]", "{", "}", "#", "%", "^", "*", "+", "=")
    }
}

internal object KeyboardLanguages {
    private const val QWERTY_TOP = "qwertyuiop"
    private const val QWERTY_HOME = "asdfghjkl"

    val ENGLISH = TypingLayout(
        id = "en",
        shortName = "EN",
        displayName = "English",
        rows = listOf(QWERTY_TOP, QWERTY_HOME, "zxcvbnm"),
    )

    /**
     * The layouts, in the order Settings lists them. Same set as iOS: seven,
     * each with its own rows and accents.
     */
    val catalogue: List<TypingLayout> = listOf(
        ENGLISH,
        TypingLayout(
            id = "es",
            shortName = "ES",
            displayName = "Español",
            // ñ is a letter in Spanish, so it has a key, as on iOS and Gboard.
            rows = listOf(QWERTY_TOP, "asdfghjklñ", "zxcvbnm"),
            accents = mapOf(
                "a" to listOf("á"), "e" to listOf("é"), "i" to listOf("í"),
                "o" to listOf("ó"), "u" to listOf("ú", "ü"), "n" to listOf("ñ"),
            ),
        ),
        TypingLayout(
            id = "pt",
            shortName = "PT",
            displayName = "Português",
            rows = listOf(QWERTY_TOP, QWERTY_HOME, "zxcvbnm"),
            accents = mapOf(
                "a" to listOf("á", "â", "ã", "à"), "c" to listOf("ç"), "e" to listOf("é", "ê"),
                "i" to listOf("í"), "o" to listOf("ó", "ô", "õ"), "u" to listOf("ú", "ü"),
            ),
        ),
        TypingLayout(
            id = "fr",
            shortName = "FR",
            displayName = "Français",
            rows = listOf("azertyuiop", "qsdfghjklm", "wxcvbn"),
            accents = mapOf(
                "a" to listOf("à", "â", "æ"), "c" to listOf("ç"), "e" to listOf("é", "è", "ê", "ë"),
                "i" to listOf("î", "ï"), "o" to listOf("ô", "œ"), "u" to listOf("ù", "û", "ü"),
                "y" to listOf("ÿ"),
            ),
        ),
        TypingLayout(
            id = "de",
            shortName = "DE",
            displayName = "Deutsch",
            rows = listOf("qwertzuiop", QWERTY_HOME, "yxcvbnm"),
            accents = mapOf(
                "a" to listOf("ä"), "o" to listOf("ö"), "u" to listOf("ü"), "s" to listOf("ß"),
            ),
        ),
        TypingLayout(
            id = "ru",
            shortName = "РУ",
            displayName = "Русский",
            // 33 letters over 31 keys: ё behind е and ъ behind ь, as on iOS.
            rows = listOf("йцукенгшщзх", "фывапролджэ", "ячсмитьбю"),
            accents = mapOf("е" to listOf("ё"), "ь" to listOf("ъ")),
        ),
        TypingLayout(
            id = "uk",
            shortName = "УК",
            displayName = "Українська",
            // ї has a key; ґ is rare enough to sit behind г, as on iOS.
            rows = listOf("йцукенгшщзхї", "фівапролджє", "ячсмитьбю"),
            accents = mapOf("г" to listOf("ґ")),
        ),
    )

    fun layout(id: String): TypingLayout? = catalogue.firstOrNull { it.id == id }

    /**
     * The layouts when none were ever chosen: English first, plus one for each
     * of the phone's languages the catalogue has. English is always in, so a
     * user upgrading from the English-only keyboard on a German phone keeps
     * English (and its suggestions, autocorrect and swipe) with a language key
     * to reach German, rather than waking up on German with no way back.
     * Turning English off is an explicit choice in Settings.
     * [languageTags] are BCP 47 tags, `ru-RU`.
     */
    fun forPreferredLanguages(languageTags: List<String>): List<TypingLayout> {
        val subtags = languageTags.map { it.substringBefore('-').substringBefore('_').lowercase() }.toSet()
        return catalogue.filter { it.isEnglish || it.id in subtags }
    }

    /** The layouts turned on, in catalogue order; nothing stored follows the phone. */
    fun enabled(storedIds: List<String>, languageTags: List<String>): List<TypingLayout> {
        if (storedIds.isEmpty()) return forPreferredLanguages(languageTags)
        val chosen = catalogue.filter { it.id in storedIds }
        return chosen.ifEmpty { listOf(ENGLISH) }
    }

    /** The layout to type on: the stored one if it is still on, else the first that is. */
    fun active(activeId: String, enabled: List<TypingLayout>): TypingLayout =
        enabled.firstOrNull { it.id == activeId } ?: enabled.firstOrNull() ?: ENGLISH

    /** The layout after [current], wrapping; null when there is only one. */
    fun next(current: TypingLayout, enabled: List<TypingLayout>, forward: Boolean = true): TypingLayout? {
        if (enabled.size < 2) return null
        val index = enabled.indexOfFirst { it.id == current.id }
        if (index < 0) return enabled.first()
        val step = if (forward) 1 else enabled.size - 1
        return enabled[(index + step) % enabled.size]
    }

    /** Settings' toggle: [id] on or off, never leaving no layout at all. */
    fun toggled(current: List<TypingLayout>, id: String, on: Boolean): List<String> {
        val ids = current.map { it.id }.toMutableSet()
        if (on) ids.add(id) else ids.remove(id)
        if (ids.isEmpty()) return current.map { it.id }
        return catalogue.filter { it.id in ids }.map { it.id }
    }

    /** What the keyboard is typing in right now, for code outside the composable. */
    fun activeFor(settings: VocaPhoneSettings, languageTags: List<String>): TypingLayout =
        active(settings.activeKeyboardLayout, enabled(settings.keyboardLayouts, languageTags))

    /**
     * The single switch the English-only machinery (word list suggestions,
     * swipe, autocorrect, learned fixes) reads: false on Spanish, Russian
     * and the rest, where English corrections would be wrong.
     */
    fun isEnglishLayout(settings: VocaPhoneSettings, languageTags: List<String>): Boolean =
        activeFor(settings, languageTags).isEnglish

    /** The phone's languages as BCP 47 tags, most preferred first. */
    fun deviceLanguageTags(): List<String> {
        val locales = android.os.LocaleList.getDefault()
        return (0 until locales.size()).map { locales[it].toLanguageTag() }
    }
}
