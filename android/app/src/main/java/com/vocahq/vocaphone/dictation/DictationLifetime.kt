package com.vocahq.vocaphone.dictation

import com.vocahq.vocaphone.core.DictationState
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Job
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import kotlinx.coroutines.selects.select

/** Keep status until dictation ends or this attempt resolves without recording. */
internal suspend fun monitorDictation(
    lifetime: Job?,
    states: StateFlow<DictationState>,
    startupRepair: Deferred<Unit>? = null,
    publish: (String) -> Unit,
) = coroutineScope {
    if (lifetime == null || lifetime.isCompleted || startupRepair?.isCompleted == true) {
        return@coroutineScope
    }
    val updates = launch(start = CoroutineStart.UNDISPATCHED) {
        states.map { it.statusText }.distinctUntilChanged().collect { publish(it) }
    }
    try {
        // A repair can wait for a model download long after recording was
        // rejected. Release the service without cancelling that progress job.
        // Use the attempt's signal rather than a possibly stale UI phase.
        select<Unit> {
            lifetime.onJoin {}
            if (startupRepair != null) startupRepair.onAwait {}
        }
    } finally {
        updates.cancel()
    }
}
