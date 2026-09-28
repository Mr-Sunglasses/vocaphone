package com.vocahq.vocaphone.dictation

import com.vocahq.vocaphone.core.MissingPermission
import com.vocahq.vocaphone.local.LocalModelState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * What a keyboard mic tap does while on-device dictation cannot start, and
 * how a wait on a download ends.
 *
 * Both used to treat *any* download as the one that mattered: with the
 * configured model missing and an unrelated download running, the keyboard
 * said "downloading", and that unrelated file landing cleared the repair it
 * had nothing to do with. The state now carries which download will be used,
 * and these are the rules that read it.
 */
class DownloadFollowTest {

    private val parakeet = "parakeet-tdt-0.6b-v2-en"
    private val tiny = "tiny-q5_1"

    // --- modelRepair: why dictation cannot start -----------------------------

    /** Present the way the controller reads it once `downloaded` is filled in. */
    private fun repair(id: String, state: LocalModelState, present: Boolean = id.isNotEmpty() && id in state.downloaded) =
        modelRepair(configuredId = id, configuredPresent = present, models = state)

    @Test
    fun aModelFoundOnDiskBeforeTheLaunchRefreshNeedsNoRepair() {
        // Right after launch `downloaded` can still be empty; the controller's
        // stat pass is what says the files are there.
        assertNull(repair(parakeet, LocalModelState(), present = true))
    }

    @Test
    fun aModelNotOnThePhoneButDownloadingIsAWaitNotUnavailable() {
        // The merge regression this signature exists for: a stored model that
        // is not on disk yet reads as "unavailable" unless its own download is
        // checked first.
        val state = LocalModelState(downloading = parakeet, pendingUse = parakeet, progress = 12)
        assertEquals(MissingPermission.MODEL_DOWNLOADING, repair(parakeet, state, present = false))
    }

    @Test
    fun aRetiredSelectionWithNothingComingIsUnavailable() {
        assertEquals(
            MissingPermission.LOCAL_MODEL_UNAVAILABLE,
            repair("retired-model", LocalModelState(), present = false),
        )
    }

    @Test
    fun aConfiguredModelOnDiskNeedsNoRepair() {
        assertNull(repair(parakeet, LocalModelState(downloaded = setOf(parakeet))))
    }

    @Test
    fun theDownloadTheAppIntendsToUseIsAWait() {
        val state = LocalModelState(downloading = parakeet, pendingUse = parakeet, progress = 40)
        assertEquals(MissingPermission.MODEL_DOWNLOADING, repair("", state))
    }

    @Test
    fun theConfiguredModelReDownloadingIsAWaitToo() {
        val state = LocalModelState(downloading = parakeet)
        assertEquals(MissingPermission.MODEL_DOWNLOADING, repair(parakeet, state))
    }

    @Test
    fun aPendingModelOnDiskButNotYetChosenIsStillAWait() {
        val state = LocalModelState(downloaded = setOf(parakeet), pendingUse = parakeet)
        assertEquals(MissingPermission.MODEL_PREPARING, repair("", state))
    }

    /** Once adopted — id persisted, pending cleared — the first arm passes it. */
    @Test
    fun anAdoptedModelNeedsNoRepair() {
        val state = LocalModelState(downloaded = setOf(parakeet), pendingUse = null)
        assertNull(repair(parakeet, state))
    }

    /**
     * Greptile's case. The configured model is gone and something *else* is
     * downloading. That is not a wait — nothing on its way will fix this —
     * so the answer is "choose a model", not "downloading".
     */
    @Test
    fun anUnrelatedDownloadIsNotAReasonToWait() {
        val state = LocalModelState(downloading = tiny, progress = 30)
        assertEquals(MissingPermission.LOCAL_MODEL_UNAVAILABLE, repair(parakeet, state))
    }

    @Test
    fun nothingConfiguredAndNothingComingIsMissing() {
        assertEquals(MissingPermission.LOCAL_MODEL_UNAVAILABLE, repair("", LocalModelState()))
        assertEquals(MissingPermission.LOCAL_MODEL_UNAVAILABLE, repair(parakeet, LocalModelState(downloaded = setOf(tiny))))
    }

    // --- downloadOutcome: how the wait ends ---------------------------------

    @Test
    fun theTargetStillDownloadingIsAWait() {
        assertEquals(DownloadOutcome.WAITING, downloadOutcome(LocalModelState(downloading = parakeet, progress = 40), parakeet))
    }

    @Test
    fun theTargetOnDiskAndAdoptedLanded() {
        assertEquals(DownloadOutcome.LANDED, downloadOutcome(LocalModelState(downloaded = setOf(parakeet)), parakeet))
    }

    /** On disk but still pending is not landed yet — adoption is loading it. */
    @Test
    fun theTargetOnDiskButStillPendingIsPreparing() {
        val state = LocalModelState(downloaded = setOf(parakeet), pendingUse = parakeet, preparing = "Parakeet")
        assertEquals(DownloadOutcome.PREPARING, downloadOutcome(state, parakeet))
    }

    /** Prepare failure clears the pending flag; the wait ends and the next tap re-evaluates. */
    @Test
    fun aClearedPendingFlagEndsTheWaitEvenIfNothingWasAdopted() {
        val state = LocalModelState(downloaded = setOf(parakeet), pendingUse = null)
        assertEquals(DownloadOutcome.LANDED, downloadOutcome(state, parakeet))
    }

    /** The other half of Greptile's case: a different file landing is not this wait ending. */
    @Test
    fun anUnrelatedModelLandingDoesNotEndTheWait() {
        val state = LocalModelState(downloaded = setOf(tiny), downloading = parakeet, progress = 55)
        assertEquals(DownloadOutcome.WAITING, downloadOutcome(state, parakeet))
    }

    @Test
    fun theTargetStoppingWithoutLandingDied() {
        assertEquals(DownloadOutcome.DIED, downloadOutcome(LocalModelState(downloading = null), parakeet))
    }

    @Test
    fun theTargetBeingReplacedByAnotherDownloadDied() {
        assertEquals(DownloadOutcome.DIED, downloadOutcome(LocalModelState(downloading = tiny), parakeet))
    }

    @Test
    fun landedWinsOverAReplacementThatStartedAfterwards() {
        val state = LocalModelState(downloaded = setOf(parakeet), downloading = tiny, pendingUse = null)
        assertEquals(DownloadOutcome.LANDED, downloadOutcome(state, parakeet))
    }
}
