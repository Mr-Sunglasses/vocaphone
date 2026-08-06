package io.github.mrsunglasses.localflow.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class MicrophonePreferenceTest {

    @Test
    fun `stored values survive a round trip`() {
        MicrophonePreference.entries.forEach { preference ->
            assertEquals(preference, MicrophonePreference.fromStored(preference.storedValue))
        }
    }

    /** These strings are on disk in every install; renaming one silently resets it. */
    @Test
    fun `stored values are the literals already written to settings`() {
        assertEquals(
            listOf("automatic", "phone", "wired", "bluetooth", "usb"),
            MicrophonePreference.entries.map { it.storedValue },
        )
    }

    @Test
    fun `an install predating the setting reads back as automatic`() {
        assertEquals(MicrophonePreference.AUTOMATIC, MicrophonePreference.fromStored(null))
    }

    @Test
    fun `a category this build no longer knows reads back as automatic`() {
        assertEquals(MicrophonePreference.AUTOMATIC, MicrophonePreference.fromStored("hdmi"))
    }

    @Test
    fun `automatic is the first option offered, as it is on iOS`() {
        assertEquals(MicrophonePreference.AUTOMATIC, MicrophonePreference.entries.first())
        assertEquals(MicrophonePreference.AUTOMATIC, MicrophonePreference.DEFAULT)
    }

    @Test
    fun `every option explains itself differently in both states`() {
        val details = MicrophonePreference.entries.map { it.detail }
        assertEquals(details.size, details.distinct().size)

        MicrophonePreference.entries
            .filterNot { it == MicrophonePreference.AUTOMATIC }
            .forEach { preference ->
                assertNotEquals(preference.detail, preference.unavailableDetail)
                assertTrue(
                    "${preference.name} does not say what is missing",
                    preference.unavailableDetail.startsWith("No "),
                )
            }
    }
}
