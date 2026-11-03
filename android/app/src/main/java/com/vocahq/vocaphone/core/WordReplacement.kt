package com.vocahq.vocaphone.core

import java.util.UUID
import org.json.JSONArray
import org.json.JSONObject

/**
 * What an engine keeps writing for something the user says, and what to write
 * instead: "get hub" → "GitHub", "cube cuttle, cube control" → "kubectl".
 * Custom words fix close spellings of a word; a replacement is for the hearing
 * no spelling rule would connect to it. Mirrors `WordReplacement.swift`, and
 * the JSON is the same on both platforms.
 */
data class WordReplacement(
    val id: String = UUID.randomUUID().toString(),
    /** One or more heard forms, comma separated. Matching ignores case. */
    val heard: String,
    /** Exactly what to type instead. */
    val written: String,
) {
    /** Each non-empty heard form, its inner whitespace a single space. */
    val heardForms: List<String>
        get() = heard.split(',')
            .map { form -> form.split(WHITESPACE).filter { it.isNotEmpty() }.joinToString(" ") }
            .filter { it.isNotEmpty() }

    val isValid: Boolean
        get() = heardForms.isNotEmpty() && written.isNotBlank()

    private fun toJson(): JSONObject = JSONObject().apply {
        put("id", id)
        put("heard", heard)
        put("written", written)
    }

    companion object {
        private val WHITESPACE = Regex("\\s+")

        fun encode(replacements: List<WordReplacement>): String =
            JSONArray(replacements.map { it.toJson() }).toString()

        /** Corrupt or unreadable storage is no replacements rather than a failed dictation. */
        fun decode(stored: String?): List<WordReplacement> {
            if (stored.isNullOrBlank()) return emptyList()
            return runCatching {
                val array = JSONArray(stored)
                List(array.length()) { index ->
                    val entry = array.getJSONObject(index)
                    WordReplacement(
                        id = entry.getString("id"),
                        heard = entry.getString("heard"),
                        written = entry.getString("written"),
                    )
                }
            }.getOrDefault(emptyList())
        }
    }
}

/**
 * Applies [WordReplacement]s to a transcript, and the list operations both
 * Settings and anything that learns a replacement share. Mirrors
 * `WordReplacements` in `WordReplacement.swift`.
 */
object WordReplacements {

    /** [text] after [apply], and where the written forms sit in it. */
    data class Applied(val text: String, val written: List<IntRange>)

    /**
     * [list] with [heard] → [written] added. A row that already writes
     * [written] takes the heard form beside its own, so one target stays one
     * row; a heard form some row already has, compared ignoring case, is taken
     * off that row first, so it never fires two ways. Several heard forms
     * separated by commas ("get hub, git hub") are each added. Invalid input
     * returns [list] unchanged.
     */
    fun adding(heard: String, written: String, list: List<WordReplacement>): List<WordReplacement> {
        val forms = heard.split(',')
        if (forms.size > 1) return forms.fold(list) { result, form -> adding(form, written, result) }
        val form = heard.split(Regex("\\s+")).filter { it.isNotEmpty() }.joinToString(" ")
        val target = written.trim()
        if (form.isEmpty() || form.contains(',') || target.isEmpty()) return list
        val lowered = form.lowercase()
        val result = mutableListOf<WordReplacement>()
        for (row in list) {
            val forms = row.heardForms
            val kept = forms.filter { it.lowercase() != lowered }
            if (kept.size != forms.size) {
                if (kept.isEmpty()) continue
                result += row.copy(heard = kept.joinToString(", "))
            } else {
                result += row
            }
        }
        val index = result.indexOfFirst { it.written == target }
        if (index >= 0) {
            result[index] = result[index].copy(heard = (result[index].heardForms + form).joinToString(", "))
        } else {
            result += WordReplacement(heard = form, written = target)
        }
        return result
    }

    /**
     * The written forms worth a speech model listening for, in list order. See
     * [RecognitionHints.isHintableReplacement].
     */
    fun hintTargets(replacements: List<WordReplacement>): List<String> =
        replacements.filter { it.isValid }.map { it.written }

    /**
     * [text] with every heard form replaced by its written form.
     *
     * Whole words only, ignoring case, longest heard form first so "open ai
     * studio" wins over "open ai" where both match. One pass, left to right: a
     * written form is never matched again. A match that overlaps
     * [protectedRanges] — a snippet trigger, which expands later — is left as
     * it is. Returns the new text and where the written forms sit in it, for
     * the stages after this one to leave alone.
     */
    fun apply(
        text: String,
        replacements: List<WordReplacement>,
        protectedRanges: List<IntRange> = emptyList(),
    ): Applied {
        val forms = forms(replacements)
        if (text.isEmpty() || forms.isEmpty()) return Applied(text, emptyList())
        val output = StringBuilder()
        val written = mutableListOf<IntRange>()
        var copiedUpTo = 0
        var index = 0
        while (index < text.length) {
            val form = forms.firstOrNull { matches(it, index, text, protectedRanges) }
            if (form == null) {
                index += 1
                continue
            }
            output.append(text, copiedUpTo, index)
            val start = output.length
            output.append(form.written)
            written += start until output.length
            index += form.heard.length
            copiedUpTo = index
        }
        if (written.isEmpty()) return Applied(text, emptyList())
        output.append(text, copiedUpTo, text.length)
        return Applied(output.toString(), written)
    }

    private class Form(val heard: String, val written: String) {
        val startsWithWord = isWordCodePoint(heard.codePointAt(0))
        val endsWithWord = isWordCodePoint(heard.codePointBefore(heard.length))
    }

    // Stable, so of two equally long forms the earlier row wins.
    private fun forms(replacements: List<WordReplacement>): List<Form> =
        replacements.filter { it.isValid }
            .flatMap { replacement -> replacement.heardForms.map { Form(it, replacement.written) } }
            .sortedByDescending { it.heard.length }

    /**
     * Whether [form] is heard at [index]: the same characters ignoring case,
     * starting and ending on a word boundary — or, for a form that starts or
     * ends with punctuation, on whitespace — and touching no protected range.
     */
    private fun matches(form: Form, index: Int, text: String, protected: List<IntRange>): Boolean {
        val end = index + form.heard.length
        if (end > text.length || !text.regionMatches(index, form.heard, 0, form.heard.length, ignoreCase = true)) {
            return false
        }
        // A match must not begin or end inside a character: between a
        // surrogate pair's halves, or before a combining mark.
        if (index > 0 && Character.isLowSurrogate(text[index])) return false
        if (end < text.length && Character.isLowSurrogate(text[end])) return false
        if (index > 0) {
            val before = text.codePointBefore(index)
            if (if (form.startsWithWord) isWordCodePoint(before) else !Character.isWhitespace(before)) return false
        }
        if (end < text.length) {
            val after = text.codePointAt(end)
            if (if (form.endsWithWord) isWordCodePoint(after) else !Character.isWhitespace(after)) return false
        }
        return protected.none { it.first < end && index <= it.last }
    }

    /**
     * Letters and digits, and what is written inside a word without being
     * either: combining marks (a Devanagari vowel sign, an accent typed as a
     * separate mark) and the zero-width joiners Indic scripts use. Without them
     * "कल" matched the start of "कला" and left its vowel sign behind. iOS
     * compares whole characters (grapheme clusters), so it never splits one.
     */
    private fun isWordCodePoint(codePoint: Int): Boolean {
        if (Character.isLetterOrDigit(codePoint)) return true
        if (codePoint == 0x200C || codePoint == 0x200D) return true
        return when (Character.getType(codePoint).toByte()) {
            Character.NON_SPACING_MARK, Character.COMBINING_SPACING_MARK, Character.ENCLOSING_MARK -> true
            else -> false
        }
    }
}
