package com.vocahq.vocaphone.core

import org.junit.Assert.assertEquals
import org.junit.Test

class TranscriptStylerTest {
    @Test
    fun `local styles match the gateway examples`() {
        val source = "hello there. how are you"
        assertEquals(source, TranscriptStyler.apply(source, WritingStyle.RAW))
        assertEquals("hello there. how are you.", TranscriptStyler.apply(source, WritingStyle.CLEAN))
        assertEquals("Hello there. How are you.", TranscriptStyler.apply(source, WritingStyle.FORMAL))
        assertEquals("Hello there. How are you", TranscriptStyler.apply(source, WritingStyle.CASUAL))
        assertEquals("hello there, how are you", TranscriptStyler.apply(source, WritingStyle.VERY_CASUAL))
        assertEquals("Hello there! How are you!", TranscriptStyler.apply(source, WritingStyle.EXCITED))
    }

    @Test
    fun `local styling keeps protected spans intact`() {
        val source = "Email John@Example.com at 3:30."
        assertEquals(
            "email John@Example.com at 3:30",
            TranscriptStyler.apply(source, WritingStyle.VERY_CASUAL),
        )
    }

    @Test
    fun `local styling uses language punctuation`() {
        assertEquals(
            "家に帰りました！ジョンが電話してきました！",
            TranscriptStyler.apply(
                "家に帰りました。ジョンが電話してきました。",
                WritingStyle.EXCITED,
                "ja",
            ),
        )
        assertEquals(
            "मैं कल बाजार जाऊंगा।",
            TranscriptStyler.apply("मैं कल बाजार जाऊंगा", WritingStyle.FORMAL, "hi"),
        )
    }
}
