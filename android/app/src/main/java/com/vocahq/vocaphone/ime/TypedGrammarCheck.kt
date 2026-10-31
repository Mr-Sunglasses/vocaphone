package com.vocahq.vocaphone.ime

import com.vocahq.vocaphone.grammar.TypedGrammar
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * "Check grammar while typing" inside the keyboard: waits for the user to
 * pause, reads the sentences before the cursor, has the grammar model check
 * them off the keyboard's thread, and publishes at most one fix for the strip.
 *
 * Nothing here runs per keystroke. [textChanged] is called from the keyboard's
 * own coalesced editor read and only restarts a timer; the long read of the
 * editor and the model run happen once, after [pauseMillis] of quiet. A
 * keystroke during the model run cancels the result rather than the run, so
 * a stale fix never reaches the strip.
 *
 * [readBefore] is the `InputConnection` read, [correct] the grammar model
 * (null while it is still loading), and [isEnglish] the language gate; all
 * three are injected so the timing is tested without a keyboard or a model.
 */
internal class TypedGrammarCheck(
    private val scope: CoroutineScope,
    private val worker: CoroutineDispatcher,
    private val readBefore: (Int) -> String?,
    private val correct: (String, Set<String>) -> String?,
    private val isEnglish: (String) -> Boolean,
    private val pauseMillis: Long = PAUSE_MILLIS,
) {
    private val current = MutableStateFlow<TypedGrammar.Fix?>(null)

    /** The fix the strip offers, if any. */
    val fix: StateFlow<TypedGrammar.Fix?> = current

    private var job: Job? = null

    /**
     * The last text checked, whatever the answer was, so a pause that changes
     * nothing does not run the model again. A dismissed fix's text and an
     * applied fix's result land here too, so neither is offered twice.
     */
    private var settled: String? = null

    /**
     * Fixes waved away in this field, as the words and what they would have
     * become. The sentence goes on being checked as the user types on, and
     * without this the same fix would come back at every pause.
     */
    private val dismissed = HashSet<Pair<String, String>>()

    /**
     * The keyboard re-read its short [window] of text before the cursor. A fix
     * that no longer describes it goes at once; a new check starts after the
     * pause, unless [enabled] is false, which also drops any fix on screen.
     */
    fun textChanged(window: String, enabled: Boolean, keep: () -> Set<String>) {
        job?.cancel()
        if (!enabled) {
            current.value = null
            return
        }
        current.value?.let { if (!TypedGrammar.stillDescribes(it, window)) current.value = null }
        job = scope.launch {
            delay(pauseMillis)
            check(keep())
        }
    }

    private suspend fun check(keep: Set<String>) {
        val before = readBefore(TypedGrammar.READ_LIMIT) ?: return
        val region = TypedGrammar.region(before, startKnown = before.length < TypedGrammar.READ_LIMIT)
        if (region == null) {
            current.value = null
            return
        }
        if (region == settled || region == current.value?.checked) return
        if (!isEnglish(region)) {
            settled = region
            current.value = null
            return
        }
        var corrected = withContext(worker) { correct(region, keep) }
        if (corrected == null) {
            // The model was not loaded, and asking started the load. One
            // more try once it has had time; after that the next pause asks.
            delay(LOAD_RETRY_MILLIS)
            corrected = withContext(worker) { correct(region, keep) } ?: return
        }
        settled = region
        current.value = TypedGrammar.fix(region, corrected)?.takeIf { (it.original to it.replacement) !in dismissed }
    }

    /** Hands the fix over to be applied, and remembers its result as checked. */
    fun take(): TypedGrammar.Fix? {
        job?.cancel()
        val taken = current.value ?: return null
        current.value = null
        settled = taken.corrected
        return taken
    }

    /** The user waved the fix away: it is not offered again in this field. */
    fun dismiss() {
        val fix = current.value ?: return
        settled = fix.checked
        dismissed.add(fix.original to fix.replacement)
        current.value = null
    }

    /** A new field, or the keyboard went away: nothing carries over. */
    fun reset() {
        job?.cancel()
        job = null
        settled = null
        dismissed.clear()
        current.value = null
    }

    companion object {
        /** Long enough to be a pause rather than a gap between words. */
        const val PAUSE_MILLIS = 700L

        /** About what a cold load of the model takes on a mid-range phone. */
        const val LOAD_RETRY_MILLIS = 1_200L
    }
}
