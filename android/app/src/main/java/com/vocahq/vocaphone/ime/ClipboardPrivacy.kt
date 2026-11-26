package com.vocahq.vocaphone.ime

/**
 * Which clips the keyboard must neither keep in its history nor offer on the
 * chip, decided from facts about the clip rather than from the field the
 * keyboard happens to be in when it reads it.
 *
 * Checking only the current field missed the common case: a password copied
 * in a password manager (keyboard hidden, or shown in its search box) was
 * recorded the moment the user tapped into an ordinary field to paste it.
 *
 * Two signals:
 *
 * - The clip says so. Android 13 added `ClipDescription.EXTRA_IS_SENSITIVE`
 *   (`"android.content.extra.IS_SENSITIVE"`) to the description's extras.
 *   Password managers set the same key on older releases, before the
 *   constant existed, and a few spell the value as a string; both count.
 * - The clip changed while the keyboard was in a password or other sensitive
 *   field. That copy came from the secret, so the clip is remembered (by its
 *   timestamp and a hash, never its text) and stays out of history after the
 *   user moves to a field where it would otherwise be recorded.
 */
internal object ClipboardPrivacy {
    /** `ClipDescription.EXTRA_IS_SENSITIVE`, which is also the key apps set before API 33. */
    const val EXTRA_IS_SENSITIVE = "android.content.extra.IS_SENSITIVE"

    /**
     * Whether the description's extras mark the clip sensitive. [value] is
     * whatever the extras hold under [EXTRA_IS_SENSITIVE]: a Boolean from the
     * platform and well-behaved apps, a String from some older ones.
     */
    fun markedSensitive(value: Any?): Boolean = when (value) {
        is Boolean -> value
        is String -> value.equals("true", ignoreCase = true)
        is Number -> value.toInt() != 0
        else -> false
    }
}

/**
 * Clips first seen while a sensitive field had the keyboard, for this
 * process's life. Holds fingerprints only — the clip's own timestamp and the
 * hash of its text — so the secret itself is never kept a second time.
 */
internal class SensitiveClips(private val capacity: Int = 16) {
    data class Fingerprint(val timestampMillis: Long, val textHash: Int)

    private val seen = ArrayDeque<Fingerprint>()

    /** The clip changed while a sensitive field was focused: never record it. */
    fun mark(fingerprint: Fingerprint) {
        if (fingerprint in seen) return
        seen.addLast(fingerprint)
        while (seen.size > capacity) seen.removeFirst()
    }

    fun contains(fingerprint: Fingerprint): Boolean = fingerprint in seen

    companion object {
        fun of(timestampMillis: Long, text: String?): Fingerprint =
            Fingerprint(timestampMillis, text?.hashCode() ?: 0)
    }
}

/** Swipe-to-delete on a clipboard-history tile. */
internal object ClipboardSwipe {
    /** Past this share of the tile's width, letting go deletes it. */
    const val DELETE_FRACTION = 0.35f

    fun deletes(dragPx: Float, widthPx: Float): Boolean =
        widthPx > 0f && kotlin.math.abs(dragPx) >= widthPx * DELETE_FRACTION
}
