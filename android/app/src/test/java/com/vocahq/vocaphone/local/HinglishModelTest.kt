package com.vocahq.vocaphone.local

import com.vocahq.vocaphone.core.ModelLanguageSupport
import com.vocahq.vocaphone.core.TranscriptionLanguage
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The catalog and picker side of Roman Hinglish: who may reach it, what it
 * claims, and what it must never be mistaken for.
 *
 * Every assertion here is about containment. The mode is experimental, it is one
 * model, and it produces text no other model in the catalog produces — so the
 * risk is not that it fails, it is that it leaks: into a recommendation, into
 * another language's decode, or into the translate row.
 */
class HinglishModelTest {

    private val hinglish = requireNotNull(
        LocalModelCatalog.find("hinglish-apex-large-v3-turbo-q5_0"),
    )

    private val roman = TranscriptionLanguage.HINGLISH_ROMAN.wireValue

    @Test
    fun `the model is pinned by repository, revision and digest`() {
        assertEquals("Marquestra/Whisper-Hindi2Hinglish-Apex-GGML", hinglish.repository)
        assertEquals(40, hinglish.revision.length)
        assertEquals(1, hinglish.files.size)
        hinglish.files.forEach { file ->
            assertEquals("SHA-256 is 64 hex characters", 64, file.sha256.length)
            assertTrue(file.sha256.all { it in "0123456789abcdef" })
            assertTrue(file.sizeBytes > 0)
        }
        assertEquals(hinglish.files.sumOf { it.sizeBytes }, hinglish.sizeBytes)
    }

    @Test
    fun `the download url is built from the pin and nothing else`() {
        assertEquals(
            "https://huggingface.co/Marquestra/Whisper-Hindi2Hinglish-Apex-GGML/resolve/" +
                "${hinglish.revision}/ggml-apex-hinglish-q5_0.bin",
            LocalModelCatalog.downloadUrl(hinglish, hinglish.primaryFile),
        )
    }

    @Test
    fun `it claims the output script and no language`() {
        // Claiming "hi" would be the tempting lie. It does not transcribe Hindi
        // — it transcribes Hindi into Latin — and a user who picked Hindi
        // expecting Devanagari would get neither an error nor what they asked
        // for.
        assertEquals(setOf(roman), hinglish.languageCodes)
        assertFalse(hinglish.coversLanguage("hi"))
        assertFalse(hinglish.coversLanguage("en"))
        assertTrue(hinglish.producesFixedScript)
    }

    @Test
    fun `it is never offered as a recommendation`() {
        val languages = listOf("hi", "en", "de", "bn", "ta")
        val budgets = listOf(2L, 3L, 4L, 6L, 8L, 12L)
        for (language in languages) {
            for (ram in budgets) {
                val profile = DeviceProfile(
                    totalRamGB = ram,
                    cpuCores = 8,
                    performanceClass = 33,
                    abi = "arm64-v8a",
                    maxCpuKHz = 2_400_000,
                    sherpaAvailable = true,
                    language = language,
                )
                assertFalse(
                    "recommended for $language at ${ram}GB",
                    LocalModelCatalog.recommendations(profile).any { it.model.id == hinglish.id },
                )
                assertTrue(LocalModelCatalog.recommended(profile).id != hinglish.id)
            }
        }
    }

    @Test
    fun `it cannot translate`() {
        // Whisper's translate task is still in there — it is the same decoder —
        // and offering the row would hand back the English translation this mode
        // exists to avoid.
        assertTrue(hinglish.translationTargets.isEmpty())
        assertEquals("", hinglish.resolveTranslationTarget("en", "hi"))
    }

    @Test
    fun `the roman row needs a model that says so in as many words`() {
        val language = TranscriptionLanguage.HINGLISH_ROMAN
        assertTrue(ModelLanguageSupport.isSelectable(language, setOf(roman)))
        assertFalse(ModelLanguageSupport.isSelectable(language, setOf("hi", "en")))
        // Silence is a no here, unlike every ordinary language: an unknown
        // gateway has certainly not been taught this value, and offering it
        // would produce Devanagari or an English translation.
        assertFalse(ModelLanguageSupport.isSelectable(language, emptySet()))
    }

    @Test
    fun `ordinary languages still default to selectable when nothing is claimed`() {
        // The rule above must not have narrowed anything else.
        listOf(TranscriptionLanguage.HINDI, TranscriptionLanguage.ENGLISH).forEach { language ->
            assertTrue(ModelLanguageSupport.isSelectable(language, emptySet()))
        }
    }

    @Test
    fun `a stale roman choice falls back to automatic`() {
        assertEquals(
            TranscriptionLanguage.AUTOMATIC,
            ModelLanguageSupport.resolve(TranscriptionLanguage.HINGLISH_ROMAN, setOf("hi", "en")),
        )
    }

    @Test
    fun `the decoder is asked for hindi and the transcript stays roman`() {
        // The token is a whisper implementation detail; the transcript language
        // is the contract the normalizer and the writing styles read.
        assertEquals("hi", ModelLanguageSupport.decoderLanguage(roman))
        assertEquals(roman, ModelLanguageSupport.transcriptLanguage(roman, reported = "hi"))
        assertEquals(roman, ModelLanguageSupport.outputLanguage(roman, "hi", translateTo = ""))
    }

    @Test
    fun `no other language is routed through this mapping`() {
        listOf("hi", "en", "auto", "de", "").forEach { code ->
            assertEquals(code, ModelLanguageSupport.decoderLanguage(code))
        }
    }

    @Test
    fun `no other model claims the roman code`() {
        val claiming = LocalModelCatalog.all.filter { roman in it.languageCodes }
        assertEquals(listOf(hinglish.id), claiming.map { it.id })
    }

    @Test
    fun `the label says experimental where a user will read it`() {
        assertTrue(hinglish.experimental)
        assertTrue(hinglish.displayName.contains("Experimental"))
        assertTrue(TranscriptionLanguage.HINGLISH_ROMAN.isExperimental)
        assertTrue(TranscriptionLanguage.HINGLISH_ROMAN.detail.contains("Experimental"))
        assertEquals("Hinglish", TranscriptionLanguage.HINGLISH_ROMAN.shortLabel)
    }

    @Test
    fun `nothing else in the catalog became experimental`() {
        assertEquals(
            listOf(hinglish.id),
            LocalModelCatalog.all.filter { it.experimental }.map { it.id },
        )
    }

    @Test
    fun `it runs on whisper cpp, so it needs no sherpa jni`() {
        assertEquals(LocalModelEngine.WHISPER, hinglish.engine)
        assertNotNull(LocalModelCatalog.find(hinglish.id))
        assertTrue(LocalModelCatalog.isUsableOnDevice(hinglish, 6L, sherpaAvailable = false))
        assertFalse(LocalModelCatalog.isUsableOnDevice(hinglish, 3L, sherpaAvailable = false))
    }
}
