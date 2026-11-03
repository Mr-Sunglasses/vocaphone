package com.vocahq.vocaphone.ime

import com.vocahq.vocaphone.core.CorrectionLearnerTest
import com.vocahq.vocaphone.core.LearnedCorrection
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The keyboard's side of learning from corrections: readings in order, pairs out at the end. */
@OptIn(ExperimentalCoroutinesApi::class)
class DictationCorrectionObserverTest {
    private val dispatcher = StandardTestDispatcher()
    private val scope = TestScope(dispatcher)
    private val delivered = mutableListOf<List<LearnedCorrection>>()
    /** On the test's background scope, which ends the observer's loop with the test. */
    private fun TestScope.observer() =
        DictationCorrectionObserver(backgroundScope, deliver = { delivered += it }, worker = dispatcher)
    private val isKnown: (String) -> Boolean = { it.lowercase() in CorrectionLearnerTest.COMMON }

    @Test
    fun `hands over the fix when the dictation is finished`() = scope.runTest {
        val observer = observer()
        observer.dictationInserted("ask Namratha about it", isKnown)
        assertTrue(observer.isActive)
        val limit = observer.readLimit
        assertTrue(limit >= 32)
        observer.fieldRead("ask Namratha about it", "", limit)
        observer.fieldRead("ask Namrata", " about it", limit)
        runCurrent()
        assertTrue("Nothing is handed over before the end", delivered.isEmpty())
        observer.finish()
        runCurrent()
        assertFalse(observer.isActive)
        assertEquals(listOf("Namratha" to "Namrata"), delivered.single().map { it.heard to it.corrected })
    }

    @Test
    fun `the next dictation finishes the one before`() = scope.runTest {
        val observer = observer()
        observer.dictationInserted("ask Namratha about it", isKnown)
        observer.fieldRead("ask Namratha about it", "", observer.readLimit)
        observer.fieldRead("ask Namrata about it", "", observer.readLimit)
        observer.dictationInserted("and the code", isKnown)
        runCurrent()
        assertEquals(1, delivered.size)
    }

    @Test
    fun `nothing learned hands over nothing, and readings without a dictation are ignored`() = scope.runTest {
        val observer = observer()
        observer.fieldRead("ask Namratha about it", "", 32)
        observer.dictationInserted("ask Namratha about it", isKnown)
        observer.fieldRead("ask Namratha about it", "", observer.readLimit)
        observer.finish()
        observer.finish()
        runCurrent()
        assertTrue(delivered.isEmpty())
        assertEquals(0, observer.readLimit)
    }
}
