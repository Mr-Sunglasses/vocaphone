package com.vocahq.vocaphone.ime

import android.view.KeyEvent

/** One button of the text-editing panel (Gboard's "Text editing"). */
internal enum class TextEditAction {
    LEFT,
    RIGHT,
    UP,
    DOWN,
    HOME,
    END,
    SELECT_ALL,
    CUT,
    COPY,
    PASTE,
    UNDO,
    REDO,
}

/**
 * How each panel action reaches the editor, kept apart from the service so it
 * can be tested.
 *
 * Clipboard and history actions go through
 * `InputConnection.performContextMenuAction` with the framework ids TextView
 * understands (`android.R.id.selectAll/cut/copy/paste/undo/redo`). An editor
 * that does not (it returns false; Chrome and some Compose fields) gets the
 * desktop shortcut instead, Ctrl+A/X/C/V/Z and Ctrl+Shift+Z, which those
 * editors do handle.
 *
 * Movement is arrow and Home/End key events. With Select on, left and right
 * extend the selection by setting it from the anchor (exact in every editor
 * that reports its selection); up, down, Home and End carry Shift, which
 * TextView, Chrome and Compose all read as "extend".
 */
internal object TextEditing {
    data class Key(val keyCode: Int, val metaState: Int = 0)

    fun contextMenuId(action: TextEditAction): Int? = when (action) {
        TextEditAction.SELECT_ALL -> android.R.id.selectAll
        TextEditAction.CUT -> android.R.id.cut
        TextEditAction.COPY -> android.R.id.copy
        TextEditAction.PASTE -> android.R.id.paste
        TextEditAction.UNDO -> android.R.id.undo
        TextEditAction.REDO -> android.R.id.redo
        else -> null
    }

    /** The keyboard shortcut for a context-menu action the editor turned down. */
    fun shortcut(action: TextEditAction): Key? {
        val ctrl = KeyEvent.META_CTRL_ON or KeyEvent.META_CTRL_LEFT_ON
        val shift = KeyEvent.META_SHIFT_ON or KeyEvent.META_SHIFT_LEFT_ON
        return when (action) {
            TextEditAction.SELECT_ALL -> Key(KeyEvent.KEYCODE_A, ctrl)
            TextEditAction.CUT -> Key(KeyEvent.KEYCODE_X, ctrl)
            TextEditAction.COPY -> Key(KeyEvent.KEYCODE_C, ctrl)
            TextEditAction.PASTE -> Key(KeyEvent.KEYCODE_V, ctrl)
            TextEditAction.UNDO -> Key(KeyEvent.KEYCODE_Z, ctrl)
            TextEditAction.REDO -> Key(KeyEvent.KEYCODE_Z, ctrl or shift)
            else -> null
        }
    }

    /** The key event for a movement action, extending the selection when [selecting]. */
    fun movement(action: TextEditAction, selecting: Boolean): Key? {
        val code = when (action) {
            TextEditAction.LEFT -> KeyEvent.KEYCODE_DPAD_LEFT
            TextEditAction.RIGHT -> KeyEvent.KEYCODE_DPAD_RIGHT
            TextEditAction.UP -> KeyEvent.KEYCODE_DPAD_UP
            TextEditAction.DOWN -> KeyEvent.KEYCODE_DPAD_DOWN
            TextEditAction.HOME -> KeyEvent.KEYCODE_MOVE_HOME
            TextEditAction.END -> KeyEvent.KEYCODE_MOVE_END
            else -> return null
        }
        val meta = if (selecting) KeyEvent.META_SHIFT_ON or KeyEvent.META_SHIFT_LEFT_ON else 0
        return Key(code, meta)
    }

    /**
     * Left/right with Select on, as a selection range: the anchor stays where
     * selecting started and the moving end goes one character — one
     * *user-perceived* character, so an emoji or an accented letter built
     * from several code units is never cut in half. [window] is the editor's
     * text starting at absolute offset [windowStart]; it must contain the
     * moving end, or this returns null and the caller lets the editor move.
     * Returns (start, end) for `setSelection`, which takes either order.
     */
    fun extend(
        anchor: Int,
        focus: Int,
        action: TextEditAction,
        window: CharSequence?,
        windowStart: Int,
    ): Pair<Int, Int>? {
        if (action != TextEditAction.LEFT && action != TextEditAction.RIGHT) return null
        if (action == TextEditAction.LEFT && focus <= 0) return anchor to 0
        val text = window?.toString() ?: return null
        val local = focus - windowStart
        if (local < 0 || local > text.length) return null
        val breaks = java.text.BreakIterator.getCharacterInstance().apply { setText(text) }
        val next = if (action == TextEditAction.LEFT) {
            if (local == 0) return null
            breaks.preceding(local)
        } else {
            if (local == text.length) return null
            breaks.following(local)
        }
        if (next == java.text.BreakIterator.DONE) return null
        return anchor to windowStart + next
    }

    /** Arrows and Home/End repeat while held; the rest fire once. */
    fun repeats(action: TextEditAction): Boolean = when (action) {
        TextEditAction.LEFT, TextEditAction.RIGHT, TextEditAction.UP, TextEditAction.DOWN -> true
        else -> false
    }
}
