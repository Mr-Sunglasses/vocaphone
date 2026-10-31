package com.vocahq.vocaphone.spell

import com.vocahq.vocaphone.writing.WritingCategory
import com.vocahq.vocaphone.writing.WritingCheck
import com.vocahq.vocaphone.writing.WritingFixtures
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ModelWaitTest {
    private val checker = WritingCheck(WritingFixtures.rules)
    private val text = "He don't know."
    private val options = WritingCheck.Options(setOf(WritingCategory.CORRECTNESS), typed = true)

    /** A model that is still loading until [loadsAfter] polls have passed, or forever when null. */
    private class Loader(private val loadsAfter: Int?, private val fails: Boolean = false) {
        var polls = 0
        var asked = 0
        val loading get() = loadsAfter == null || polls < loadsAfter
        val loaded get() = !loading && !fails
        val model = WritingCheck.Model { sentence ->
            asked++
            if (loaded) sentence.replace("don't", "doesn't") else null
        }
    }

    private fun run(loader: Loader) = ModelWait.check(
        check = { checker.check(text, loader.model, options) },
        loading = { loader.loading },
        loaded = { loader.loaded },
        sleep = { loader.polls++ },
    )

    @Test
    fun `a model that loads in time is asked again`() {
        val loader = Loader(loadsAfter = 3)
        val report = run(loader)
        assertFalse(report.modelPending)
        assertEquals(listOf("doesn't"), report.suggestions.map { it.replacement })
        assertEquals(3, loader.polls)
        assertEquals(2, loader.asked)
    }

    @Test
    fun `a loaded model is not waited on`() {
        val loader = Loader(loadsAfter = 0)
        val report = run(loader)
        assertFalse(report.modelPending)
        assertEquals(0, loader.polls)
        assertEquals(1, loader.asked)
    }

    @Test
    fun `a slow load keeps the rule-only answer after the bound`() {
        val loader = Loader(loadsAfter = null)
        val report = run(loader)
        assertTrue(report.modelPending)
        assertEquals((ModelWait.WAIT_MILLIS / ModelWait.POLL_MILLIS).toInt(), loader.polls)
        assertEquals(1, loader.asked)
    }

    @Test
    fun `a failed load is not asked again`() {
        val loader = Loader(loadsAfter = 1, fails = true)
        val report = run(loader)
        assertTrue(report.modelPending)
        assertEquals(1, loader.polls)
        assertEquals(1, loader.asked)
    }
}
