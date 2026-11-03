package com.vocahq.vocaphone.ime

import com.vocahq.vocaphone.core.CorrectionWatch
import com.vocahq.vocaphone.core.LearnedCorrection
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch

/**
 * Learns the spellings the user fixes in a dictation this keyboard typed
 * ([CorrectionWatch]), without adding work to a keystroke.
 *
 * The keyboard already reads the text around the cursor, coalesced, after
 * its edits ([VocaPhoneInputMethodService.refreshEditorText]). For a short
 * while after a dictation that read is widened to cover it, and each reading
 * is handed here; the comparison runs in order on [worker], never on the
 * thread that draws the keyboard. [finish] — the next dictation, the
 * keyboard going away, the field closing, or [WATCH_MILLIS] — hands what was
 * learned, the "heard → corrected" pairs alone, to [deliver].
 *
 * The keyboard's calls come from its main thread.
 */
internal class DictationCorrectionObserver(
    scope: CoroutineScope,
    private val deliver: suspend (List<LearnedCorrection>) -> Unit,
    worker: CoroutineDispatcher = Dispatchers.Default,
) {
    private sealed interface Event {
        class Start(val inserted: String, val isKnownWord: (String) -> Boolean) : Event
        class Read(val before: String, val after: String, val reachesStart: Boolean, val reachesEnd: Boolean) : Event
        data object Finish : Event
    }

    private val events = Channel<Event>(Channel.UNLIMITED)

    /** Characters to read either side of the cursor for this dictation; 0 while none is followed. */
    var readLimit: Int = 0
        private set

    val isActive: Boolean get() = readLimit > 0

    init {
        scope.launch(worker) {
            var watch: CorrectionWatch? = null
            for (event in events) {
                when (event) {
                    is Event.Start -> watch = CorrectionWatch(event.isKnownWord).takeIf { it.start(event.inserted) }
                    is Event.Read -> watch?.read(event.before, event.after, event.reachesStart, event.reachesEnd)
                    Event.Finish -> {
                        val found = watch?.finish().orEmpty()
                        watch = null
                        if (found.isNotEmpty()) runCatching { deliver(found) }
                    }
                }
            }
        }
    }

    /**
     * A dictation was just typed. Finishes the one before it, then follows
     * this one; the next [fieldRead] is its baseline.
     */
    fun dictationInserted(inserted: String, isKnownWord: (String) -> Boolean) {
        finish()
        readLimit = CorrectionWatch.readLimit(inserted)
        events.trySend(Event.Start(inserted, isKnownWord))
    }

    /**
     * What the keyboard read around the cursor, [requested] characters each
     * side: a side that came back shorter reached the end of the field.
     */
    fun fieldRead(before: String, after: String, requested: Int) {
        if (!isActive) return
        events.trySend(Event.Read(before, after, before.length < requested, after.length < requested))
    }

    /** Stop following the dictation and hand over what it taught. */
    fun finish() {
        if (!isActive) return
        readLimit = 0
        events.trySend(Event.Finish)
    }

    fun close() {
        finish()
        events.close()
    }

    companion object {
        /** Longest a dictation is followed, as VocaMac does. */
        const val WATCH_MILLIS = 20_000L
    }
}
