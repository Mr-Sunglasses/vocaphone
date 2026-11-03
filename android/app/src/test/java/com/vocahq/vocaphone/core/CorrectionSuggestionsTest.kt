package com.vocahq.vocaphone.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Suggesting, adding and dismissing learned spellings. The same cases as `CorrectionSuggestionsTests.swift`. */
class CorrectionSuggestionsTest {
    private val namrata = LearnedCorrection("Namratha", "Namrata", heardIsWord = false, namesTerm = true)
    private val main = LearnedCorrection("mane", "main", heardIsWord = true, namesTerm = false)

    private fun receive(
        found: List<LearnedCorrection>,
        suggestions: List<CorrectionSuggestion> = emptyList(),
        dismissed: List<String> = emptyList(),
        listed: (String, String) -> Boolean = { _, _ -> false },
    ) = CorrectionSuggestions.receive(found, suggestions, dismissed, now = 1_000, isListed = listed)

    @Test
    fun `a first fix is suggested`() {
        val received = receive(listOf(namrata))
        assertEquals(listOf("Namrata"), received.suggestions.map { it.corrected })
        assertEquals(1, received.suggestions.single().occurrences)
        assertTrue(received.added.isEmpty())
    }

    @Test
    fun `the same name fixed twice is added`() {
        val once = receive(listOf(namrata)).suggestions
        val twice = receive(listOf(namrata), once)
        assertTrue(twice.suggestions.isEmpty())
        assertEquals(listOf("Namrata"), twice.added.map { it.corrected })
        assertEquals(2, twice.added.single().occurrences)
    }

    @Test
    fun `a plain word fixed twice stays a suggestion`() {
        val once = receive(listOf(main)).suggestions
        val twice = receive(listOf(main), once)
        assertTrue(twice.added.isEmpty())
        assertEquals(2, twice.suggestions.single().occurrences)
    }

    @Test
    fun `dismissed and listed fixes are skipped`() {
        assertTrue(receive(listOf(namrata), dismissed = listOf(CorrectionSuggestion.key("namratha", "Namrata"))).suggestions.isEmpty())
        assertTrue(receive(listOf(namrata), listed = { _, corrected -> corrected == "Namrata" }).suggestions.isEmpty())
    }

    @Test
    fun `the list is capped, newest first`() {
        val many = (0 until CorrectionSuggestions.CAPACITY + 5).map {
            LearnedCorrection("heard$it", "Written$it", heardIsWord = false, namesTerm = false)
        }
        val received = receive(many)
        assertEquals(CorrectionSuggestions.CAPACITY, received.suggestions.size)
        assertEquals("Written${CorrectionSuggestions.CAPACITY + 4}", received.suggestions.first().corrected)
    }

    @Test
    fun `adding writes a replacement only where it is safe`() {
        fun learned(heard: String, corrected: String, heardIsWord: Boolean) = CorrectionSuggestions.learn(
            CorrectionSuggestion(heard, corrected, heardIsWord = heardIsWord),
            emptyList(),
        )
        // Different letters: a replacement, and the word.
        val name = learned("Namratha", "Namrata", heardIsWord = false)
        assertEquals(listOf("Namratha" to "Namrata"), name.replacements.map { it.heard to it.written })
        assertEquals("Namrata", name.term)
        // Fixing "cloud" once must not rewrite every cloud.
        assertTrue(learned("cloud", "Claude", heardIsWord = true).replacements.isEmpty())
        // A casing fix needs no replacement; joined words get one.
        assertTrue(learned("github", "GitHub", heardIsWord = false).replacements.isEmpty())
        assertEquals(listOf("git hub"), learned("git hub", "GitHub", heardIsWord = false).replacements.map { it.heard })
    }

    @Test
    fun `listed means a custom word or a replacement from the same hearing`() {
        val rows = listOf(WordReplacement(heard = "get hub, git hub", written = "GitHub"))
        assertTrue(CorrectionSuggestions.isListed("Git Hub", "GitHub", rows, emptyList()))
        assertTrue(CorrectionSuggestions.isListed("anything", "Namrata", emptyList(), listOf("Namrata")))
        assertTrue(!CorrectionSuggestions.isListed("gitbub", "GitHub", rows, emptyList()))
    }

    @Test
    fun `dismissals are kept, newest last and bounded`() {
        var dismissed = emptyList<String>()
        repeat(CorrectionSuggestions.DISMISSED_CAPACITY + 3) { dismissed = CorrectionSuggestions.dismissing("k$it", dismissed) }
        assertEquals(CorrectionSuggestions.DISMISSED_CAPACITY, dismissed.size)
        assertEquals("k${CorrectionSuggestions.DISMISSED_CAPACITY + 2}", dismissed.last())
    }

    @Test
    fun `an added word joins the custom words without rewriting them`() {
        assertEquals("Namrata", CorrectionSuggestions.vocabulary("", "Namrata"))
        assertEquals("Kubernetes, kubectl\nNamrata", CorrectionSuggestions.vocabulary("Kubernetes, kubectl", "Namrata"))
        assertEquals("Namrata", CorrectionSuggestions.vocabulary("Namrata", "Namrata"))
        // A differently cased copy gives way.
        assertEquals("Kubernetes\nGitHub", CorrectionSuggestions.vocabulary("github, Kubernetes", "GitHub"))
    }

    @Test
    fun `suggestions survive storage`() {
        val stored = CorrectionSuggestion.encode(receive(listOf(namrata, main)).suggestions)
        val decoded = CorrectionSuggestion.decode(stored)
        assertEquals(listOf("main", "Namrata"), decoded.map { it.corrected })
        assertTrue(decoded.first().heardIsWord)
        assertTrue(CorrectionSuggestion.decode("not json").isEmpty())
        assertEquals(listOf("a", "b"), CorrectionSuggestion.decodeKeys(CorrectionSuggestion.encodeKeys(listOf("a", "b"))))
    }

    @Test
    fun `a term the keyboard dictionary cannot hold becomes a replacement while dictation reads it`() {
        val gpt = CorrectionSuggestion("gpt for", "GPT4", heardIsWord = false)
        val claude = CorrectionSuggestion("cloud", "Claude Code", heardIsWord = true)
        val kanishk = CorrectionSuggestion("Kanish", "Kanishk", heardIsWord = false)
        // Synced: a plain word goes to the personal dictionary dictation reads.
        assertEquals(CorrectionSuggestions.Destination.PERSONAL_DICTIONARY, CorrectionSuggestions.destination(kanishk, synced = true, savable = true, explicit = false))
        // Synced: digits or a space cannot go there, and the custom words are not read.
        assertEquals(CorrectionSuggestions.Destination.REPLACEMENT, CorrectionSuggestions.destination(gpt, synced = true, savable = false, explicit = false))
        // One ordinary word heard is only made a replacement when the user asks.
        assertEquals(CorrectionSuggestions.Destination.NOT_YET, CorrectionSuggestions.destination(claude, synced = true, savable = false, explicit = false))
        assertEquals(CorrectionSuggestions.Destination.REPLACEMENT, CorrectionSuggestions.destination(claude, synced = true, savable = false, explicit = true))
        // Not synced: the custom words are what dictation reads.
        assertEquals(CorrectionSuggestions.Destination.CUSTOM_WORDS, CorrectionSuggestions.destination(gpt, synced = false, savable = false, explicit = false))
    }
}
