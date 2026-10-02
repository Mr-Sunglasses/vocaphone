package com.vocahq.vocaphone.dictation

import com.vocahq.vocaphone.core.DictationPhase
import com.vocahq.vocaphone.core.DictationState
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
        val observer = launch { monitorDictation(lifetime, states, statuses::add) }
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
        monitorDictation(null, states, statuses::add)
        monitorDictation(CompletableDeferred(Unit), states, statuses::add)
        assertTrue(statuses.isEmpty())
    }

    @Test
    fun `cancelling service cancels status observer without cancelling dictation`() = runTest {
        val lifetime = CompletableDeferred<Unit>()
        val states = MutableStateFlow(DictationState(phase = DictationPhase.LISTENING))
        val statuses = mutableListOf<String>()
        val observer = launch { monitorDictation(lifetime, states, statuses::add) }
        runCurrent()
        observer.cancel()
        runCurrent()
        states.value = DictationState(phase = DictationPhase.TRANSCRIBING)
        runCurrent()
        assertEquals(listOf("Listening"), statuses)
        assertFalse(lifetime.isCancelled)
        lifetime.complete(Unit)
    }
}
