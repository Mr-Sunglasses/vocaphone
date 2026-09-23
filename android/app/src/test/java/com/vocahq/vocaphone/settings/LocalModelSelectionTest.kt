package com.vocahq.vocaphone.settings

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The guard that keeps a stale on-device selection from reaching the microphone.
 *
 * The launch migration moves a stored id off a model that has left the catalog,
 * but it runs in a coroutine and a dictation can start before it finishes -- or
 * be cancelled by its own timeout part way through. Neither case may end with a
 * recorded dictation that fails at delivery, so the state is checked where
 * dictation starts rather than trusted to have been repaired.
 */
class LocalModelSelectionTest {

    private fun settings(enabled: Boolean, id: String) = VocaPhoneSettings(
        localTranscriptionEnabled = enabled,
        localModelId = id,
    )

    @Test
    fun `a model still in the catalog is usable`() {
        assertFalse(settings(enabled = true, id = "small-q8_0").localModelMissing)
    }

    /** The exact state an un-run or half-run migration leaves behind. */
    @Test
    fun `a retired id with on-device still enabled is reported missing`() {
        assertTrue(settings(enabled = true, id = "medium.en-q5_0").localModelMissing)
        assertTrue(settings(enabled = true, id = "dolphin-base-ctc").localModelMissing)
        assertTrue(settings(enabled = true, id = "moonshine-base-en").localModelMissing)
    }

    /**
     * The half-applied clear the atomic write now prevents: no selection, switch
     * still on. Reported rather than recorded, whichever way it was reached.
     */
    @Test
    fun `an empty selection with on-device still enabled is reported missing`() {
        assertTrue(settings(enabled = true, id = "").localModelMissing)
    }

    @Test
    fun `nothing is reported when the gateway route is selected`() {
        assertFalse(settings(enabled = false, id = "").localModelMissing)
        assertFalse(settings(enabled = false, id = "medium.en-q5_0").localModelMissing)
    }
}
