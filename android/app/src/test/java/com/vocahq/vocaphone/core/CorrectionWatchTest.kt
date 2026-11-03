package com.vocahq.vocaphone.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Following a dictation through the user's edits, from what the keyboard
 * reads around the cursor. The same cases as `CorrectionWatchTests.swift`.
 */
class CorrectionWatchTest {
    private val isKnown: (String) -> Boolean = { it.lowercase() in CorrectionLearnerTest.COMMON }

    private fun watching(inserted: String): CorrectionWatch =
        CorrectionWatch(isKnown).also { assertTrue(it.start(inserted)) }

    /** A field read whole: both sides reach its ends. */
    private fun CorrectionWatch.whole(before: String, after: String = "") = read(before, after, true, true)

    private fun pairs(found: List<LearnedCorrection>) = found.map { it.heard to it.corrected }

    @Test
    fun `learns a fix made in the middle of a short message`() {
        val watch = watching("ask Namratha about it ")
        watch.whole("ask Namratha about it ")
        // The cursor moved back into the name and one letter went.
        watch.whole("ask Namrata", " about it ")
        val found = watch.finish()
        assertEquals(listOf("Namratha" to "Namrata"), pairs(found))
        assertFalse(found.single().heardIsWord)
        assertTrue(found.single().namesTerm)
        assertFalse(watch.isActive)
    }

    @Test
    fun `keeps the fix when the message is sent and the field cleared`() {
        val watch = watching("ask Namratha about it")
        watch.whole("ask Namratha about it")
        watch.whole("ask Namrata about it")
        watch.whole("")
        assertEquals(listOf("Namratha" to "Namrata"), pairs(watch.finish()))
    }

    @Test
    fun `the last reading that finds the dictation wins`() {
        val watch = watching("ask Namratha about it")
        watch.whole("ask Namratha about it")
        // Half-way through retyping the name, then done.
        watch.whole("ask Namrat", " about it")
        watch.whole("ask Namrata", " about it")
        assertEquals(listOf("Namratha" to "Namrata"), pairs(watch.finish()))
    }

    @Test
    fun `undoing a fix unlearns it`() {
        val watch = watching("ask Namratha about it")
        watch.whole("ask Namratha about it")
        watch.whole("ask Namrata about it")
        watch.whole("ask Namratha about it")
        assertTrue(watch.finish().isEmpty())
    }

    @Test
    fun `writing on after a fix keeps it`() {
        val watch = watching("ask Namratha about it")
        watch.whole("ask Namratha about it")
        watch.whole("ask Namrata about it and the report")
        assertEquals(listOf("Namratha" to "Namrata"), pairs(watch.finish()))
    }

    @Test
    fun `finds a dictation in the middle of a long field from partial readings`() {
        val earlier = "Notes from Monday. ".repeat(20)
        val inserted = "please ask Namratha about it"
        val later = " Then we ship on Friday. ".repeat(10)
        val watch = watching(inserted)
        // Just after the insertion: the cursor at its end, neither side reaching the field's ends.
        watch.read(earlier.takeLast(60) + inserted, later.take(60), false, false)
        // The cursor moved into the name; the window moved with it.
        val edited = earlier + "please ask Namrata about it" + later
        val cursor = edited.indexOf("Namrata") + 4
        watch.read(edited.substring(cursor - 50, cursor), edited.substring(cursor, cursor + 50), false, false)
        assertEquals(listOf("Namratha" to "Namrata"), pairs(watch.finish()))
    }

    @Test
    fun `gives up where the dictation cannot be told apart`() {
        val span = DictatedSpan(
            dictated = "ask Namratha",
            before = "Re: ",
            after = ".",
            beforeIsFieldStart = false,
            afterIsFieldEnd = false,
        )
        // Two copies with different text between the same anchors.
        assertNull(span.edited("Re: ask Namrata. Re: ask Namrita.", reachesStart = true, reachesEnd = true))
        // Two copies saying the same thing are one answer.
        assertEquals(
            "ask Namrata",
            span.edited("Re: ask Namrata. Re: ask Namrata.", reachesStart = true, reachesEnd = true),
        )
        // An anchor is gone.
        assertNull(span.edited("Fwd: ask Namrata.", reachesStart = true, reachesEnd = true))
    }

    @Test
    fun `a field anchor needs a reading that reaches the field's end`() {
        val span = DictatedSpan("ask Namratha", before = "", after = "", beforeIsFieldStart = true, afterIsFieldEnd = true)
        assertEquals("ask Namrata", span.edited("ask Namrata", reachesStart = true, reachesEnd = true))
        assertNull(span.edited("ask Namrata", reachesStart = false, reachesEnd = true))
    }

    @Test
    fun `a field that moved on is not learned from`() {
        val watch = watching("ask Namratha about it")
        watch.whole("ask Namratha about it")
        // Sent, then a new message in the same field.
        watch.whole("ok")
        assertTrue(watch.finish().isEmpty())
    }

    @Test
    fun `rewording teaches nothing`() {
        val watch = watching("put it there please")
        watch.whole("put it there please")
        watch.whole("put it their please")
        assertTrue(watch.finish().isEmpty())
    }

    @Test
    fun `an ordinary word fixed to a name is marked as a word`() {
        val watch = watching("ask cloud about it")
        watch.whole("ask cloud about it")
        watch.whole("ask Claude about it")
        val found = watch.finish().single()
        assertEquals("cloud" to "Claude", found.heard to found.corrected)
        assertTrue(found.heardIsWord)
        assertTrue(found.namesTerm)
    }

    @Test
    fun `text in another language is not followed`() {
        assertFalse(CorrectionWatch(isKnown).start("frag Namratha danach bitte"))
        assertFalse(CorrectionWatch(isKnown).start("   "))
    }

    @Test
    fun `a dictation not at the cursor after insertion is dropped`() {
        val watch = watching("ask Namratha about it")
        watch.whole("something else entirely")
        assertFalse(watch.isActive)
        watch.whole("ask Namrata about it")
        assertTrue(watch.finish().isEmpty())
    }

    @Test
    fun `a space after the dictation still finds its baseline`() {
        val span = DictatedSpan.baseline("ask Namratha", "Hi. ask Namratha ", " Bye", reachesStart = true, reachesEnd = true)
        assertEquals("Hi. ", span?.before)
        assertEquals("  Bye", span?.after)
        assertNull(DictatedSpan.baseline("ask Namratha", "ask Namratha and more", "", true, true))
    }
}
