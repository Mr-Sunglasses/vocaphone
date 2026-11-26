package com.vocahq.vocaphone.ime

import android.view.KeyEvent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TextEditingTest {
    @Test
    fun clipboardAndHistoryActionsUseTheFrameworkMenuIds() {
        assertEquals(android.R.id.selectAll, TextEditing.contextMenuId(TextEditAction.SELECT_ALL))
        assertEquals(android.R.id.cut, TextEditing.contextMenuId(TextEditAction.CUT))
        assertEquals(android.R.id.copy, TextEditing.contextMenuId(TextEditAction.COPY))
        assertEquals(android.R.id.paste, TextEditing.contextMenuId(TextEditAction.PASTE))
        assertEquals(android.R.id.undo, TextEditing.contextMenuId(TextEditAction.UNDO))
        assertEquals(android.R.id.redo, TextEditing.contextMenuId(TextEditAction.REDO))
        assertNull(TextEditing.contextMenuId(TextEditAction.LEFT))
    }

    @Test
    fun anEditorThatDeclinesGetsTheShortcut() {
        val undo = TextEditing.shortcut(TextEditAction.UNDO)!!
        assertEquals(KeyEvent.KEYCODE_Z, undo.keyCode)
        assertTrue(undo.metaState and KeyEvent.META_CTRL_ON != 0)
        assertTrue(undo.metaState and KeyEvent.META_SHIFT_ON == 0)
        val redo = TextEditing.shortcut(TextEditAction.REDO)!!
        assertEquals(KeyEvent.KEYCODE_Z, redo.keyCode)
        assertTrue(redo.metaState and KeyEvent.META_SHIFT_ON != 0)
        assertEquals(KeyEvent.KEYCODE_V, TextEditing.shortcut(TextEditAction.PASTE)!!.keyCode)
        assertNull(TextEditing.shortcut(TextEditAction.HOME))
    }

    @Test
    fun selectingAddsShiftToMovement() {
        val plain = TextEditing.movement(TextEditAction.UP, selecting = false)!!
        assertEquals(KeyEvent.KEYCODE_DPAD_UP, plain.keyCode)
        assertEquals(0, plain.metaState)
        val extending = TextEditing.movement(TextEditAction.END, selecting = true)!!
        assertEquals(KeyEvent.KEYCODE_MOVE_END, extending.keyCode)
        assertTrue(extending.metaState and KeyEvent.META_SHIFT_ON != 0)
        assertNull(TextEditing.movement(TextEditAction.COPY, selecting = true))
    }

    @Test
    fun selectExtendsFromTheAnchorOneCharacterAtATime() {
        assertEquals(5 to 6, TextEditing.extend(anchor = 5, focus = 5, action = TextEditAction.RIGHT))
        assertEquals(5 to 7, TextEditing.extend(anchor = 5, focus = 6, action = TextEditAction.RIGHT))
        // Back past the anchor selects to its left.
        assertEquals(5 to 4, TextEditing.extend(anchor = 5, focus = 5, action = TextEditAction.LEFT))
        assertEquals(0 to 0, TextEditing.extend(anchor = 0, focus = 0, action = TextEditAction.LEFT))
        assertNull(TextEditing.extend(anchor = 0, focus = 0, action = TextEditAction.UP))
    }

    @Test
    fun onlyArrowsRepeat() {
        assertTrue(TextEditing.repeats(TextEditAction.LEFT))
        assertTrue(TextEditing.repeats(TextEditAction.DOWN))
        assertFalse(TextEditing.repeats(TextEditAction.PASTE))
        assertFalse(TextEditing.repeats(TextEditAction.UNDO))
    }
}
