package com.vocahq.vocaphone.data

import android.app.ActivityManager.RunningAppProcessInfo
import android.app.ApplicationExitInfo
import java.nio.file.Files
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ProcessExitTest {

    private fun exit(
        timestampMillis: Long = 1_000L,
        reason: Int = ApplicationExitInfo.REASON_CRASH_NATIVE,
        status: Int = 11,
        importance: Int = RunningAppProcessInfo.IMPORTANCE_FOREGROUND_SERVICE,
        rssKilobytes: Long = 700 * 1024,
    ) = ProcessExit(timestampMillis, reason, status, importance, rssKilobytes)

    @Test
    fun `reasons map to the diagnostic log vocabulary`() {
        val reasons = listOf(
            ApplicationExitInfo.REASON_EXIT_SELF,
            ApplicationExitInfo.REASON_SIGNALED,
            ApplicationExitInfo.REASON_LOW_MEMORY,
            ApplicationExitInfo.REASON_CRASH,
            ApplicationExitInfo.REASON_CRASH_NATIVE,
            ApplicationExitInfo.REASON_ANR,
            ApplicationExitInfo.REASON_INITIALIZATION_FAILURE,
            ApplicationExitInfo.REASON_PERMISSION_CHANGE,
            ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE,
            ApplicationExitInfo.REASON_USER_REQUESTED,
            ApplicationExitInfo.REASON_USER_STOPPED,
            ApplicationExitInfo.REASON_DEPENDENCY_DIED,
            ApplicationExitInfo.REASON_OTHER,
            ApplicationExitInfo.REASON_FREEZER,
            ApplicationExitInfo.REASON_PACKAGE_STATE_CHANGE,
            ApplicationExitInfo.REASON_PACKAGE_UPDATED,
        )
        reasons.forEach { reason ->
            val name = ProcessExitVocabulary.reason(reason)
            assertTrue("$reason mapped to $name", name in DiagnosticLog.EXIT_REASONS)
            assertFalse("$reason should have a name of its own", name == "unknown")
        }
        assertEquals("crash_native", ProcessExitVocabulary.reason(ApplicationExitInfo.REASON_CRASH_NATIVE))
    }

    /**
     * A reason Android has not shipped yet must not widen what this log can
     * contain. It becomes `unknown` rather than a number nobody vetted.
     */
    @Test
    fun `an unrecognised reason is not passed through`() {
        assertEquals("unknown", ProcessExitVocabulary.reason(9_999))
    }

    @Test
    fun `importance separates a foreground kill from housekeeping`() {
        assertEquals(
            "foreground",
            ProcessExitVocabulary.importance(RunningAppProcessInfo.IMPORTANCE_FOREGROUND),
        )
        assertEquals(
            "foreground_service",
            ProcessExitVocabulary.importance(RunningAppProcessInfo.IMPORTANCE_FOREGROUND_SERVICE),
        )
        assertEquals(
            "cached",
            ProcessExitVocabulary.importance(RunningAppProcessInfo.IMPORTANCE_CACHED),
        )
        assertEquals(
            "gone",
            ProcessExitVocabulary.importance(RunningAppProcessInfo.IMPORTANCE_GONE),
        )
        assertEquals("unknown", ProcessExitVocabulary.importance(0))
        // The tiers with no name of their own land next door rather than
        // falling out: top-sleeping and cant-save-state sit between service and
        // cached, and are reported as the less important of the two.
        assertEquals("service", ProcessExitVocabulary.importance(250))
        assertEquals(
            "cached",
            ProcessExitVocabulary.importance(RunningAppProcessInfo.IMPORTANCE_TOP_SLEEPING),
        )
        DiagnosticLog.EXIT_IMPORTANCES.let { allowed ->
            (0..1_100 step 5).forEach { value ->
                assertTrue(value.toString(), ProcessExitVocabulary.importance(value) in allowed)
            }
        }
    }

    @Test
    fun `resident size is bucketed rather than exact`() {
        assertEquals("unknown", ProcessExitVocabulary.footprint(0))
        assertEquals("under_256mb", ProcessExitVocabulary.footprint(200 * 1024))
        assertEquals("under_512mb", ProcessExitVocabulary.footprint(400 * 1024))
        assertEquals("under_1gb", ProcessExitVocabulary.footprint(700 * 1024))
        assertEquals("under_2gb", ProcessExitVocabulary.footprint(1_500 * 1024))
        assertEquals("under_4gb", ProcessExitVocabulary.footprint(3_000 * 1024))
        assertEquals("over_4gb", ProcessExitVocabulary.footprint(9_000L * 1024))
    }

    /**
     * `status` is a signal only for the reasons where the kernel ended the
     * process. Reading an ordinary exit code as a signal would name the wrong
     * cause with total confidence.
     */
    @Test
    fun `signals are named only where status holds one`() {
        assertEquals(
            "sigsegv",
            ProcessExitVocabulary.signal(ApplicationExitInfo.REASON_CRASH_NATIVE, 11),
        )
        assertEquals(
            "sigill",
            ProcessExitVocabulary.signal(ApplicationExitInfo.REASON_SIGNALED, 4),
        )
        assertEquals(
            "sigkill",
            ProcessExitVocabulary.signal(ApplicationExitInfo.REASON_SIGNALED, 9),
        )
        assertEquals(
            "other",
            ProcessExitVocabulary.signal(ApplicationExitInfo.REASON_SIGNALED, 31),
        )
        assertEquals("none", ProcessExitVocabulary.signal(ApplicationExitInfo.REASON_LOW_MEMORY, 11))
        assertEquals("none", ProcessExitVocabulary.signal(ApplicationExitInfo.REASON_EXIT_SELF, 0))
    }

    @Test
    fun `exits are written once and never re-reported`() = runTest {
        val directory = Files.createTempDirectory("vocaphone-exits").toFile()
        try {
            val log = DiagnosticLog(directory.resolve("events.log"), buildVersion = "test")
            var watermark = 0L
            val exits = listOf(exit(timestampMillis = 100L), exit(timestampMillis = 200L))
            val reporter = ProcessExitReporter(
                diagnostics = log,
                claimExitsUpTo = { newest ->
                    val previous = watermark
                    if (newest > watermark) watermark = newest
                    previous
                },
                recentExits = { exits },
            )

            reporter.report()
            assertEquals(2, log.read().lineSequence().count { "event=exit" in it })

            // The system hands back the same list every time it is asked.
            reporter.report()
            assertEquals(2, log.read().lineSequence().count { "event=exit" in it })

            // A new death is still reported, and only that one.
            val withNewer = exits + exit(timestampMillis = 300L)
            ProcessExitReporter(
                diagnostics = log,
                claimExitsUpTo = { newest ->
                    val previous = watermark
                    if (newest > watermark) watermark = newest
                    previous
                },
                recentExits = { withNewer },
            ).report()
            assertEquals(3, log.read().lineSequence().count { "event=exit" in it })
        } finally {
            directory.deleteRecursively()
        }
    }

    /**
     * The watermark, not the log, is what stops a repeat: the log is bounded
     * and the user can clear it from About, and a week-old crash must not
     * reappear as though it had just happened.
     */
    @Test
    fun `clearing the log does not resurrect old exits`() = runTest {
        val directory = Files.createTempDirectory("vocaphone-exits").toFile()
        try {
            val log = DiagnosticLog(directory.resolve("events.log"), buildVersion = "test")
            var watermark = 0L
            val reporter = ProcessExitReporter(
                diagnostics = log,
                claimExitsUpTo = { newest ->
                    val previous = watermark
                    if (newest > watermark) watermark = newest
                    previous
                },
                recentExits = { listOf(exit(timestampMillis = 100L)) },
            )

            reporter.report()
            log.clear()
            reporter.report()

            assertEquals(0, log.read().lineSequence().count { "event=exit" in it })
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun `a system that reports nothing is not an error`() = runTest {
        val directory = Files.createTempDirectory("vocaphone-exits").toFile()
        try {
            val log = DiagnosticLog(directory.resolve("events.log"), buildVersion = "test")
            ProcessExitReporter(
                diagnostics = log,
                claimExitsUpTo = { error("must not be claimed when there is nothing to report") },
                recentExits = { emptyList() },
            ).report()
            ProcessExitReporter(
                diagnostics = log,
                claimExitsUpTo = { 0L },
                recentExits = { error("the platform refused the query") },
            ).report()

            assertEquals("", log.read())
        } finally {
            directory.deleteRecursively()
        }
    }
}
