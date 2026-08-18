package com.vocahq.vocaphone.telemetry

import com.vocahq.vocaphone.BuildConfig
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * What this build is pointed at, and whether it is allowed to speak.
 *
 * The Aptabase ingest key is committed rather than injected (see
 * `build.gradle.kts` for why), which means a typo in it is a silent failure:
 * the app keeps queueing events and every flush is rejected, with nothing
 * visible to the user and nothing in a crash report. These tests are what turns
 * that into a build failure.
 */
class TelemetryConfigTest {

    @Test
    fun `a self-hosted key is the only shape accepted`() {
        assertTrue(TelemetryConfig.isSelfHostedKey("A-SH-3275173609"))

        // Blanked by a fork.
        assertFalse(TelemetryConfig.isSelfHostedKey(""))
        // The prefix on its own is not a key.
        assertFalse(TelemetryConfig.isSelfHostedKey("A-SH-"))
        // Aptabase Cloud keys. Accepting one would point a build that believes
        // it is self-hosted at eu./us.aptabase.com instead, which is the one
        // mistake here that would actually send data to a third party.
        assertFalse(TelemetryConfig.isSelfHostedKey("A-EU-3275173609"))
        assertFalse(TelemetryConfig.isSelfHostedKey("A-US-3275173609"))
    }

    /**
     * Runs in the `full` flavour, where reporting is compiled in. The F-Droid
     * variant of this test asserts the opposite by way of
     * [telemetryIsCompiledOutOrFullyConfigured].
     */
    @Test
    fun telemetryIsCompiledOutOrFullyConfigured() {
        if (!BuildConfig.TELEMETRY) {
            // F-Droid: nothing configured, nothing to check.
            assertTrue(BuildConfig.APTABASE_HOST.isEmpty())
            assertTrue(BuildConfig.APTABASE_KEY.isEmpty())
            return
        }
        assertTrue(
            "a build with telemetry compiled in must carry a usable key",
            TelemetryConfig.isSelfHostedKey(BuildConfig.APTABASE_KEY),
        )
        assertTrue(
            "the ingest host must be https: an ingest posted over cleartext " +
                "would put the counters, and the key, on the wire in the open",
            BuildConfig.APTABASE_HOST.startsWith("https://"),
        )
    }

    /**
     * Debug builds queue events so the "See what's sent" screen is useful while
     * developing, and never transmit them. Without this the dataset fills with
     * runs of a tree that corresponds to no release.
     */
    @Test
    fun `a debug build never transmits`() {
        if (BuildConfig.DEBUG) assertFalse(TelemetryConfig.canTransmit)
    }
}
