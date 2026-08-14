package com.vocahq.vocaphone.settings

import org.junit.Assert.assertEquals
import org.junit.Test

class ClipboardHistoryTest {

    @Test
    fun newestClipMovesToTheFrontAndDropsDuplicates() {
        val first = ClipboardHistory.remember(emptyList(), "one")
        val second = ClipboardHistory.remember(first, "two")
        val again = ClipboardHistory.remember(second, "one")
        assertEquals(listOf("one", "two"), again)
    }

    @Test
    fun encodeRoundTrips() {
        val items = listOf("hello", "line\nbreak")
        assertEquals(items, ClipboardHistory.decode(ClipboardHistory.encode(items)))
    }
}
