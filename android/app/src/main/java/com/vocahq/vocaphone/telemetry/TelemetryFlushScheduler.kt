package com.vocahq.vocaphone.telemetry

import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch

/**
 * Flushes the queue when the app goes to the background.
 *
 * ## Why not WorkManager
 *
 * `androidx.work` is already a dependency and deferred background work is the
 * obvious-looking choice, but it is the wrong tool for this queue. Events live
 * in memory and do not survive the process (see [TelemetryQueue] for why that
 * is deliberate), so a job that runs half an hour later — after Android has
 * reclaimed the process — almost always wakes to find nothing to send. The
 * flush has to happen while the process that holds the events is still alive,
 * which means process lifecycle, not a scheduler.
 *
 * The cost is that a process death loses whatever was queued. That is
 * acceptable: these are counters, not records, and the alternative is a
 * disk-backed queue holding data that is not worth persisting.
 *
 * ## This is not the main flush trigger
 *
 * It used to be, and that was a bug worth remembering. `ProcessLifecycleOwner`
 * observes *activities*, and the IME is a Service — so a dictation done from
 * the keyboard inside another app happens with no activity on screen, no
 * background transition is ever reported, and [onStop] never runs. Every one of
 * those events sat in the queue until the process died. Delivery is owned by
 * the debounced flush in [Telemetry] instead, which fires wherever the event
 * came from; this observer only adds the immediate send when someone does leave
 * the app, so a burst does not wait out the debounce.
 */
internal class TelemetryFlushScheduler(
    private val telemetry: Telemetry,
    private val scope: CoroutineScope,
) : DefaultLifecycleObserver {

    fun start() {
        if (!TelemetryConfig.compiledIn) return
        ProcessLifecycleOwner.get().lifecycle.addObserver(this)
    }

    /**
     * Fired when the last activity stops — the app is backgrounded, but the
     * process is still up and the coroutine has time to finish. Failures are
     * swallowed inside [Telemetry.flush]; nothing here can surface an error to
     * a user who never asked for this feature to work.
     */
    override fun onStop(owner: LifecycleOwner) {
        scope.launch { telemetry.flush() }
    }
}
