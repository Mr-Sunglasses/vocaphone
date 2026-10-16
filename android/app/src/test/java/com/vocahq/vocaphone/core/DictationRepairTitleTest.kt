package com.vocahq.vocaphone.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Every repair used to be titled "Permission needed" and to open Settings
 * home, so a model still downloading read "Permission needed · Model
 * downloading 42%" and the person went looking for a permission that was on.
 */
class DictationRepairTitleTest {

    private fun repair(vararg missing: MissingPermission, progress: Int? = null) = DictationState(
        phase = DictationPhase.PERMISSION_REPAIR,
        missingPermissions = missing.toSet(),
        modelDownloadProgress = progress,
    )

    @Test
    fun theTitleNamesWhatIsMissing() {
        assertEquals("Microphone permission needed", repair(MissingPermission.MICROPHONE).repairTitle)
        assertEquals("Notification permission needed", repair(MissingPermission.NOTIFICATIONS).repairTitle)
        assertEquals("Gateway not set up", repair(MissingPermission.GATEWAY_NOT_CONFIGURED).repairTitle)
        assertEquals("Model downloading", repair(MissingPermission.MODEL_DOWNLOADING, progress = 42).repairTitle)
        assertEquals("Preparing model", repair(MissingPermission.MODEL_PREPARING).repairTitle)
        assertEquals("Voice model needed", repair(MissingPermission.LOCAL_MODEL_UNAVAILABLE).repairTitle)
    }

    @Test
    fun aMissingMicrophoneOutranksTheGatewayItWasReportedWith() {
        // missingPermissions() reports both on a fresh install; the microphone
        // is the one the user can fix from the keyboard's destination.
        val both = repair(MissingPermission.GATEWAY_NOT_CONFIGURED, MissingPermission.MICROPHONE)
        assertEquals("Microphone permission needed", both.repairTitle)
        assertEquals(DictationState.REPAIR_PAGE_DICTATE, both.repairPage)
    }

    @Test
    fun eachRepairOpensThePageWithItsFix() {
        assertEquals(DictationState.REPAIR_PAGE_DICTATE, repair(MissingPermission.MICROPHONE).repairPage)
        assertEquals(DictationState.REPAIR_PAGE_DICTATE, repair(MissingPermission.NOTIFICATIONS).repairPage)
        assertEquals("connection", repair(MissingPermission.GATEWAY_NOT_CONFIGURED).repairPage)
        assertEquals("models", repair(MissingPermission.MODEL_DOWNLOADING).repairPage)
        assertEquals("models", repair(MissingPermission.MODEL_PREPARING).repairPage)
        assertEquals("models", repair(MissingPermission.LOCAL_MODEL_UNAVAILABLE).repairPage)
    }

    @Test
    fun onlyARepairHasAPage() {
        assertNull(DictationState().repairPage)
        assertNull(DictationState(phase = DictationPhase.FAILED).repairPage)
    }

    @Test
    fun theKeyboardLineSaysWhatATapDoesWithoutRepeatingTheTitle() {
        assertEquals(
            "42% · Tap to see the download",
            repair(MissingPermission.MODEL_DOWNLOADING, progress = 42).repairAction,
        )
        assertEquals("Tap to see the download", repair(MissingPermission.MODEL_DOWNLOADING).repairAction)
        assertEquals("Tap to set up your gateway", repair(MissingPermission.GATEWAY_NOT_CONFIGURED).repairAction)
        assertEquals("Tap to download one", repair(MissingPermission.LOCAL_MODEL_UNAVAILABLE).repairAction)
        assertEquals(
            "Tap to check again or open VocaPhone",
            repair(MissingPermission.MICROPHONE).repairAction,
        )
    }

    @Test
    fun failuresGetAShortTitleKeyedOnTheirCode() {
        assertEquals("Gateway unreachable", failureTitle("gateway_unreachable"))
        assertEquals("Gateway token rejected", failureTitle("unauthorized"))
        assertEquals("Gateway token rejected", failureTitle("http_403"))
        assertEquals("Language not supported", failureTitle("language_unsupported"))
        assertEquals("Nothing was heard", failureTitle("empty_transcript"))
        assertEquals("Microphone interrupted", failureTitle("audio_interrupted"))
        assertEquals("Couldn't start the microphone", failureTitle("microphone_service_refused"))
        assertEquals("Dictation failed", failureTitle("http_418"))
        assertEquals("Gateway unreachable", DictationFailure("gateway_unreachable", "x", true).title)
    }
}
