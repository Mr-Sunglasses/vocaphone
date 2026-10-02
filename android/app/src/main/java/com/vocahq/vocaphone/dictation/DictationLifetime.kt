package com.vocahq.vocaphone.dictation

import com.vocahq.vocaphone.core.DictationState
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch

/** Keep status current until the actual work ends, even if StateFlow skips a phase. */
internal suspend fun monitorDictation(
    lifetime: Job?,
    states: StateFlow<DictationState>,
    publish: (String) -> Unit,
) = coroutineScope {
    if (lifetime == null || lifetime.isCompleted) return@coroutineScope
    val updates = launch(start = CoroutineStart.UNDISPATCHED) {
        states.map { it.statusText }.distinctUntilChanged().collect { publish(it) }
    }
    try {
        lifetime.join()
    } finally {
        updates.cancel()
    }
}
