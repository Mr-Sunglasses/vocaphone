package com.vocahq.vocaphone.core

/**
 * From Android 13, an app installed from outside an app store cannot be granted
 * accessibility access: the switch is visible in Settings but greyed out and
 * marked "Restricted setting". No API requests the exemption and no manifest
 * flag opts out of it — only the user can lift it, from the overflow menu in
 * App info. An app whose whole purpose runs through an accessibility service
 * therefore has to explain that, or a sideloaded user is simply stuck.
 *
 * Deciding whether to explain it is a one-sided bet, and this policy takes the
 * safe side: showing the guidance when it was not needed costs a paragraph the
 * user skips, while hiding it when it was needed leaves them at a dead end with
 * nothing on screen to suggest a way forward.
 */
object RestrictedSettingsPolicy {

    /**
     * Only the Play Store is treated as exempt. Other stores may well be, but
     * the exemption is not documented per-installer, and guessing wrong in that
     * direction is the expensive mistake.
     */
    private val STORE_INSTALLERS = setOf("com.android.vending")

    /** The first Android release that restricts sideloaded accessibility access. */
    const val FIRST_RESTRICTED_SDK = 33

    /**
     * [installerPackage] is the installing package reported by `PackageManager`,
     * which is null for an install that recorded no originator at all — the
     * plain sideload case, and the one that is always restricted.
     */
    fun guidanceNeeded(
        sdkInt: Int,
        installerPackage: String?,
        accessibilityGranted: Boolean,
    ): Boolean = when {
        // Nothing to explain once it is on: the user got past it.
        accessibilityGranted -> false
        sdkInt < FIRST_RESTRICTED_SDK -> false
        else -> installerPackage !in STORE_INSTALLERS
    }
}
