package com.vocahq.vocaphone.settings

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ClipboardEntriesTest {
    private val hour = ClipboardRetention.ONE_HOUR.millis

    @Test
    fun roundTripsTextImagesAndPins() {
        val image = ClipboardHistory.encodeImage("image/png", "clipboard/1.png")
        val entries = listOf(
            ClipEntry("line one\nline two", 10L, pinned = true),
            ClipEntry(image, 20L),
            ClipEntry("tab\tand \u001d group sep", 30L),
        )
        assertEquals(entries, ClipboardEntries.decode(ClipboardEntries.encode(entries)))
    }

    @Test
    fun unpinnedClipsExpireAfterTheRetention() {
        val entries = listOf(
            ClipEntry("fresh", 9 * hour - 1),
            ClipEntry("old", 8 * hour),
            ClipEntry("pinned old", 1L, pinned = true),
        )
        val kept = ClipboardEntries.prune(entries, nowMillis = 9 * hour, retention = ClipboardRetention.ONE_HOUR)
        assertEquals(listOf("fresh", "pinned old"), kept.map { it.text })
    }

    @Test
    fun longerRetentionKeepsMore() {
        val entries = listOf(ClipEntry("a day old", 0L))
        val now = 23 * hour
        assertTrue(ClipboardEntries.prune(entries, now, ClipboardRetention.ONE_HOUR).isEmpty())
        assertEquals(1, ClipboardEntries.prune(entries, now, ClipboardRetention.ONE_DAY).size)
        assertEquals(1, ClipboardEntries.prune(entries, 6 * 24 * hour, ClipboardRetention.ONE_WEEK).size)
    }

    @Test
    fun aClipFromTheFutureIsKept() {
        val entries = listOf(ClipEntry("clock went back", 10 * hour))
        assertEquals(1, ClipboardEntries.prune(entries, hour, ClipboardRetention.ONE_HOUR).size)
    }

    @Test
    fun clearKeepsPins() {
        val entries = listOf(ClipEntry("a", 1L), ClipEntry("b", 2L, pinned = true))
        assertEquals(listOf("b"), ClipboardEntries.clear(entries).map { it.text })
    }

    @Test
    fun copyingAPinnedClipAgainKeepsItPinnedAndMovesItUp() {
        val entries = listOf(ClipEntry("x", 1L), ClipEntry("keep", 2L, pinned = true))
        val next = ClipboardEntries.remember(entries, " keep ", nowMillis = 3L, retention = ClipboardRetention.ONE_DAY)
        assertEquals(listOf("keep", "x"), next.map { it.text })
        assertTrue(next.first().pinned)
        assertEquals(3L, next.first().copiedAtMillis)
    }

    @Test
    fun pinUnpinAndRemove() {
        val entries = listOf(ClipEntry("a", 1L), ClipEntry("b", 2L))
        val pinned = ClipboardEntries.setPinned(entries, "b", true)
        assertEquals(listOf("b", "a"), ClipboardEntries.forDisplay(pinned).map { it.text })
        val unpinned = ClipboardEntries.setPinned(pinned, "b", false)
        assertEquals(listOf("a", "b"), ClipboardEntries.forDisplay(unpinned).map { it.text })
        assertEquals(listOf("b"), ClipboardEntries.remove(entries, "a").map { it.text })
    }

    @Test
    fun recentClipsAreCappedButPinsDoNotCountAgainstIt() {
        var entries = listOf(ClipEntry("pin", 0L, pinned = true))
        repeat(ClipboardEntries.MAX_RECENT + 5) { index ->
            entries = ClipboardEntries.remember(entries, "clip $index", index.toLong() + 1, ClipboardRetention.ONE_WEEK)
        }
        assertEquals(ClipboardEntries.MAX_RECENT, entries.count { !it.pinned })
        assertTrue(entries.any { it.pinned && it.text == "pin" })
    }

    @Test
    fun theOldListIsDatedAtTheUpgrade() {
        val migrated = ClipboardEntries.migrate(listOf("one", "two", "one"), nowMillis = 42L)
        assertEquals(listOf(ClipEntry("one", 42L), ClipEntry("two", 42L)), migrated)
    }

    @Test
    fun retentionReadsBackAndDefaultsToAnHour() {
        assertEquals(ClipboardRetention.ONE_WEEK, ClipboardRetention.fromStored("1w"))
        assertEquals(ClipboardRetention.ONE_HOUR, ClipboardRetention.fromStored(null))
        assertEquals(ClipboardRetention.ONE_HOUR, ClipboardRetention.fromStored("forever"))
    }
}
