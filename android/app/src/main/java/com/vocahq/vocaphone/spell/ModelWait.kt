package com.vocahq.vocaphone.spell

import com.vocahq.vocaphone.writing.WritingCheck

/**
 * The spell checker answers once per request: an answer given while the
 * grammar model was still loading is rule-only, and nothing would replace it
 * until the framework asks about that text again. So a check that found the
 * model loading (asking started the load) waits a bounded time for it, polling,
 * and checks once more when it is in. A load that fails or runs past the bound
 * keeps the rule-only answer; the next request asks the model again.
 *
 * The framework calls the service on its own binder threads and delivers the
 * answer asynchronously, so the wait holds no one's UI thread. It only happens
 * on the first checks after the process starts or the model changes.
 */
internal object ModelWait {
    /** A little over a cold load of the model on a mid-range phone. */
    const val WAIT_MILLIS = 1_500L
    const val POLL_MILLIS = 50L

    fun check(
        check: () -> WritingCheck.Report,
        loading: () -> Boolean,
        loaded: () -> Boolean,
        waitMillis: Long = WAIT_MILLIS,
        sleep: (Long) -> Unit = Thread::sleep,
    ): WritingCheck.Report {
        val first = check()
        if (!first.modelPending) return first
        var waited = 0L
        while (loading() && waited < waitMillis) {
            sleep(POLL_MILLIS)
            waited += POLL_MILLIS
        }
        return if (loaded()) check() else first
    }
}
