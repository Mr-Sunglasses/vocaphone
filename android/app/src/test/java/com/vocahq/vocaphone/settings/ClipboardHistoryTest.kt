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

    @Test
    fun imageItemsRoundTripAndKeepTextHistoryWorking() {
        val image = ClipboardHistory.encodeImage("image/png", "clipboard/1.png")
        assertEquals("image/png" to "clipboard/1.png", ClipboardHistory.parseImage(image))
        assertEquals("Image", ClipboardHistory.preview(image))
        assertEquals("hello", ClipboardHistory.preview("hello"))
        val mixed = ClipboardHistory.remember(listOf("hello"), image)
        assertEquals(listOf(image, "hello"), mixed)
        assertEquals(setOf("clipboard/1.png"), ClipboardHistory.imagePaths(mixed))
        assertEquals(mixed, ClipboardHistory.decode(ClipboardHistory.encode(mixed)))
    }
}
