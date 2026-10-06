package com.vocahq.vocaphone.core

/**
 * Whether to tell the user that the bubble was blocked by a missing
 * "Display over other apps" permission.
 *
 * Losing that permission is silent and total: every upstream check can pass —
 * the field is eligible, [BubblePolicy] says SHOW — and the overlay simply
 * never reaches the screen. A fresh install is the common way in, since the
 * permission is not carried across an uninstall. The user is typing in someone
 * else's app when it happens, so the in-app checklist cannot reach them; a
 * notification is the only surface that can.
 *
 * Consulted only at the moment the bubble was supposed to appear, so a user who
 * has switched the bubble off, snoozed it, or simply is not typing never hears
 * about it. One notification per blocked episode: re-posting on the next
 * keystroke after the user has swiped it away is nagging, and swiping it away
 * is an explicit "I have seen this". The episode ends when the permission comes
 * back, which re-arms the notice against a later regression.
 */
object OverlayNoticePolicy {

    enum class Action {
        /** Tell the user the bubble is blocked. */
        POST,

        /** The permission is back; clear a notice that is no longer true. */
        CANCEL,

        NOTHING,
    }

    fun decide(overlayGranted: Boolean, alreadyPosted: Boolean): Action = when {
        overlayGranted && alreadyPosted -> Action.CANCEL
        overlayGranted -> Action.NOTHING
        // Already told them, and they have not fixed it yet.
        alreadyPosted -> Action.NOTHING
        else -> Action.POST
    }
}
