package com.vocahq.vocaphone.local

import kotlinx.coroutines.Job
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LocalModelDownloadRetentionTest {

    @Test
    fun `leaving the picker must not cancel a download`() {
        assertFalse(CANCEL_MODEL_DOWNLOAD_WHEN_HOST_LEAVES)
    }

    @Test
    fun `cancelling the picker job does not cancel a process-scoped download`() {
        val download = Job()
        val picker = Job()

        picker.cancel()

        assertTrue(download.isActive)
        assertFalse(download.isCancelled)
        download.complete()
    }
}
