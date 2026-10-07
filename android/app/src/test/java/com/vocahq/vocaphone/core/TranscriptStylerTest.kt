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
    fun `clean and formal flatten mid-sentence title case from the model`() {
        val titled = "Hello There. The Keyboard Is Ready"
        assertEquals(
            "hello there. the keyboard is ready.",
            TranscriptStyler.apply(titled, WritingStyle.CLEAN),
        )
        assertEquals(
            "Hello there. The keyboard is ready.",
            TranscriptStyler.apply(titled, WritingStyle.FORMAL),
        )
        assertEquals(
            "Hello there. The keyboard is ready",
            TranscriptStyler.apply(titled, WritingStyle.CASUAL),
        )
    }

    @Test
    fun `parakeet title case and chunk joins flatten under formal`() {
        // Parakeet TDT emits native capitalization, and sherpa joins windows
        // with a space, so the next window often starts with a capital mid-sentence.
        assertEquals(
            "I think we should go to the store.",
            TranscriptStyler.apply(
                "I Think We Should Go To The Store",
                WritingStyle.FORMAL,
            ),
        )
        assertEquals(
            "Hello there how are you today.",
            TranscriptStyler.apply(
                "Hello there How are you today",
                WritingStyle.FORMAL,
            ),
        )
        assertEquals(
            "Yes, it's ready now.",
            TranscriptStyler.apply("Yes, It's Ready Now", WritingStyle.FORMAL),
        )
    }

    @Test
    fun `flattening keeps mixed-case names, acronyms, and the pronoun I`() {
        val source = "I use VocaPhone and GraphQL at NASA today"
        assertEquals(
            "I use VocaPhone and GraphQL at NASA today.",
            TranscriptStyler.apply(source, WritingStyle.CLEAN),
        )
        assertEquals(
            "I use VocaPhone and GraphQL at NASA today.",
            TranscriptStyler.apply(source, WritingStyle.FORMAL),
        )
        assertEquals(
            "I went home.",
            TranscriptStyler.apply("i went home", WritingStyle.CLEAN),
        )
    }

    /** A capital in an otherwise ordinary sentence is a name someone said. */
    @Test
    fun `names survive in an ordinary sentence`() {
        val source = "I met Sarah in Paris on Monday"
        for (style in listOf(WritingStyle.CLEAN, WritingStyle.FORMAL)) {
            assertEquals("I met Sarah in Paris on Monday.", TranscriptStyler.apply(source, style))
        }
        assertEquals("I met Sarah in Paris on Monday", TranscriptStyler.apply(source, WritingStyle.CASUAL))
        assertEquals("I met Sarah in Paris on Monday!", TranscriptStyler.apply(source, WritingStyle.EXCITED))
        // Four capitals in seven words is a sentence full of names, not a
        // Title-Cased one.
        assertEquals(
            "Meet Sarah and John in Paris on Monday.",
            TranscriptStyler.apply("Meet Sarah and John in Paris on Monday", WritingStyle.FORMAL),
        )
        assertEquals("Call Sarah.", TranscriptStyler.apply("Call Sarah", WritingStyle.CLEAN))
        assertEquals("Ich habe Hunger.", TranscriptStyler.apply("Ich habe Hunger", WritingStyle.FORMAL))
    }

    /** A chunk-join function word is flattened, but not inside a multi-word name. */
    @Test
    fun `multi-word names keep their function words`() {
        assertEquals(
            "We flew to the Bank Of America office.",
            TranscriptStyler.apply("we flew to the Bank Of America office", WritingStyle.FORMAL),
        )
        assertEquals(
            "I moved to The Hague last year.",
            TranscriptStyler.apply("I moved to The Hague last year", WritingStyle.FORMAL),
        )
        assertEquals(
            "Sarah said it was fine.",
            TranscriptStyler.apply("Sarah said It was fine", WritingStyle.FORMAL),
        )
    }

    /** A Title-Cased sentence does not cost the next one its names. */
    @Test
    fun `title case is judged per sentence`() {
        assertEquals(
            "The meeting is at noon. Ask Sarah about it.",
            TranscriptStyler.apply("The Meeting Is At Noon. Ask Sarah about it", WritingStyle.FORMAL),
        )
        assertEquals("Do it now.", TranscriptStyler.apply("Do It Now", WritingStyle.FORMAL))
        assertEquals(
            "Ate a lot of pizza today.",
            TranscriptStyler.apply("Ate A Lot Of Pizza Today", WritingStyle.FORMAL),
        )
    }

    @Test
    fun `long all caps is still flattened`() {
        assertEquals("This is really good.", TranscriptStyler.apply("this is REALLY good", WritingStyle.FORMAL))
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
    fun `automatic language recognizes unpunctuated danda scripts`() {
        val hindi = "मैं कल बाजार जाऊंगा"
        assertEquals(
            "a detected language punctuates by script",
            "मैं कल बाजार जाऊंगा।",
            TranscriptStyler.apply(hindi, WritingStyle.FORMAL, "hi"),
        )
        assertEquals(
            "automatic falls back to the script when an engine omits its language",
            "मैं कल बाजार जाऊंगा।",
            TranscriptStyler.apply(hindi, WritingStyle.FORMAL, "auto"),
        )
        assertEquals(
            "আমি কাল যাব।",
            TranscriptStyler.apply("আমি কাল যাব", WritingStyle.FORMAL, "auto"),
        )
        assertEquals(
            "ਮੈਂ ਕੱਲ੍ਹ ਜਾਵਾਂਗਾ।",
            TranscriptStyler.apply("ਮੈਂ ਕੱਲ੍ਹ ਜਾਵਾਂਗਾ", WritingStyle.FORMAL, "auto"),
        )
    }

    @Test
    fun `hindi normalizes sentence dots without touching protected dots or ellipses`() {
        assertEquals(
            "मूल्य 22.5 है। U.S. टीम example.com देखें... ठीक है।",
            TranscriptStyler.apply(
                "मूल्य 22.5 है. U.S. टीम example.com देखें... ठीक है.",
                WritingStyle.FORMAL,
                "auto",
            ),
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
