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
 */
internal class WritingCheckSession(
    private val scope: CoroutineScope,
    private val worker: CoroutineDispatcher,
    /** The field around the cursor, read once per pause; null when there is none. */
    private val read: () -> Field?,
    /** The checker; null until the rules have loaded. */
    private val checker: () -> WritingCheck?,
    /** The grammar model for one sentence, or null when it is not in use. */
    private val model: () -> ((String, Set<String>) -> String?)?,
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
    private var options = Options(WritingCategory.entries.toSet(), emptySet(), tone = true)

    /** Suggestions waved away in this field, by [WritingSuggestion.key]. */
    private val dismissed = HashSet<String>()

    /** The model's answer per sentence, for this field. */
    private val answers = object : LinkedHashMap<String, String>(64, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, String>?) = size > ANSWER_CACHE
    }

    /** The field text the last check read, so a pause that changed nothing does not check again. */
    private var settled: String? = null

    /**
     * The keyboard re-read its short [window] of text before the cursor. A
     * report that no longer matches it goes at once; a new check starts after
     * the pause, unless [enabled] is false, which also clears the strip.
     */
    fun textChanged(window: String, enabled: Boolean, options: () -> Options) {
        job?.cancel()
        if (!enabled) {
            current.value = null
            busy.value = false
            return
        }
        current.value?.let { report ->
            val before = report.field.text.substring(0, report.field.cursor)
            if (!before.trimEnd().endsWith(window.trimEnd().takeLast(MATCH_TAIL))) current.value = null
        }
        job = scope.launch {
            delay(pauseMillis)
            check(options())
        }
    }

    /** Checks now, without waiting for a pause: the panel's "Check again". */
    fun checkNow(options: Options) {
        job?.cancel()
        settled = null
        job = scope.launch { check(options) }
    }

    private suspend fun check(options: Options) {
        val field = read() ?: return
        if (field.text == settled && options == this.options) return
        this.options = options
        val checker = checker() ?: return
        if (field.text.isBlank() || !isEnglish(field.text)) {
            settled = field.text
            current.value = null
            return
        }
        busy.value = true
        try {
            val model = model()
            var report = withContext(worker) { run(checker, field, options, model) }
            if (report.modelPending) {
                // The model was loading, and asking started the load. One more
                // try once it has had time; after that the next pause asks.
                delay(LOAD_RETRY_MILLIS)
                report = withContext(worker) { run(checker, field, options, model) }
            }
            settled = field.text
            current.value = report
        } finally {
            busy.value = false
        }
    }

    private fun run(
        checker: WritingCheck,
        field: Field,
        options: Options,
        model: ((String, Set<String>) -> String?)?,
    ): Report {
        val cached = model?.let { ask ->
            WritingCheck.Model { sentence ->
                answers[sentence] ?: ask(sentence, options.keep)?.also { answers[sentence] = it }
            }
        }
        val result = checker.check(field.text, cached, WritingCheck.Options(options.categories, options.keep, typed = true))
        val word = wordAt(field.text, field.cursor)
        val suggestions = result.suggestions.filter { s ->
            // Not the word being typed: it is not finished.
            s.key !in dismissed && (word == null || s.markEnd < word.first || s.markStart > word.second)
        }
        val chips = suggestions.filter { it.isActionable }.sortedBy { kotlin.math.abs(it.markEnd - field.cursor) }.take(MAX_CHIPS)
        return Report(field, suggestions, if (options.tone) result.tones else emptyList(), chips, result.modelPending)
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
     * [suggestion] is being applied: it leaves the report, and the others are
     * moved to where they now sit in the edited text, so the panel stays
     * usable before the next check.
     */
    fun applied(suggestion: WritingSuggestion) {
        val report = current.value ?: return
        val edited = WritingCheck.apply(report.field.text, suggestion) ?: return
        val delta = edited.length - report.field.text.length
        val cursor = if (report.field.cursor >= suggestion.end) report.field.cursor + delta else report.field.cursor
        val field = report.field.copy(text = edited, cursor = cursor)
        val rest = WritingCheck.rebase(report.suggestions.filter { it != suggestion }, report.field.text, edited)
        settled = null
        current.value = report.copy(
            field = field,
            suggestions = rest,
            chips = rest.filter { it.isActionable }.sortedBy { kotlin.math.abs(it.markEnd - cursor) }.take(MAX_CHIPS),
        )
    }

    /** The user waved [suggestion] away: it is not offered again in this field. */
    fun dismiss(suggestion: WritingSuggestion) {
        dismissed.add(suggestion.key)
        val report = current.value ?: return
        current.value = report.copy(
            suggestions = report.suggestions.filter { it.key != suggestion.key },
            chips = report.chips.filter { it.key != suggestion.key },
        )
    }

    /** A new field, or the keyboard went away: nothing carries over. */
    fun reset() {
        job?.cancel()
        job = null
        settled = null
        dismissed.clear()
        answers.clear()
        busy.value = false
        current.value = null
    }

    /** The grammar setting or the model changed: its old answers no longer hold. */
    fun forgetAnswers() {
        answers.clear()
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
    }
}
