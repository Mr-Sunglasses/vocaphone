package com.vocahq.vocaphone.local

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DownloadReadinessTest {

    private val large = 670L * 1_000_000L
    private val small = 32L * 1_000_000L

    @Test
    fun aFullPhoneIsToldBeforeTheDownloadStartsRatherThanAfter() {
        val warning = downloadWarning(
            sizeBytes = large,
            freeBytes = 210L * 1_000_000L,
            metered = false,
        )

        val storage = warning as DownloadWarning.NotEnoughStorage
        assertTrue(storage.requiredBytes > large)
        assertEquals(210L * 1_000_000L, storage.freeBytes)
    }

    @Test
    fun storageOutranksTheRadioSoOnlyTheHardStopIsShown() {
        val warning = downloadWarning(
            sizeBytes = large,
            freeBytes = 100L * 1_000_000L,
            metered = true,
        )

        assertTrue(warning is DownloadWarning.NotEnoughStorage)
    }

    @Test
    fun aLargeDownloadOnMobileDataIsWorthSaying() {
        val warning =
            downloadWarning(sizeBytes = large, freeBytes = 8L * 1_000_000_000L, metered = true)

        assertEquals(DownloadWarning.MeteredConnection(large), warning)
    }

    @Test
    fun theSmallModelTheWarningPointsAtDoesNotWarnAboutItself() {
        val warning = downloadWarning(
            sizeBytes = small,
            freeBytes = 8L * 1_000_000_000L,
            metered = true,
        )

        assertNull(warning)
    }

    @Test
    fun wifiWithRoomToSpareSaysNothing() {
        assertNull(
            downloadWarning(sizeBytes = large, freeBytes = 8L * 1_000_000_000L, metered = false),
        )
    }

    @Test
    fun anUnreadableFreeSpaceReadingIsNotTreatedAsAFullDisk() {
        // StatFs returns 0 when the query fails. Blocking every download on
        // that would be worse than the failure it is trying to prevent.
        assertNull(downloadWarning(sizeBytes = large, freeBytes = 0, metered = false))
    }

    @Test
    fun headroomScalesWithTheModelButNeverDropsBelowTheFloor() {
        assertEquals(128L * 1_000_000L, storageHeadroomBytes(small))
        assertEquals(large / 4, storageHeadroomBytes(large))
    }

    @Test
    fun noEstimateIsClaimedWhileItWouldStillBeNoise() {
        // A rate measured over the first second is mostly connection setup.
        assertNull(downloadTimeRemaining(1_000_000, large, elapsedMillis = 400))
        assertNull(downloadTimeRemaining(0, large, elapsedMillis = 30_000))
        assertNull(downloadTimeRemaining(large, large, elapsedMillis = 30_000))
    }

    @Test
    fun aSettledEstimateReadsInPlainWords() {
        // 100 MB in 10s = 10 MB/s, 570 MB left, so a little under a minute.
        assertEquals(
            "about a minute left",
            downloadTimeRemaining(
                downloadedBytes = 100L * 1_000_000L,
                totalBytes = large,
                elapsedMillis = 10_000,
            ),
        )
        // 335 MB in 10s = 33.5 MB/s, so ~10 seconds of the same again.
        assertEquals(
            "about 10 seconds left",
            downloadTimeRemaining(
                downloadedBytes = large / 2,
                totalBytes = large,
                elapsedMillis = 10_000,
            ),
        )
        // 67 MB in 10s = 6.7 MB/s, 603 MB left, so a minute and a half.
        assertEquals(
            "about 2 minutes left",
            downloadTimeRemaining(
                downloadedBytes = large / 10,
                totalBytes = large,
                elapsedMillis = 10_000,
            ),
        )
    }

    @Test
    fun aVerySlowConnectionDoesNotPromiseAnHourlyFigure() {
        assertNull(
            downloadTimeRemaining(
                downloadedBytes = 1_000_000,
                totalBytes = large,
                elapsedMillis = 60_000,
            ),
        )
    }

    @Test
    fun theSizeLineSaysHowMuchHasActuallyMoved() {
        assertEquals(
            "254 MB of 670 MB",
            downloadSizeProgress(254L * 1_000_000L, large),
        )
        assertNull(downloadSizeProgress(0, 0))
    }

    @Test
    fun byteLabelsSwitchToGigabytesWhereTheyReadBetter() {
        assertEquals("670 MB", byteLabel(large))
        assertEquals("1.2 GB", byteLabel(1_200_000_000L))
    }
}
