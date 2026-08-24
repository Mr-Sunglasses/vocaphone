package com.vocahq.vocaphone.ime

import java.util.Locale

internal object KeyAccents {
    /**
     * Letter → first row of the `?123` page. Hold-and-release types the hint;
     * accents stay in the same popup behind it.
     *
     * q-p are `1`-`0`. a-l and z-m follow the two punctuation rows under
     * those digits (`@#$…` then `*"'…`).
     */
    private val letterSymbols = mapOf(
        "q" to "1", "w" to "2", "e" to "3", "r" to "4", "t" to "5",
        "y" to "6", "u" to "7", "i" to "8", "o" to "9", "p" to "0",
        "a" to "@", "s" to "#", "d" to "$", "f" to "_", "g" to "&",
        "h" to "-", "j" to "+", "k" to "(", "l" to ")",
        "z" to "*", "x" to "\"", "c" to "'", "v" to ":", "b" to ";",
        "n" to "!", "m" to "?",
    )

    /**
     * When the number row already shows `1`-`0`, q-p would be blank if they
     * kept those digits. They take the first row of the `#+=` page instead.
     */
    private val qwertySymbolsWhenNumberRow = mapOf(
        "q" to "[", "w" to "]", "e" to "{", "r" to "}", "t" to "#",
        "y" to "%", "u" to "^", "i" to "*", "o" to "+", "p" to "=",
    )

    private val variants = mapOf(
        "a" to listOf("à", "á", "â", "ä", "æ", "ã", "å", "ā"),
        "c" to listOf("ç", "ć", "č"),
        "d" to listOf("ð"),
        "e" to listOf("è", "é", "ê", "ë", "ē", "ė", "ę"),
        "g" to listOf("ğ"),
        "i" to listOf("ì", "í", "î", "ï", "ī", "į"),
        "l" to listOf("ł"),
        "n" to listOf("ñ", "ń"),
        "o" to listOf("ò", "ó", "ô", "ö", "õ", "ø", "ō", "œ"),
        "s" to listOf("ß", "ś", "š"),
        "u" to listOf("ù", "ú", "û", "ü", "ū"),
        "y" to listOf("ý", "ÿ"),
        "z" to listOf("ž", "ź", "ż"),
        "'" to listOf("'", "‘", "’", "‚"),
        "\"" to listOf("\"", "“", "”", "„"),
        "-" to listOf("-", "–", "—", "•"),
        "." to listOf(".", "…"),
        "?" to listOf("?", "¿"),
        "!" to listOf("!", "¡"),
        "$" to listOf("$", "€", "£", "¥", "₹", "₩"),
        "1" to listOf("!"),
        "2" to listOf("@"),
        "3" to listOf("#"),
        "4" to listOf("$"),
        "5" to listOf("%"),
        "6" to listOf("^"),
        "7" to listOf("&"),
        "8" to listOf("*"),
        "9" to listOf("("),
        "0" to listOf(")"),
    )

    fun forKey(
        key: KeyboardKey,
        shift: ShiftState,
        longPressSymbols: Boolean = false,
        numberRow: Boolean = false,
    ): List<String> {
        if (key.type != KeyboardKeyType.CHARACTER) return emptyList()
        val base = key.output.lowercase(Locale.ROOT)
        val accents = variants[base].orEmpty()
        val symbol = letterSymbol(base, longPressSymbols, numberRow)
        if (symbol == null && accents.isEmpty()) return emptyList()
        val shiftedAccents = if (shift == ShiftState.OFF) {
            accents
        } else {
            accents.map { it.uppercase(Locale.ROOT) }
        }
        // The hinted symbol does not follow shift: long-press e is 3, not #,
        // whether or not caps is on. Accents still capitalise.
        return (listOfNotNull(symbol) + shiftedAccents).distinct()
    }

    /**
     * Light corner mark. Digits keep `!` on `1` when number-key hints are on.
     * Letters show a `?123` / `#+=` symbol when long-press-for-symbols is on.
     * q-p show `1`-`0` unless the number row is already there, then the
     * first `#+=` row (`[]{}#%^*+=`).
     */
    fun hint(
        key: KeyboardKey,
        numberKeyHints: Boolean = true,
        longPressSymbols: Boolean = false,
        numberRow: Boolean = false,
    ): String? {
        if (key.type != KeyboardKeyType.CHARACTER) return null
        val base = key.output
        if (base.length != 1) return null
        if (base[0].isDigit()) {
            return if (numberKeyHints) variants[base]?.firstOrNull() else null
        }
        return letterSymbol(base.lowercase(Locale.ROOT), longPressSymbols, numberRow)
    }

    private fun letterSymbol(
        base: String,
        longPressSymbols: Boolean,
        numberRow: Boolean,
    ): String? {
        if (!longPressSymbols) return null
        if (numberRow) qwertySymbolsWhenNumberRow[base]?.let { return it }
        return letterSymbols[base]
    }
}
