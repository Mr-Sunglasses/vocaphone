package com.vocahq.vocaphone.accessibility

import android.view.accessibility.AccessibilityEvent
import com.vocahq.vocaphone.accessibility.BubbleRefreshPolicy.Refresh
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class BubbleRefreshPolicyTest {

    @Test
    fun `keystroke events wait for typing to pause`() {
        assertEquals(
            Refresh.AFTER_TYPING,
            BubbleRefreshPolicy.forEvent(AccessibilityEvent.TYPE_VIEW_TEXT_CHANGED),
        )
        assertEquals(
            Refresh.AFTER_TYPING,
            BubbleRefreshPolicy.forEvent(AccessibilityEvent.TYPE_VIEW_TEXT_SELECTION_CHANGED),
        )
    }

    @Test
    fun `events that can change the field still refresh at once`() {
        listOf(
            AccessibilityEvent.TYPE_VIEW_FOCUSED,
            AccessibilityEvent.TYPE_VIEW_CLICKED,
            AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED,
            AccessibilityEvent.TYPE_WINDOWS_CHANGED,
        ).forEach { type ->
            assertEquals(type.toString(), Refresh.IMMEDIATE, BubbleRefreshPolicy.forEvent(type))
        }
    }

    @Test
    fun `the pause is short enough to feel immediate`() {
        // Long enough to cover the gap between keystrokes, short enough that a
        // field announced only by a text change still gets its bubble promptly.
        assertTrue(BubbleRefreshPolicy.TYPING_QUIET_MILLIS in 100L..250L)
    }
}
