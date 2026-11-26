package com.vocahq.vocaphone.ime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ClipboardPrivacyTest {
    @Test
    fun theKeyIsThePlatformConstant() {
        // ClipDescription.EXTRA_IS_SENSITIVE, and what password managers set
        // on releases that predate the constant.
        assertEquals("android.content.extra.IS_SENSITIVE", ClipboardPrivacy.EXTRA_IS_SENSITIVE)
    }

    @Test
    fun booleanAndStringFlagsBothCount() {
        assertTrue(ClipboardPrivacy.markedSensitive(true))
        assertTrue(ClipboardPrivacy.markedSensitive("true"))
        assertTrue(ClipboardPrivacy.markedSensitive("TRUE"))
        assertTrue(ClipboardPrivacy.markedSensitive(1))
        assertFalse(ClipboardPrivacy.markedSensitive(false))
        assertFalse(ClipboardPrivacy.markedSensitive("false"))
        assertFalse(ClipboardPrivacy.markedSensitive(0))
        assertFalse(ClipboardPrivacy.markedSensitive(null))
    }

    @Test
    fun aClipCopiedInAPasswordFieldStaysOutAfterward() {
        val clips = SensitiveClips()
        val secret = SensitiveClips.of(1_000L, "hunter2")
        clips.mark(secret)
        assertTrue(clips.contains(SensitiveClips.of(1_000L, "hunter2")))
    }

    @Test
    fun aLaterCopyOfDifferentTextIsNotTainted() {
        val clips = SensitiveClips()
        clips.mark(SensitiveClips.of(1_000L, "hunter2"))
        assertFalse(clips.contains(SensitiveClips.of(2_000L, "lunch at noon")))
        // Same text copied again later is a new clip with its own timestamp.
        assertFalse(clips.contains(SensitiveClips.of(3_000L, "hunter2")))
    }

    @Test
    fun onlyTheNewestFingerprintsAreKept() {
        val clips = SensitiveClips(capacity = 2)
        clips.mark(SensitiveClips.of(1L, "a"))
        clips.mark(SensitiveClips.of(2L, "b"))
        clips.mark(SensitiveClips.of(3L, "c"))
        assertFalse(clips.contains(SensitiveClips.of(1L, "a")))
        assertTrue(clips.contains(SensitiveClips.of(3L, "c")))
    }
}
