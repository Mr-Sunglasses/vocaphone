package com.vocahq.vocaphone.local

import kotlinx.coroutines.Job
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class DownloadJobsTest {

    @Test
    fun `a time-limit cancel survives the next download starting before it unwinds`() {
        // onTimeout cancels; the user taps Download again while the first job
        // still holds the mutex. Its unwind must still read TIME_LIMIT.
        val jobs = DownloadJobs()
        var firstReason: () -> DownloadCancelReason = { error("not launched") }
        var secondReason: () -> DownloadCancelReason = { error("not launched") }
        val first = Job()
        jobs.start { firstReason = it; first }

        jobs.cancel(DownloadCancelReason.TIME_LIMIT)
        val second = Job()
        jobs.cancel(DownloadCancelReason.USER) // startDownload cancels first
        jobs.start { secondReason = it; second }

        assertEquals(DownloadCancelReason.TIME_LIMIT, firstReason())
        assertEquals(DownloadCancelReason.USER, secondReason())
        assertSame(second, jobs.current())
    }

    @Test
    fun `a user cancel labels only the job it stopped`() {
        val jobs = DownloadJobs()
        var reason: () -> DownloadCancelReason = { error("not launched") }
        val job = Job()
        jobs.start { reason = it; job }

        jobs.cancel(DownloadCancelReason.USER)

        assertEquals(DownloadCancelReason.USER, reason())
        assertTrue(job.isCancelled)
        assertNull(jobs.current())
    }

    @Test
    fun `a finished download is no longer current`() {
        val jobs = DownloadJobs()
        val job = Job()
        jobs.start { job }
        job.complete()
        assertNull(jobs.current())
        // Nothing in flight: a cancel is a no-op rather than a stale label.
        jobs.cancel(DownloadCancelReason.TIME_LIMIT)
        assertNull(jobs.current())
    }
}
