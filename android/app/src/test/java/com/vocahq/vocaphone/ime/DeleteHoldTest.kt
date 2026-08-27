package com.vocahq.vocaphone.ime

import org.junit.Assert.assertEquals
import org.junit.Test

class DeleteHoldTest {

    @Test
    fun `hold starts on characters then words then the line`() {
        assertEquals(DeleteHold.Stage.CHAR, DeleteHold.stage(0))
        assertEquals(DeleteHold.Stage.CHAR, DeleteHold.stage(DeleteHold.WORD_AFTER_MS - 1))
        assertEquals(DeleteHold.Stage.WORD, DeleteHold.stage(DeleteHold.WORD_AFTER_MS))
        assertEquals(DeleteHold.Stage.WORD, DeleteHold.stage(DeleteHold.LINE_AFTER_MS - 1))
        assertEquals(DeleteHold.Stage.LINE, DeleteHold.stage(DeleteHold.LINE_AFTER_MS))
        assertEquals(DeleteHold.CHAR_INTERVAL_MS, DeleteHold.interval(0))
        assertEquals(DeleteHold.WORD_INTERVAL_MS, DeleteHold.interval(DeleteHold.WORD_AFTER_MS))
        assertEquals(DeleteHold.LINE_INTERVAL_MS, DeleteHold.interval(DeleteHold.LINE_AFTER_MS))
    }

    @Test
    fun `first backspace after a swipe removes the whole word`() {
        assertEquals(
            KeyboardCommand.DeleteSurrounding(6, 0),
            DeleteHold.command(
                heldMs = 0,
                swipeUndo = true,
                before = "hello ",
                after = "",
            ),
        )
    }

    @Test
    fun `a hold session ramps from characters to words on a local buffer`() {
        // Editor text is not read on every repeat (50 ms coalesce). The hold
        // has to shrink its own copy or the 1 s tick still looks like a char.
        var before = "one two three"
        fun tick(heldMs: Long): KeyboardCommand {
            val command = DeleteHold.command(
                heldMs = heldMs,
                swipeUndo = false,
                before = before,
                after = "",
            )
            before = DeleteHold.remainingBefore(before, command)
            return command
        }
        assertEquals(KeyboardCommand.DeleteBackward, tick(0))
        assertEquals("one two thre", before)
        assertEquals(KeyboardCommand.DeleteBackward, tick(DeleteHold.WORD_AFTER_MS - 1))
        assertEquals("one two thr", before)
        val word = tick(DeleteHold.WORD_AFTER_MS)
        assertEquals(KeyboardCommand.DeleteSurrounding(3, 0), word)
        assertEquals("one two ", before)
        val nextWord = tick(DeleteHold.WORD_AFTER_MS + DeleteHold.WORD_INTERVAL_MS)
        assertEquals(KeyboardCommand.DeleteSurrounding(4, 0), nextWord)
        assertEquals("one ", before)
    }

    @Test
    fun `hold later deletes a word then a line`() {
        assertEquals(
            KeyboardCommand.DeleteBackward,
            DeleteHold.command(0, swipeUndo = false, before = "hello world", after = ""),
        )
        assertEquals(
            KeyboardCommand.DeleteSurrounding(5, 0),
            DeleteHold.command(
                heldMs = DeleteHold.WORD_AFTER_MS,
                swipeUndo = false,
                before = "hello world",
                after = "",
            ),
        )
        assertEquals(
            KeyboardCommand.DeleteSurrounding(2, 0),
            DeleteHold.command(
                heldMs = DeleteHold.LINE_AFTER_MS,
                swipeUndo = false,
                before = "ab\ncd",
                after = "",
            ),
        )
    }
}
