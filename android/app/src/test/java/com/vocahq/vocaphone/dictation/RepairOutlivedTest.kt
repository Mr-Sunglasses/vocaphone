package com.vocahq.vocaphone.dictation

import com.vocahq.vocaphone.core.DictationPhase
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A repair state is about the settings it was worked out from. It used to
 * outlive them: "Voice model needed" stayed on the keyboard after switching
 * to a gateway, and the mic kept opening Models.
 */
class RepairOutlivedTest {

    private val onPhone = RepairInputs(localTranscription = true, localModelId = "", gatewayConfigured = true)
    private val gateway = onPhone.copy(localTranscription = false)

    @Test
    fun switchingToTheGatewayClearsAVoiceModelRepair() {
        assertTrue(repairOutlived(DictationPhase.PERMISSION_REPAIR, onPhone, gateway))
    }

    @Test
    fun choosingAModelClearsTheRepair() {
        assertTrue(repairOutlived(DictationPhase.PERMISSION_REPAIR, onPhone, onPhone.copy(localModelId = "tiny-q5_1")))
    }

    @Test
    fun settingUpTheGatewayClearsAGatewayRepair() {
        val unconfigured = gateway.copy(gatewayConfigured = false)
        assertTrue(repairOutlived(DictationPhase.PERMISSION_REPAIR, unconfigured, gateway))
    }

    @Test
    fun theFirstSettingsReadIsNotAChange() {
        assertFalse(repairOutlived(DictationPhase.PERMISSION_REPAIR, null, gateway))
    }

    @Test
    fun unchangedSettingsKeepTheRepair() {
        assertFalse(repairOutlived(DictationPhase.PERMISSION_REPAIR, onPhone, onPhone))
    }

    @Test
    fun onlyARepairIsCleared() {
        DictationPhase.entries
            .filter { it != DictationPhase.PERMISSION_REPAIR }
            .forEach { phase -> assertFalse(phase.name, repairOutlived(phase, onPhone, gateway)) }
    }
}
