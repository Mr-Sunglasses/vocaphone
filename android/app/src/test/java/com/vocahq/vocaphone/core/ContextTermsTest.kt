package com.vocahq.vocaphone.core

import com.vocahq.vocaphone.local.LocalModelCatalog
import com.vocahq.vocaphone.local.hotwordSearchFor
import com.vocahq.vocaphone.local.sherpaHotwords
import com.vocahq.vocaphone.local.whisperPrompt
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Mirrors the iOS client's `ContextTermsTests`. The extraction cases are
 * VocaMac's `ScreenContextTermsTests`, which this is ported from.
 */
class ContextTermsTest {

    private val common = setOf(
        "func", "let", "ping", "about", "the", "and", "keys", "in", "tomorrow", "we", "ship",
        "check", "apple", "notes", "and", "so", "on", "send", "email", "setup", "now", "open",
        "push", "it", "to", "ask", "call", "by", "id", "get", "user", "hi", "can", "you",
        "please", "bump", "export", "then",
    )
    private val isKnown: (String) -> Boolean = { it.lowercase() in common }

    // Extraction

    @Test
    fun `extracts identifiers and names`() {
        val text = """
            func loadUser(userId: String) { let max_retries = 3 }
            Ping Namrata about the GitHub and OpenAI keys in api-client.
        """.trimIndent()
        val terms = ContextTerms.extractFrom(text, isKnownWord = isKnown)
        for (expected in listOf("loadUser", "userId", "max_retries", "Namrata", "GitHub", "OpenAI", "api-client")) {
            assertTrue("$expected in $terms", expected in terms)
        }
    }

    @Test
    fun `skips sentence starts and ordinary capitalized words`() {
        val terms = ContextTerms.extractFrom("Tomorrow we ship. Check the Apple notes.", isKnownWord = isKnown)
        assertFalse("Tomorrow" in terms)
        assertFalse("Check" in terms)
        assertFalse("Apple" in terms)
    }

    @Test
    fun `most relevant terms come first`() {
        val filler = "and so on ".repeat(40)
        val text = "farAwayName " + filler + "nearCaret " + filler + "lastName repeatedTerm repeatedTerm"
        val terms = ContextTerms.extractFrom(text, isKnownWord = isKnown)
        // Shown twice beats shown once; then nearest the caret, here the middle.
        assertEquals("repeatedTerm", terms[0])
        assertEquals("nearCaret", terms[1])
        assertEquals(setOf("repeatedTerm", "nearCaret", "farAwayName", "lastName"), terms.toSet())
    }

    @Test
    fun `the cursor is where nearness is measured from`() {
        val filler = "and so on ".repeat(20)
        val terms = ContextTerms.extract(
            before = "Hi Namrata, " + filler + "can you ask Siddharth ",
            after = filler + "about Kubernetes",
            isKnownWord = isKnown,
        )
        assertEquals(listOf("Siddharth", "Kubernetes", "Namrata"), terms)
    }

    @Test
    fun `deduplicates and caps`() {
        val text = (0 until 400).joinToString(" ") { "varName$it" } + " varName0"
        val terms = ContextTerms.extractFrom(text, isKnownWord = isKnown)
        assertEquals(ContextTerms.MAX_TERMS, terms.size)
        assertEquals("varName0", terms.first())
    }

    @Test
    fun `reads a thousand characters either side of the cursor`() {
        val filler = "x".repeat(ContextTerms.MAX_CHARACTERS_EACH_SIDE)
        assertTrue(ContextTerms.extract("farBefore $filler", "$filler farAfter", isKnown).isEmpty())
        assertEquals(
            listOf("nearBefore"),
            ContextTerms.extract(before = "nearBefore " + filler.drop(11), after = null, isKnownWord = isKnown),
        )
    }

    @Test
    fun `acronyms that are not ordinary words`() {
        val terms = ContextTerms.extractFrom("PLEASE bump CUDA and the ONNX export, then OAuth.", isKnownWord = isKnown)
        assertEquals(setOf("CUDA", "ONNX", "OAuth"), terms.toSet())
    }

    @Test
    fun `without a word list only the shapes are kept`() {
        assertEquals(listOf("GitHub"), ContextTerms.extractFrom("Ping Namrata about GitHub.") { true })
    }

    @Test
    fun `a word inside a longer one is not a term`() {
        // Accented letters and underscores continue a word, as `\b` would say.
        assertTrue(ContextTerms.extractFrom("see ÉcoleTest and _privateName", isKnownWord = isKnown).isEmpty())
    }

    // Correction

    private fun correct(text: String, terms: List<String>, vocabulary: List<String> = emptyList()) =
        ContextTerms.correct(text, terms, vocabulary, isKnown)

    @Test
    fun `spells an exact letter match the way the field does`() {
        assertEquals("push it to GitHub now", correct("push it to git hub now", listOf("GitHub")))
        assertEquals("ask Namrata about it", correct("ask namrata about it", listOf("Namrata")))
        assertEquals("GitHub's down", correct("Github's down", listOf("GitHub")))
    }

    @Test
    fun `never a near miss`() {
        assertEquals("ask namrta about it", correct("ask namrta about it", listOf("Namrata")))
        assertEquals("push it to git hubs", correct("push it to git hubs", listOf("GitHub")))
    }

    @Test
    fun `the user's own spelling wins`() {
        assertEquals("open Vocaphone", correct("open Vocaphone", listOf("VOCAPHONE"), listOf("Vocaphone")))
        assertEquals("open vocaphone", correct("open vocaphone", listOf("VocaPhone"), listOf("Vocaphone")))
    }

    @Test
    fun `an ordinary word is never respelled`() {
        assertEquals("send the email now", correct("send the email now", listOf("e-mail")))
        assertEquals("send the setup now", correct("send the setup now", listOf("setUp")))
        assertEquals("check the apple notes", correct("check the apple notes", listOf("APPLE")))
        // A word that is not one still takes the field's spelling.
        assertEquals("open voca-mac now", correct("open vocamac now", listOf("voca-mac")))
    }

    @Test
    fun `an identifier never joins words`() {
        assertEquals("call get user by id", correct("call get user by id", listOf("getUserById")))
        assertEquals("call getUserById", correct("call getuserbyid", listOf("getUserById")))
    }

    @Test
    fun `a protected word is left alone`() {
        assertEquals("git hub sig", ContextTerms.correct("git hub sig", listOf("GitHub"), protectedRanges = listOf(0..2)))
    }

    @Test
    fun `is identifier shaped`() {
        for (term in listOf("userId", "iPhone", "max_retries", "api-client", "varName0")) {
            assertTrue(term, ContextTerms.isIdentifierShaped(term))
        }
        assertFalse(ContextTerms.isIdentifierShaped("GitHub"))
        assertFalse(ContextTerms.isIdentifierShaped("Namrata"))
    }

    // The funnel and the hints

    @Test
    fun `the funnel spells context terms after the vocabulary`() {
        fun finish(raw: String, style: WritingStyle = WritingStyle.CASUAL, vocabulary: List<String> = emptyList()) =
            // Styled upstream, so the words are exactly the ones checked.
            DictatedTranscript.finished(
                raw, style = style, language = "en", styledUpstream = true, repairSpeech = false,
                vocabulary = vocabulary, isDictionaryWord = { it in common },
                contextTerms = listOf("GitHub", "Namrata"),
            )
        assertEquals("ask Namrata to push it to GitHub", finish("ask namrata to push it to git hub"))
        assertEquals("ask namrata", finish("ask namrata", style = WritingStyle.RAW))
        assertEquals("ask NAMRATA", finish("ask namrata", vocabulary = listOf("NAMRATA")))
    }

    @Test
    fun `context terms reach whisper's prompt and qwen3's hotwords after the user's words`() {
        assertEquals("Kanishk, GitHub, Namrata.", whisperPrompt("Kanishk", contextTerms = listOf("GitHub", "Namrata")))
        val qwen = requireNotNull(LocalModelCatalog.find("qwen3-asr-0.6b"))
        assertEquals("Kanishk,GitHub,Namrata", sherpaHotwords(qwen, "Kanishk", contextTerms = listOf("GitHub", "Namrata")))
        // Qwen3-ASR takes them as a stream option, so they need no list of the user's.
        assertEquals("GitHub,Namrata", sherpaHotwords(qwen, "", contextTerms = listOf("GitHub", "Namrata")))
    }

    private val unified = requireNotNull(LocalModelCatalog.find("parakeet-unified-0.6b-en"))
    private val context = listOf("GitHub", "Namrata")

    @Test
    fun `with no list of the user's, context keeps parakeet unified on greedy search everywhere`() {
        // warm, warmAhead, prepare, the incremental session and transcribe all
        // ask hotwordSearchFor, which takes no context.
        assertFalse(hotwordSearchFor(unified, "", emptyList()))
        // And the decode hands a greedy recognizer no hotwords, whatever the cursor held.
        assertNull(sherpaHotwords(unified, "", emptyList(), context))
        assertNull(RecognitionHints.sherpaHotwords(unified, emptyList(), emptyList(), context))
    }

    @Test
    fun `with a list of the user's, context joins parakeet unified's hotwords after it`() {
        assertTrue(hotwordSearchFor(unified, "Kanishk", emptyList()))
        assertEquals("Kanishk/GitHub/Namrata", sherpaHotwords(unified, "Kanishk", emptyList(), context))
        assertEquals("Kanishk/GitHub/Namrata", sherpaHotwords(unified, "", listOf("Kanishk"), context))
        // The 64-term cap cuts the cursor's terms, never the user's.
        val user = (1..60).map { "User$it" }
        val many = (1..30).map { "Screen$it" }
        val kept = requireNotNull(
            RecognitionHints.sherpaHotwords(unified, user, emptyList(), many),
        ).split("/")
        assertEquals(RecognitionHints.MAX_TRANSDUCER_HOTWORDS, kept.size)
        assertEquals(user, kept.take(60))
        assertEquals(listOf("Screen1", "Screen2", "Screen3", "Screen4"), kept.drop(60))
    }
}
