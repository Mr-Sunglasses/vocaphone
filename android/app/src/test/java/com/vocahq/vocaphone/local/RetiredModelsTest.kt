package com.vocahq.vocaphone.local

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

    /**
     * `LocalModelCatalog.sherpaAvailable` reads `Build.SUPPORTED_ABIS`, which is
     * null on the JVM, so every sherpa replacement would be skipped here unless
     * the flag is passed. Named rather than positional so it cannot be mistaken
     * for the RAM argument.
     */
    private fun replacement(id: String, ram: Long = phone, sherpa: Boolean = true) =
        RetiredModels.replacementFor(id, totalRamGB = ram, sherpaAvailable = sherpa)

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
    fun `retired sherpa models land on what replaced them`() {
        // Canary is smaller and more accurate than the Moonshine Base it took over.
        assertEquals("canary-180m-flash", replacement("moonshine-base-en"))
        assertEquals(
            "canary-180m-flash",
            replacement("fast-conformer-ctc-4-lang"),
        )
        assertEquals("dolphin-small-ctc", replacement("dolphin-base-ctc"))
        // The Russian model kept its weights family and changed id, so that an
        // already-downloaded v2 is swept rather than failing its SHA-256 check.
        assertEquals("giga-am-ctc-v3-ru", replacement("giga-am-ctc-ru"))
    }

    @Test
    fun `a sherpa replacement is skipped where sherpa cannot run`() {
        assertNull(
            replacement("dolphin-base-ctc", sherpa = false),
        )
        // Whisper replacements are unaffected: that engine is always present.
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
     * The case a 2 GB phone on Dolphin Base lands in: every replacement wants
     * more memory than it has. Clearing the selection alone would leave
     * on-device transcription switched on with nothing behind it, and
     * `deliverLocal` would record the audio and then fail on every dictation.
     */
    @Test
    fun `a retired model with no replacement this phone can run clears the selection`() {
        assertEquals(
            RetiredModels.Outcome.Cleared,
            RetiredModels.resolve("dolphin-base-ctc", totalRamGB = 2, sherpaAvailable = true),
        )
        assertNull(replacement("dolphin-base-ctc", ram = 2))
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
            RetiredModels.resolve("dolphin-base-ctc", totalRamGB = phone, sherpaAvailable = false),
        )
    }
}
