package com.vocahq.vocaphone.ime

import com.vocahq.vocaphone.writing.WritingCategory
import com.vocahq.vocaphone.writing.WritingCheck
import com.vocahq.vocaphone.writing.WritingFixtures
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class WritingCheckSessionTest {
    private val dispatcher = StandardTestDispatcher()
    private val scope = TestScope(dispatcher)

    private var editor = ""
    private var cursor = -1
    private var reads = 0
    private val asked = mutableListOf<String>()
    /** Whether each call in [asked] was the thorough tier. */
    private val tiers = mutableListOf<Boolean>()
    private var loaded = true
    private var modelOn = true
    private var english = true
    /** Runs inside the model's call, as something on the main thread could while the worker is busy. */
    private var duringAsk: (() -> Unit)? = null
    // Model-only slips: the rules alone catch neither "She go" nor "cars was".
    private val checker = WritingCheck(WritingFixtures.rules)
    private val options = WritingCheckSession.Options(WritingCategory.entries.toSet(), emptySet(), tone = true)

    private val session = WritingCheckSession(
        scope = scope,
        worker = dispatcher,
        read = {
            reads++
            WritingCheckSession.Field(editor, offset = 10, cursor = if (cursor < 0) editor.length else cursor)
        },
        checker = { checker },
        model = {
            if (!modelOn) {
                null
            } else {
                { sentence, _, thorough ->
                    asked.add(sentence)
                    tiers.add(thorough)
                    duringAsk?.also { duringAsk = null }?.invoke()
                    if (!loaded) null else sentence.replace("She go ", "She goes ").replace(" was ", " were ")
                }
            }
        },
        isEnglish = { english },
    )

    private fun type(text: String, enabled: Boolean = true, auto: Boolean = true) {
        editor = text
        session.textChanged(text.takeLast(32), enabled, auto) { options }
    }

    private fun TestScope.pause() {
        advanceTimeBy(WritingCheckSession.PAUSE_MILLIS + 1)
        runCurrent()
    }

    private fun labels() = session.report.value?.suggestions?.map { it.label }

    @Test
    fun `a pause checks the field with the rules and the model`() = scope.runTest {
        type("She go home. I could of told you. ")
        pause()
        assertEquals(listOf("go → goes", "of → have"), labels())
        assertEquals(2, session.report.value?.chips?.size)
    }

    @Test
    fun `the button asks the model for the thorough tier, and so does every pause after it`() = scope.runTest {
        type("She go home. ")
        pause()
        assertEquals(listOf(false), tiers)
        session.checkNow(options)
        runCurrent()
        // The thorough tier keeps its own answers, so the sentence is asked again.
        assertEquals(listOf("She go home.", "She go home."), asked)
        assertEquals(listOf(false, true), tiers)
        type("She go home. The cars was late. ")
        pause()
        assertEquals(listOf("She go home.", "She go home.", "The cars was late."), asked)
        assertEquals(listOf(false, true, true), tiers)
    }

    @Test
    fun `typing before the pause ends checks nothing`() = scope.runTest {
        type("She go home. ")
        advanceTimeBy(WritingCheckSession.PAUSE_MILLIS / 2)
        type("She go home. A")
        advanceTimeBy(WritingCheckSession.PAUSE_MILLIS / 2)
        runCurrent()
        assertEquals(0, reads)
        assertEquals(emptyList<String>(), asked)
    }

    @Test
    fun `the word being typed is never flagged`() = scope.runTest {
        type("I definately")
        pause()
        assertEquals(emptyList<String>(), labels())
        type("I definately ")
        pause()
        assertEquals(listOf("definately → definitely"), labels())
    }

    @Test
    fun `each sentence goes to the model once`() = scope.runTest {
        type("She go home. ")
        pause()
        type("She go home. The cars was late. ")
        pause()
        assertEquals(listOf("She go home.", "The cars was late."), asked)
        assertEquals(listOf("go → goes", "was → were"), labels())
    }

    @Test
    fun `the same text is not checked twice`() = scope.runTest {
        type("The cars was late. ")
        pause()
        val reads = this@WritingCheckSessionTest.reads
        session.textChanged("The cars was late. ", true) { options }
        pause()
        assertEquals(reads + 1, this@WritingCheckSessionTest.reads)
        assertEquals(listOf("The cars was late."), asked)
    }

    @Test
    fun `without the model the rules still check`() = scope.runTest {
        modelOn = false
        type("She go home. I could of told you. ")
        pause()
        assertEquals(listOf("of → have"), labels())
        assertEquals(emptyList<String>(), asked)
    }

    @Test
    fun `a model still loading is asked once more`() = scope.runTest {
        loaded = false
        type("She go home. ")
        pause()
        assertNull(session.report.value)
        loaded = true
        advanceTimeBy(WritingCheckSession.LOAD_RETRY_MILLIS + 1)
        runCurrent()
        assertEquals(listOf("go → goes"), labels())
    }

    @Test
    fun `turning it off clears the strip`() = scope.runTest {
        type("She go home. ")
        pause()
        type("She go home. ", enabled = false)
        assertNull(session.report.value)
    }

    @Test
    fun `a dismissed suggestion stays away in this field`() = scope.runTest {
        type("She go home. ")
        pause()
        session.dismiss(session.report.value!!.suggestions.single())
        assertEquals(emptyList<String>(), labels())
        type("She go home. Fine. ")
        pause()
        assertEquals(emptyList<String>(), labels())
    }

    @Test
    fun `applying moves the others to where they now are`() = scope.runTest {
        type("She go home. I could of told you. ")
        pause()
        val first = session.report.value!!.suggestions.first()
        session.applied(first)
        val report = session.report.value!!
        assertEquals("She goes home. I could of told you. ", report.field.text)
        val rest = report.suggestions.single()
        assertEquals("of", report.field.text.substring(rest.start, rest.end))
    }

    @Test
    fun `another language is left alone`() = scope.runTest {
        english = false
        type("Je ne sais pas. ")
        pause()
        assertNull(session.report.value)
        assertTrue(asked.isEmpty())
    }

    @Test
    fun `reset forgets everything`() = scope.runTest {
        type("She go home. ")
        pause()
        session.reset()
        assertNull(session.report.value)
        assertFalse(session.checking.value)
        type("She go home. ")
        pause()
        assertEquals(listOf("She go home.", "She go home."), asked)
    }

    @Test
    fun `moving the cursor checks again for where it now is`() = scope.runTest {
        type("I definately agree. ")
        pause()
        assertEquals(listOf("definately → definitely"), labels())
        // Into the misspelt word: the text is the same, but it is now being typed.
        cursor = 6
        session.textChanged("I defi", true) { options }
        pause()
        assertEquals(6, session.report.value?.field?.cursor)
        assertEquals(emptyList<String>(), labels())
        cursor = -1
        session.textChanged(editor, true) { options }
        pause()
        assertEquals(listOf("definately → definitely"), labels())
    }

    @Test
    fun `ending a selection brings the suggestions back`() = scope.runTest {
        type("I definately agree. ")
        pause()
        type("I definately agree. ", enabled = false)
        assertNull(session.report.value)
        type("I definately agree. ")
        pause()
        assertEquals(listOf("definately → definitely"), labels())
    }

    @Test
    fun `a model that never answered is asked again at the next pause`() = scope.runTest {
        loaded = false
        type("She go home. ")
        pause()
        advanceTimeBy(WritingCheckSession.LOAD_RETRY_MILLIS + 1)
        runCurrent()
        assertEquals(emptyList<String>(), labels())
        loaded = true
        session.textChanged("She go home. ", true) { options }
        pause()
        assertEquals(listOf("go → goes"), labels())
    }

    @Test
    fun `accepting several fixes takes each off the report`() = scope.runTest {
        type("I definately recieve it. ")
        pause()
        val fixes = session.report.value!!.suggestions
        assertEquals(listOf("definately → definitely", "recieve → receive"), fixes.map { it.label })
        // In reading order, as Accept all collects them; the first one changes length.
        session.applied(fixes)
        assertEquals("I definitely receive it. ", session.report.value!!.field.text)
        assertEquals(emptyList<String>(), labels())
    }

    @Test
    fun `an undone fix is not offered again although it left the report`() = scope.runTest {
        type("I definately agree. ")
        pause()
        val fix = session.report.value!!.suggestions.single()
        session.applied(fix)
        assertEquals(emptyList<String>(), labels())
        session.dismissKey(fix.key)
        type("I definately agree. ")
        pause()
        assertEquals(emptyList<String>(), labels())
    }

    @Test
    fun `a check overtaken by a reset leaves nothing behind`() = scope.runTest {
        duringAsk = { session.reset() }
        type("She go home. ")
        pause()
        assertNull(session.report.value)
        assertFalse(session.checking.value)
        type("She go home. ")
        pause()
        // The old check's answer was not kept for the new field.
        assertEquals(listOf("She go home.", "She go home."), asked)
        assertEquals(listOf("go → goes"), labels())
    }

    @Test
    fun `the button checks a field whatever the setting`() = scope.runTest {
        type("She go home. ", auto = false)
        pause()
        assertNull(session.report.value)
        assertEquals(0, reads)
        session.checkNow(options)
        assertTrue(session.checking.value)
        runCurrent()
        assertEquals(listOf("go → goes"), labels())
        assertFalse(session.checking.value)
    }

    @Test
    fun `after the button the field is followed`() = scope.runTest {
        type("She go home. ", auto = false)
        session.checkNow(options)
        runCurrent()
        type("She go home. The cars was late. ", auto = false)
        pause()
        assertEquals(listOf("go → goes", "was → were"), labels())
    }

    @Test
    fun `typing on keeps the count but not the chips`() = scope.runTest {
        type("She go home. ")
        pause()
        assertEquals(1, session.report.value?.chips?.size)
        type("She go home. Then")
        assertEquals(listOf("go → goes"), labels())
        assertEquals(emptyList<Any>(), session.report.value?.chips)
    }

    @Test
    fun `a new field stops following`() = scope.runTest {
        type("She go home. ", auto = false)
        session.checkNow(options)
        runCurrent()
        session.reset()
        type("The cars was late. ", auto = false)
        pause()
        assertNull(session.report.value)
    }
}
