package com.vocahq.vocaphone.ime

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class TypedGrammarCheckTest {
    private val dispatcher = StandardTestDispatcher()
    private val scope = TestScope(dispatcher)

    private var editor = ""
    private var reads = 0
    private val checked = mutableListOf<String>()
    private var loaded = true
    private var english = true

    private val check = TypedGrammarCheck(
        scope = scope,
        worker = dispatcher,
        readBefore = { reads++; editor },
        correct = { text, _ ->
            checked.add(text)
            if (!loaded) null else text.replace("don't", "doesn't").replace("was", "were")
        },
        isEnglish = { english },
    )

    private fun type(text: String, enabled: Boolean = true) {
        editor = text
        check.textChanged(text.takeLast(32), enabled) { emptySet() }
    }

    private fun TestScope.pause() {
        advanceTimeBy(TypedGrammarCheck.PAUSE_MILLIS + 1)
        runCurrent()
    }

    @Test
    fun `a pause after a sentence offers its fix`() = scope.runTest {
        type("He don't know. ")
        pause()
        assertEquals("don't → doesn't", check.fix.value?.label)
    }

    @Test
    fun `typing before the pause ends checks nothing`() = scope.runTest {
        type("He don't know. ")
        advanceTimeBy(TypedGrammarCheck.PAUSE_MILLIS / 2)
        type("He don't know. A")
        advanceTimeBy(TypedGrammarCheck.PAUSE_MILLIS / 2)
        runCurrent()
        assertEquals(0, reads)
        assertEquals(emptyList<String>(), checked)
    }

    @Test
    fun `mid-word nothing is sent to the model`() = scope.runTest {
        type("He don't kno")
        pause()
        assertEquals(1, reads)
        assertEquals(emptyList<String>(), checked)
        assertNull(check.fix.value)
    }

    @Test
    fun `the same text is not checked twice`() = scope.runTest {
        type("They was late. ")
        pause()
        type("They was late.  ")
        pause()
        assertEquals(listOf("They was late."), checked)
        assertEquals("was → were", check.fix.value?.label)
    }

    @Test
    fun `typing on past the sentence hides the fix`() = scope.runTest {
        type("He don't know. ")
        pause()
        type("He don't know. Then")
        assertNull(check.fix.value)
    }

    @Test
    fun `turning it off hides the fix and stops checking`() = scope.runTest {
        type("He don't know. ")
        pause()
        type("He don't know. ", enabled = false)
        assertNull(check.fix.value)
        pause()
        assertEquals(1, checked.size)
    }

    @Test
    fun `a dismissed fix is not offered again for the same text`() = scope.runTest {
        type("He don't know. ")
        pause()
        check.dismiss()
        type("He don't know.  ")
        pause()
        assertNull(check.fix.value)
        assertEquals(1, checked.size)
    }

    @Test
    fun `a dismissed fix stays away as the user types on`() = scope.runTest {
        type("He don't know. ")
        pause()
        check.dismiss()
        type("He don't know. It is fine. ")
        pause()
        assertEquals(2, checked.size)
        assertNull(check.fix.value)
    }

    @Test
    fun `an applied fix's result is not checked again`() = scope.runTest {
        type("He don't know. ")
        pause()
        val taken = check.take()
        assertEquals("He doesn't know.", taken?.corrected)
        type("He doesn't know. ")
        pause()
        assertEquals(listOf("He don't know."), checked)
        assertNull(check.fix.value)
    }

    @Test
    fun `a model still loading is asked once more`() = scope.runTest {
        loaded = false
        type("He don't know. ")
        pause()
        assertNull(check.fix.value)
        loaded = true
        advanceTimeBy(TypedGrammarCheck.LOAD_RETRY_MILLIS + 1)
        runCurrent()
        assertEquals("don't → doesn't", check.fix.value?.label)
    }

    @Test
    fun `another language is left alone`() = scope.runTest {
        english = false
        type("He don't know. ")
        pause()
        assertEquals(emptyList<String>(), checked)
        assertNull(check.fix.value)
    }

    @Test
    fun `reset forgets everything`() = scope.runTest {
        type("He don't know. ")
        pause()
        check.reset()
        assertNull(check.fix.value)
        type("He don't know. ")
        pause()
        assertEquals(2, checked.size)
    }
}
