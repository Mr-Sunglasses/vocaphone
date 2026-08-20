package com.vocahq.vocaphone.ui

import com.vocahq.vocaphone.core.DictationTone
import com.vocahq.vocaphone.core.MicrophonePreference
import com.vocahq.vocaphone.core.WritingStyle
import com.vocahq.vocaphone.settings.AudioRetention
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SettingsChoiceTest {

    @Test
    fun `dropdown options still write the same stored values`() {
        assertEquals("voca", DictationTone.VOCA.id)
        assertEquals("off", DictationTone.OFF.id)
        assertEquals("automatic", MicrophonePreference.AUTOMATIC.storedValue)
        assertEquals("phone", MicrophonePreference.PHONE.storedValue)
        assertEquals("bluetooth", MicrophonePreference.BLUETOOTH.storedValue)
        assertEquals(1, AudioRetention.ONE_HOUR.hours)
        assertEquals(6, AudioRetention.SIX_HOURS.hours)
        assertEquals(24, AudioRetention.ONE_DAY.hours)

        assertEquals(DictationTone.VOCA, DictationTone.fromStored("voca"))
        assertEquals(MicrophonePreference.AUTOMATIC, MicrophonePreference.fromStored("automatic"))
        assertEquals(AudioRetention.SIX_HOURS, AudioRetention.fromHours(6))
    }

    @Test
    fun `dropdown option sets and defaults are unchanged`() {
        assertEquals(
            listOf("Lift", "Flick", "Ember", "Step", "Voca", "Soft", "Chirp", "Scale", "Drop", "Glass", "Off"),
            DictationTone.entries.map { it.displayName },
        )
        assertFalse(DictationTone.entries.any { it.displayName.equals("Fifth", ignoreCase = true) })
        assertEquals(DictationTone.VOCA, DictationTone.DEFAULT)
        assertEquals(MicrophonePreference.AUTOMATIC, MicrophonePreference.DEFAULT)
        assertEquals(AudioRetention.SIX_HOURS, AudioRetention.DEFAULT)
        assertEquals(3, AudioRetention.entries.size)
        assertEquals(5, MicrophonePreference.entries.size)
    }

    @Test
    fun `every dropdown option has a one-line explanation`() {
        DictationTone.entries.forEach { assertTrue(it.detail.isNotBlank()) }
        MicrophonePreference.entries.forEach { assertTrue(it.detail.isNotBlank()) }
        AudioRetention.entries.forEach { assertTrue(it.detail.isNotBlank()) }
        WritingStyle.entries.forEach { assertTrue(it.detail.isNotBlank()) }
    }
}
