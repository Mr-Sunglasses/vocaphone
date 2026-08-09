package com.vocahq.vocaphone.ime

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class KeyboardPreferenceCoordinatorTest {

    @Test
    fun `write stays pending until durable settings update completes`() = runTest {
        val releaseWrite = CompletableDeferred<Unit>()
        val coordinator = KeyboardPreferenceCoordinator(this, onError = {})

        assertTrue(coordinator.submit { releaseWrite.await() })
        runCurrent()
        assertTrue(coordinator.isPending)

        releaseWrite.complete(Unit)
        advanceUntilIdle()
        assertFalse(coordinator.isPending)
    }

    @Test
    fun `a second selection cannot overtake the active write`() = runTest {
        val releaseWrite = CompletableDeferred<Unit>()
        var secondWriteRan = false
        val coordinator = KeyboardPreferenceCoordinator(this, onError = {})

        assertTrue(coordinator.submit { releaseWrite.await() })
        assertFalse(coordinator.submit { secondWriteRan = true })
        releaseWrite.complete(Unit)
        advanceUntilIdle()

        assertFalse(secondWriteRan)
    }

    @Test
    fun `failed writes clear pending state and report the error`() = runTest {
        var errorReported = false
        val coordinator = KeyboardPreferenceCoordinator(this) { errorReported = true }

        assertTrue(coordinator.submit { error("DataStore unavailable") })
        advanceUntilIdle()

        assertTrue(errorReported)
        assertFalse(coordinator.isPending)
    }
}
