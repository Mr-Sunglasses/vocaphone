package com.vocahq.vocaphone.dictation

import com.vocahq.vocaphone.core.DictationPhase
import com.vocahq.vocaphone.core.DictationState
import com.vocahq.vocaphone.core.MissingPermission
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class DictationLifetimeTest {
    @Test
    fun `short tap that resets to equal idle still ends the observer`() = runTest {
        val lifetime = CompletableDeferred<Unit>()
        val states = MutableStateFlow(DictationState())
        val observer = launch { monitorDictation(lifetime, states) {} }
        runCurrent()
        // Neither intermediate state reaches the collector.
        states.value = DictationState(phase = DictationPhase.LISTENING)
        states.value = DictationState()
        lifetime.complete(Unit)
        runCurrent()
        assertTrue(observer.isCompleted)
    }

    @Test
    fun `service remains through inference and publishes changed status only`() = runTest {
        val lifetime = CompletableDeferred<Unit>()
        val states = MutableStateFlow(DictationState(phase = DictationPhase.TRANSCRIBING))
        val statuses = mutableListOf<String>()
        val observer = launch { monitorDictation(lifetime, states, publish = statuses::add) }
        runCurrent()
        assertFalse(observer.isCompleted)
        states.value = states.value.copy(recordedMillis = 100)
        runCurrent()
        states.value = DictationState(phase = DictationPhase.INSERTING)
        runCurrent()
        assertEquals(listOf("Transcribing", "Inserting"), statuses)
        lifetime.complete(Unit)
        runCurrent()
        assertTrue(observer.isCompleted)
    }

    @Test
    fun `already completed and missing pipelines need no status observer`() = runTest {
        val states = MutableStateFlow(DictationState())
        val statuses = mutableListOf<String>()
        monitorDictation(null, states, publish = statuses::add)
        monitorDictation(CompletableDeferred(Unit), states, publish = statuses::add)
        assertTrue(statuses.isEmpty())
    }

    @Test
    fun `cancelling service cancels status observer without cancelling dictation`() = runTest {
        val lifetime = CompletableDeferred<Unit>()
        val states = MutableStateFlow(DictationState(phase = DictationPhase.LISTENING))
        val statuses = mutableListOf<String>()
        val observer = launch { monitorDictation(lifetime, states, publish = statuses::add) }
        runCurrent()
        observer.cancel()
        runCurrent()
        states.value = DictationState(phase = DictationPhase.TRANSCRIBING)
        runCurrent()
        assertEquals(listOf("Listening"), statuses)
        assertFalse(lifetime.isCancelled)
        lifetime.complete(Unit)
    }
    @Test
    fun `download and preparation repairs release service while progress job stays active`() = runTest {
        for (missing in listOf(MissingPermission.MODEL_DOWNLOADING, MissingPermission.MODEL_PREPARING)) {
            val lifetime = CompletableDeferred<Unit>()
            val startupRepair = CompletableDeferred<Unit>()
            val states = MutableStateFlow(DictationState())
            val statuses = mutableListOf<String>()
            val observer = launch { monitorDictation(lifetime, states, startupRepair, statuses::add) }
            runCurrent()
            states.value = DictationState(
                phase = DictationPhase.PERMISSION_REPAIR,
                missingPermissions = setOf(missing),
            )
            startupRepair.complete(Unit)
            runCurrent()
            assertTrue(observer.isCompleted)
            assertTrue(lifetime.isActive)
            val published = statuses.toList()
            states.value = states.value.copy(modelDownloadProgress = 80)
            runCurrent()
            assertEquals(published, statuses)
            lifetime.complete(Unit)
        }
    }

    @Test
    fun `repair resolved before service subscribes needs no notification observer`() = runTest {
        val lifetime = CompletableDeferred<Unit>()
        val startupRepair = CompletableDeferred(Unit)
        val states = MutableStateFlow(DictationState(phase = DictationPhase.PERMISSION_REPAIR))
        val statuses = mutableListOf<String>()
        monitorDictation(lifetime, states, startupRepair, statuses::add)
        assertTrue(statuses.isEmpty())
        assertTrue(lifetime.isActive)
        lifetime.complete(Unit)
    }

    @Test
    fun `stale repair state does not release a new attempt before inference completes`() = runTest {
        val lifetime = CompletableDeferred<Unit>()
        val startupRepair = CompletableDeferred<Unit>()
        val states = MutableStateFlow(DictationState(phase = DictationPhase.PERMISSION_REPAIR))
        val observer = launch { monitorDictation(lifetime, states, startupRepair) {} }
        runCurrent()
        assertFalse(observer.isCompleted)
        states.value = DictationState(phase = DictationPhase.TRANSCRIBING)
        runCurrent()
        assertFalse(observer.isCompleted)
        lifetime.complete(Unit)
        runCurrent()
        assertTrue(observer.isCompleted)
        assertFalse(startupRepair.isCancelled)
    }

    @Test
    fun `equal repair snapshots still release because startup outcome is explicit`() = runTest {
        val state = DictationState(
            phase = DictationPhase.PERMISSION_REPAIR,
            missingPermissions = setOf(MissingPermission.MODEL_DOWNLOADING),
        )
        val states = MutableStateFlow(state)
        val lifetime = CompletableDeferred<Unit>()
        val startupRepair = CompletableDeferred<Unit>()
        val observer = launch { monitorDictation(lifetime, states, startupRepair) {} }
        runCurrent()
        // StateFlow suppresses the equal state, but the current attempt resolves.
        states.value = state.copy()
        startupRepair.complete(Unit)
        runCurrent()
        assertTrue(observer.isCompleted)
        assertTrue(lifetime.isActive)
        lifetime.complete(Unit)
    }
}
