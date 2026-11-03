package com.vocahq.vocaphone.core

import com.vocahq.vocaphone.local.LocalModelCatalog
import com.vocahq.vocaphone.local.SherpaFamily
import com.vocahq.vocaphone.local.whisperPrompt
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Mirrors the iOS client's `RecognitionHintsTests`: both build the same list
 * and the same engine strings from the same stored vocabulary.
 */
class RecognitionHintsTest {

    @Test
    fun `the user's first term ends the list`() {
        assertEquals(
            listOf("Tailscale", "VocaHQ", "Kanishk"),
            RecognitionHints.terms(listOf("Kanishk", "VocaHQ", "Tailscale")),
        )
        assertEquals(emptyList<String>(), RecognitionHints.terms(emptyList()))
    }

    @Test
    fun `context comes first, then replacements, then the user's own words`() {
        assertEquals(
            listOf("Redis", "Kubernetes", "Grafana", "GitHub", "Namrata", "Kanishk"),
            RecognitionHints.terms(
                vocabulary = listOf("Kanishk", "Namrata"),
                replacementTargets = listOf("GitHub", "Grafana"),
                contextTerms = listOf("Kubernetes", "Redis"),
            ),
        )
    }

    @Test
    fun `the user's spelling wins a duplicate`() {
        assertEquals(
            listOf("Jira", "Figma", "GitHub"),
            RecognitionHints.terms(
                vocabulary = listOf("GitHub"),
                replacementTargets = listOf("github", "Figma"),
                contextTerms = listOf("GITHUB", "figma", "Jira"),
            ),
        )
    }

    @Test
    fun `a replacement that types a snippet is no hint`() {
        assertTrue(RecognitionHints.isHintableReplacement("GitHub"))
        assertTrue(RecognitionHints.isHintableReplacement("Claude Code"))
        assertFalse(RecognitionHints.isHintableReplacement("me@example.com"))
        assertFalse(RecognitionHints.isHintableReplacement("https://vocahq.com"))
        assertFalse(RecognitionHints.isHintableReplacement("see you at the usual place"))
        assertFalse(RecognitionHints.isHintableReplacement("42"))
        assertFalse(RecognitionHints.isHintableReplacement("x"))
    }

    @Test
    fun `context terms stop at their count and the character budget`() {
        val counted = RecognitionHints.terms(listOf("Kanishk"), contextTerms = (1..300).map { "Context$it" })
        assertEquals(RecognitionHints.MAX_CONTEXT_TERMS + 1, counted.size)
        assertEquals(listOf("Context1", "Kanishk"), counted.takeLast(2))

        val long = (1..300).map { "Context$it" + "x".repeat(30) }
        val budgeted = RecognitionHints.terms(listOf("Kanishk"), contextTerms = long)
        assertTrue(budgeted.joinToString(", ").length <= RecognitionHints.MAX_CHARACTERS)
        assertEquals("Kanishk", budgeted.last())
    }

    @Test
    fun `the user's own words are never cut by the list budget`() {
        val vocabulary = (1..200).map { "Colleague$it" + "y".repeat(20) }
        val terms = RecognitionHints.terms(vocabulary, contextTerms = listOf("Screen"))
        assertEquals(200, terms.size)
        assertFalse("Screen" in terms)
    }

    @Test
    fun `the whisper prompt is the list as text`() {
        assertEquals(
            "Kanishk, VocaHQ, Tailscale.",
            RecognitionHints.whisperPrompt(listOf("Tailscale", "VocaHQ", "Kanishk")),
        )
        assertEquals("", RecognitionHints.whisperPrompt(emptyList()))
    }

    @Test
    fun `a pasted list of thousands builds the prompt from the terms that fit`() {
        val terms = RecognitionHints.terms(vocabulary = (1..50_000).map { "Name$it" })
        val prompt = RecognitionHints.whisperPrompt(terms)
        assertTrue(prompt.startsWith("Name1, Name2, "))
        assertTrue(prompt.length <= RecognitionHints.WHISPER_PROMPT_CHARACTERS)
        assertEquals(
            prompt,
            RecognitionHints.whisperPrompt(terms.takeLast(200)),
        )
    }

    @Test
    fun `an over-long prompt loses the front of the list and never half a term`() {
        val terms = RecognitionHints.terms((1..200).map { "Supercalifragilistic$it" })
        val prompt = RecognitionHints.whisperPrompt(terms)
        assertTrue(prompt.length <= RecognitionHints.WHISPER_PROMPT_CHARACTERS)
        // The user's first terms survive, written in the user's order.
        assertTrue(prompt.startsWith("Supercalifragilistic1, Supercalifragilistic2, "))
        prompt.removeSuffix(".").split(", ").forEach { term ->
            assertTrue("`$term` should be whole", term.matches(Regex("Supercalifragilistic\\d+")))
        }
    }

    @Test
    fun `context is the first to go from a full prompt`() {
        val terms = RecognitionHints.terms(
            vocabulary = listOf("Kanishk", "Namrata"),
            contextTerms = (1..300).map { "Screen$it" },
        )
        val prompt = RecognitionHints.whisperPrompt(terms)
        assertTrue(prompt.length <= RecognitionHints.WHISPER_PROMPT_CHARACTERS)
        assertTrue(prompt.startsWith("Kanishk, Namrata, Screen1, "))
        assertFalse("Screen100" in prompt)
    }

    @Test
    fun `a term that alone exceeds the budget leaves no prompt`() {
        assertEquals("", RecognitionHints.whisperPrompt(listOf("x".repeat(700))))
    }

    @Test
    fun `stored vocabulary reaches the prompt in the user's priority`() {
        assertEquals("Kanishk, VocaHQ, Tailscale.", whisperPrompt("Kanishk\nVocaHQ, Tailscale"))
        assertEquals("", whisperPrompt(""))
    }

    @Test
    fun `only a prompted empty decode is retried without the prompt`() {
        assertTrue(RecognitionHints.shouldRetryWithoutPrompt("", "Kanishk."))
        assertTrue(RecognitionHints.shouldRetryWithoutPrompt("  ", "Kanishk."))
        assertFalse(RecognitionHints.shouldRetryWithoutPrompt("", ""))
        assertFalse(RecognitionHints.shouldRetryWithoutPrompt("Kanishk said hi", "Kanishk."))
    }

    @Test
    fun `qwen3 hotwords are comma separated with no spaces`() {
        assertEquals(
            "Kanishk,Claude Code,Tailscale",
            RecognitionHints.qwen3Hotwords(listOf("Tailscale", "Claude Code", "Kanishk")),
        )
        assertNull(RecognitionHints.qwen3Hotwords(emptyList()))
        assertNull(RecognitionHints.qwen3Hotwords(listOf("  ", ",")))
    }

    @Test
    fun `a comma inside a term would split it`() {
        assertEquals("Smith  Jones", RecognitionHints.qwen3Hotwords(listOf("Smith, Jones")))
    }

    @Test
    fun `qwen3 keeps the end of the list within its caps`() {
        val kept = RecognitionHints.qwen3Hotwords(RecognitionHints.terms((1..50).map { "Name$it" }))!!.split(",")
        assertEquals(RecognitionHints.MAX_HOTWORDS, kept.size)
        assertEquals("Name1", kept.first())
        assertFalse("Name21" in kept)

        val long = RecognitionHints.qwen3Hotwords((1..10).map { "Term$it" + "z".repeat(40) })!!
        assertTrue(long.length <= RecognitionHints.MAX_HOTWORD_CHARACTERS)
        assertTrue(long.startsWith("Term10" + "z".repeat(40) + ","))
    }

    @Test
    fun `only qwen3 takes hotwords`() {
        val terms = listOf("Kanishk")
        assertEquals("Kanishk", RecognitionHints.sherpaHotwords(SherpaFamily.QWEN3_ASR, terms))
        SherpaFamily.entries.filter { it != SherpaFamily.QWEN3_ASR }.forEach { family ->
            assertNull(family.name, RecognitionHints.sherpaHotwords(family, terms))
        }
        assertNull(RecognitionHints.sherpaHotwords(null, terms))
        assertNull(RecognitionHints.sherpaHotwords(SherpaFamily.QWEN3_ASR, emptyList()))
    }

    @Test
    fun `whisper and qwen3 are the models a vocabulary reaches while decoding`() {
        assertTrue(LocalModelCatalog.find("qwen3-asr-0.6b")!!.supportsCustomVocabulary)
        assertTrue(LocalModelCatalog.find("small-q8_0")!!.supportsCustomVocabulary)
        assertFalse(LocalModelCatalog.find("parakeet-tdt-0.6b-v2-en")!!.supportsCustomVocabulary)
    }
}
