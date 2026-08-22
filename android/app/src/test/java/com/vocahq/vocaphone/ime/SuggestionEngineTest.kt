package com.vocahq.vocaphone.ime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SuggestionEngineTest {

    private val dictionary = SuggestionDictionary(
        words = listOf("hello", "help", "held", "the", "there", "their", "book"),
        bigrams = mapOf(
            "the" to listOf("first", "same", "other"),
            "see" to listOf("you", "the"),
        ),
    )

    @Test
    fun `completions follow frequency order and skip the exact prefix`() {
        assertEquals(listOf("hello", "help", "held"), dictionary.complete("hel"))
        assertEquals(listOf("Hello", "Help", "Held"), dictionary.complete("Hel"))
        assertEquals(listOf("HELLO", "HELP", "HELD"), dictionary.complete("HEL"))
        assertTrue(dictionary.complete("zzz").isEmpty())
    }

    @Test
    fun `next word uses the last token before the cursor`() {
        assertEquals("world", SuggestionEngine.lastWord("hello world"))
        assertEquals("world", SuggestionEngine.lastWord("hello world "))
        assertEquals("dont", SuggestionEngine.lastWord("I don't"))
        assertEquals(listOf("you", "the"), dictionary.next("see"))
        assertTrue(dictionary.next("xyz").isEmpty())
    }

    @Test
    fun `corrections prefer nearby dictionary words`() {
        assertEquals(listOf("hello"), dictionary.correct("helllo"))
        assertEquals(listOf("the"), dictionary.correct("teh"))
        assertTrue(dictionary.correct("hello").isEmpty())
        assertEquals(listOf("Hello"), dictionary.correct("Helllo"))
    }

    @Test
    fun `word span covers the token around the cursor`() {
        val span = SuggestionEngine.wordSpan("say hel", "lo there")
        assertEquals("hello", span?.word)
        assertEquals(3, span?.beforeLength)
        assertEquals(2, span?.afterLength)
    }

    @Test
    fun `strip offers corrections for a misspelled committed word`() {
        val strip = dictionary.strip(
            composing = "",
            before = "helllo",
            after = "",
            correctionsEnabled = true,
        )
        assertEquals("hello", strip.words.first())
        assertTrue(strip.replacesWord)
    }

    @Test
    fun `similar offers nearby words even when the typed word is known`() {
        assertTrue(dictionary.correct("hello").isEmpty())
        val nearby = dictionary.similar("hello")
        assertTrue(nearby.contains("help") || nearby.contains("held"))
        assertTrue("hello" !in nearby)
    }

    @Test
    fun `strip offers nearby replacements when the cursor is in a known word`() {
        val strip = dictionary.strip(
            composing = "",
            before = "hello",
            after = "",
            correctionsEnabled = true,
        )
        assertTrue(strip.replacesWord)
        assertTrue(strip.words.any { it == "help" || it == "held" })
        assertTrue("hello" !in strip.words)
    }

    @Test
    fun `strip skips replacements when corrections are off`() {
        val strip = dictionary.strip(
            composing = "",
            before = "hello",
            after = "",
            correctionsEnabled = false,
        )
        assertTrue(strip.words.isEmpty())
        assertTrue(!strip.replacesWord)
    }

    @Test
    fun `strip keeps next-word guesses after a space`() {
        val strip = dictionary.strip(
            composing = "",
            before = "the ",
            after = "",
            correctionsEnabled = true,
        )
        assertEquals(listOf("first", "same", "other"), strip.words)
        assertTrue(strip.emojis.isEmpty())
        assertTrue(!strip.replacesWord)
    }

    @Test
    fun `strip offers emoji with the word after a space`() {
        val strip = dictionary.strip(
            composing = "",
            before = "happy ",
            after = "",
            correctionsEnabled = false,
        )
        assertEquals(listOf("😊", "😄", "😁"), strip.emojis)
        assertTrue(strip.items.any { it.text == "😊" && it.isEmoji })
        assertTrue(!strip.replacesWord)
    }

    @Test
    fun `strip offers emoji while the trigger word is being composed`() {
        val strip = dictionary.strip(
            composing = "sad",
            before = "",
            after = "",
            correctionsEnabled = false,
        )
        assertEquals(listOf("😢", "😭", "😞"), strip.emojis)
        assertTrue(strip.words.none { it == "😢" })
    }

    @Test
    fun lastTypedWordKeepsCaseAndApostrophes() {
        assertEquals("O'Brien", SuggestionEngine.lastTypedWord("Hello O'Brien "))
        assertEquals("Kanishk", SuggestionEngine.lastTypedWord("Kanishk."))
        assertEquals("kanishk", SuggestionEngine.lastTypedWord("I am kanishk"))
        assertEquals(null, SuggestionEngine.lastTypedWord("   "))
    }

    @Test
    fun `strip completes personal words ahead of the shipped list`() {
        val strip = dictionary.strip(
            composing = "kan",
            before = "",
            after = "",
            correctionsEnabled = false,
            personalRaw = "Kanishk\nVocaPhone",
        )
        assertEquals("Kanishk", strip.words.first())
        assertEquals(null, strip.saveWord)
    }

    @Test
    fun `strip offers to save an unknown word`() {
        val strip = dictionary.strip(
            composing = "kanishk",
            before = "",
            after = "",
            correctionsEnabled = false,
        )
        assertEquals("kanishk", strip.saveWord)
        assertTrue(strip.items.first().savesWord)
        assertEquals("kanishk", strip.items.first().text)
    }

    @Test
    fun `strip does not offer to save a prefix of a known word`() {
        val strip = dictionary.strip(
            composing = "hel",
            before = "",
            after = "",
            correctionsEnabled = false,
        )
        assertEquals(null, strip.saveWord)
        assertTrue(strip.words.isNotEmpty())
    }

    @Test
    fun `strip offers to save a finished unknown word`() {
        val strip = dictionary.strip(
            composing = "",
            before = "Thanks Kanishk ",
            after = "",
            correctionsEnabled = false,
            personalRaw = "",
        )
        assertEquals("Kanishk", strip.saveWord)
    }

    @Test
    fun `strip does not offer to save a word already in the personal dictionary`() {
        val strip = dictionary.strip(
            composing = "kanishk",
            before = "",
            after = "",
            correctionsEnabled = false,
            personalRaw = "Kanishk",
        )
        assertEquals(null, strip.saveWord)
    }

    @Test
    fun `strip does not offer emoji for a prefix of a trigger`() {
        val strip = dictionary.strip(
            composing = "hap",
            before = "",
            after = "",
            correctionsEnabled = false,
        )
        assertTrue(strip.emojis.isEmpty())
    }

    @Test
    fun `strip still offers emoji after a period`() {
        val strip = dictionary.strip(
            composing = "",
            before = "sad.",
            after = "",
            correctionsEnabled = false,
        )
        assertEquals(listOf("😢", "😭", "😞"), strip.emojis)
        assertTrue(!EmojiCommit.shouldReplaceTrigger("", "sad."))
    }

    @Test
    fun lastWordForEmojiSkipsTrailingPunctuation() {
        assertEquals("sad", SuggestionEngine.lastWordForEmoji("sad."))
        assertEquals("sad", SuggestionEngine.lastWordForEmoji("sad "))
        assertEquals("sad", SuggestionEngine.lastWordForEmoji("I am sad!"))
        assertEquals("happy", SuggestionEngine.lastWord("happy "))
        assertEquals(null, SuggestionEngine.lastWord("sad."))
    }

    @Test
    fun `word before deletes the previous token and its trailing space`() {
        assertEquals(5, SuggestionEngine.wordBefore("hello world"))
        assertEquals(6, SuggestionEngine.wordBefore("hello world "))
        assertEquals(2, SuggestionEngine.wordBefore("hello. "))
        assertEquals(0, SuggestionEngine.wordBefore(""))
        assertEquals(3, SuggestionEngine.wordBefore("   "))
    }

    @Test
    fun `line before deletes back to the previous newline`() {
        assertEquals(1, SuggestionEngine.lineBefore("a\nb\nc"))
        assertEquals(1, SuggestionEngine.lineBefore("a\nb\n"))
        assertEquals(5, SuggestionEngine.lineBefore("hello"))
        assertEquals(0, SuggestionEngine.lineBefore(""))
    }

    /**
     * The winner is asserted rather than the whole list. Admitting words whose
     * letters the finger only came near widened what a path can return — that
     * is the point of it, since those extra words fill the strip the user
     * picks from — so only the ranking is a promise here.
     */
    @Test
    fun `swipe matches a path across letter keys`() {
        assertEquals("the", dictionary.swipe("the").first())
        assertEquals("the", dictionary.swipe("tghe").first())
        assertEquals("hello", dictionary.swipe("hjkello").first())
        assertEquals("hello", dictionary.swipe("helo").first())
        assertEquals("book", dictionary.swipe("bok").first())
        assertTrue(dictionary.swipe("qz").isEmpty())
        assertTrue(dictionary.swipe("h").isEmpty())
    }

    @Test
    fun `a word whose keys were all crossed outranks a shape-alike that was not`() {
        // j-o-e-l traces almost the same line as this h-e-l-l-o path and is
        // reachable from it one key at a time, but "hello" is the word the
        // finger actually spelled and has to stay in front of it.
        val words = SuggestionDictionary(
            words = listOf("joel", "hello"),
            bigrams = emptyMap(),
        )
        assertEquals("hello", words.swipe("hjkello").first())
    }

    @Test
    fun `a swipe that started off its first key still finds its word`() {
        // A recorded h-e-l-l-o path whose start landed a little high, on "u"
        // rather than "h", so "h" is nowhere in the keys the finger crossed.
        // Requiring every letter exactly threw "hello" out over that one miss,
        // while it is plainly still the best answer for the gesture.
        val words = SuggestionDictionary(
            words = listOf("hello", "help", "held", "book"),
            bigrams = emptyMap(),
        )
        assertFalse(SuggestionEngine.isSubsequence("helo", "uytrertyuiklo"))
        assertEquals("hello", words.swipe("uytrertyuiklo").first())
    }

    @Test
    fun `a reachable subsequence still needs every letter in order`() {
        assertTrue(SuggestionEngine.isReachableSubsequence("helo", "hjkelo"))
        // "k" stands in for "l" and "p" for "o": both are neighbours.
        assertTrue(SuggestionEngine.isReachableSubsequence("helo", "hgerkp"))
        // "z" is nowhere near "l", so the word is not spelled here.
        assertFalse(SuggestionEngine.isReachableSubsequence("helo", "hgerzo"))
        // Right letters, wrong order.
        assertFalse(SuggestionEngine.isReachableSubsequence("helo", "hole"))
    }

    /**
     * The path here was `src/main/assets/suggestions/en.txt`, which stopped
     * existing when the word list moved to the repository root to be shared
     * with iOS. `assumeTrue` turned that into a skip rather than a failure, so
     * the only check that swipe ranks the real ten thousand word list correctly
     * silently stopped running — including through a rewrite of the ranking.
     */
    @Test
    fun `english list picks some not see on an s-o-m-e swipe`() {
        val file = generateSequence(java.io.File("").absoluteFile) { it.parentFile }
            .map { java.io.File(it, "assets/keyboard/en.txt") }
            .firstOrNull(java.io.File::isFile)
        org.junit.Assume.assumeTrue(
            "assets/keyboard is only present in the repository",
            file != null,
        )
        requireNotNull(file)
        val dict = SuggestionDictionary(
            words = file.readLines().map { it.trim() }.filter { it.isNotEmpty() },
            bigrams = emptyMap(),
        )
        assertEquals("some", dict.swipe("sdfghjklomnhytre").first())
        assertEquals("hello", dict.swipe("hjkello").first())
        assertEquals("the", dict.swipe("tghe").first())
    }

    @Test
    fun `swipe prefers the word whose key path matches the gesture`() {
        val words = SuggestionDictionary(
            words = listOf("see", "she", "same", "some", "store", "case"),
            bigrams = emptyMap(),
        )
        // S → O → M → E crosses the home row, then down to M, then up to E.
        // "see" is earlier in the list and is a subsequence, but the shape is "some".
        assertEquals("some", words.swipe("sdfghjklomnhytre").first())
        assertEquals("some", words.swipe("sertoiuytrewmne").first())
    }

    @Test
    fun `replaceable word includes a trailing space after a swipe`() {
        val span = SuggestionEngine.replaceableWord("hello ", "")
        assertEquals("hello", span?.word)
        assertEquals(6, span?.beforeLength)
        assertEquals(0, span?.afterLength)
    }

    @Test
    fun `a picked suggestion keeps its trailing space at the end of the text`() {
        assertEquals("hello ", SuggestionEngine.suggestionCommit("hello", ""))
    }

    @Test
    fun `a picked suggestion spaces itself from a word that follows`() {
        assertEquals("hello ", SuggestionEngine.suggestionCommit("hello", "world"))
    }

    @Test
    fun `a picked suggestion drops the space the text after it already has`() {
        // Editing "hel|lo world": the word span takes "hello" out and the
        // commit lands in front of " world", which is already separated.
        assertEquals("hello", SuggestionEngine.suggestionCommit("hello", " world"))
        assertEquals("hello", SuggestionEngine.suggestionCommit("hello", "\nrest"))
    }

    @Test
    fun `a picked suggestion does not push punctuation away from its word`() {
        assertEquals("hello", SuggestionEngine.suggestionCommit("hello", ", world"))
        assertEquals("hello", SuggestionEngine.suggestionCommit("hello", "."))
    }
}
