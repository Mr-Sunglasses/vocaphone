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
