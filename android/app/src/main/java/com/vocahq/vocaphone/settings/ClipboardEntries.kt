package com.vocahq.vocaphone.settings

/** One clipboard-history item: the text (or image token), when it was copied, and whether it is pinned. */
data class ClipEntry(
    val text: String,
    val copiedAtMillis: Long,
    val pinned: Boolean = false,
)

/**
 * How long an unpinned clip stays in the keyboard's history. Pinned clips
 * stay until they are unpinned or deleted, whatever this says, and survive
 * Clear. Gboard keeps unpinned clips for an hour; that is the default here.
 */
enum class ClipboardRetention(val storedValue: String, val millis: Long) {
    ONE_HOUR("1h", 60L * 60 * 1000),
    ONE_DAY("1d", 24L * 60 * 60 * 1000),
    ONE_WEEK("1w", 7L * 24 * 60 * 60 * 1000),
    ;

    val displayName: String
        get() = when (this) {
            ONE_HOUR -> "1 hour"
            ONE_DAY -> "1 day"
            ONE_WEEK -> "1 week"
        }

    companion object {
        val DEFAULT = ONE_HOUR

        fun fromStored(value: String?): ClipboardRetention =
            entries.firstOrNull { it.storedValue == value } ?: DEFAULT
    }
}

/**
 * The clipboard history as stored: newest first, one [ClipEntry] per distinct
 * text. Pure, so the retention and pin rules are tested without DataStore.
 *
 * Stored as entries joined by [ClipboardHistory.SEPARATOR], each
 * `millis<GS>pinned<GS>text` with GS (U+001D) splitting only the first two
 * fields, so image tokens (which use U+001F) and ordinary text pass through.
 * The older format was bare texts under another key; [migrate] reads it once.
 */
object ClipboardEntries {
    /** Unpinned clips kept, at most. */
    const val MAX_RECENT = ClipboardHistory.MAX_ITEMS

    /** Pinned clips kept, at most: pins are deliberate, but the store is one preference. */
    const val MAX_PINNED = 50

    private const val FIELD = "\u001d"

    fun encode(entries: List<ClipEntry>): String = entries.joinToString(ClipboardHistory.SEPARATOR) {
        "${it.copiedAtMillis}$FIELD${if (it.pinned) "1" else "0"}$FIELD${it.text}"
    }

    fun decode(stored: String?): List<ClipEntry> =
        stored?.split(ClipboardHistory.SEPARATOR)?.mapNotNull { part ->
            val fields = part.split(FIELD, limit = 3)
            if (fields.size != 3 || fields[2].isEmpty()) return@mapNotNull null
            val millis = fields[0].toLongOrNull() ?: return@mapNotNull null
            ClipEntry(text = fields[2], copiedAtMillis = millis, pinned = fields[1] == "1")
        }.orEmpty()

    /**
     * The legacy list of texts, dated [nowMillis]: their copy time was never
     * kept, so retention counts from the upgrade rather than deleting a
     * history on the first launch after it.
     */
    fun migrate(legacy: List<String>, nowMillis: Long): List<ClipEntry> =
        legacy.distinct().map { ClipEntry(it, nowMillis) }

    /**
     * [incoming] at the top. Copying a pinned clip again keeps it pinned.
     * Expired clips go, and the recent part is capped at [MAX_RECENT].
     */
    fun remember(
        existing: List<ClipEntry>,
        incoming: String,
        nowMillis: Long,
        retention: ClipboardRetention,
    ): List<ClipEntry> {
        val text = if (ClipboardHistory.isImage(incoming)) incoming.take(ClipboardHistory.MAX_ITEM_CHARS)
        else incoming.trim().take(ClipboardHistory.MAX_ITEM_CHARS)
        if (text.isEmpty()) return prune(existing, nowMillis, retention)
        val wasPinned = existing.any { it.text == text && it.pinned }
        val next = listOf(ClipEntry(text, nowMillis, wasPinned)) + existing.filter { it.text != text }
        return prune(next, nowMillis, retention)
    }

    /**
     * Pinned clips always stay; an unpinned one stays for [retention] after
     * it was copied. A clip dated in the future (the clock was set back) is
     * kept rather than guessed about. The recent part is capped at
     * [MAX_RECENT] and the pinned part at [MAX_PINNED], newest kept.
     */
    fun prune(entries: List<ClipEntry>, nowMillis: Long, retention: ClipboardRetention): List<ClipEntry> {
        var recent = 0
        var pinned = 0
        return entries.filter { entry ->
            if (entry.pinned) {
                pinned++ < MAX_PINNED
            } else {
                val age = nowMillis - entry.copiedAtMillis
                (age < retention.millis) && recent++ < MAX_RECENT
            }
        }
    }

    fun setPinned(entries: List<ClipEntry>, text: String, pinned: Boolean): List<ClipEntry> =
        entries.map { if (it.text == text) it.copy(pinned = pinned) else it }

    fun remove(entries: List<ClipEntry>, text: String): List<ClipEntry> = entries.filter { it.text != text }

    /** Clear keeps the pins: they are the clips someone asked to keep. */
    fun clear(entries: List<ClipEntry>): List<ClipEntry> = entries.filter { it.pinned }

    /** The panel's order: pinned first, then the rest, each newest first. */
    fun forDisplay(entries: List<ClipEntry>): List<ClipEntry> =
        entries.filter { it.pinned } + entries.filter { !it.pinned }

    fun imagePaths(entries: List<ClipEntry>): Set<String> =
        ClipboardHistory.imagePaths(entries.map { it.text })
}
