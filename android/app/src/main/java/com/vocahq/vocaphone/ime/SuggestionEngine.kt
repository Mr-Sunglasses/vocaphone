package com.vocahq.vocaphone.ime

import android.content.res.AssetManager

/**
 * The typing dictionary, with the indexes that keep it off the frame budget.
 *
 * Every lookup here used to be a full scan of all ten thousand words, run from
 * composition on every keystroke: `complete` tested `startsWith` against each
 * one, `similar` ran a Damerau-Levenshtein matrix against each one — allocating
 * three `IntArray`s a word — and `swipe` rebuilt each word's collapsed spelling
 * from scratch. Typing a word the dictionary does not know cost roughly a
 * millisecond per keystroke on a desktop JVM, which is a dropped frame or
 * several on a phone, and it landed on exactly the keystrokes where the user is
 * mid-word and watching the strip.
 *
 * The indexes below are built once, at load, on whatever thread does the
 * loading — which is deliberately not the keyboard's. They cost about a
 * megabyte for the shipped list and turn all three scans into small ones. The
 * results are identical: every index preserves the frequency order of [words],
 * because that order is what the strip's ranking means.
 */
internal class SuggestionDictionary(
    private val words: List<String>,
    private val bigrams: Map<String, List<String>>,
    /** Words the strip never offers on its own; see [NeverSuggest]. */
    val neverSuggest: NeverSuggest = NeverSuggest.EMPTY,
) {
    private val known = words.toHashSet()

    /** `word.length`, unboxed, so the length filter never touches a String. */
    private val lengths = IntArray(words.size) { words[it].length }

    /**
     * Which letters each word contains, one bit per letter, with bit 26 for
     * anything outside a-z. Two words within edit distance 2 cannot differ by
     * more than four letters — each edit adds at most one letter and removes at
     * most one — so a word whose bit count differs by more is rejected before
     * the matrix runs. On the shipped list this declines around 95% of the
     * candidates that survive the length filter, for one xor and one popcount.
     */
    private val letterMasks = IntArray(words.size) { letterMask(words[it]) }

    /**
     * Indices of the words starting with each prefix of up to
     * [PREFIX_KEY_LENGTH] characters, ascending, so a bucket walk is still a
     * frequency-ordered walk. A longer prefix reuses the longest bucket it has
     * and re-tests `startsWith`, which is exact and cheap on a small bucket.
     */
    private val prefixIndex: Map<String, IntArray> = buildPrefixIndex(words)

    /** Each word's swipe spelling, collapsed once here instead of per gesture. */
    private val collapsed: Array<String> =
        Array(words.size) { SuggestionEngine.collapseLetters(words[it]) }

    /** Unboxed lengths for [collapsed], so the reject path never derefs a String. */
    private val collapsedLength = IntArray(words.size) { collapsed[it].length }

    /**
     * Ideal resampled paths, one per word, so a geometric swipe does not
     * rebuild twenty-four points for every candidate. Letter-string swipes
     * do not read these: they keep the previous scorer so those tests stay
     * a lock.
     */
    private val swipeIdeal: Array<FloatArray> =
        Array(words.size) { SwipeLayout.sampleWord(collapsed[it]) }

    /** Colinear shortcut of each word, same length as [swipeIdeal]. */
    private val swipeShortcut: Array<FloatArray> =
        Array(words.size) { SwipeLayout.sampleWordShortcut(words[it]) }

    /** Word indices whose collapsed form starts with each letter, still in frequency order. */
    private val swipeByFirst: Array<IntArray> = buildSwipeFirst(collapsed)

    fun isKnown(word: String): Boolean = known.contains(word.lowercase())

    fun complete(prefix: String, limit: Int = 3, allowed: (String) -> Boolean = ALLOW_ALL): List<String> {
        if (prefix.isEmpty()) return emptyList()
        val lower = prefix.lowercase()
        val bucket = prefixIndex[lower.take(PREFIX_KEY_LENGTH)] ?: return emptyList()
        val matches = ArrayList<String>(limit)
        for (index in bucket) {
            val word = words[index]
            if (lengths[index] <= lower.length || !word.startsWith(lower)) continue
            if (!allowed(word)) continue
            matches.add(SuggestionEngine.matchCase(prefix, word))
            if (matches.size == limit) break
        }
        return matches
    }

    fun next(previousWord: String, limit: Int = 3, allowed: (String) -> Boolean = ALLOW_ALL): List<String> {
        if (previousWord.isEmpty()) return emptyList()
        return bigrams[previousWord.lowercase()].orEmpty().filter(allowed).take(limit)
    }

    fun correct(
        typed: String,
        limit: Int = 3,
        shouldAbort: () -> Boolean = { false },
        taps: FloatArray? = null,
        previousWord: String = "",
        allowed: (String) -> Boolean = ALLOW_ALL,
    ): List<String> {
        val lower = typed.lowercase()
        if (lower.length < 2 || isKnown(lower)) return emptyList()
        return similar(typed, limit, shouldAbort, taps, previousWord, allowed)
    }

    /**
     * Words within two edits of [typed], best first. Without [taps] that is
     * a neighbouring-key substitution, then one edit, then two, in frequency
     * order. With them (where each letter's finger landed, see [TapTrace]) a
     * wider pool is ranked by [TapRanking], which also favours a word the
     * bigram table predicts after [previousWord].
     */
    fun similar(
        typed: String,
        limit: Int = 3,
        shouldAbort: () -> Boolean = { false },
        taps: FloatArray? = null,
        previousWord: String = "",
        allowed: (String) -> Boolean = ALLOW_ALL,
    ): List<String> {
        val lower = typed.lowercase()
        if (lower.length < 2) return emptyList()
        val ranked = taps != null
        val pool = if (ranked) maxOf(limit, RANK_POOL) else limit
        val neighbor = ArrayList<Int>(pool)
        val distance1 = ArrayList<Int>(pool)
        val distance2 = ArrayList<Int>(pool)
        val minLen = (lower.length - 2).coerceAtLeast(1)
        val maxLen = lower.length + 2
        val typedMask = letterMask(lower)
        // One set of rows for the whole scan rather than three arrays per word.
        val scratch = SuggestionEngine.EditDistanceScratch(maxLen)
        for (index in words.indices) {
            if ((index and 127) == 0 && shouldAbort()) return emptyList()
            val length = lengths[index]
            if (length < minLen || length > maxLen) continue
            if ((typedMask xor letterMasks[index]).countOneBits() > MAX_LETTER_DIFFERENCE) continue
            val word = words[index]
            if (word == lower) continue
            val distance = SuggestionEngine.editDistance(lower, word, max = 2, scratch = scratch)
            if (distance !in 1..2 || !allowed(word)) continue
            when (distance) {
                1 -> {
                    if (SuggestionEngine.isNeighborSubstitution(lower, word)) neighbor.add(index)
                    else distance1.add(index)
                }
                2 -> if (distance2.size < pool) distance2.add(index)
            }
            if (neighbor.size >= pool) break
        }
        if (!ranked) {
            return (neighbor + distance1 + distance2)
                .take(limit)
                .map { SuggestionEngine.matchCase(typed, words[it]) }
        }
        val candidates = neighbor.map { TapRanking.Candidate(words[it], 0, it) } +
            distance1.take(pool).map { TapRanking.Candidate(words[it], 1, it) } +
            distance2.map { TapRanking.Candidate(words[it], 2, it) }
        val predicted = if (previousWord.isEmpty()) emptySet() else bigrams[previousWord.lowercase()].orEmpty().toHashSet()
        return TapRanking.order(lower, candidates, taps, predicted)
            .take(limit)
            .map { SuggestionEngine.matchCase(typed, it) }
    }

    fun strip(
        composing: String,
        before: String,
        after: String,
        correctionsEnabled: Boolean,
        personalRaw: String = "",
        shouldAbort: () -> Boolean = { false },
        options: StripOptions = StripOptions.DEFAULT,
    ): SuggestionStrip {
        val token = composing.ifEmpty { SuggestionEngine.lastWordForEmoji(before).orEmpty() }
        val emojis = EmojiSuggestions.glyphs(token)
        val personal = personalSet(personalRaw)
        if (composing.isNotEmpty()) {
            // The editor read can already hold the word being typed.
            val previous = SuggestionEngine.lastWord(before.removeSuffix(composing)).orEmpty()
            val allowed = gate(previous, options.allowSwears, personal, options.blocked)
            val personalHits = PersonalDictionary.completions(personalRaw, composing)
                .filter { it.lowercase() !in options.blocked }
            val completions = complete(composing, allowed = allowed)
            // A held-back word the user typed in full stays as typed.
            val typedHeldBack = isHeldBack(composing, options.allowSwears, personal)
            val corrections = if (correctionsEnabled && !typedHeldBack) {
                correct(
                    composing,
                    shouldAbort = shouldAbort,
                    taps = options.taps,
                    previousWord = previous,
                    allowed = allowed,
                )
            } else {
                emptyList()
            }
            val learned = if (options.learnedFixes && !typedHeldBack) {
                LearnedFixes.fixFor(
                    typed = composing,
                    memory = options.memory,
                    isWord = { false },
                    blocked = { !allowed(it) },
                    personalSpelling = { fix -> PersonalDictionary.terms(personalRaw).firstOrNull { it.equals(fix, ignoreCase = true) } },
                )
            } else {
                null
            }
            // A learned fix is what space makes, so it is the only one worked out then.
            val autocorrection = options.autocorrect?.takeIf { learned == null && !typedHeldBack }?.let { tuning ->
                autocorrection(composing, before, after, previous, allowed, personalRaw, options, tuning, shouldAbort)
            }
            val save = saveCandidate(
                word = composing,
                personalRaw = personalRaw,
                // Still typing a known word: hello/help already fill the strip.
                hasCompletions = personalHits.isNotEmpty() || completions.isNotEmpty(),
            )
            // The word as typed sits beside a pending correction, unless the
            // + chip already offers it.
            val keepTyped = composing.takeIf { autocorrection != null && save == null }
            val words = (listOfNotNull(learned, autocorrection) + personalHits + completions + corrections)
                .distinct()
                // A fix the user undid twice is never the first offer.
                .sortedBy { options.memory.isRejected(composing, it) }
                .take(if (keepTyped != null) 2 else 3)
            return SuggestionStrip(
                words,
                emojis,
                saveWord = save,
                autocorrection = autocorrection,
                forWord = composing,
                keepTyped = keepTyped,
            )
        }
        val finished = SuggestionEngine.lastTypedWord(before)
        val save = saveCandidate(
            word = finished.orEmpty(),
            personalRaw = personalRaw,
            hasCompletions = false,
        )
        if (correctionsEnabled) {
            val span = SuggestionEngine.wordSpan(before, after)
            if (span != null && span.word.length >= 2 && !isHeldBack(span.word, options.allowSwears, personal)) {
                val previous = SuggestionEngine.lastWord(before.dropLast(span.beforeLength)).orEmpty()
                val nearby = similar(
                    span.word,
                    shouldAbort = shouldAbort,
                    allowed = gate(previous, options.allowSwears, personal, options.blocked),
                ).sortedBy { options.memory.isRejected(span.word, it) }
                if (nearby.isNotEmpty()) {
                    return SuggestionStrip(nearby, emojis, replacesWord = true, saveWord = save)
                }
            }
        }
        val previous = SuggestionEngine.lastWord(before).orEmpty()
        return SuggestionStrip(
            next(previous, allowed = gate(previous, options.allowSwears, personal, options.blocked)),
            emojis,
            saveWord = save,
        )
    }

    /**
     * The correction space should make for [composing], or null to leave it.
     * Walks the word list, so it runs with the strip, off the composition
     * thread; see [Autocorrect] for the decision itself.
     */
    private fun autocorrection(
        composing: String,
        before: String,
        after: String,
        previous: String,
        allowed: (String) -> Boolean,
        personalRaw: String,
        options: StripOptions,
        tuning: AutocorrectTuning,
        shouldAbort: () -> Boolean,
    ): String? {
        val lower = composing.lowercase()
        val personalTerms = PersonalDictionary.terms(personalRaw)
        val isPersonal = personalTerms.any { it.equals(composing, ignoreCase = true) }
        val known = isKnown(lower)
        // Only a word that might be corrected pays for the scan.
        val candidates = if (known || isPersonal || lower.length < Autocorrect.MIN_LENGTH) {
            emptyList()
        } else {
            val listed = autocorrectCandidates(lower, shouldAbort, allowed) ?: return null
            // The user's own words are candidates too, as fairly common ones.
            val own = personalTerms.mapNotNull { term ->
                val edits = SuggestionEngine.editDistance(lower, term.lowercase(), max = 2)
                if (edits in 1..2 && allowed(term)) AutocorrectCandidate(term, PERSONAL_RANK, edits) else null
            }
            (listed + own).filterNot { options.memory.isRejected(composing, it.word) }
        }
        val beforeWord = SuggestionEngine.beforeComposing(before, composing)
        val decision = Autocorrect.decide(
            AutocorrectContext(
                typed = composing,
                tokenBefore = beforeWord.takeLastWhile { !it.isWhitespace() },
                atSentenceStart = SentenceBoundary.endsSentence(beforeWord),
                midWord = after.firstOrNull()?.let { it.isLetterOrDigit() } == true,
                isKnown = known,
                isPersonal = isPersonal,
                asserted = lower in options.asserted,
                heldBack = isHeldBack(composing, options.allowSwears, personalSet(personalRaw)),
                candidates = candidates,
                followers = if (previous.isEmpty()) emptySet() else bigrams[previous.lowercase()].orEmpty().toHashSet(),
                tuning = tuning,
            ),
        )
        val fix = decision.replacement ?: return null
        // The short-word table's fixes are not list words; gate them the same.
        return fix.takeIf { allowed(it) && !options.memory.isRejected(composing, it) }
    }

    /**
     * Every listed word within two edits of [lower] that [allowed] lets
     * through, in frequency order, with its rank and distance. Unlike
     * [similar] it never stops early: a correction needs its competitors as
     * well as its winner. Null when [shouldAbort] says so.
     */
    fun autocorrectCandidates(
        lower: String,
        shouldAbort: () -> Boolean = { false },
        allowed: (String) -> Boolean = ALLOW_ALL,
        cap: Int = AUTOCORRECT_POOL,
    ): List<AutocorrectCandidate>? {
        if (lower.length < 2) return emptyList()
        val found = ArrayList<AutocorrectCandidate>()
        val minLen = (lower.length - 2).coerceAtLeast(1)
        val maxLen = lower.length + 2
        val typedMask = letterMask(lower)
        val scratch = SuggestionEngine.EditDistanceScratch(maxLen)
        for (index in words.indices) {
            if ((index and 127) == 0 && shouldAbort()) return null
            val length = lengths[index]
            if (length < minLen || length > maxLen) continue
            if ((typedMask xor letterMasks[index]).countOneBits() > MAX_LETTER_DIFFERENCE) continue
            val word = words[index]
            if (word == lower) continue
            val distance = SuggestionEngine.editDistance(lower, word, max = 2, scratch = scratch)
            if (distance !in 1..2 || !allowed(word)) continue
            found.add(AutocorrectCandidate(word, index, distance))
            if (found.size >= cap) break
        }
        return found
    }

    /**
     * Whether the strip may offer [word] after [previous]: never one the user
     * blocked, always one of the user's own words otherwise.
     */
    fun allows(
        word: String,
        previous: String?,
        allowSwears: Boolean,
        personal: Set<String>,
        blocked: Set<String> = emptySet(),
    ): Boolean {
        val key = word.lowercase()
        if (key in blocked) return false
        return key in personal || !neverSuggest.blocks(word, previous, allowSwears)
    }

    /** [word] is one the keyboard never offers, and not one of the user's. */
    fun isHeldBack(word: String, allowSwears: Boolean, personal: Set<String>): Boolean =
        neverSuggest.blocks(word, allowSwears) && word.lowercase() !in personal

    private fun gate(
        previous: String?,
        allowSwears: Boolean,
        personal: Set<String>,
        blocked: Set<String> = emptySet(),
    ): (String) -> Boolean = { word -> allows(word, previous, allowSwears, personal, blocked) }

    private fun saveCandidate(
        word: String,
        personalRaw: String,
        hasCompletions: Boolean,
    ): String? {
        if (hasCompletions) return null
        if (!PersonalDictionary.isSavable(word)) return null
        if (isKnown(word) || PersonalDictionary.contains(personalRaw, word)) return null
        return word
    }

    fun swipe(
        path: String,
        limit: Int = 6,
        shouldAbort: () -> Boolean = { false },
        points: FloatArray = FloatArray(0),
        previousWord: String = "",
        allowed: (String) -> Boolean = ALLOW_ALL,
    ): List<String> {
        val keys = SuggestionEngine.collapseLetters(path)
        if (keys.length < 2) return emptyList()
        return if (points.size >= 4) {
            swipeGeometric(keys, points, previousWord, limit, shouldAbort, allowed)
        } else {
            swipeFromKeys(keys, limit, shouldAbort, allowed)
        }
    }

    /**
     * The matcher the letter-string tests lock. Changing it is a behaviour
     * change for every caller that only has the keys the finger entered, so
     * keep the formula here even after the geometric scorer grows.
     */
    private fun swipeFromKeys(
        keys: String,
        limit: Int,
        shouldAbort: () -> Boolean,
        allowed: (String) -> Boolean,
    ): List<String> {
        val gesture = SuggestionEngine.SwipeGesture(keys)
        val scored = ArrayList<Pair<String, Float>>()
        for (rank in words.indices) {
            if ((rank and 127) == 0 && shouldAbort()) return emptyList()
            val compact = collapsed[rank]
            val last = collapsedLength[rank] - 1
            if (last < 1) continue
            if (!gesture.endsAreReachable(compact[0], compact[last])) continue
            val exact = SuggestionEngine.isSubsequence(compact, keys)
            if (!exact && !SuggestionEngine.isReachableSubsequence(compact, keys)) continue
            scored.add(words[rank] to gesture.score(compact, rank, approximate = !exact))
        }
        return scored
            .sortedByDescending { it.second }
            .asSequence()
            .map { it.first }
            .filter(allowed)
            .take(limit)
            .toList()
    }

    /**
     * Real (x, y) traces. Start-letter buckets are the first level of the
     * candidate tree; when the finger turned, a word also has to cover
     * every apex (the keys around each direction change) in order.
     */
    private fun swipeGeometric(
        keys: String,
        points: FloatArray,
        previousWord: String,
        limit: Int,
        shouldAbort: () -> Boolean,
        allowed: (String) -> Boolean,
    ): List<String> {
        val gesture = SwipeLayout.Gesture(keys, points)
        val predicted = if (previousWord.isEmpty()) {
            emptySet()
        } else {
            bigrams[previousWord.lowercase()].orEmpty().toHashSet()
        }
        val scored = ArrayList<Pair<String, Float>>()
        fun consider(requireTurns: Boolean): Boolean {
            var seen = 0
            for (letter in 'a'..'z') {
                if (!gesture.mayBeginWith(letter)) continue
                val bucket = swipeByFirst[letter - 'a']
                for (rank in bucket) {
                    if ((seen and 127) == 0 && shouldAbort()) return true
                    seen++
                    val compact = collapsed[rank]
                    val last = collapsedLength[rank] - 1
                    if (last < 1) continue
                    if (!gesture.endsAreReachable(compact[0], compact[last])) continue
                    if (requireTurns && !gesture.coversWord(compact)) continue
                    scored.add(
                        words[rank] to gesture.score(
                            compactWord = compact,
                            originalWord = words[rank],
                            frequencyRank = rank,
                            wordCount = words.size,
                            predictedWord = words[rank] in predicted,
                            full = swipeIdeal[rank],
                            shortcut = swipeShortcut[rank],
                        ),
                    )
                }
            }
            return false
        }
        val aborted = consider(requireTurns = gesture.hasTurns)
        if (aborted) return emptyList()
        // A noisy trace can invent extra apexes and empty the tree. Fall
        // back to start/end so we still commit a word the strip can fix.
        if (scored.isEmpty() && gesture.hasTurns) {
            if (consider(requireTurns = false)) return emptyList()
        }
        return scored
            .sortedByDescending { it.second }
            .asSequence()
            .map { it.first }
            .filter(allowed)
            .take(limit)
            .toList()
    }

    companion object {
        /**
         * How many leading characters a prefix bucket is keyed by. Three keeps
         * the map at a few thousand entries for the shipped list while leaving
         * the average bucket small enough to walk.
         */
        private const val PREFIX_KEY_LENGTH = 3

        /** See [letterMasks]: two edits can move at most four distinct letters. */
        private const val MAX_LETTER_DIFFERENCE = 4

        /** Candidates [TapRanking] chooses among when it knows where the taps landed. */
        private const val RANK_POOL = 8

        /** Enough near words for a correction to know its competitors; most typos have under ten. */
        private const val AUTOCORRECT_POOL = 48

        /** Where a personal dictionary word ranks as an autocorrect candidate: common, not top. */
        private const val PERSONAL_RANK = 300

        val ALLOW_ALL: (String) -> Boolean = { true }

        fun personalSet(personalRaw: String): Set<String> =
            if (personalRaw.isBlank()) emptySet() else PersonalDictionary.terms(personalRaw).mapTo(HashSet()) { it.lowercase() }

        private fun letterMask(word: String): Int {
            var mask = 0
            for (character in word) mask = mask or SuggestionEngine.letterBit(character)
            return mask
        }

        private fun buildSwipeFirst(collapsed: Array<String>): Array<IntArray> {
            val buckets = Array(26) { ArrayList<Int>() }
            collapsed.forEachIndexed { index, compact ->
                if (compact.length < 2) return@forEachIndexed
                val first = compact[0]
                if (first in 'a'..'z') buckets[first - 'a'].add(index)
            }
            return Array(26) { buckets[it].toIntArray() }
        }

        private fun buildPrefixIndex(words: List<String>): Map<String, IntArray> {
            val builders = HashMap<String, MutableList<Int>>()
            words.forEachIndexed { index, word ->
                val lower = word.lowercase()
                for (length in 1..minOf(PREFIX_KEY_LENGTH, lower.length)) {
                    builders.getOrPut(lower.substring(0, length)) { ArrayList() }.add(index)
                }
            }
            return builders.mapValues { (_, indices) -> indices.toIntArray() }
        }

        // Both files come from assets/keyboard/ at the repository root, merged
        // into the asset root by the sourceSets entry in app/build.gradle.kts.
        // The iOS keyboard reads the same two files.
        fun load(assets: AssetManager) = SuggestionDictionary(
            words = assets.open("en.txt").bufferedReader().readLines()
                .map { it.trim() }
                .filter { it.isNotEmpty() },
            bigrams = parseBigrams(
                assets.open("en-bigrams.txt").bufferedReader().readLines(),
            ),
            neverSuggest = runCatching { NeverSuggest.load(assets) }.getOrDefault(NeverSuggest.EMPTY),
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

/**
 * What else shapes one strip besides the text: the swear-word setting, the
 * autocorrect memory, and where the taps of the composing word landed.
 */
internal class StripOptions(
    val allowSwears: Boolean = false,
    val memory: AutocorrectMemory = AutocorrectMemory.EMPTY,
    /** "Learn my typing fixes": a learned fix leads the strip. */
    val learnedFixes: Boolean = false,
    val taps: FloatArray? = null,
    /** Autocorrect is on in this field, this sure; null works out no correction. */
    val autocorrect: AutocorrectTuning? = null,
    /** Words put back after a correction in this field, lowercase: never corrected again here. */
    val asserted: Set<String> = emptySet(),
    /** Words the user blocked with a long press, lowercase: never offered or corrected to. */
    val blocked: Set<String> = emptySet(),
) {
    companion object {
        val DEFAULT = StripOptions()
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

    /**
     * The last token as the user typed it, for adding to the personal
     * dictionary. [lastWord] strips apostrophes and case for bigram lookup;
     * saving "obrien" when they wrote "O'Brien" would miss the point.
     */
    fun lastTypedWord(textBeforeCursor: CharSequence): String? {
        var end = textBeforeCursor.length
        while (end > 0 && !isTypedWordChar(textBeforeCursor[end - 1])) end--
        if (end == 0) return null
        var start = end
        while (start > 0 && isTypedWordChar(textBeforeCursor[start - 1])) start--
        val word = textBeforeCursor.subSequence(start, end).toString()
        return word.takeIf { it.any(Char::isLetter) }
    }

    private fun isTypedWordChar(character: Char): Boolean =
        character.isLetter() || character == '\''

    /** Last word even when a space or period is already sitting after it. */
    fun lastWordForEmoji(textBeforeCursor: CharSequence): String? {
        var end = textBeforeCursor.length
        while (end > 0 && !isWordChar(textBeforeCursor[end - 1])) end--
        if (end == 0) return null
        var start = end
        while (start > 0 && isWordChar(textBeforeCursor[start - 1])) start--
        val word = textBeforeCursor.subSequence(start, end).toString().replace("'", "").lowercase()
        return word.takeIf { it.any(Char::isLetter) }
    }

    internal fun matchCase(prefix: String, word: String): String = when {
        prefix.all { it.isUpperCase() } -> word.uppercase()
        prefix.first().isUpperCase() -> word.replaceFirstChar { it.uppercase() }
        else -> word
    }

    fun wordBefore(before: CharSequence): Int {
        if (before.isEmpty()) return 0
        var index = before.length
        while (index > 0 && before[index - 1].isWhitespace()) index--
        if (index == 0) return before.length
        if (isWordChar(before[index - 1])) {
            while (index > 0 && isWordChar(before[index - 1])) index--
        } else {
            while (index > 0 && !before[index - 1].isWhitespace() && !isWordChar(before[index - 1])) {
                index--
            }
        }
        return before.length - index
    }

    /**
     * Option-Delete: the word before the cursor together with the spaces and
     * punctuation between it and the cursor ("world. " in "hello world. ").
     */
    fun wordWithSeparatorsBefore(before: CharSequence): Int {
        val first = wordBefore(before)
        if (first == 0 || first == before.length) return first
        val chunk = before.subSequence(before.length - first, before.length)
        if (chunk.any(::isWordChar)) return first
        return first + wordBefore(before.subSequence(0, before.length - first))
    }

    /**
     * [before] without the composing word at its end. The editor read is
     * coalesced, so it may hold all of [composing], a prefix of it, or none.
     */
    fun beforeComposing(before: String, composing: String): String {
        for (length in composing.length downTo 1) {
            if (before.endsWith(composing.substring(0, length))) return before.dropLast(length)
        }
        return before
    }

    fun lineBefore(before: CharSequence): Int {
        if (before.isEmpty()) return 0
        if (before.last() == '\n') return 1
        val newline = before.lastIndexOf('\n')
        return before.length - (newline + 1)
    }

    internal fun isNeighborSubstitution(left: String, right: String): Boolean {
        if (left.length != right.length) return false
        var diff = -1
        for (index in left.indices) {
            if (left[index] == right[index]) continue
            if (diff >= 0) return false
            diff = index
        }
        if (diff < 0) return false
        return right[diff] in nearbyLetters(left[diff])
    }

    fun replaceableWord(before: CharSequence, after: CharSequence): WordSpan? {
        wordSpan(before, after)?.let { return it }
        val text = before.toString()
        val trimmed = text.trimEnd()
        if (trimmed.length == text.length) return null
        val span = wordSpan(trimmed, "") ?: return null
        return span.copy(beforeLength = span.beforeLength + (text.length - trimmed.length))
    }

    fun wordSpan(before: CharSequence, after: CharSequence): WordSpan? {
        var start = before.length
        while (start > 0 && isWordChar(before[start - 1])) start--
        var end = 0
        while (end < after.length && isWordChar(after[end])) end++
        if (start == before.length && end == 0) return null
        val word = buildString {
            append(before.subSequence(start, before.length))
            append(after.subSequence(0, end))
        }
        if (word.none { it.isLetter() }) return null
        return WordSpan(word, before.length - start, end)
    }

    /**
     * Three rows of the edit-distance matrix, reused across a whole scan.
     *
     * The rows are the same shape for every candidate, so allocating them per
     * word meant three `IntArray`s per dictionary entry — tens of thousands of
     * short-lived arrays per keystroke, and the garbage collection that comes
     * with them, on the thread drawing the keyboard.
     *
     * Not thread-safe, deliberately: one belongs to one scan, and sharing one
     * between scans would interleave two matrices in the same rows.
     */
    internal class EditDistanceScratch(maxRightLength: Int) {
        var previousPrevious = IntArray(maxRightLength + 1)
            private set
        var previous = IntArray(maxRightLength + 1)
            private set
        var current = IntArray(maxRightLength + 1)
            private set

        /**
         * Grows in place rather than handing back a bigger one, so a caller
         * that held onto this keeps the rows that grew.
         *
         * Returning a replacement looked equivalent and was not: `similar`
         * binds its scratch once and reuses it for a whole scan, so it would
         * have kept the undersized one and allocated a replacement per
         * candidate — the exact cost this class exists to remove, with nothing
         * failing to say so.
         */
        fun fit(columns: Int) {
            if (previous.size > columns) return
            previousPrevious = IntArray(columns + 1)
            previous = IntArray(columns + 1)
            current = IntArray(columns + 1)
        }
    }

    internal fun editDistance(left: String, right: String, max: Int): Int =
        editDistance(left, right, max, EditDistanceScratch(right.length))

    internal fun editDistance(
        left: String,
        right: String,
        max: Int,
        scratch: EditDistanceScratch,
    ): Int {
        if (left == right) return 0
        if (kotlin.math.abs(left.length - right.length) > max) return max + 1
        val columns = right.length
        scratch.fit(columns)
        var previousPrevious = scratch.previousPrevious
        var previous = scratch.previous
        var current = scratch.current
        // Only the prefix this candidate uses is reset; the tail is never read.
        for (index in 0..columns) {
            previousPrevious[index] = 0
            previous[index] = index
        }
        for (i in 1..left.length) {
            current[0] = i
            var rowMin = current[0]
            val leftChar = left[i - 1]
            for (j in 1..columns) {
                val substitution = if (leftChar == right[j - 1]) 0 else 1
                var value = minOf(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + substitution,
                )
                if (
                    i > 1 &&
                    j > 1 &&
                    leftChar == right[j - 2] &&
                    left[i - 2] == right[j - 1]
                ) {
                    value = minOf(value, previousPrevious[j - 2] + 1)
                }
                current[j] = value
                if (value < rowMin) rowMin = value
            }
            if (rowMin > max) return max + 1
            val recycled = previousPrevious
            previousPrevious = previous
            previous = current
            current = recycled
        }
        return previous[columns]
    }

    internal fun collapseLetters(path: String): String = buildString {
        for (character in path.lowercase()) {
            if (character.isLetter() && (isEmpty() || character != last())) append(character)
        }
    }

    /**
     * One gesture's key path, with everything that depends only on the gesture
     * worked out once.
     *
     * Scoring used to take the raw path and re-derive all of this per candidate,
     * so a ten thousand word list resampled the user's sixteen points ten
     * thousand times and rebuilt its own neighbour sets on the way in.
     */
    internal class SwipeGesture(val keys: String) {
        private val samples = samplePath(keys, SAMPLE_POINTS)
        private val length = pathLength(keys)

        /**
         * The acceptable first and last keys as letter bitmaps rather than
         * `Set<Char>`. Membership in a `Set<Char>` boxes the character, and this
         * is tested twice for every word in the list on every gesture — twenty
         * thousand boxes per swipe, for a question a shift and an and answers.
         */
        private val firstMask = letterBits(nearbyLetters(keys.first()) + keys.first())
        private val lastMask = letterBits(nearbyLetters(keys.last()) + keys.last())

        fun endsAreReachable(first: Char, last: Char): Boolean =
            letterBit(first) and firstMask != 0 && letterBit(last) and lastMask != 0

        fun score(compactWord: String, frequencyRank: Int, approximate: Boolean): Float {
            val shape = shapeDistance(compactWord)
            val lengthGap = kotlin.math.abs(length - pathLength(compactWord))
            val endPenalty =
                (if (compactWord.first() == keys.first()) 0f else 0.7f) +
                    (if (compactWord.last() == keys.last()) 0f else 0.7f)
            val frequency = 1f / (1f + frequencyRank / 400f)
            val nearby = if (approximate) NEARBY_KEY_PENALTY else 0f
            return frequency * 2f - shape * 3f - lengthGap * 0.35f - endPenalty - nearby
        }

        private fun shapeDistance(word: String): Float {
            val ideal = samplePath(word, SAMPLE_POINTS)
            if (samples.isEmpty() || ideal.isEmpty()) return Float.MAX_VALUE
            var sum = 0f
            for (index in samples.indices) sum += samples[index].distanceTo(ideal[index])
            return sum / samples.size
        }
    }

    internal fun nearbyLetters(letter: Char): Set<Char> = NEARBY[letter].orEmpty()

    /** One bit per a-z letter; bit 26 stands in for everything else. */
    internal fun letterBit(letter: Char): Int {
        val offset = letter - 'a'
        return if (offset in 0..25) 1 shl offset else 1 shl 26
    }

    internal fun letterBits(letters: Iterable<Char>): Int {
        var mask = 0
        for (letter in letters) mask = mask or letterBit(letter)
        return mask
    }

    private fun pathLength(keys: String): Float {
        var length = 0f
        var previous: KeyXY? = null
        for (character in keys) {
            val point = QWERTY[character] ?: continue
            if (previous != null) length += previous.distanceTo(point)
            previous = point
        }
        return length
    }

    private fun samplePath(keys: String, count: Int): List<KeyXY> {
        val points = keys.mapNotNull { QWERTY[it] }
        if (points.isEmpty()) return emptyList()
        if (points.size == 1 || count <= 1) return List(count.coerceAtLeast(1)) { points.first() }
        val prefix = FloatArray(points.size)
        for (index in 1 until points.size) {
            prefix[index] = prefix[index - 1] + points[index - 1].distanceTo(points[index])
        }
        val total = prefix.last().coerceAtLeast(0.0001f)
        return List(count) { sample ->
            val target = total * sample / (count - 1)
            var index = 1
            while (index < prefix.lastIndex && prefix[index] < target) index++
            val start = prefix[index - 1]
            val span = (prefix[index] - start).coerceAtLeast(0.0001f)
            val t = ((target - start) / span).coerceIn(0f, 1f)
            val from = points[index - 1]
            val to = points[index]
            KeyXY(from.x + (to.x - from.x) * t, from.y + (to.y - from.y) * t)
        }
    }

    private data class KeyXY(val x: Float, val y: Float) {
        fun distanceTo(other: KeyXY): Float {
            val dx = x - other.x
            val dy = y - other.y
            return kotlin.math.sqrt(dx * dx + dy * dy)
        }
    }

    private const val SAMPLE_POINTS = 16

    /**
     * How much worse a word is for having been matched through a neighbouring
     * key rather than the one the finger crossed.
     *
     * It has to be large enough that a word which really was spelled out beats
     * a shape-alike that was not, and small enough that a genuinely wobbly
     * swipe still finds its word. Simulated over the shipped list against noisy
     * paths, anything from roughly 1 to 1.5 sits on the same plateau; 1.5 is
     * the end of it that keeps the exactly-spelled word in front.
     */
    private const val NEARBY_KEY_PENALTY = 1.5f

    private val QWERTY: Map<Char, KeyXY> = buildMap {
        fun row(y: Float, startX: Float, letters: String) {
            letters.forEachIndexed { index, letter -> put(letter, KeyXY(startX + index, y)) }
        }
        row(0f, 0f, "qwertyuiop")
        row(1f, 0.5f, "asdfghjkl")
        row(2f, 1.5f, "zxcvbnm")
    }

    /**
     * Keys within reach of a mistyped one, worked out once for the whole
     * layout. Derived per call, this allocated a list and a set on every
     * distance-1 candidate the correction scan found, and twice per swipe.
     *
     * Declared after [QWERTY] because an object's properties initialize in
     * source order, and this one reads it.
     */
    private val NEARBY: Map<Char, Set<Char>> = QWERTY.mapValues { (letter, origin) ->
        QWERTY.entries
            .filter { (other, point) -> other != letter && origin.distanceTo(point) < 1.55f }
            .map { it.key }
            .toSet()
    }

    /**
     * For each letter, the keys a finger aiming at it could plausibly have
     * crossed instead: the key itself and its neighbours, as one bitmap.
     *
     * Declared after [NEARBY] for the same source-order reason it is.
     */
    private val REACH: IntArray = IntArray(26) { offset ->
        val letter = 'a' + offset
        letterBits(NEARBY[letter].orEmpty() + letter)
    }

    private fun reachMask(letter: Char): Int {
        val offset = letter - 'a'
        return if (offset in 0..25) REACH[offset] else 0
    }

    /** Whether every letter of [word] appears in [path], in order. */
    internal fun isSubsequence(word: String, path: String): Boolean {
        var index = 0
        for (character in path) {
            if (index < word.length && character == word[index]) index++
        }
        return index == word.length
    }

    /**
     * Whether a swipe could have spelled [word], allowing for a finger that
     * clipped the key next to the one it was aiming at.
     *
     * The exact version of this test threw the right word away outright. A
     * corner apex landing a quarter of a key off — which is most of them —
     * leaves that letter missing from the crossed keys, and one missing letter
     * eliminated the candidate no matter how well the rest of the gesture fit.
     * Simulated against noisy paths for the shipped word list, that cost about
     * a fifth of swipes at a quarter-key wobble and half of them at a third.
     *
     * Neighbours are admitted here and nowhere else: a letter may be met by a
     * key beside it, but every letter must still be met, in order. Letting a
     * letter go unmatched entirely was measurably worse, because the noise it
     * admits outranks the word more often than it rescues it.
     *
     * A word that only matches this way is scored below one whose keys were
     * all actually crossed — see [NEARBY_KEY_PENALTY]. Without that, a word
     * sharing the gesture's shape but not its letters wins on shape alone.
     */
    internal fun isReachableSubsequence(word: String, path: String): Boolean {
        var index = 0
        for (character in path) {
            if (index == word.length) break
            if (letterBit(character) and reachMask(word[index]) != 0) index++
        }
        return index == word.length
    }

    private fun isWordChar(character: Char): Boolean =
        character.isLetterOrDigit() || character == '\''

    /**
     * A picked suggestion carries its own trailing space so the next word can
     * follow straight on. At the end of the text that is what everyone wants;
     * mid-text it is not, because the space that already separates this word
     * from the next one is still sitting there and the field ends up with two.
     *
     * The space belongs before another word and nowhere else, so it is dropped
     * whenever the cursor is about to land in front of anything that is not a
     * word character: existing whitespace, a comma, a closing bracket.
     */
    fun suggestionCommit(word: String, textAfterCursor: CharSequence): String =
        if (textAfterCursor.isEmpty() || isWordChar(textAfterCursor[0])) "$word " else word
}
