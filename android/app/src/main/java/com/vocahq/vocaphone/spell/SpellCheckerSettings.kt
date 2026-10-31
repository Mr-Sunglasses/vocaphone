package com.vocahq.vocaphone.spell

import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.provider.Settings
import android.view.textservice.TextServicesManager

/** The system's spell checker setting, which is where VocaPhone is chosen. */
object SpellCheckerSettings {
    /** Whether VocaPhone is the spell checker every app is using right now. */
    fun isActive(context: Context): Boolean {
        val manager = context.getSystemService(TextServicesManager::class.java) ?: return false
        return runCatching {
            manager.isSpellCheckerEnabled && manager.currentSpellCheckerInfo?.packageName == context.packageName
        }.getOrDefault(false)
    }

    /**
     * Opens the spell checker page. Android has no public intent for it, so
     * this tries the page itself, then the language and input settings it
     * lives in, then Settings.
     */
    fun open(context: Context) {
        val attempts = listOf(
            Intent().setComponent(ComponentName("com.android.settings", "com.android.settings.Settings\$SpellCheckersSettingsActivity")),
            Intent(Settings.ACTION_INPUT_METHOD_SETTINGS),
            Intent(Settings.ACTION_SETTINGS),
        )
        for (intent in attempts) {
            try {
                context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                return
            } catch (_: ActivityNotFoundException) {
            } catch (_: SecurityException) {
            }
        }
    }
}
