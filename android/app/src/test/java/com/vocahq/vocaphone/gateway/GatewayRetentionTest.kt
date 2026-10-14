package com.vocahq.vocaphone.gateway

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Which failures keep the recording for Retry. A rejected token or an
 * unsupported language used to delete it, although fixing the setting is all
 * it takes for the same recording to succeed.
 */
class GatewayRetentionTest {

    @Test
    fun aRejectedTokenKeepsTheRecordingButIsNotRetriedAsIs() {
        for (status in listOf(401, 403)) {
            val error = GatewayException.fromStatus(status, "unauthorized")
            assertFalse(error.recoverable)
            assertTrue(error.fixableInSettings)
            assertTrue(error.retainsAudio)
        }
    }

    @Test
    fun anUnsupportedLanguageKeepsTheRecording() {
        val error = GatewayException.fromStatus(422, "language_unsupported")
        assertFalse(error.recoverable)
        assertTrue(error.retainsAudio)
    }

    @Test
    fun failuresNoSettingFixesStillDiscardIt() {
        assertFalse(GatewayException.fromStatus(413, "audio_too_large").retainsAudio)
        assertFalse(GatewayException.fromStatus(415, null).retainsAudio)
        assertFalse(GatewayException.fromStatus(404, null).retainsAudio)
        assertFalse(GatewayException.emptyTranscript().retainsAudio)
    }

    @Test
    fun transientFailuresKeepItAsBefore() {
        assertTrue(GatewayException.fromStatus(503, null).retainsAudio)
        assertTrue(GatewayException.unreachable().retainsAudio)
    }
}
