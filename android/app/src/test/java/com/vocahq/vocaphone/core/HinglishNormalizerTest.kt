package com.vocahq.vocaphone.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * What the normalizer must guarantee, and what it must not do.
 *
 * The guarantees are narrow on purpose. Two of them are absolute — no Devanagari
 * reaches a text field, and no English word is rewritten — and everything else
 * is a spelling convention that a reasonable person could have settled
 * differently. So the strict assertions live on the script and on the words that
 * were genuinely spoken in English; the spelling assertions check one documented
 * choice at a time rather than pinning whole sentences, which would make the
 * suite brittle for no gain.
 */
class HinglishNormalizerTest {

    private fun normalize(text: String) = HinglishNormalizer.normalize(text)

    // --------------------------------------------------------------- script

    @Test
    fun `devanagari never survives`() {
        listOf(
            "आज मुझे office में एक important meeting attend करनी है",
            "कल मेरी client के साथ deployment meeting है",
            "सब कुछ ठीक है।",
            "मैं थोड़ी देर में call करता हूँ",
        ).forEach { spoken ->
            val normalized = normalize(spoken)
            assertFalse(
                "Devanagari leaked from \"$spoken\" as \"$normalized\"",
                HinglishNormalizer.containsDevanagari(normalized),
            )
        }
    }

    @Test
    fun `devanagari is transliterated rather than deleted`() {
        // The failure this rules out is the quiet one: dropping the script
        // instead of converting it loses words the user actually said, and the
        // transcript still looks like a clean sentence.
        val normalized = normalize("मुझे कल जाना है")
        assertEquals(4, normalized.split(" ").size)
        assertTrue(normalized, normalized.contains("mujhe"))
    }

    @Test
    fun `an already roman transcript is left alone`() {
        val roman = "Kal meri client ke saath deployment meeting hai."
        assertEquals(roman, normalize(roman))
    }

    // -------------------------------------------------------------- english

    @Test
    fun `english words spoken in english are preserved verbatim`() {
        val normalized = normalize(
            "मुझे server पर नया deployment करना है और database migrate करना है",
        )
        listOf("server", "deployment", "database", "migrate").forEach { word ->
            assertTrue("lost \"$word\" in \"$normalized\"", normalized.contains(word))
        }
    }

    @Test
    fun `an english homograph of a hindi spelling is not rewritten`() {
        // "men" is में out of the transliterator and the English plural
        // everywhere else. Only the first may become "mein"; rewriting the
        // second is the over-correction this layer exists to avoid.
        assertEquals("Three men joined the call.", normalize("Three men joined the call."))
        assertTrue(normalize("मैं office में हूँ").contains("mein"))
    }

    @Test
    fun `proper nouns and brand names are untouched`() {
        val normalized = normalize("कल Google Meet पर Priya से baat karni hai")
        listOf("Google", "Meet", "Priya").forEach { word ->
            assertTrue("lost \"$word\" in \"$normalized\"", normalized.contains(word))
        }
    }

    // ------------------------------------------------------------ protected

    @Test
    fun `urls emails paths and handles survive every pass`() {
        listOf(
            "docs पर जाओ https://vocahq.com/setup?ref=a_b",
            "मुझे mail करो at yaviral@example.com",
            "फ़ाइल है /var/log/whisper.log में",
            "@priya को tag करो #release में",
        ).forEach { spoken ->
            val protectedSpan = Regex("""\S*(?:://|@|/|#)\S*""").find(spoken)!!.value
            assertTrue(
                "lost \"$protectedSpan\" from \"${normalize(spoken)}\"",
                normalize(spoken).contains(protectedSpan),
            )
        }
    }

    @Test
    fun `a command keeps its flags`() {
        val normalized = normalize("फिर run करो git push --force-with-lease")
        assertTrue(normalized, normalized.contains("--force-with-lease"))
    }

    @Test
    fun `shouted abbreviations keep their capitals`() {
        val normalized = normalize("API का response GPU पर slow है")
        assertTrue(normalized, normalized.contains("API"))
        assertTrue(normalized, normalized.contains("GPU"))
    }

    @Test
    fun `numbers dates and prices are left as they arrived`() {
        val normalized = normalize("meeting है 3:30 बजे और budget है 45,000 रुपये")
        assertTrue(normalized, normalized.contains("3:30"))
        assertTrue(normalized, normalized.contains("45,000"))
    }

    // ------------------------------------------------------------- spelling

    @Test
    fun `one spelling per word, per the documented convention`() {
        // One word per assertion, so a convention change reads as a convention
        // change rather than as a broken sentence.
        assertTrue(normalize("मुझे").contains("mujhe"))
        assertTrue(normalize("muje aana hai").contains("mujhe"))
        assertTrue(normalize("kyu nahi aaye").contains("kyun"))
        assertTrue(normalize("nahi aa raha").contains("nahin"))
        assertTrue(normalize("thik hai").contains("theek"))
    }

    @Test
    fun `hey becomes hai mid-sentence and stays hey as an opener`() {
        assertEquals("Sab theek hai", normalize("Sab theek hey"))
        assertEquals("Hey, kaise ho?", normalize("Hey, kaise ho?"))
    }

    @Test
    fun `case is carried through a rewrite`() {
        assertTrue(normalize("Muje kal jaana hai").startsWith("Mujhe"))
    }

    // -------------------------------------------------------- punctuation

    @Test
    fun `a danda becomes a full stop`() {
        val normalized = normalize("सब ठीक है ।")
        assertTrue(normalized, normalized.endsWith("."))
        assertFalse(normalized, normalized.contains('।'))
    }

    @Test
    fun `spacing around punctuation is tidied without inventing any`() {
        assertEquals("Haan, theek hai.", normalize("Haan ,   theek hai."))
    }

    @Test
    fun `terminators are not added here`() {
        // TranscriptStyler runs after this and owns capitalization and sentence
        // endings for every language. Doing it twice would fight it.
        assertEquals("theek hai", normalize("theek hai"))
    }

    // ----------------------------------------------------------- behaviour

    @Test
    fun `normalizing twice changes nothing the second time`() {
        val once = normalize("आज मुझे office में meeting attend करनी है")
        assertEquals(once, normalize(once))
    }

    @Test
    fun `blank input gives blank output`() {
        assertEquals("", normalize(""))
        assertEquals("", normalize("   \n  "))
    }

    @Test
    fun `each pass can be turned off independently`() {
        val spoken = "muje में jaana hai"
        assertEquals(
            spoken,
            HinglishNormalizer.normalize(
                spoken,
                HinglishNormalizer.Options(
                    transliterateDevanagari = false,
                    applyRomanizedConventions = false,
                    applyGlobalConventions = false,
                    normalizePunctuation = false,
                ),
            ),
        )
        // Transliteration on, conventions off: the mechanical spelling stands.
        assertTrue(
            HinglishNormalizer.normalize(
                "में",
                HinglishNormalizer.Options(applyRomanizedConventions = false),
            ).contains("men"),
        )
    }
}
