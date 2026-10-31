package com.vocahq.vocaphone.ime

import com.vocahq.vocaphone.writing.WritingCategory
import com.vocahq.vocaphone.writing.WritingCheck
import com.vocahq.vocaphone.writing.WritingFixtures
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * "Fix obvious typos as I type", driven the way the keyboard drives it: the
 * report is collected as it is published, so a fix's edit republishes the
 * report with the other typos still in it.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class WritingAutoFixTest {
    private val dispatcher = StandardTestDispatcher()
    private val scope = TestScope(dispatcher)
    private val options = WritingCheckSession.Options(WritingCategory.entries.toSet(), emptySet(), tone = false)

    private var editor = FakeWritingEditor("", 0)
    /** Where the field the keyboard reads starts in the editor. */
    private var offset = 0

    private val session = WritingCheckSession(
        scope = scope,
        worker = dispatcher,
        read = ::field,
        checker = { WritingCheck(WritingFixtures.rules) },
        model = { null },
        isEnglish = { true },
    )

    private var undo: AutoFix? = null

    private fun field() = WritingCheckSession.Field(editor.text.substring(offset), offset, editor.cursor - offset)

    /** The keyboard's maybeAutoFix, less the settings. */
    private fun maybeAutoFix(report: WritingCheckSession.Report) {
        val candidate = autoFixCandidate(report, undoPending = undo != null) ?: return
        val fresh = field()
        val fix = autoFixFor(report, candidate, fresh) ?: return
        val commit = commitWritingFixes(editor.connection, listOf(fix), fresh.offset + fresh.cursor, false)
        session.applied(commit.applied.mapNotNull { it.suggestion })
        undo = commit.applied.singleOrNull()?.let { AutoFix.of(it, fresh) }
    }

    private fun TestScope.collect() {
        backgroundScope.launch(UnconfinedTestDispatcher(testScheduler)) {
            session.report.collect { if (it != null) maybeAutoFix(it) }
        }
    }

    private fun type(text: String) {
        editor.text += text
        editor.cursor = editor.text.length
        // The keyboard's refresh: any edit after the fix ends its Undo.
        if (undo?.stillOffered(editor.text.takeLast(32), hasSelection = false) == false) undo = null
        session.textChanged(editor.text.takeLast(32), enabled = true) { options }
    }

    private fun TestScope.pause() {
        advanceTimeBy(WritingCheckSession.PAUSE_MILLIS + 1)
        runCurrent()
    }

    private fun undo() {
        val fix = undo!!.undoIn(field())!!
        undo = null
        commitWritingFixes(editor.connection, listOf(fix), editor.cursor, false)
    }

    @Test
    fun `two typos in one check are fixed one per Undo`() = scope.runTest {
        collect()
        type("I definately recieve it. ")
        pause()
        // The edit republished the report with "definately" still in it; it waits for the Undo offer to end.
        assertEquals("I definately receive it. ", editor.text)
        assertEquals("recieve → receive", undo?.label)
        assertEquals(listOf("definately → definitely"), session.report.value?.suggestions?.map { it.label })

        type("So ")
        assertNull(undo)
        pause()
        assertEquals("I definitely receive it. So ", editor.text)
        assertEquals("definately → definitely", undo?.label)

        // Undo puts back the word it names, and only that one.
        undo()
        assertEquals("I definately receive it. So ", editor.text)
        assertEquals(editor.text.length, editor.cursor)
    }

    @Test
    fun `Undo restores the typo where it was typed`() = scope.runTest {
        collect()
        offset = 4
        editor = FakeWritingEditor("Hi. ", 4)
        type("I dont recieve it. ")
        pause()
        assertEquals("Hi. I dont receive it. ", editor.text)
        undo()
        assertEquals("Hi. I dont recieve it. ", editor.text)
    }

    @Test
    fun `a cursor moved onto or before the typo after the check leaves it alone`() = scope.runTest {
        type("I recieve it. ")
        pause()
        val report = session.report.value!!
        val candidate = autoFixCandidate(report, undoPending = false)!!
        for (cursor in listOf(0, 2, 5, 9)) {
            editor.cursor = cursor
            assertNull("cursor at $cursor", autoFixFor(report, candidate, field()))
        }
        editor.cursor = editor.text.length
        assertEquals(WritingFix(2, 9, "receive", candidate), autoFixFor(report, candidate, field()))
    }

    @Test
    fun `a report older than the text after the typo makes no fix`() = scope.runTest {
        type("I recieve it. ")
        pause()
        val report = session.report.value!!
        val candidate = autoFixCandidate(report, undoPending = false)!!
        editor.text += "And"
        editor.cursor = editor.text.length
        assertNull(autoFixFor(report, candidate, field()))
        editor.text = "I recieve that. "
        editor.cursor = editor.text.length
        assertNull(autoFixFor(report, candidate, field()))
    }

    @Test
    fun `text added before the typo still moves the fix onto it`() = scope.runTest {
        type("I recieve it. ")
        pause()
        val report = session.report.value!!
        val candidate = autoFixCandidate(report, undoPending = false)!!
        editor.text = "Yes, I recieve it. "
        editor.cursor = editor.text.length
        assertEquals(WritingFix(7, 14, "receive", candidate), autoFixFor(report, candidate, field()))
    }

    @Test
    fun `no fix is offered while an Undo is pending`() = scope.runTest {
        type("I recieve it. ")
        pause()
        val report = session.report.value!!
        assertNull(autoFixCandidate(report, undoPending = true))
        assertNotNull(autoFixCandidate(report, undoPending = false))
    }
}
