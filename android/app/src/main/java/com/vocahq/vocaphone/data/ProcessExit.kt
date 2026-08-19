package com.vocahq.vocaphone.data

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context

/**
 * One ended process of this app, as the system remembers it.
 *
 * Deliberately plain integers rather than an [ApplicationExitInfo]: that class
 * cannot be constructed off a device, and the interesting part — turning the
 * SDK's numbers into something a bug report can be read from — is arithmetic
 * that has no business needing an emulator to test.
 */
data class ProcessExit(
    val timestampMillis: Long,
    val reason: Int,
    val status: Int,
    val importance: Int,
    val rssKilobytes: Long,
)

/**
 * Turns the SDK's exit numbers into [DiagnosticLog]'s closed vocabularies.
 *
 * Every mapping is total: an unrecognised value becomes `unknown` or `other`
 * rather than being passed through, so a future Android release that adds a
 * reason code cannot widen what this log can contain.
 */
object ProcessExitVocabulary {

    // Signal numbers are the Linux ones; ApplicationExitInfo.getStatus carries
    // the signal for an exit the kernel delivered rather than the app choosing.
    private const val SIGQUIT = 3
    private const val SIGILL = 4
    private const val SIGABRT = 6
    private const val SIGBUS = 7
    private const val SIGKILL = 9
    private const val SIGSEGV = 11

    fun reason(reason: Int): String = when (reason) {
        ApplicationExitInfo.REASON_EXIT_SELF -> "exit_self"
        ApplicationExitInfo.REASON_SIGNALED -> "signaled"
        ApplicationExitInfo.REASON_LOW_MEMORY -> "low_memory"
        ApplicationExitInfo.REASON_CRASH -> "crash"
        ApplicationExitInfo.REASON_CRASH_NATIVE -> "crash_native"
        ApplicationExitInfo.REASON_ANR -> "anr"
        ApplicationExitInfo.REASON_INITIALIZATION_FAILURE -> "initialization_failure"
        ApplicationExitInfo.REASON_PERMISSION_CHANGE -> "permission_change"
        ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE -> "excessive_resource_usage"
        ApplicationExitInfo.REASON_USER_REQUESTED -> "user_requested"
        ApplicationExitInfo.REASON_USER_STOPPED -> "user_stopped"
        ApplicationExitInfo.REASON_DEPENDENCY_DIED -> "dependency_died"
        ApplicationExitInfo.REASON_OTHER -> "other"
        ApplicationExitInfo.REASON_FREEZER -> "freezer"
        ApplicationExitInfo.REASON_PACKAGE_STATE_CHANGE -> "package_state_change"
        ApplicationExitInfo.REASON_PACKAGE_UPDATED -> "package_updated"
        else -> "unknown"
    }

    /**
     * Ranges rather than equality: the importance constants are ordered, and
     * the ones between the named tiers — TOP_SLEEPING, CANT_SAVE_STATE — should
     * land in the neighbouring bucket instead of falling out as unknown.
     */
    fun importance(importance: Int): String = when {
        importance <= 0 -> "unknown"
        importance <= ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND -> "foreground"
        importance <= ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND_SERVICE ->
            "foreground_service"
        importance <= ActivityManager.RunningAppProcessInfo.IMPORTANCE_VISIBLE -> "visible"
        importance <= ActivityManager.RunningAppProcessInfo.IMPORTANCE_PERCEPTIBLE -> "perceptible"
        importance <= ActivityManager.RunningAppProcessInfo.IMPORTANCE_SERVICE -> "service"
        importance <= ActivityManager.RunningAppProcessInfo.IMPORTANCE_CACHED -> "cached"
        else -> "gone"
    }

    /**
     * Bucketed, never exact. The number is only ever read as "did the model fit
     * in this process", and a byte count is a fingerprint that a coarse band is
     * not.
     */
    fun footprint(rssKilobytes: Long): String = when {
        rssKilobytes <= 0 -> "unknown"
        rssKilobytes < 256 * 1024 -> "under_256mb"
        rssKilobytes < 512 * 1024 -> "under_512mb"
        rssKilobytes < 1024 * 1024 -> "under_1gb"
        rssKilobytes < 2 * 1024 * 1024 -> "under_2gb"
        rssKilobytes < 4 * 1024 * 1024 -> "under_4gb"
        else -> "over_4gb"
    }

    /**
     * The signal, for the two reasons where `status` holds one. For every other
     * reason it is an exit status and naming it as a signal would be a lie.
     */
    fun signal(reason: Int, status: Int): String {
        val signalled = reason == ApplicationExitInfo.REASON_SIGNALED ||
            reason == ApplicationExitInfo.REASON_CRASH_NATIVE
        if (!signalled) return "none"
        return when (status) {
            SIGQUIT -> "sigquit"
            SIGILL -> "sigill"
            SIGABRT -> "sigabrt"
            SIGBUS -> "sigbus"
            SIGKILL -> "sigkill"
            SIGSEGV -> "sigsegv"
            else -> "other"
        }
    }
}

/**
 * Writes the exits the system recorded since the last time it was asked.
 *
 * Called once per process start. The watermark lives outside the diagnostic
 * log because that log is bounded and the user can clear it, and neither should
 * cause the same crash to be reported twice — or, worse, re-reported forever.
 */
class ProcessExitReporter(
    private val diagnostics: DiagnosticLog,
    private val claimExitsUpTo: suspend (Long) -> Long,
    private val recentExits: suspend () -> List<ProcessExit>,
) {

    suspend fun report() {
        val exits = runCatching { recentExits() }.getOrNull().orEmpty()
        if (exits.isEmpty()) return
        val newest = exits.maxOf { it.timestampMillis }
        val alreadyReported = claimExitsUpTo(newest)
        exits.asSequence()
            .filter { it.timestampMillis > alreadyReported }
            .sortedBy { it.timestampMillis }
            .forEach { exit ->
                diagnostics.recordExit(
                    reason = ProcessExitVocabulary.reason(exit.reason),
                    importance = ProcessExitVocabulary.importance(exit.importance),
                    footprint = ProcessExitVocabulary.footprint(exit.rssKilobytes),
                    signal = ProcessExitVocabulary.signal(exit.reason, exit.status),
                    atMillis = exit.timestampMillis,
                )
            }
    }

    companion object {
        /**
         * The system keeps roughly this many per app, so asking for more gains
         * nothing. On the first launch after an update the whole retained
         * history lands at once, which is the point: a tester who has been
         * crashing for a week gets the reason for every one of those crashes
         * without having to reproduce it again.
         */
        const val MAX_EXITS = 16
    }
}

/** The system's record of how this app's recent processes ended. */
fun Context.recentProcessExits(limit: Int = ProcessExitReporter.MAX_EXITS): List<ProcessExit> {
    val manager = getSystemService(ActivityManager::class.java) ?: return emptyList()
    // Every VocaPhone component — keyboard, companion app, microphone service —
    // shares one process, so there is no sub-process to filter down to.
    return manager.getHistoricalProcessExitReasons(packageName, 0, limit).map { info ->
        ProcessExit(
            timestampMillis = info.timestamp,
            reason = info.reason,
            status = info.status,
            importance = info.importance,
            rssKilobytes = info.rss,
        )
    }
}
