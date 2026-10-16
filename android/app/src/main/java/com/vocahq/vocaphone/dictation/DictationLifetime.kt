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
) = monitorDictation(lifetime, states, startupRepair, DictationState::statusText, publish)

/** As above, publishing whatever [describe] makes of each state, once per change. */
internal suspend fun <T> monitorDictation(
    lifetime: Job?,
    states: StateFlow<DictationState>,
    startupRepair: Deferred<Unit>?,
    describe: (DictationState) -> T,
    publish: (T) -> Unit,
) = coroutineScope {
    if (lifetime == null || lifetime.isCompleted || startupRepair?.isCompleted == true) {
        return@coroutineScope
    }
    val updates = launch(start = CoroutineStart.UNDISPATCHED) {
        states.map(describe).distinctUntilChanged().collect { publish(it) }
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

/**
 * What the recording notification says. It was "VocaPhone is working" with
 * only Cancel, even while the microphone was open: nothing in the shade said
 * it was recording, and the only way to stop and keep the words was to go
 * back to wherever the dictation started.
 */
internal data class RecordingNotice(
    val title: String,
    val text: String,
    /** Finish (stop and transcribe) is offered only while the microphone is open. */
    val offersFinish: Boolean,
) {
    companion object {
        fun of(state: DictationState): RecordingNotice = if (state.phase.holdsMicrophone) {
            RecordingNotice(
                title = "Recording",
                text = if (state.approachingLimit) "One minute left" else "Tap Finish to transcribe",
                offersFinish = true,
            )
        } else {
            RecordingNotice(title = "VocaPhone", text = state.statusText, offersFinish = false)
        }
    }
}
