package com.vocahq.vocaphone.ui

import android.content.Context
import android.view.inputmethod.InputMethodManager

/**
 * The language tags of every enabled system keyboard, in the order the person
 * enabled them.
 *
 * App-only, deliberately. `local/` is compiled into the keyboard extension,
 * and the keyboard has no business asking the input method service about
 * itself — so the query sits here and the result is handed to
 * [com.vocahq.vocaphone.local.DeviceProfile] as plain strings.
 *
 * Not every enabled subtype is a language. Auxiliary subtypes and voice-mode
 * subtypes are Gboard's emoji and voice-typing entries, and VocaPhone's own
 * keyboard is in this list too; they are skipped here and again, by tag, in
 * the catalog's normalisation, so neither layer depends on the other having
 * caught them.
 *
 * Best-effort: some OEM builds throw from the input method service early in
 * boot, and a missing list must not cost the recommendation.
 */
object KeyboardInputLanguages {
    fun enabled(context: Context): List<String> = runCatching {
        val imm = context.applicationContext.getSystemService(InputMethodManager::class.java)
            ?: return@runCatching emptyList()
        val tags = LinkedHashSet<String>()
        for (method in imm.enabledInputMethodList) {
            for (subtype in imm.getEnabledInputMethodSubtypeList(method, true)) {
                if (subtype.isAuxiliary) continue
                if (subtype.mode == "voice") continue
                @Suppress("DEPRECATION")
                val tag = subtype.languageTag.ifBlank { subtype.locale }
                if (tag.isNotBlank()) tags.add(tag)
            }
        }
        tags.toList()
    }.getOrDefault(emptyList())
}
