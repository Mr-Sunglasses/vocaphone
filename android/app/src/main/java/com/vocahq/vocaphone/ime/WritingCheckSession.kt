package com.vocahq.vocaphone.ime

import com.vocahq.vocaphone.writing.WritingCategory
import com.vocahq.vocaphone.writing.WritingCheck
import com.vocahq.vocaphone.writing.WritingSuggestion
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.concurrent.ConcurrentHashMap

/**
 * Writing check inside the keyboard: after the user pauses, the field around
 * the cursor is read once, checked off the keyboard's thread with the rules and
 * (when it is downloaded) the grammar model, and the suggestions are published
 * for the strip's badge, its chips and the panel. Grammarly's keyboard, with
 * nothing sent anywhere.
 *
 * Nothing here runs per keystroke beyond restarting a timer; the editor read
 * and the check happen once per pause. The model is asked one sentence at a
 * time and its answers are kept, so a pause after typing one more word costs
 * one sentence, not the whole field. All four dependencies are injected so the
 * timing and the bookkeeping are tested without a keyboard or a model.
 *
 * Everything but the check itself runs on [scope]'s thread (the keyboard's
 * main thread): the worker gets copies of the answers it may reuse and hands
 * back the ones it used, which are kept only if the field has not been reset
 * since. A cancelled check cannot stop a model call already running, so it
 * must not be able to write anything shared.
 */
internal class WritingCheckSession(
    private val scope: CoroutineScope,
    private val worker: CoroutineDispatcher,
    /** The field around the cursor, read once per pause; null when there is none. */
    private val read: () -> Field?,
    /** The checker; null until the rules have loaded. */
    private val checker: () -> WritingCheck?,
    /**
     * The grammar model for one sentence, or null when it is not in use. Its
     * third argument is whether the user asked for this check (the thorough
     * tier, [com.vocahq.vocaphone.grammar.GrammarTagger.THOROUGH_KEEP_BIAS]).
     */
    private val model: () -> ((String, Set<String>, Boolean) -> String?)?,
    private val isEnglish: (String) -> Boolean,
    private val pauseMillis: Long = PAUSE_MILLIS,
) {
    /** What one read of the editor saw: [text] starts at editor position [offset]; the cursor is at [cursor] in it. */
    data class Field(val text: String, val offset: Int, val cursor: Int)

    data class Options(
        val categories: Set<WritingCategory>,
        val keep: Set<String>,
        val tone: Boolean,
    )

    /** What the strip and the panel show. */
    data class Report(
        val field: Field,
        val suggestions: List<WritingSuggestion>,
        val tones: List<WritingCheck.Tone>,
        /** Suggestions the strip may offer as chips: between words, not under the cursor. */
        val chips: List<WritingSuggestion>,
        val modelPending: Boolean,
    ) {
        val count: Int get() = suggestions.size
    }

    private val current = MutableStateFlow<Report?>(null)
    val report: StateFlow<Report?> = current

    private val busy = MutableStateFlow(false)
    /** A check is running: the badge shows it. */
    val checking: StateFlow<Boolean> = busy

    private var job: Job? = null

    /** Suggestions waved away in this field, by [WritingSuggestion.key]. Main thread only. */
    private val dismissed = HashSet<String>()

    /** The model's answer per tier and sentence ([answerKey]), for this field. Main thread only. */
    private val answers = object : LinkedHashMap<String, String>(64, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, String>?) = size > ANSWER_CACHE
    }

    /** Bumped whenever [answers] stop holding: answers from an older check are dropped. */
    private var era = 0

    /** The latest check started; only it may clear [checking]. */
    private var checks = 0

    /** What a check reads: the field, where the cursor is in it, and the options. */
    private data class Settled(val text: String, val cursor: Int, val options: Options)

    /**
     * What the last finished check saw, so a pause that changed nothing does
     * not check again. Cleared whenever the report shown no longer comes from
     * it, and left clear while the model has not answered.
     */
    private var settled: Settled? = null

    /**
     * The user asked for a check in this field: later pauses check it too,
     * and every check of it is thorough, so a pause never trades the
     * suggestions the button found for fewer.
     */
    private var following = false

    /**
     * The keyboard re-read its short [window] of text before the cursor.
     *
     * [enabled] false (a field Writing check does not belong in) clears
     * everything. Otherwise a report the window no longer matches keeps its
     * count for the button but loses its chips, which might point at words
     * that have moved; applying from it reads the field again first anyway.
     * A new check starts after the pause when [auto] ("Check while typing")
     * is on, or once the user has asked for a check in this field with the
     * button, which follows the field from then on.
     */
    fun textChanged(window: String, enabled: Boolean, auto: Boolean = true, options: () -> Options) {
        job?.cancel()
        if (!enabled) {
            following = false
            current.value = null
            settled = null
            busy.value = false
            return
        }
        current.value?.let { report ->
            val before = report.field.text.substring(0, report.field.cursor)
            if (!before.trimEnd().endsWith(window.trimEnd().takeLast(MATCH_TAIL))) {
                settled = null
                if (report.chips.isNotEmpty()) current.value = report.copy(chips = emptyList())
            }
        }
        if (!auto && !following) return
        job = scope.launch {
            delay(pauseMillis)
            check(options())
        }
    }

    /**
     * Checks now, without waiting for a pause: the Writing check button and
     * the panel's "Check again". Works whether or not "Check while typing" is
     * on, and the field is followed after it until the keyboard leaves it.
     */
    fun checkNow(options: Options) {
        job?.cancel()
        settled = null
        following = true
        busy.value = true
        job = scope.launch {
            try {
                check(options)
            } finally {
                busy.value = false
            }
        }
    }

    private suspend fun check(options: Options) {
        val field = read() ?: return
        val state = Settled(field.text, field.cursor, options)
        if (state == settled) return
        val checker = checker() ?: return
        if (field.text.isBlank() || !isEnglish(field.text)) {
            settled = state
            current.value = null
            return
        }
        val token = ++checks
        busy.value = true
        try {
            val model = model()
            val thorough = following
            var report = ask(checker, field, options, model, thorough)
            if (report.modelPending) {
                // The model was loading, and asking started the load. One more
                // try once it has had time.
                delay(LOAD_RETRY_MILLIS)
                report = ask(checker, field, options, model, thorough)
            }
            // A sentence the model still has not answered keeps the check
            // open: the next pause asks again, even if nothing changed.
            settled = if (report.modelPending) null else state
            current.value = shown(report.field, report.suggestions, report)
        } finally {
            if (token == checks) busy.value = false
        }
    }

    /**
     * One pass on the worker. It reads a copy of [answers] and writes only its
     * own map; what it used comes back here and is kept if no reset or
     * [forgetAnswers] came in between. `withContext` throws once the check
     * was cancelled, so a cancelled pass never publishes a report.
     */
    private suspend fun ask(
        checker: WritingCheck,
        field: Field,
        options: Options,
        model: ((String, Set<String>, Boolean) -> String?)?,
        thorough: Boolean,
    ): Report {
        val known = HashMap(answers)
        val used = ConcurrentHashMap<String, String>()
        val era = this.era
        try {
            return withContext(worker) { run(checker, field, options, model, thorough, known, used) }
        } finally {
            if (era == this.era) answers.putAll(used)
        }
    }

    private fun run(
        checker: WritingCheck,
        field: Field,
        options: Options,
        model: ((String, Set<String>, Boolean) -> String?)?,
        thorough: Boolean,
        known: Map<String, String>,
        used: MutableMap<String, String>,
    ): Report {
        val cached = model?.let { ask ->
            WritingCheck.Model { sentence ->
                val key = answerKey(thorough, sentence)
                (known[key] ?: ask(sentence, options.keep, thorough))?.also { used[key] = it }
            }
        }
        val result = checker.check(field.text, cached, WritingCheck.Options(options.categories, options.keep, typed = true))
        val word = wordAt(field.text, field.cursor)
        val suggestions = result.suggestions.filter { s ->
            // Not the word being typed: it is not finished.
            word == null || s.markEnd < word.first || s.markStart > word.second
        }
        return Report(field, suggestions, if (options.tone) result.tones else emptyList(), emptyList(), result.modelPending)
    }

    /** [report] with [field] and [suggestions], less the dismissed, and the chips nearest the cursor. */
    private fun shown(field: Field, suggestions: List<WritingSuggestion>, report: Report): Report {
        val kept = suggestions.filter { it.key !in dismissed }
        val chips = kept.filter { it.isActionable }.sortedBy { kotlin.math.abs(it.markEnd - field.cursor) }.take(MAX_CHIPS)
        return report.copy(field = field, suggestions = kept, chips = chips)
    }

    /** The word the cursor touches, as `[start, end)`; null when it sits between words. */
    private fun wordAt(text: String, cursor: Int): Pair<Int, Int>? {
        var start = cursor
        while (start > 0 && isWordChar(text[start - 1])) start--
        var end = cursor
        while (end < text.length && isWordChar(text[end])) end++
        return if (end > start) start to end else null
    }

    private fun isWordChar(c: Char) = c.isLetterOrDigit() || c == '\'' || c == '’'

    /**
     * [suggestions], all from the current report, were applied to the field:
     * they leave the report, and the others are moved to where they now sit
     * in the edited text, so the panel stays usable before the next check.
     * They are taken from the end back, as the editor was edited, so each
     * one's offsets still hold when its turn comes.
     */
    fun applied(suggestions: List<WritingSuggestion>) {
        val report = current.value ?: return
        var field = report.field
        var rest = report.suggestions
        for (suggestion in suggestions.sortedByDescending { it.start }) {
            val edited = WritingCheck.apply(field.text, suggestion) ?: continue
            val delta = edited.length - field.text.length
            val cursor = if (field.cursor >= suggestion.end) field.cursor + delta else field.cursor
            rest = WritingCheck.rebase(rest.filter { it != suggestion }, field.text, edited)
            field = field.copy(text = edited, cursor = cursor)
        }
        if (field == report.field) return
        settled = null
        current.value = shown(field, rest, report)
    }

    fun applied(suggestion: WritingSuggestion) = applied(listOf(suggestion))

    /** The user waved [suggestion] away: it is not offered again in this field. */
    fun dismiss(suggestion: WritingSuggestion) = dismissKey(suggestion.key)

    /**
     * The change with this [WritingSuggestion.key] is not offered again in
     * this field, whether or not the report still holds it: an undone
     * automatic fix has already left the report by the time it is undone.
     */
    fun dismissKey(key: String) {
        dismissed.add(key)
        val report = current.value ?: return
        current.value = report.copy(
            suggestions = report.suggestions.filter { it.key != key },
            chips = report.chips.filter { it.key != key },
        )
    }

    /** A new field, or the keyboard went away: nothing carries over. */
    fun reset() {
        job?.cancel()
        job = null
        settled = null
        following = false
        dismissed.clear()
        answers.clear()
        era++
        busy.value = false
        current.value = null
    }

    /** The grammar setting or the model changed: its old answers no longer hold. */
    fun forgetAnswers() {
        answers.clear()
        era++
        settled = null
    }

    companion object {
        /** Long enough to be a pause rather than a gap between words. */
        const val PAUSE_MILLIS = 700L

        /** About what a cold load of the model takes on a mid-range phone. */
        const val LOAD_RETRY_MILLIS = 1_200L

        /** How much of the field one check reads on each side of the cursor. */
        const val READ_EACH_SIDE = 2_000

        const val MAX_CHIPS = 3
        private const val ANSWER_CACHE = 256
        private const val MATCH_TAIL = 24

        /** The model answers a sentence differently per tier, so each tier keeps its own. */
        private fun answerKey(thorough: Boolean, sentence: String) = (if (thorough) "T\u0000" else "B\u0000") + sentence
    }
}
