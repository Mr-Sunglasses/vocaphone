package com.vocahq.vocaphone

/**
 * Every notification id the app posts, in one place.
 *
 * An id is the key Android replaces a notification by, across channels. The
 * model download and the blocked-bubble notice were both 4102, so whichever
 * posted second replaced the other: a bubble notice during a download took
 * over the download's foreground notification, and the download's next
 * progress tick wiped the notice. A new id goes here, not in a companion.
 */
internal object NotificationIds {
    const val DICTATION = 4101
    const val MODEL_DOWNLOAD = 4102
    const val OVERLAY_PERMISSION = 4103

    val all: List<Int> = listOf(DICTATION, MODEL_DOWNLOAD, OVERLAY_PERMISSION)
}
