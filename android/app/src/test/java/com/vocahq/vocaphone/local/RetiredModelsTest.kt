package com.vocahq.vocaphone.local

import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Shrinking the catalog is only safe if everyone it stranded lands somewhere
 * sensible. The failure this guards is silent: an unknown id reads back as no
 * selection, and the app re-derives a first-run recommendation, so a phone
 * deliberately running a large model comes back on the smallest one.
 */
class RetiredModelsTest {

    private val phone = 8L
    private val smallPhone = 4L

    @Test
    fun `launch migration writes replacement and notice together`() = runTest {
        var selected = "medium-q5_0"
        var notice = ""
        var enabled = true
        val outcome = RetiredModels.migrate(
            stored = selected,
            totalRamGB = 8,
            replace = { replacement -> selected = replacement; notice = replacement },
            clear = { selected = ""; enabled = false; notice = "" },
        )
        assertEquals(RetiredModels.Outcome.Replaced("large-v3-turbo-q8_0"), outcome)
        assertEquals("large-v3-turbo-q8_0", selected)
        assertEquals(selected, notice)
        assertTrue(enabled)
    }

    @Test
    fun `launch migration clears an unavailable local route`() = runTest {
        var selected = "dolphin-base-ctc"
        var notice = "dolphin-base-ctc"
        var enabled = true
        val outcome = RetiredModels.migrate(
            stored = selected,
            totalRamGB = 2,
            sherpaAvailable = false,
            replace = { replacement -> selected = replacement; notice = replacement },
            clear = { selected = ""; enabled = false; notice = "" },
        )
        assertEquals(RetiredModels.Outcome.Cleared, outcome)
        assertEquals("", selected)
        assertEquals("", notice)
        assertFalse(enabled)
    }

    /**
     * `LocalModelCatalog.sherpaAvailable` reads `Build.SUPPORTED_ABIS`, which is
     * null on the JVM, so every sherpa replacement would be skipped here unless
     * the flag is passed. Named rather than positional so it cannot be mistaken
     * for the RAM argument.
     */
    private fun replacement(
        id: String,
        ram: Long = phone,
        sherpa: Boolean = true,
        languages: Collection<String> = emptyList(),
    ) = RetiredModels.replacementFor(
        id,
        totalRamGB = ram,
        sherpaAvailable = sherpa,
        languages = languages,
    )

    @Test
    fun `every retired id is really gone and every replacement really exists`() {
        for ((retired, replacements) in RetiredModels.replacements) {
            assertNull(
                "$retired is still in the catalog and must not be listed as retired",
                LocalModelCatalog.find(retired),
            )
            assertTrue("$retired has no replacements", replacements.isNotEmpty())
            for (replacement in replacements) {
                assertNotNull(
                    "$retired points at $replacement, which is not in the catalog",
                    LocalModelCatalog.find(replacement),
                )
            }
        }
    }

    @Test
    fun `a model still in the catalog is left alone`() {
        assertFalse(RetiredModels.isRetired("small-q8_0"))
        assertEquals("small-q8_0", replacement("small-q8_0"))
        assertEquals("", replacement(""))
    }

    @Test
    fun `a dropped quantization lands on the surviving build of the same rung`() {
        assertEquals("tiny-q8_0", replacement("tiny-q5_1"))
        assertEquals("base-q8_0", replacement("base-q5_1"))
        assertEquals("small-q8_0", replacement("small-q5_1"))
        // The F16 builds too, which were twice the size for no accuracy gain.
        assertEquals("small-q8_0", replacement("small"))
    }

    @Test
    fun `a dropped english build lands on the multilingual one beside it`() {
        assertEquals("tiny-q8_0", replacement("tiny.en-q8_0"))
        assertEquals("base-q8_0", replacement("base.en"))
        assertEquals("small-q8_0", replacement("small.en-q5_1"))
    }

    /**
     * The case the migration exists for. Someone on Medium chose a heavy model
     * on purpose, so they get the heaviest one still shipping -- not Tiny.
     */
    @Test
    fun `a dropped size promotes rather than falling to the floor`() {
        assertEquals("large-v3-turbo-q8_0", replacement("medium.en"))
        assertEquals("large-v3-turbo-q8_0", replacement("medium-q5_0"))
        assertEquals("large-v3-turbo-q8_0", replacement("large-v2-q8_0"))
        assertEquals("large-v3-turbo-q8_0", replacement("large-v3"))
    }

    /**
     * "Nearest" has to survive the device. Large v3 Turbo needs 6 GB, so a 4 GB
     * phone on Medium steps down the surviving ladder instead of off it.
     */
    @Test
    fun `a promotion the phone cannot hold steps down instead`() {
        assertEquals("small-q8_0", replacement("medium-q5_0", ram = smallPhone))
        assertEquals("base-q8_0", replacement("medium-q5_0", ram = 2))
    }

    @Test
    fun `every moonshine build lands on the small parakeet`() {
        listOf("moonshine-tiny-en", "moonshine-base-en", "moonshine-v2-tiny-en", "moonshine-v2-base-en")
            .forEach { assertEquals(it, "parakeet-tdt-ctc-110m-en", replacement(it, ram = 2)) }
    }

    @Test
    fun `retired sherpa models land on what replaced them`() {
        assertEquals(
            "canary-180m-flash",
            replacement("fast-conformer-ctc-4-lang"),
        )
        // Both Dolphin builds prefer Whisper Large, then Small, then SenseVoice.
        // Empty languages keep the Whisper path, including Small on a 3 GB phone.
        listOf("dolphin-base-ctc", "dolphin-small-ctc").forEach {
            assertEquals(it, "large-v3-turbo-q8_0", replacement(it))
            assertEquals(it, "small-q8_0", replacement(it, ram = 3))
        }
        assertEquals("sense-voice", replacement("paraformer-zh-small", ram = 2))
        // The Russian model kept its weights family and changed id, so that an
        // already-downloaded v2 is swept rather than failing its SHA-256 check.
        assertEquals("giga-am-v3-ru", replacement("giga-am-ctc-ru"))
    }

    @Test
    fun `a sherpa replacement is skipped where sherpa cannot run`() {
        assertNull(
            replacement("fast-conformer-ctc-4-lang", sherpa = false),
        )
        // Whisper replacements are unaffected: that engine is always present,
        // which is also where the retired Dolphin builds land when SenseVoice
        // cannot run.
        assertEquals("large-v3-turbo-q8_0", replacement("dolphin-small-ctc", sherpa = false))
        assertEquals(
            "small-q8_0",
            replacement("dolphin-small-ctc", ram = 3, sherpa = false, languages = listOf("yue")),
        )
        assertEquals(
            "small-q8_0",
            replacement("small.en", sherpa = false),
        )
    }

    /**
     * An id this build does not recognise is what a downgrade looks like, so it
     * is left alone rather than discarded.
     */
    @Test
    fun `an id from neither the catalog nor the retired table is left alone`() {
        assertEquals("something-nobody-shipped", replacement("something-nobody-shipped"))
    }

    /**
     * SenseVoice needs 2 GB, so a 2 GB phone with sherpa can land there. The
     * cleared case is the phone that still has nothing: sherpa is missing, or
     * the device is smaller than every remaining candidate.
     */
    @Test
    fun `a retired model with no replacement this phone can run clears the selection`() {
        assertEquals(
            RetiredModels.Outcome.Cleared,
            RetiredModels.resolve("dolphin-base-ctc", totalRamGB = 2, sherpaAvailable = false),
        )
        assertNull(replacement("dolphin-base-ctc", ram = 2, sherpa = false))
        assertNull(replacement("dolphin-base-ctc", ram = 1))
        assertEquals("sense-voice", replacement("dolphin-base-ctc", ram = 2))
    }

    /**
     * Whisper Small cannot transcribe Cantonese, so a 3 GB Dolphin install
     * that was used for `yue` must not stay on Small. SenseVoice covers it
     * and fits. English, and a migration with no language information, still
     * prefer Small so SenseVoice does not steal those phones.
     */
    @Test
    fun `dolphin retirement prefers a fitting model that still covers the language`() {
        listOf("dolphin-base-ctc", "dolphin-small-ctc").forEach { id ->
            assertEquals(
                id,
                "sense-voice",
                replacement(id, ram = 3, languages = listOf("yue")),
            )
            assertEquals(
                id,
                "large-v3-turbo-q8_0",
                replacement(id, ram = 8, languages = listOf("yue")),
            )
            assertEquals(
                id,
                "small-q8_0",
                replacement(id, ram = 3, languages = listOf("en")),
            )
            assertEquals(
                id,
                "small-q8_0",
                replacement(id, ram = 3, languages = listOf("hi")),
            )
            assertEquals(id, "small-q8_0", replacement(id, ram = 3))
            assertEquals(
                id,
                "sense-voice",
                replacement(id, ram = 2, languages = listOf("yue")),
            )
        }
    }

    /**
     * The language someone chose to dictate in outranks the others the
     * migration collects, and is never traded for a model without it.
     */
    @Test
    fun `the chosen language outranks the others and is never dropped`() {
        fun resolve(id: String, ram: Long, primary: String?, languages: List<String> = emptyList()) =
            RetiredModels.resolve(id, ram, sherpaAvailable = true, languages = languages, primaryLanguage = primary)
        listOf("dolphin-base-ctc", "dolphin-small-ctc").forEach { id ->
            // Cantonese chosen, Hindi also on the phone: nothing covers both,
            // and Small would keep Hindi but lose Cantonese.
            assertEquals(id, RetiredModels.Outcome.Replaced("sense-voice"), resolve(id, 3, "yue", listOf("yue", "hi")))
            // The other way round, Small keeps the chosen Hindi.
            assertEquals(id, RetiredModels.Outcome.Replaced("small-q8_0"), resolve(id, 3, "hi", listOf("hi", "yue")))
        }
        // Hindi chosen on a 2 GB phone: only SenseVoice fits, and it has no
        // Hindi, so the route is cleared as it was before SenseVoice was a rung.
        assertEquals(RetiredModels.Outcome.Cleared, resolve("dolphin-base-ctc", 2, "hi", listOf("hi")))
        // Automatic is not a chosen language.
        assertEquals(RetiredModels.Outcome.Replaced("sense-voice"), resolve("dolphin-base-ctc", 2, "auto"))
        // A ladder that never covered the language ignores it: a stale German
        // setting does not strand a Moonshine user.
        assertEquals(
            RetiredModels.Outcome.Replaced("parakeet-tdt-ctc-110m-en"),
            resolve("moonshine-base-en", 2, "de"),
        )
    }

    @Test
    fun `resolve reports the three outcomes apart`() {
        assertEquals(
            RetiredModels.Outcome.Unchanged,
            RetiredModels.resolve("small-q8_0", totalRamGB = phone, sherpaAvailable = true),
        )
        assertEquals(
            RetiredModels.Outcome.Unchanged,
            RetiredModels.resolve("", totalRamGB = phone, sherpaAvailable = true),
        )
        assertEquals(
            RetiredModels.Outcome.Replaced("large-v3-turbo-q8_0"),
            RetiredModels.resolve("medium.en", totalRamGB = phone, sherpaAvailable = true),
        )
    }

    /**
     * Sherpa is absent from the fdroid flavor and on x86_64, so a retired sherpa
     * model there has nowhere to go either -- and must take the switch with it
     * rather than leaving a dead local route.
     */
    @Test
    fun `a retired sherpa model clears the selection where sherpa cannot run`() {
        assertEquals(
            RetiredModels.Outcome.Cleared,
            RetiredModels.resolve("fast-conformer-ctc-4-lang", totalRamGB = phone, sherpaAvailable = false),
        )
    }
}
