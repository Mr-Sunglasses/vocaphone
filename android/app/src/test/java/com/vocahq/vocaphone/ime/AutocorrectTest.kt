package com.vocahq.vocaphone.ime

import android.text.InputType
import com.vocahq.vocaphone.settings.AutocorrectStrength
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AutocorrectTest {

    private val small = SuggestionDictionary(
        words = listOf("the", "and", "you", "that", "what", "want", "help", "hello", "ten", "receive", "going"),
        bigrams = mapOf("be" to listOf("there", "the")),
    )

    private fun strip(
        typed: String,
        before: String = "",
        after: String = "",
        tuning: AutocorrectTuning = AutocorrectTuning.NORMAL,
        dictionary: SuggestionDictionary = small,
        personal: String = "",
        options: (AutocorrectTuning) -> StripOptions = { StripOptions(autocorrect = it) },
    ) = dictionary.strip(typed, before, after, correctionsEnabled = true, personalRaw = personal, options = options(tuning))

    private fun decide(typed: String, vararg candidates: AutocorrectCandidate, sentenceStart: Boolean = true) =
        Autocorrect.decide(
            AutocorrectContext(typed = typed, candidates = candidates.toList(), atSentenceStart = sentenceStart),
        )

    @Test
    fun `a clear typo is corrected and offered beside what was typed`() {
        val strip = strip("teh")
        assertEquals("the", strip.autocorrection)
        assertEquals("teh", strip.forWord)
        assertEquals("the", strip.autocorrectionFor("teh"))
        assertNull(strip.autocorrectionFor("tehx"))
        val kinds = strip.items.map { it.kind }
        assertTrue(SuggestionKind.AUTOCORRECT in kinds)
        assertEquals("the", strip.items.first { it.kind == SuggestionKind.AUTOCORRECT }.text)
    }

    @Test
    fun `the typed capitals carry over to the fix`() {
        assertEquals("The", strip("Teh").autocorrection)
        assertEquals("Receive", strip("Recieve").autocorrection)
    }

    @Test
    fun `known words, personal words and short words stand`() {
        assertNull(strip("the").autocorrection)
        assertNull(strip("helo", personal = "Helo").autocorrection)
        assertNull(strip("te").autocorrection)
    }

    @Test
    fun `two equally near readings are a coin toss and stand`() {
        // "hepl" is a swap from help and nothing else; "helo" is help or hello.
        assertEquals("help", decide("hepl", AutocorrectCandidate("help", 50, 1), AutocorrectCandidate("hello", 2000, 2)).replacement)
        val ambiguous = decide("helo", AutocorrectCandidate("help", 75, 1), AutocorrectCandidate("hello", 2500, 1))
        assertTrue(ambiguous is AutocorrectDecision.Refused)
    }

    @Test
    fun `the previous word breaks a tie`() {
        val both = arrayOf(AutocorrectCandidate("for", 10, 1), AutocorrectCandidate("got", 10, 1))
        assertTrue(Autocorrect.decide(AutocorrectContext("fot", candidates = both.toList())) is AutocorrectDecision.Refused)
        assertEquals(
            "got",
            Autocorrect.decide(AutocorrectContext("fot", candidates = both.toList(), followers = setOf("got"))).replacement,
        )
    }

    @Test
    fun `addresses, handles, numbers and shouting are left alone`() {
        assertNull(strip("goign", before = "www.").autocorrection)
        assertNull(strip("goign", before = "mail me at me@").autocorrection)
        assertNull(strip("goign", before = "3").autocorrection)
        assertNull(strip("TEH").autocorrection)
        // Mid-word: only a prefix of the word is in hand.
        assertNull(strip("teh", after = "re").autocorrection)
        // An opening bracket or quote is fine.
        assertEquals("going", strip("goign", before = "so (").autocorrection)
    }

    @Test
    fun `a capital mid-sentence is a name, at the start of one it is not`() {
        assertNull(strip("Goign", before = "I saw ").autocorrection)
        assertEquals("Going", strip("Goign", before = "Done. ").autocorrection)
        assertEquals("Going", strip("Goign").autocorrection)
    }

    @Test
    fun `a word put back in this field or undone twice is not corrected again`() {
        assertNull(strip("teh", options = { StripOptions(autocorrect = it, asserted = setOf("teh")) }).autocorrection)
        val rejected = AutocorrectMemory.EMPTY.withRejection("teh", "the").withRejection("teh", "the")
        assertTrue(strip("teh", options = { StripOptions(autocorrect = it, memory = rejected) }).autocorrection != "the")
    }

    @Test
    fun `a blocked word is never the fix`() {
        val blocked = strip("teh", options = { StripOptions(autocorrect = it, blocked = setOf("the")) })
        assertTrue(blocked.autocorrection != "the")
        assertFalse("the" in blocked.words)
    }

    @Test
    fun `off when the field or the setting says so`() {
        assertNull(small.strip("teh", "", "", true).autocorrection)
    }

    @Test
    fun `the short word table fixes what the list cannot`() {
        assertEquals("I", strip("i").autocorrection)
        assertEquals("I'm", strip("im").autocorrection)
        assertEquals("Don't", strip("Dont").autocorrection)
        assertEquals("can't", ShortWordCorrections.replacement("cant"))
        assertNull(strip("DONT").autocorrection)
        assertNull(ShortWordCorrections.replacement("its"))
        assertEquals("I", ShortWordCorrections.beforeApostrophe("i"))
        assertNull(ShortWordCorrections.beforeApostrophe("I"))
    }

    @Test
    fun `swaps and doubles cost less than other slips`() {
        assertTrue(Autocorrect.editCost("teh", "the") < Autocorrect.editCost("tex", "the"))
        assertTrue(Autocorrect.editCost("realy", "really") < Autocorrect.editCost("rely", "relay") + 0.5f)
        assertTrue(Autocorrect.editCost("tge", "the") < Autocorrect.editCost("tpe", "the"))
        assertTrue(Autocorrect.isTransposition("teh", "the"))
        assertFalse(Autocorrect.isTransposition("teh", "ten"))
    }

    @Test
    fun `strength scales how sure a correction has to be`() {
        assertEquals(AutocorrectTuning.MILD, AutocorrectTuning.of(AutocorrectStrength.MILD))
        assertEquals(AutocorrectTuning.NORMAL, AutocorrectTuning.of(AutocorrectStrength.DEFAULT))
        // Two edits: never on Mild.
        val twoEdits = AutocorrectCandidate("tomorrow", 900, 2)
        assertTrue(Autocorrect.decide(AutocorrectContext("tommorow", candidates = listOf(twoEdits), tuning = AutocorrectTuning.MILD)) is AutocorrectDecision.Refused)
        assertEquals("tomorrow", Autocorrect.decide(AutocorrectContext("tommorow", candidates = listOf(twoEdits))).replacement)
    }

    @Test
    fun `fields where Gboard would not correct`() {
        val text = InputType.TYPE_CLASS_TEXT
        assertTrue(Autocorrect.allowedIn(text))
        assertTrue(Autocorrect.allowedIn(text or InputType.TYPE_TEXT_FLAG_MULTI_LINE or InputType.TYPE_TEXT_VARIATION_SHORT_MESSAGE))
        assertFalse(Autocorrect.allowedIn(text or InputType.TYPE_TEXT_VARIATION_PASSWORD))
        assertFalse(Autocorrect.allowedIn(text or InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS))
        assertFalse(Autocorrect.allowedIn(text or InputType.TYPE_TEXT_VARIATION_URI))
        assertFalse(Autocorrect.allowedIn(text or InputType.TYPE_TEXT_VARIATION_PERSON_NAME))
        assertFalse(Autocorrect.allowedIn(text or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS))
        assertFalse(Autocorrect.allowedIn(text or InputType.TYPE_TEXT_FLAG_AUTO_COMPLETE))
        assertFalse(Autocorrect.allowedIn(text or InputType.TYPE_TEXT_VARIATION_WEB_EDIT_TEXT))
        assertTrue(
            Autocorrect.allowedIn(text or InputType.TYPE_TEXT_VARIATION_WEB_EDIT_TEXT or InputType.TYPE_TEXT_FLAG_AUTO_CORRECT),
        )
        assertFalse(Autocorrect.allowedIn(InputType.TYPE_CLASS_NUMBER))
    }

    /**
     * The threshold, held against the shipped list: common typos corrected,
     * chat words, names and ambiguous typos left as typed.
     */
    @Test
    fun `shipped list corrects common typos and leaves chat words alone`() {
        val file = generateSequence(java.io.File("").absoluteFile) { it.parentFile }
            .map { java.io.File(it, "assets/keyboard/en.txt") }
            .firstOrNull(java.io.File::isFile)
        org.junit.Assume.assumeTrue("assets/keyboard is only present in the repository", file != null)
        requireNotNull(file)
        val dictionary = SuggestionDictionary(
            words = file.readLines().map { it.trim() }.filter { it.isNotEmpty() },
            bigrams = SuggestionDictionary.parseBigrams(java.io.File(file.parentFile, "en-bigrams.txt").readLines()),
        )
        val fixes = mapOf(
            "teh" to "the", "adn" to "and", "hte" to "the", "taht" to "that", "waht" to "what", "jsut" to "just",
            "knwo" to "know", "woudl" to "would", "becuase" to "because", "recieve" to "receive", "thier" to "their",
            "occured" to "occurred", "untill" to "until", "beleive" to "believe", "freind" to "friend",
            "goverment" to "government", "thnaks" to "thanks", "yuo" to "you", "realy" to "really", "whcih" to "which",
            "tge" to "the", "cna" to "can", "nto" to "not", "ahve" to "have", "wrok" to "work", "wolrd" to "world",
            "tomorow" to "tomorrow", "agian" to "again", "goign" to "going", "meetign" to "meeting", "wiht" to "with",
            "whne" to "when", "thsi" to "this", "comming" to "coming", "writting" to "writing", "finaly" to "finally",
        )
        for ((typo, fix) in fixes) {
            assertEquals(typo, fix, strip(typo, dictionary = dictionary).autocorrection)
        }
        val stands = listOf(
            "helo", "wierd", "happend", "pls", "plz", "gona", "wanna", "lol", "omw", "btw", "haha", "kinda", "yeah",
            "okay", "alot", "anyways", "tho", "sry", "thx", "covid", "zoom", "vocaphone", "iphone", "msg", "txt",
            "tonite", "monday",
        )
        for (word in stands) {
            assertNull(word, strip(word, dictionary = dictionary).autocorrection)
        }
    }
}
