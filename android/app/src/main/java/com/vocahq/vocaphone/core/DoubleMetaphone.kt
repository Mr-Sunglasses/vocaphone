package com.vocahq.vocaphone.core

/**
 * Lawrence Philips' Double Metaphone: a phonetic key for English words and
 * names, with an alternate key for the ones that have two common sounds
 * ("Schmidt" XMT/SMT). Ported from the Apache Commons Codec version, by way of
 * VocaMac's; mirrors `DoubleMetaphone.swift`.
 *
 * [VocabularyCorrection] uses it to tell a misheard spelling of a custom word
 * from an unrelated word: "Kubernetes" and "cooper netties" share the key
 * KPRNTS, "cucumbers" (KKMPRS) does not. A key is evidence, never a match on
 * its own: "cloud" and "Claude" share KLT too.
 */
object DoubleMetaphone {

    data class Key(val primary: String, val alternate: String) {
        /** Whether the two words can sound alike: any key of one equals any key of the other. */
        fun matches(other: Key): Boolean =
            primary == other.primary || primary == other.alternate ||
                alternate == other.primary || alternate == other.alternate
    }

    /**
     * The keys of [word], or null when it isn't plain ASCII letters (the rules
     * are for English spelling) or has no consonant to key on. [maxLength]
     * caps each key; whole terms are compared, so the default is longer than
     * the classic four.
     */
    fun encode(word: String, maxLength: Int = 12): Key? {
        if (word.isEmpty() || !word.all { it in 'a'..'z' || it in 'A'..'Z' }) return null
        val encoder = Encoder(word.uppercase().toCharArray(), maxLength)
        encoder.run()
        if (encoder.primary.isEmpty()) return null
        return Key(encoder.primary.toString(), encoder.alternate.toString())
    }

    private class Encoder(val value: CharArray, val maxLength: Int) {
        val slavoGermanic: Boolean
        val primary = StringBuilder()
        val alternate = StringBuilder()

        init {
            val text = String(value)
            slavoGermanic = text.contains("W") || text.contains("K") || text.contains("CZ") || text.contains("WITZ")
        }

        private val isComplete: Boolean get() = primary.length >= maxLength && alternate.length >= maxLength

        private fun char(index: Int): Char = if (index >= 0 && index < value.size) value[index] else '\u0000'

        private fun isVowel(index: Int): Boolean = char(index) in "AEIOUY" && char(index) != '\u0000'

        private fun contains(start: Int, length: Int, vararg options: String): Boolean {
            if (start < 0 || start + length > value.size) return false
            val slice = String(value, start, length)
            return slice in options
        }

        private fun add(main: String, other: String = main) {
            if (primary.length < maxLength) primary.append(main.take(maxLength - primary.length))
            if (alternate.length < maxLength) alternate.append(other.take(maxLength - alternate.length))
        }

        private fun addPrimary(text: String) {
            if (primary.length < maxLength) primary.append(text.take(maxLength - primary.length))
        }

        private fun addAlternate(text: String) {
            if (alternate.length < maxLength) alternate.append(text.take(maxLength - alternate.length))
        }

        fun run() {
            var index = 0
            if (contains(0, 2, "GN", "KN", "PN", "WR", "PS")) index = 1
            if (char(0) == 'X') {
                add("S")
                index = 1
            }
            while (!isComplete && index < value.size) {
                index = step(index)
            }
        }

        private fun step(index: Int): Int = when (char(index)) {
            'A', 'E', 'I', 'O', 'U', 'Y' -> {
                if (index == 0) add("A")
                index + 1
            }
            'B' -> {
                add("P")
                if (char(index + 1) == 'B') index + 2 else index + 1
            }
            'C' -> handleC(index)
            'D' -> handleD(index)
            'F' -> {
                add("F")
                if (char(index + 1) == 'F') index + 2 else index + 1
            }
            'G' -> handleG(index)
            'H' -> handleH(index)
            'J' -> handleJ(index)
            'K' -> {
                add("K")
                if (char(index + 1) == 'K') index + 2 else index + 1
            }
            'L' -> handleL(index)
            'M' -> {
                add("M")
                if (conditionM0(index)) index + 2 else index + 1
            }
            'N' -> {
                add("N")
                if (char(index + 1) == 'N') index + 2 else index + 1
            }
            'P' -> if (char(index + 1) == 'H') {
                add("F")
                index + 2
            } else {
                add("P")
                if (contains(index + 1, 1, "P", "B")) index + 2 else index + 1
            }
            'Q' -> {
                add("K")
                if (char(index + 1) == 'Q') index + 2 else index + 1
            }
            'R' -> handleR(index)
            'S' -> handleS(index)
            'T' -> handleT(index)
            'V' -> {
                add("F")
                if (char(index + 1) == 'V') index + 2 else index + 1
            }
            'W' -> handleW(index)
            'X' -> handleX(index)
            'Z' -> handleZ(index)
            else -> index + 1
        }

        // C

        private fun handleC(index: Int): Int {
            if (conditionC0(index)) {
                add("K")
                return index + 2
            }
            if (index == 0 && contains(index, 6, "CAESAR")) {
                add("S")
                return index + 2
            }
            if (contains(index, 2, "CH")) return handleCH(index)
            if (contains(index, 2, "CZ") && !contains(index - 2, 4, "WICZ")) {
                add("S", "X")
                return index + 2
            }
            if (contains(index + 1, 3, "CIA")) {
                add("X")
                return index + 3
            }
            if (contains(index, 2, "CC") && !(index == 1 && char(0) == 'M')) return handleCC(index)
            if (contains(index, 2, "CK", "CG", "CQ")) {
                add("K")
                return index + 2
            }
            if (contains(index, 2, "CI", "CE", "CY")) {
                if (contains(index, 3, "CIO", "CIE", "CIA")) add("S", "X") else add("S")
                return index + 2
            }
            add("K")
            if (contains(index + 1, 2, " C", " Q", " G")) return index + 3
            if (contains(index + 1, 1, "C", "K", "Q") && !contains(index + 1, 2, "CE", "CI")) return index + 2
            return index + 1
        }

        private fun conditionC0(index: Int): Boolean {
            if (contains(index, 4, "CHIA")) return true
            if (index <= 1 || isVowel(index - 2) || !contains(index - 1, 3, "ACH")) return false
            val next = char(index + 2)
            return (next != 'I' && next != 'E') || contains(index - 2, 6, "BACHER", "MACHER")
        }

        private fun handleCC(index: Int): Int {
            if (contains(index + 2, 1, "I", "E", "H") && !contains(index + 2, 2, "HU")) {
                if ((index == 1 && char(index - 1) == 'A') || contains(index - 1, 5, "UCCEE", "UCCES")) {
                    add("KS")
                } else {
                    add("X")
                }
                return index + 3
            }
            add("K")
            return index + 2
        }

        private fun handleCH(index: Int): Int {
            if (index > 0 && contains(index, 4, "CHAE")) {
                add("K", "X")
            } else if (conditionCH0(index) || conditionCH1(index)) {
                add("K")
            } else if (index > 0) {
                if (contains(0, 2, "MC")) add("K") else add("X", "K")
            } else {
                add("X")
            }
            return index + 2
        }

        private fun conditionCH0(index: Int): Boolean {
            if (index != 0) return false
            if (!(contains(index + 1, 5, "HARAC", "HARIS") || contains(index + 1, 3, "HOR", "HYM", "HIA", "HEM"))) {
                return false
            }
            return !contains(0, 5, "CHORE")
        }

        private fun conditionCH1(index: Int): Boolean {
            if (contains(0, 4, "VAN ", "VON ") || contains(0, 3, "SCH")) return true
            if (contains(index - 2, 6, "ORCHES", "ARCHIT", "ORCHID") || contains(index + 2, 1, "T", "S")) return true
            val before = contains(index - 1, 1, "A", "O", "U", "E") || index == 0
            val after = contains(index + 2, 1, "L", "R", "N", "M", "B", "H", "F", "V", "W", " ") ||
                index + 1 == value.size - 1
            return before && after
        }

        // D, G, H, J, L, M

        private fun handleD(index: Int): Int {
            if (contains(index, 2, "DG")) {
                if (contains(index + 2, 1, "I", "E", "Y")) {
                    add("J")
                    return index + 3
                }
                add("TK")
                return index + 2
            }
            add("T")
            return if (contains(index, 2, "DT", "DD")) index + 2 else index + 1
        }

        private fun handleG(index: Int): Int {
            val next = char(index + 1)
            if (next == 'H') return handleGH(index)
            if (next == 'N') {
                if (index == 1 && isVowel(0) && !slavoGermanic) {
                    add("KN", "N")
                } else if (!contains(index + 2, 2, "EY") && next != 'Y' && !slavoGermanic) {
                    add("N", "KN")
                } else {
                    add("KN")
                }
                return index + 2
            }
            if (contains(index + 1, 2, "LI") && !slavoGermanic) {
                add("KL", "L")
                return index + 2
            }
            if (index == 0 && (
                    next == 'Y' ||
                        contains(index + 1, 2, "ES", "EP", "EB", "EL", "EY", "IB", "IL", "IN", "IE", "EI", "ER")
                    )
            ) {
                add("K", "J")
                return index + 2
            }
            if ((contains(index + 1, 2, "ER") || next == 'Y') &&
                !contains(0, 6, "DANGER", "RANGER", "MANGER") &&
                !contains(index - 1, 1, "E", "I") && !contains(index - 1, 3, "RGY", "OGY")
            ) {
                add("K", "J")
                return index + 2
            }
            if (contains(index + 1, 1, "E", "I", "Y") || contains(index - 1, 4, "AGGI", "OGGI")) {
                if (contains(0, 4, "VAN ", "VON ") || contains(0, 3, "SCH") || contains(index + 1, 2, "ET")) {
                    add("K")
                } else if (contains(index + 1, 3, "IER")) {
                    add("J")
                } else {
                    add("J", "K")
                }
                return index + 2
            }
            add("K")
            return if (next == 'G') index + 2 else index + 1
        }

        private fun handleGH(index: Int): Int {
            if (index > 0 && !isVowel(index - 1)) {
                add("K")
                return index + 2
            }
            if (index == 0) {
                add(if (char(index + 2) == 'I') "J" else "K")
                return index + 2
            }
            if ((index > 1 && contains(index - 2, 1, "B", "H", "D")) ||
                (index > 2 && contains(index - 3, 1, "B", "H", "D")) ||
                (index > 3 && contains(index - 4, 1, "B", "H"))
            ) {
                return index + 2
            }
            if (index > 2 && char(index - 1) == 'U' && contains(index - 3, 1, "C", "G", "L", "R", "T")) {
                add("F")
            } else if (index > 0 && char(index - 1) != 'I') {
                add("K")
            }
            return index + 2
        }

        private fun handleH(index: Int): Int {
            if ((index == 0 || isVowel(index - 1)) && isVowel(index + 1)) {
                add("H")
                return index + 2
            }
            return index + 1
        }

        private fun handleJ(index: Int): Int {
            if (contains(index, 4, "JOSE") || contains(0, 4, "SAN ")) {
                if ((index == 0 && char(index + 4) == ' ') || value.size == 4 || contains(0, 4, "SAN ")) {
                    add("H")
                } else {
                    add("J", "H")
                }
                return index + 1
            }
            if (index == 0 && !contains(index, 4, "JOSE")) {
                add("J", "A")
            } else if (isVowel(index - 1) && !slavoGermanic && (char(index + 1) == 'A' || char(index + 1) == 'O')) {
                add("J", "H")
            } else if (index == value.size - 1) {
                addPrimary("J")
            } else if (!contains(index + 1, 1, "L", "T", "K", "S", "N", "M", "B", "Z") &&
                !contains(index - 1, 1, "S", "K", "L")
            ) {
                add("J")
            }
            return if (char(index + 1) == 'J') index + 2 else index + 1
        }

        private fun handleL(index: Int): Int {
            if (char(index + 1) != 'L') {
                add("L")
                return index + 1
            }
            if (conditionL0(index)) addPrimary("L") else add("L")
            return index + 2
        }

        private fun conditionL0(index: Int): Boolean {
            if (index == value.size - 3 && contains(index - 1, 4, "ILLO", "ILLA", "ALLE")) return true
            return (contains(value.size - 2, 2, "AS", "OS") || contains(value.size - 1, 1, "A", "O")) &&
                contains(index - 1, 4, "ALLE")
        }

        private fun conditionM0(index: Int): Boolean {
            if (char(index + 1) == 'M') return true
            return contains(index - 1, 3, "UMB") && (index + 1 == value.size - 1 || contains(index + 2, 2, "ER"))
        }

        // R, S, T, W, X, Z

        private fun handleR(index: Int): Int {
            if (index == value.size - 1 && !slavoGermanic && contains(index - 2, 2, "IE") &&
                !contains(index - 4, 2, "ME", "MA")
            ) {
                addAlternate("R")
            } else {
                add("R")
            }
            return if (char(index + 1) == 'R') index + 2 else index + 1
        }

        private fun handleS(index: Int): Int {
            if (contains(index - 1, 3, "ISL", "YSL")) return index + 1
            if (index == 0 && contains(index, 5, "SUGAR")) {
                add("X", "S")
                return index + 1
            }
            if (contains(index, 2, "SH")) {
                add(if (contains(index + 1, 4, "HEIM", "HOEK", "HOLM", "HOLZ")) "S" else "X")
                return index + 2
            }
            if (contains(index, 3, "SIO", "SIA") || contains(index, 4, "SIAN")) {
                if (slavoGermanic) add("S") else add("S", "X")
                return index + 3
            }
            if ((index == 0 && contains(index + 1, 1, "M", "N", "L", "W")) || contains(index + 1, 1, "Z")) {
                add("S", "X")
                return if (contains(index + 1, 1, "Z")) index + 2 else index + 1
            }
            if (contains(index, 2, "SC")) return handleSC(index)
            if (index == value.size - 1 && contains(index - 2, 2, "AI", "OI")) {
                addAlternate("S")
            } else {
                add("S")
            }
            return if (contains(index + 1, 1, "S", "Z")) index + 2 else index + 1
        }

        private fun handleSC(index: Int): Int {
            if (char(index + 2) == 'H') {
                if (contains(index + 3, 2, "OO", "ER", "EN", "UY", "ED", "EM")) {
                    if (contains(index + 3, 2, "ER", "EN")) add("X", "SK") else add("SK")
                } else if (index == 0 && !isVowel(3) && char(3) != 'W') {
                    add("X", "S")
                } else {
                    add("X")
                }
            } else if (contains(index + 2, 1, "I", "E", "Y")) {
                add("S")
            } else {
                add("SK")
            }
            return index + 3
        }

        private fun handleT(index: Int): Int {
            if (contains(index, 4, "TION") || contains(index, 3, "TIA", "TCH")) {
                add("X")
                return index + 3
            }
            if (contains(index, 2, "TH") || contains(index, 3, "TTH")) {
                if (contains(index + 2, 2, "OM", "AM") || contains(0, 4, "VAN ", "VON ") || contains(0, 3, "SCH")) {
                    add("T")
                } else {
                    add("0", "T")
                }
                return index + 2
            }
            add("T")
            return if (contains(index + 1, 1, "T", "D")) index + 2 else index + 1
        }

        private fun handleW(index: Int): Int {
            if (contains(index, 2, "WR")) {
                add("R")
                return index + 2
            }
            if (index == 0 && (isVowel(index + 1) || contains(index, 2, "WH"))) {
                if (isVowel(index + 1)) add("A", "F") else add("A")
                return index + 1
            }
            if ((index == value.size - 1 && isVowel(index - 1)) ||
                contains(index - 1, 5, "EWSKI", "EWSKY", "OWSKI", "OWSKY") || contains(0, 3, "SCH")
            ) {
                addAlternate("F")
                return index + 1
            }
            if (contains(index, 4, "WICZ", "WITZ")) {
                add("TS", "FX")
                return index + 4
            }
            return index + 1
        }

        private fun handleX(index: Int): Int {
            if (index == 0) {
                add("S")
                return index + 1
            }
            val silentEnding = index == value.size - 1 &&
                (contains(index - 3, 3, "IAU", "EAU") || contains(index - 2, 2, "AU", "OU"))
            if (!silentEnding) add("KS")
            return if (contains(index + 1, 1, "C", "X")) index + 2 else index + 1
        }

        private fun handleZ(index: Int): Int {
            if (char(index + 1) == 'H') {
                add("J")
                return index + 2
            }
            if (contains(index + 1, 2, "ZO", "ZI", "ZA") || (slavoGermanic && index > 0 && char(index - 1) != 'T')) {
                add("S", "TS")
            } else {
                add("S")
            }
            return if (char(index + 1) == 'Z') index + 2 else index + 1
        }
    }
}
