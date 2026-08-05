package io.github.mrsunglasses.localflow.core

import io.github.mrsunglasses.localflow.core.OverlayNoticePolicy.Action
import org.junit.Assert.assertEquals
import org.junit.Test

class OverlayNoticePolicyTest {

    @Test
    fun `tells the user the first time the bubble is blocked`() {
        assertEquals(
            Action.POST,
            OverlayNoticePolicy.decide(overlayGranted = false, alreadyPosted = false),
        )
    }

    @Test
    fun `does not re-post on every keystroke while it stays broken`() {
        // refreshBubble runs on every accessibility event, so the un-posted
        // state is the only thing standing between the user and a flood.
        assertEquals(
            Action.NOTHING,
            OverlayNoticePolicy.decide(overlayGranted = false, alreadyPosted = true),
        )
    }

    @Test
    fun `clears the notice once the permission is granted again`() {
        assertEquals(
            Action.CANCEL,
            OverlayNoticePolicy.decide(overlayGranted = true, alreadyPosted = true),
        )
    }

    @Test
    fun `stays quiet when the bubble works and nothing was ever posted`() {
        assertEquals(
            Action.NOTHING,
            OverlayNoticePolicy.decide(overlayGranted = true, alreadyPosted = false),
        )
    }

    @Test
    fun `re-arms after a repair so a later regression is reported again`() {
        var posted = false
        fun step(granted: Boolean): Action =
            OverlayNoticePolicy.decide(granted, posted).also { action ->
                when (action) {
                    Action.POST -> posted = true
                    Action.CANCEL -> posted = false
                    Action.NOTHING -> Unit
                }
            }

        assertEquals(Action.POST, step(granted = false))
        assertEquals(Action.NOTHING, step(granted = false))
        assertEquals(Action.CANCEL, step(granted = true))
        // Permission revoked a second time: the user hears about it again.
        assertEquals(Action.POST, step(granted = false))
    }
}
