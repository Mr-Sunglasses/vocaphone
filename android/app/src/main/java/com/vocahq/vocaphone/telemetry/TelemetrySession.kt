package com.vocahq.vocaphone.telemetry

import kotlin.random.Random

/**
 * The only identifier this client produces, and it is deliberately a weak one.
 *
 * Aptabase's format: epoch seconds followed by eight random digits. It lives in
 * memory, is never written to disk, and is replaced once the app has been idle
 * for [TIMEOUT_MILLIS]. It exists so the events of a single sitting can be
 * ordered relative to each other; it is not an install ID and must never become
 * one. See [TelemetryConfig] for why there is no persistent identifier here.
 *
 * Synchronised, because [Telemetry] does not serialise access: it records on
 * `Dispatchers.Default`, so two events arriving together genuinely run on
 * different threads. Unsynchronised, a burst could double-mint the id and split
 * one sitting across two sessions.
 */
internal class TelemetrySession(
    private val now: () -> Long = System::currentTimeMillis,
    private val random: Random = Random.Default,
) {
    private var id: String = mint()
    private var lastTouchedMillis: Long = now()

    /** The current session, rotating first if the app has been idle long enough. */
    @Synchronized
    fun currentId(): String {
        val timestamp = now()
        if (timestamp - lastTouchedMillis >= TIMEOUT_MILLIS) {
            id = mint()
        }
        lastTouchedMillis = timestamp
        return id
    }

    /**
     * Forces a new session. Used when reporting is switched off and on again,
     * so a re-enable cannot be stitched to the events that preceded it.
     */
    @Synchronized
    fun rotate() {
        id = mint()
        lastTouchedMillis = now()
    }

    private fun mint(): String {
        val seconds = now() / 1_000
        // Zero-padded so the suffix is always eight digits: an unpadded random
        // int would make a session minted at the same second collide in length
        // with a different one, which is exactly the sort of near-duplicate
        // that looks like a bug in a query six months from now.
        val suffix = random.nextInt(0, 100_000_000).toString().padStart(8, '0')
        return "$seconds$suffix"
    }

    private companion object {
        /**
         * One hour, matching Aptabase's own SDKs. Longer would let a single
         * "session" span a whole day and quietly become the cross-day linkage
         * the daily salt rotation is there to prevent.
         */
        const val TIMEOUT_MILLIS = 60L * 60L * 1_000L
    }
}
