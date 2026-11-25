package com.vocahq.vocaphone.ime

import java.util.Locale

/**
 * What the keyboard remembers about its own corrections, as word pairs only:
 * never the text they were typed in.
 *
 * [rejections] counts how often an automatic fix of `typed → fix` was undone.
 * Undone twice, it is never made automatically again and never offered as the
 * first correction.
 *
 * [picks] counts, for each typo, the strip corrections picked for it. A typo
 * fixed the same way twice, and never another way, is a learned fix: space
 * after typing it makes that fix (see [LearnedFixes]).
 *
 * Keys are lowercase. Both maps are bounded and keep the most recent pairs.
 */
internal data class AutocorrectMemory(
    val rejections: Map<String, Int> = emptyMap(),
    val picks: Map<String, Map<String, Int>> = emptyMap(),
) {
    fun isRejected(typed: String, fix: String): Boolean =
        (rejections[pairKey(typed, fix)] ?: 0) >= REJECTED_AFTER

    /** The fix learned for [typed], lowercase, or null. */
    fun learnedFix(typed: String): String? {
        val fixes = picks[key(typed)] ?: return null
        val (fix, count) = fixes.entries.singleOrNull() ?: return null
        if (count < LEARNED_AFTER || isRejected(typed, fix)) return null
        return fix
    }

    fun withRejection(typed: String, fix: String): AutocorrectMemory {
        val pair = pairKey(typed, fix)
        val next = LinkedHashMap(rejections)
        val count = (next.remove(pair) ?: 0) + 1
        next[pair] = count
        return copy(rejections = next.trimmed())
    }

    fun withPick(typed: String, picked: String): AutocorrectMemory {
        val typedKey = key(typed)
        val pickedKey = key(picked)
        if (typedKey.isEmpty() || pickedKey.isEmpty() || typedKey == pickedKey) return this
        val next = LinkedHashMap(picks)
        val fixes = LinkedHashMap(next.remove(typedKey).orEmpty())
        fixes[pickedKey] = (fixes[pickedKey] ?: 0) + 1
        next[typedKey] = fixes
        return copy(picks = next.trimmed())
    }

    /** One pair per line: `r<TAB>typed<TAB>fix<TAB>count` or `p<TAB>typed<TAB>picked<TAB>count`. */
    fun encode(): String = buildString {
        for ((pair, count) in rejections) append("r\t").append(pair).append('\t').append(count).append('\n')
        for ((typed, fixes) in picks) {
            for ((fix, count) in fixes) {
                append("p\t").append(typed).append('\t').append(fix).append('\t').append(count).append('\n')
            }
        }
    }

    companion object {
        val EMPTY = AutocorrectMemory()

        const val REJECTED_AFTER = 2
        const val LEARNED_AFTER = 2

        /** Pairs kept per map; the oldest go first. */
        const val CAPACITY = 500

        fun key(word: String): String = word.trim().lowercase(Locale.ROOT)

        private fun pairKey(typed: String, fix: String): String = key(typed) + "\t" + key(fix)

        private fun <V> LinkedHashMap<String, V>.trimmed(): Map<String, V> {
            while (size > CAPACITY) remove(keys.first())
            return this
        }

        fun decode(raw: String?): AutocorrectMemory {
            if (raw.isNullOrBlank()) return EMPTY
            val rejections = LinkedHashMap<String, Int>()
            val picks = LinkedHashMap<String, LinkedHashMap<String, Int>>()
            for (line in raw.split('\n')) {
                val fields = line.split('\t')
                if (fields.size != 4) continue
                val count = fields[3].toIntOrNull()?.takeIf { it > 0 } ?: continue
                val typed = key(fields[1])
                val other = key(fields[2])
                if (typed.isEmpty() || other.isEmpty()) continue
                when (fields[0]) {
                    "r" -> rejections["$typed\t$other"] = count
                    "p" -> picks.getOrPut(typed) { LinkedHashMap() }[other] = count
                }
            }
            return AutocorrectMemory(rejections, picks)
        }
    }
}

/** When the strip and the space bar use what [AutocorrectMemory] learned. */
internal object LearnedFixes {
    /**
     * A pick worth counting: a correction, not a completion. "helo → hello"
     * starts with what was typed, so it is the word finished, not fixed.
     */
    fun isCorrection(typed: String, picked: String): Boolean {
        if (typed.length < 2 || picked.isEmpty()) return false
        val typedKey = AutocorrectMemory.key(typed)
        val pickedKey = AutocorrectMemory.key(picked)
        if (!typedKey.any(Char::isLetter) || typedKey == pickedKey) return false
        return !pickedKey.startsWith(typedKey)
    }

    /**
     * What space should turn [typed] into, cased like [typed], or null to type
     * it as it is. Never when [typed] is itself a word ([isWord]: the word
     * list or the personal dictionary), never to a word [blocked] holds back,
     * and never for a word that is itself held back.
     *
     * [personalSpelling] gives the personal dictionary's spelling of a fix, so
     * a learned "vocaphone" still comes out as the "VocaPhone" the user saved.
     */
    fun fixFor(
        typed: String,
        memory: AutocorrectMemory,
        isWord: (String) -> Boolean,
        blocked: (String) -> Boolean,
        personalSpelling: (String) -> String? = { null },
    ): String? {
        if (typed.length < 2 || isWord(typed) || blocked(typed)) return null
        val fix = memory.learnedFix(typed) ?: return null
        if (blocked(fix)) return null
        val stored = personalSpelling(fix)
        return if (stored != null) PersonalDictionary.present(typed, stored) else SuggestionEngine.matchCase(typed, fix)
    }
}

/**
 * A learned fix the space bar just made: delete right after it puts [typed]
 * back, and that counts against the fix.
 */
internal data class LearnedFixUndo(val typed: String, val fixed: String) {
    /** The edit that takes back "[fixed] " and types [typed] again. */
    fun command(): KeyboardCommand = KeyboardCommand.ReplaceBeforeCursor(fixed.length + 1, typed)
}
