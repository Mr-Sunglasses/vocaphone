package com.vocahq.vocaphone.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * VocaMac's `CorrectionLearnerTests` and `SentenceStartCorrectionTests`,
 * ported. The same cases as `CorrectionLearnerTests.swift`.
 */
class CorrectionLearnerTest {
    private val isKnown: (String) -> Boolean = { it.lowercase() in COMMON }

    private fun learn(inserted: String, before: String, after: String, caret: Int? = null) =
        CorrectionLearner.corrections(inserted, before, after, caret, isKnown)

    private fun correction(heard: String, corrected: String) = CorrectionLearner.Correction(heard, corrected)

    @Test
    fun `learns a name spelling fix`() {
        assertEquals(
            listOf(correction("Namratha", "Namrata")),
            learn("ask Namratha about it", "Hi. ask Namratha about it", "Hi. ask Namrata about it"),
        )
    }

    @Test
    fun `learns casing and joining fixes`() {
        assertEquals(listOf(correction("git hub", "GitHub")), learn("push to git hub", "push to git hub", "push to GitHub"))
        assertEquals(listOf(correction("github", "GitHub")), learn("push to github", "push to github", "push to GitHub"))
    }

    @Test
    fun `sentence capitalization is not a term`() {
        assertTrue(learn("hello world", "hello world", "Hello world").isEmpty())
    }

    @Test
    fun `a common word swap is ignored`() {
        assertTrue(learn("put it there", "put it there", "put it their").isEmpty())
    }

    @Test
    fun `rewording is ignored`() {
        assertTrue(learn("that is big", "that is big", "that is large").isEmpty())
    }

    @Test
    fun `an edit outside the dictation is ignored`() {
        assertTrue(learn("ask Namratha", "Dear Bobb, ask Namratha", "Dear Bob, ask Namratha").isEmpty())
    }

    @Test
    fun `text not found is ignored`() {
        assertTrue(learn("something else", "hello", "hullo").isEmpty())
    }

    @Test
    fun `the caret picks the copy just typed`() {
        val before = "ask Namratha. ask Namratha"
        val after = "ask Namratha. ask Namrata"
        assertEquals(listOf(correction("Namratha", "Namrata")), learn("ask Namratha", before, after, before.length))
        // A caret at the first copy means the second edit wasn't in the dictation.
        assertTrue(learn("ask Namratha", before, after, 12).isEmpty())
    }

    @Test
    fun `a large rewrite is ignored`() {
        val inserted = "one two three four five six seven eight nine ten eleven twelve thirteen"
        val after = "uno dos tres cuatro cinco seis siete ocho nueve diez once doce trece"
        assertTrue(learn(inserted, inserted, after).isEmpty())
    }

    // Sentence starts (VocaMac's SentenceStartCorrectionTests).

    private val sentenceWords = setOf(
        "whether", "weather", "is", "nice", "their", "there", "going", "home", "ask", "about", "it",
    )

    private fun learnSentence(text: String, edited: String, prefix: String = "") =
        CorrectionLearner.corrections(text, prefix + text, prefix + edited) { it.lowercase() in sentenceWords }

    @Test
    fun `a sentence start capital is not a name`() {
        assertTrue(learnSentence("Whether is nice.", "Weather is nice.").isEmpty())
        assertTrue(learnSentence("Their going home.", "There going home.").isEmpty())
        assertTrue(learnSentence("Whether is nice.", "Weather is nice.", prefix = "Hi. ").isEmpty())
        assertTrue(learnSentence("ok. Whether is nice.", "ok. Weather is nice.").isEmpty())
    }

    @Test
    fun `a name at a sentence start is still learned`() {
        assertEquals(listOf(correction("Pria", "Priya")), learnSentence("Pria is nice.", "Priya is nice."))
    }

    @Test
    fun `a capital mid sentence counts as a name`() {
        assertEquals(listOf(correction("pria", "Priya")), learnSentence("ask pria about it", "ask Priya about it"))
    }

    // What the dictation became (VocaMac's DictationEditReader cases).

    @Test
    fun `a short fix is still the dictation`() {
        assertTrue(CorrectionLearner.isStillDictation("Priya", "Pria"))
    }

    @Test
    fun `a field that moved on is not the dictation`() {
        assertFalse(CorrectionLearner.isStillDictation("ok", "Sounds good, see you at five"))
        assertFalse(CorrectionLearner.isStillDictation("ok", "hello there"))
        assertFalse(CorrectionLearner.isStillDictation("", "hello there"))
        assertTrue(CorrectionLearner.isStillDictation("Sounds good, see you at 5", "Sounds good, see you at five"))
    }

    // Phone additions.

    @Test
    fun `only text in the word list's language is learned from`() {
        assertTrue(CorrectionLearner.readsAsKnownLanguage("ask Namratha about it", isKnown))
        assertFalse(CorrectionLearner.readsAsKnownLanguage("frag Namratha danach bitte", isKnown))
        assertFalse(CorrectionLearner.readsAsKnownLanguage("123 456", isKnown))
    }

    @Test
    fun `tells ordinary words and terms apart`() {
        assertTrue(CorrectionLearner.isOrdinaryWord("cloud", isKnown))
        assertFalse(CorrectionLearner.isOrdinaryWord("get hub", isKnown))
        assertFalse(CorrectionLearner.isOrdinaryWord("Namratha", isKnown))
        assertTrue(CorrectionLearner.namesATerm("Claude", isKnown))
        assertTrue(CorrectionLearner.namesATerm("kubectl", isKnown))
        assertFalse(CorrectionLearner.namesATerm("there", isKnown))
    }

    companion object {
        /** VocaMac's `TestWords.common`. */
        val COMMON = setOf(
            "the", "a", "an", "and", "i", "to", "is", "it", "in", "on", "of", "for", "with", "my", "me",
            "open", "file", "hello", "world", "cloud", "there", "their", "big", "large", "meet", "at",
            "send", "email", "call", "please", "user", "id", "kaiser", "service", "super", "base", "post", "apple",
            "notes", "mail", "check", "this", "that", "we", "should", "use", "set", "value", "ask",
            "about", "project", "today", "tomorrow", "update", "code", "run", "tests", "get", "hub",
            "put", "push", "hi", "see", "you", "five", "sounds", "good", "dear",
        )
    }
}
