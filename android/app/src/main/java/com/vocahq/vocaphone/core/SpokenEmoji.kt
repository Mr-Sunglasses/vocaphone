package com.vocahq.vocaphone.core

/**
 * Turns a dictated descriptor followed by the word "emoji" into the glyph:
 * "I'm so sad crying emoji crying emoji" becomes "I'm so sad 😭 😭".
 *
 * Deliberately **not** part of [TranscriptStyler]. That stage documents a
 * contract it has to keep — no style adds, removes, or substitutes a word —
 * and this stage exists to break it, under a switch of its own, exactly as
 * [TranscriptRepair] and [SpokenNumbers] do. Keeping them apart is what lets
 * the styles still be described honestly in Settings.
 *
 * The phrase table is [EmojiTable], the same generated file the typing strip
 * reads. What is *not* borrowed from the strip is its fuzzy matching: the strip
 * may offer 💀 for a near-miss because a suggestion is an offer the user
 * ignores, while this writes text straight to the cursor. Exact keys only.
 *
 * Conservative in the same way [SpokenNumbers] is, and for the same reason —
 * the obvious implementation produces text nobody would send:
 *
 * * A trigger with no recognized descriptor in front of it is left exactly as
 *   spoken. "Send me the emoji" survives untouched; this never guesses.
 * * Only a space or a hyphen joins a descriptor to its trigger. "I'm sad,
 *   crying emoji" converts "crying"; a comma ends the phrase rather than being
 *   read through.
 * * The longest phrase wins, so "loudly crying emoji" is 😭 and not
 *   "loudly 😭".
 *
 * English only, which is what the settings copy says. `suggestions.tsv` is
 * generated from the English CLDR annotations, so a Hindi or Japanese
 * transcript matches nothing and passes through untouched rather than being
 * partially mangled.
 *
 * Mirrors the iOS client's `SpokenEmoji`; the two are expected to produce the
 * same text for the same transcript.
 */
object SpokenEmoji {
    /**
     * The words that trigger a lookup. "emojis" is here because people
     * pluralize it; "emoji" is not itself a key in the table, so a trigger can
     * never match itself.
     */
    val TRIGGER_WORDS = setOf("emoji", "emojis")

    /**
     * Replaces every `<descriptor> emoji` span with its glyph.
     *
     * The span replaced covers the descriptor and the trigger word and nothing
     * else, which is why there is no spacing or punctuation repair here.
     * Styling has already run by this point, so the trigger arrives carrying
     * whatever mark the style put on it — "crying emoji." under CLEAN,
     * "crying emoji!" under EXCITED — and replacing only the words leaves that
     * mark, and the spaces on either side, exactly where they were. That also
     * makes the stage correct in scripts that do not put a space between
     * sentences, without needing to know which script it is in.
     */
    fun glyphsIn(text: String, language: String = "auto"): String {
        // Almost every transcript has no trigger in it at all, and this stage
        // runs on every one of them, so the "nothing to do" case is the one
        // worth being cheap. Everything below — masking, tokenizing, the walk —
        // is skipped for a transcript that cannot contain the trigger.
        //
        // The test is one character: "emoji" contains a "j", so text with no
        // "j" in it cannot contain "emoji". That is strictly weaker than the
        // word-boundary rule further down, so it can only skip work that was
        // going to find nothing, and it costs a fraction of the
        // case-insensitive substring search it replaces.
        if (text.isEmpty() || text.none { it == 'j' || it == 'J' }) return text
        if (EmojiTable.triggers.isEmpty()) return text

        // Masked so a descriptor cannot be eaten out of an address:
        // "crying emoji.com" is a hostname, not a trigger.
        val spans = ProtectedSpans.mask(text)
        val masked = spans.text
        val words = wordPattern.findAll(masked).toList()
        if (words.isEmpty()) return text

        val result = StringBuilder()
        var copied = 0
        var previousWasGlyph = false
        for (index in words.indices) {
            if (words[index].value.lowercase() !in TRIGGER_WORDS) continue
            val match = descriptorBefore(index, words, masked) ?: continue
            if (match.start < copied) continue
            val between = masked.substring(copied, match.start)
            result.append(if (previousWasGlyph) separating(between) else between)
            result.append(match.glyph)
            copied = words[index].range.last + 1
            previousWasGlyph = true
        }
        if (copied == 0) return text
        result.append(closing(masked.substring(copied), language, text))
        return spans.restore(result.toString())
    }

    /**
     * The text after the final glyph, with a sentence terminator that is all it
     * consists of dropped.
     *
     * The styler ends a sentence because a sentence needs an end, and it did
     * that while the last word was still "emoji". An emoji *is* the end: people
     * write "I'm so sad 😭" and "💯", not "I'm so sad 😭." — the glyph does the
     * job the full stop was there to do.
     *
     * Only the terminator goes, never an exclamation or a question mark, for
     * exactly the reason [TranscriptStyler]'s casual style already gives for
     * dropping one and keeping the others: a full stop is structure, while "!"
     * and "?" carry meaning that was in what the user said. So EXCITED still
     * ends "😭!" and a dictated question still ends "😭?".
     *
     * Only when the terminator is the *whole* tail. "crying emoji is how I
     * feel." keeps its full stop, because that one is ending a sentence the
     * glyph merely started.
     */
    private fun closing(tail: String, language: String, source: String): String {
        val punctuation = SentencePunctuation.resolve(language, source)
        // Thai and Lao end a sentence with nothing at all, so there is no mark
        // to drop and an empty terminator would match every tail.
        if (punctuation.terminator.isEmpty()) return tail
        return if (tail.trim() == punctuation.terminator) "" else tail
    }

    private class Descriptor(val glyph: String, val start: Int)

    /**
     * What to put between two glyphs this stage produced, given the text that
     * was between their phrases.
     *
     * Somebody dictating three emoji in a row pauses between them, and a speech
     * model writes a pause down as a comma: "crying emoji, crying emoji, crying
     * emoji" is what the transcript says, and substituting each phrase in place
     * leaves "😭, 😭, 😭". Nobody punctuates a run of emoji — they are written
     * "😭 😭 😭" — so when nothing but marks and space separates two of them,
     * that collapses to a single space.
     *
     * Deliberately narrow. It applies only between two glyphs this call just
     * inserted, never to punctuation anywhere else in the transcript: a comma
     * after the last emoji still belongs to the sentence that continues past
     * it, and "fire emoji, then home" keeps its comma. A terminator counts as
     * well as a separator, because a longer pause is written down as a full
     * stop and "😭. 😭." is no more something a person types than "😭, 😭".
     */
    private fun separating(between: String): String {
        if (between.isEmpty()) return between
        val onlyMarks = between.all {
            it.isWhitespace() || it in SentencePunctuation.UNIVERSAL_MARKS
        }
        return if (onlyMarks) " " else between
    }

    /**
     * Walks backwards from the trigger, growing a candidate key one word at a
     * time and remembering the longest one the table knows.
     *
     * The walk is bounded by the table's own widest key rather than by a word
     * count, because a key has had its spaces removed and cannot say how many
     * words built it. Growing past that length can only produce keys the table
     * does not contain.
     */
    private fun descriptorBefore(
        trigger: Int,
        words: List<MatchResult>,
        text: String,
    ): Descriptor? {
        var best: Descriptor? = null
        var key = ""
        var index = trigger - 1
        while (index >= 0 && isJoiner(index, words, text)) {
            key = words[index].value.lowercase() + key
            if (key.length > EmojiTable.widestKeyLength) break
            EmojiTable.glyphForKey(key)?.let { best = Descriptor(it, words[index].range.first) }
            index -= 1
        }
        return best
    }

    /**
     * Whether the gap between this word and the next one is nothing but a space
     * or a hyphen. Any punctuation in between ends the phrase: "sad, crying
     * emoji" is two clauses, whatever the words concatenate to.
     */
    private fun isJoiner(index: Int, words: List<MatchResult>, text: String): Boolean {
        val gap = text.substring(words[index].range.last + 1, words[index + 1].range.first)
        return gap == " " || gap == "-" || gap == "‑"
    }

    /**
     * Letters only, so a placeholder left by [ProtectedSpans] — which is digits
     * between two private-use characters — is invisible to the walk.
     */
    private val wordPattern = Regex("[A-Za-z]+(?:['’][A-Za-z]+)*")
}
