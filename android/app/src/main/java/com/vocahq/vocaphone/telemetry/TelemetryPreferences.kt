package com.vocahq.vocaphone.telemetry

import com.vocahq.vocaphone.settings.SettingsRepository

/**
 * The only three things telemetry is allowed to know about the user's settings.
 *
 * [Telemetry] could just as easily hold a `SettingsRepository`, and this
 * interface exists to make sure it cannot. Through that repository it would be
 * one field access away from the gateway URL, the custom vocabulary, and the
 * clipboard history — none of which it has any business reading, and all of
 * which someone could plausibly add to an event in a hurry. A three-method
 * contract makes the boundary reviewable at a glance instead of resting on
 * nobody ever taking the shortcut.
 *
 * It also makes the whole package unit-testable without a `Context`.
 */
internal interface TelemetryPreferences {
    suspend fun isEnabled(): Boolean
    suspend fun setEnabled(enabled: Boolean)

    /** True only the first time [key] is claimed on this install. */
    suspend fun claimMilestone(key: String): Boolean
}

internal class SettingsTelemetryPreferences(
    private val settings: SettingsRepository,
) : TelemetryPreferences {
    override suspend fun isEnabled(): Boolean = settings.current().telemetryEnabled

    override suspend fun setEnabled(enabled: Boolean) = settings.setTelemetryEnabled(enabled)

    override suspend fun claimMilestone(key: String): Boolean =
        settings.claimTelemetryMilestone(key)
}
