package com.vocahq.vocaphone.core

import java.io.File
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DictationToneTest {

    @Test
    fun `catalog ids and display names are the family list`() {
        assertEquals(
            listOf(
                "lift" to "Lift",
                "flick" to "Flick",
                "ember" to "Ember",
                "step" to "Step",
                "voca" to "Voca",
                "soft" to "Soft",
                "chirp" to "Chirp",
                "scale" to "Scale",
                "drop" to "Drop",
                "glass" to "Glass",
                "off" to "Off",
            ),
            DictationTone.entries.map { it.id to it.displayName },
        )
    }

    @Test
    fun `phone default is Voca`() {
        assertEquals(DictationTone.VOCA, DictationTone.DEFAULT)
        assertEquals("voca", DictationTone.DEFAULT.id)
    }

    @Test
    fun `an unset preference lands on Voca, not Off`() {
        assertEquals(DictationTone.VOCA, DictationTone.fromStored(null))
        assertEquals(DictationTone.VOCA, DictationTone.fromStored(""))
        assertEquals(DictationTone.VOCA, DictationTone.fromStored("   "))
    }

    @Test
    fun `an unknown stored id lands on Voca`() {
        assertEquals(DictationTone.VOCA, DictationTone.fromStored("no-such-tone"))
    }

    @Test
    fun `Off stays Off once it was saved`() {
        assertEquals(DictationTone.OFF, DictationTone.fromStored("off"))
        assertEquals(DictationTone.OFF, DictationTone.fromStored("Off"))
        assertTrue(DictationTone.OFF.playsCues.not())
    }

    @Test
    fun `a saved tone other than the default is left alone`() {
        assertEquals(DictationTone.LIFT, DictationTone.fromStored("lift"))
        assertEquals(DictationTone.GLASS, DictationTone.fromStored("glass"))
    }

    @Test
    fun `Off plays nothing`() {
        assertFalse(cueFile("off", "start").exists())
        assertFalse(cueFile("off", "stop").exists())
        assertTrue(DictationTone.OFF.playsCues.not())
    }

    @Test
    fun `shipped cues are the preview WAV bytes`() {
        CUE_BYTES.forEach { (id, startBytes, stopBytes) ->
            val start = cueFile(id, "start").readBytes()
            val stop = cueFile(id, "stop").readBytes()
            assertArrayEquals("$id start is not RIFF", RIFF, start.copyOf(4))
            assertArrayEquals("$id stop is not RIFF", RIFF, stop.copyOf(4))
            assertEquals("$id start length", startBytes, start.size)
            assertEquals("$id stop length", stopBytes, stop.size)
        }
    }

    @Test
    fun `every audible tone has a start and stop cue`() {
        DictationTone.entries.filter { it.playsCues }.forEach { tone ->
            assertTrue("${tone.id} start is missing", cueFile(tone.id, "start").isFile)
            assertTrue("${tone.id} stop is missing", cueFile(tone.id, "stop").isFile)
        }
    }

    private companion object {
        val RIFF = byteArrayOf('R'.code.toByte(), 'I'.code.toByte(), 'F'.code.toByte(), 'F'.code.toByte())

        val CUE_BYTES = listOf(
            Triple("lift", 52_964, 52_964),
            Triple("flick", 28_268, 28_268),
            Triple("ember", 44_144, 44_144),
            Triple("step", 23_858, 23_858),
            Triple("voca", 19_448, 19_448),
            Triple("soft", 7_100, 7_982),
            Triple("chirp", 15_920, 15_920),
            Triple("scale", 35_324, 35_324),
            Triple("drop", 39_734, 44_144),
            Triple("glass", 22_812, 24_176),
        )

        fun cueFile(id: String, kind: String): File {
            val name = "dictation_tone_${id}_$kind.wav"
            return listOf(
                File("src/main/res/raw/$name"),
                File("app/src/main/res/raw/$name"),
            ).firstOrNull { it.isFile } ?: File("src/main/res/raw/$name")
        }
    }
}
