package com.vocahq.vocaphone.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * "Heard → written" replacements, on their own and in the finishing funnel.
 * The same cases as `WordReplacementTests.swift`.
 */
class WordReplacementTest {
    private fun replaced(text: String, vararg replacements: WordReplacement) =
        WordReplacements.apply(text, replacements.toList()).text

    private fun replacement(heard: String, written: String) = WordReplacement(heard = heard, written = written)

    private val gitHub = replacement("get hub", "GitHub")

    @Test
    fun `ignores case and writes the user's spelling`() {
        val result = WordReplacements.apply("Push it to get hub please", listOf(gitHub))
        assertEquals("Push it to GitHub please", result.text)
        assertEquals(listOf("GitHub"), result.written.map { result.text.substring(it.first, it.last + 1) })
        assertEquals("GitHub is down.", replaced("Get Hub is down.", gitHub))
    }

    @Test
    fun `matches whole words only`() {
        val cat = replacement("cat", "Kat")
        assertEquals("the cattle and the Kat", replaced("the cattle and the cat", cat))
        assertEquals("concatenate", replaced("concatenate", cat))
        // A possessive or a full stop after the heard form is fine.
        assertEquals("the Kat's bowl.", replaced("the cat's bowl.", cat))
    }

    @Test
    fun `a combining mark belongs to the word it follows`() {
        val tomorrow = replacement("कल", "tomorrow")
        assertEquals("कला", replaced("कला", tomorrow))
        assertEquals("tomorrow कला", replaced("कल कला", tomorrow))
        // A Latin word followed by a combining accent is one word too.
        assertEquals("cafe\u0301", replaced("cafe\u0301", replacement("cafe", "Café")))
        // Nor does a match split a surrogate pair.
        assertEquals("a\uD835\uDC00b", replaced("a\uD835\uDC00b", replacement("a", "x")))
    }

    @Test
    fun `accepts several heard forms`() {
        val kubectl = replacement("cube cuttle, cube  control", "kubectl")
        assertEquals(listOf("cube cuttle", "cube control"), kubectl.heardForms)
        assertEquals("run kubectl then kubectl", replaced("run cube cuttle then Cube Control", kubectl))
    }

    @Test
    fun `the longer heard form wins`() {
        val replacements = arrayOf(replacement("open ai", "OpenAI"), replacement("open ai studio", "AI Studio"))
        assertEquals("AI Studio", replaced("open ai studio", *replacements))
        assertEquals("ask OpenAI", replaced("ask open ai", *replacements))
    }

    /** One pass: what a replacement wrote is never matched again. */
    @Test
    fun `a written form is not replaced again`() {
        assertEquals("J K", replaced("jay", replacement("jay", "J K"), replacement("k", "Kay")))
    }

    @Test
    fun `protected ranges are left alone`() {
        val text = "send get hub now"
        val start = text.indexOf("get hub")
        val result = WordReplacements.apply(text, listOf(gitHub), listOf(start until start + 7))
        assertEquals(text, result.text)
        assertTrue(result.written.isEmpty())
    }

    @Test
    fun `a heard form with punctuation needs space around it`() {
        val cpp = replacement("c++", "C++")
        assertEquals("I write C++ daily", replaced("I write c++ daily", cpp))
        assertEquals("abc++", replaced("abc++", cpp))
    }

    @Test
    fun `invalid rows do nothing`() {
        assertFalse(replacement(" , ", "X").isValid)
        assertFalse(replacement("x", "  ").isValid)
        assertEquals("x marks", replaced("x marks", replacement("x", " ")))
        assertEquals("", replaced("", replacement("x", "Y")))
    }

    @Test
    fun `hint targets are the valid written forms`() {
        val replacements = listOf(gitHub, replacement("", "Nothing"), replacement("my mail", "me@example.com"))
        assertEquals(listOf("GitHub", "me@example.com"), WordReplacements.hintTargets(replacements))
        // RecognitionHints decides which of them reads like a term.
        assertEquals(
            listOf("GitHub"),
            RecognitionHints.terms(emptyList(), replacementTargets = WordReplacements.hintTargets(replacements)),
        )
    }

    // Adding

    @Test
    fun `adding joins a row with the same written form`() {
        var list = WordReplacements.adding("get hub", "GitHub", emptyList())
        list = WordReplacements.adding("git  hub", "GitHub", list)
        assertEquals(1, list.size)
        assertEquals(listOf("get hub", "git hub"), list[0].heardForms)
    }

    @Test
    fun `adding moves a heard form to its new row`() {
        var list = WordReplacements.adding("cube control", "kubectl", emptyList())
        list = WordReplacements.adding("Cube Control", "KubeControl", list)
        assertEquals(listOf("KubeControl"), list.map { it.written })
        assertEquals(listOf("Cube Control"), list[0].heardForms)
    }

    @Test
    fun `adding takes every heard form typed with commas`() {
        val list = WordReplacements.adding("get hub, git hub", "GitHub", emptyList())
        assertEquals(1, list.size)
        assertEquals(listOf("get hub", "git hub"), list.single().heardForms)
        assertEquals("GitHub", list.single().written)
        // A form another row had moves, as a single form does.
        val moved = WordReplacements.adding("git hub, gee hub", "Gitea", list)
        assertEquals(listOf("get hub"), moved.first { it.written == "GitHub" }.heardForms)
        assertEquals(listOf("git hub", "gee hub"), moved.first { it.written == "Gitea" }.heardForms)
    }

    @Test
    fun `adding rejects what cannot match`() {
        assertTrue(WordReplacements.adding(" , ", "C", emptyList()).isEmpty())
        assertTrue(WordReplacements.adding(" ", "C", emptyList()).isEmpty())
        assertTrue(WordReplacements.adding("a", " ", emptyList()).isEmpty())
    }

    @Test
    fun `stored as JSON and unreadable storage is empty`() {
        val list = listOf(gitHub)
        assertEquals(list, WordReplacement.decode(WordReplacement.encode(list)))
        assertTrue(WordReplacement.decode("not json").isEmpty())
        assertTrue(WordReplacement.decode(null).isEmpty())
    }

    /** The iOS app writes the same JSON, with an uppercase UUID string for the id. */
    @Test
    fun `reads what iOS writes`() {
        val stored = """[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","heard":"get hub","written":"GitHub"}]"""
        assertEquals(
            listOf(WordReplacement("6F9619FF-8B86-D011-B42D-00C04FC964FF", "get hub", "GitHub")),
            WordReplacement.decode(stored),
        )
    }

    // In the funnel

    private val english = setOf("push", "it", "to", "please", "deploy", "cooper", "netties", "now")

    private fun finished(
        raw: String,
        style: WritingStyle = WritingStyle.CASUAL,
        language: String = "en",
        snippets: List<Snippet> = emptyList(),
        vocabulary: List<String> = emptyList(),
        replacements: List<WordReplacement>,
        unsure: Set<String>? = null,
    ) = DictatedTranscript.finished(
        raw,
        style = style,
        language = language,
        repairSpeech = false,
        numbersAsDigits = true,
        spokenEmoji = false,
        snippets = snippets,
        vocabulary = vocabulary,
        replacements = replacements,
        lowConfidenceWords = unsure,
        isDictionaryWord = { it in english },
    )

    /** After styling, so sentence case cannot undo the user's spelling. */
    @Test
    fun `replacements come after styling`() {
        val lower = replacement("cube control", "kubectl")
        assertEquals("kubectl is slow.", finished("cube control is slow", style = WritingStyle.FORMAL, replacements = listOf(lower)))
        assertEquals("Push it to GitHub please", finished("push it to get hub please", replacements = listOf(gitHub)))
    }

    @Test
    fun `raw gets no replacements`() {
        assertEquals("get hub", finished("get hub", style = WritingStyle.RAW, replacements = listOf(gitHub)))
    }

    @Test
    fun `every language gets replacements`() {
        assertEquals("Schick es an GitHub", finished("schick es an get hub", language = "de", replacements = listOf(gitHub)))
    }

    @Test
    fun `a snippet trigger is never replaced`() {
        val snippet = Snippet("1", "get hub", "https://github.com/me")
        assertEquals(
            "Open https://github.com/me",
            finished("open get hub", snippets = listOf(snippet), replacements = listOf(gitHub)),
        )
    }

    /**
     * Custom words leave a replacement's text alone: "GitHub" is not a near
     * miss of anything once the user has said what it is.
     */
    @Test
    fun `custom words do not touch what a replacement wrote`() {
        val vocal = replacement("vocal phone", "Vocalphone")
        assertEquals("Try Vocalphone", finished("try vocal phone", vocabulary = listOf("VocaPhone"), replacements = listOf(vocal)))
        assertEquals("Try VocaPhone", finished("try vocal phone", vocabulary = listOf("VocaPhone"), replacements = emptyList()))
    }

    @Test
    fun `the engine's doubt reaches correction`() {
        val text = "deploy to cooper netties now"
        assertEquals(
            "Deploy to Kubernetes now",
            finished(text, vocabulary = listOf("Kubernetes"), replacements = emptyList(), unsure = setOf("netties")),
        )
        assertEquals(
            "Deploy to cooper netties now",
            finished(text, vocabulary = listOf("Kubernetes"), replacements = emptyList(), unsure = emptySet()),
        )
        assertEquals(
            "Deploy to cooper netties now",
            finished(text, vocabulary = listOf("Kubernetes"), replacements = emptyList(), unsure = null),
        )
    }
}
