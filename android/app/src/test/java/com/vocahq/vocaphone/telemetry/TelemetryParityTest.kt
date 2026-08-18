package com.vocahq.vocaphone.telemetry

import com.vocahq.vocaphone.ui.UsageReportingCopy
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Holds the two clients' telemetry vocabulary and privacy copy identical.
 *
 * Both files say they are kept in step with each other, and until this existed
 * nothing checked. Drift here is the worst kind of bug this feature can have,
 * because it breaks nothing: the app builds, the tests pass, events keep
 * arriving, and a query that groups by event name silently reports one platform
 * where it claims to report both. It compares declarations and copy, not call
 * sites: a divergence like iOS declaring `model_download_finished` and never
 * calling it is invisible here and stays a review problem. What it does catch
 * is the drift already present when it was written — the two copies of the
 * privacy text had begun to disagree about the spelling of the product name.
 *
 * Reads the Swift source rather than a generated artefact, so it works from a
 * plain `gradlew test` with no iOS toolchain present.
 */
class TelemetryParityTest {

    private val repositoryRoot: File
        get() = generateSequence(File("").absoluteFile) { it.parentFile }
            .firstOrNull { File(it, "ios/VocaPhoneApp/Telemetry").isDirectory }
            ?: error("Could not locate the repository root from ${File("").absolutePath}")

    private fun swiftSource(name: String): String {
        val file = File(repositoryRoot, "ios/VocaPhoneApp/Telemetry/$name")
        assertTrue("Missing $name — did the iOS telemetry move?", file.isFile)
        return file.readText()
    }

    /**
     * Swift raw values, including the implicit ones. `case gateway` and
     * `case gateway = "gateway"` mean the same thing on the wire, and a test
     * that only understood the explicit form would quietly pass over half the
     * vocabulary.
     */
    private fun swiftCases(enumName: String): Set<String> {
        val source = swiftSource("TelemetryEvent.swift")
        val body = Regex("enum $enumName: String[^{]*\\{(.*?)\\n\\}", RegexOption.DOT_MATCHES_ALL)
            .find(source)
            ?.groupValues
            ?.get(1)
            ?: error("Could not find enum $enumName in TelemetryEvent.swift")
        return Regex("""^\s*case\s+(\w+)(?:\s*=\s*"([^"]+)")?""", RegexOption.MULTILINE)
            .findAll(body)
            .map { match ->
                match.groupValues[2].ifEmpty { match.groupValues[1] }
            }
            .toSet()
    }

    @Test
    fun `event names are identical on both platforms`() {
        assertEquals(
            "The Kotlin and Swift event vocabularies have drifted. Whichever side " +
                "is missing an entry cannot report that event at all.",
            TelemetryEvent.entries.map { it.wire }.toSet(),
            swiftCases("TelemetryEvent"),
        )
    }

    @Test
    fun `every property vocabulary is identical on both platforms`() {
        assertEquals(
            TelemetrySetupStep.entries.map { it.wire }.toSet(),
            swiftCases("TelemetrySetupStep"),
        )
        assertEquals(
            TelemetrySource.entries.map { it.wire }.toSet(),
            swiftCases("TelemetrySource"),
        )
        assertEquals(
            TelemetryStage.entries.map { it.wire }.toSet(),
            swiftCases("TelemetryStage"),
        )
        assertEquals(
            TelemetryReason.entries.map { it.wire }.toSet(),
            swiftCases("TelemetryReason"),
        )
        assertEquals(
            TelemetryDurationBucket.entries.map { it.wire }.toSet(),
            swiftCases("TelemetryDurationBucket"),
        )
        assertEquals(
            TelemetryDownloadOutcome.entries.map { it.wire }.toSet(),
            swiftCases("TelemetryDownloadOutcome"),
        )
        assertEquals(
            TelemetryQuality.entries.map { it.wire }.toSet(),
            swiftCases("TelemetryQuality"),
        )
    }

    /**
     * `model_id` is the one property whose values are not an enum on either
     * platform, so the enum comparison above cannot see it. Its two sentinels
     * are still wire values: a platform that renamed `unknown` would split one
     * bucket into two and nothing else would notice.
     */
    @Test
    fun `the model_id sentinels are identical on both platforms`() {
        val swift = swiftSource("TelemetryEvent.swift")

        listOf("gateway" to TelemetryModelId.GATEWAY, "unknown" to TelemetryModelId.UNKNOWN)
            .forEach { (swiftName, kotlinValue) ->
                val declared = Regex("""static let $swiftName\s*=\s*"([^"]+)"""")
                    .find(swift)
                    ?.groupValues
                    ?.get(1)
                    ?: error("Could not find TelemetryModelID.$swiftName in the Swift source")
                assertEquals(
                    "The $swiftName sentinel has drifted between platforms",
                    kotlinValue,
                    declared,
                )
            }
    }

    /**
     * The privacy promise has to read the same on both platforms. Two apps
     * making subtly different claims about one pipeline is worse than either
     * claim alone, and a copy edit applied to one file is the obvious way for
     * that to happen.
     */
    @Test
    fun `the usage-reporting copy is word-for-word on both platforms`() {
        val swift = swiftSource("UsageReportingCopy.swift")

        listOf(
            "whatIsSent" to UsageReportingCopy.WHAT_IS_SENT,
            "whatIsNeverSent" to UsageReportingCopy.WHAT_IS_NEVER_SENT,
            "optOutIsLogged" to UsageReportingCopy.OPT_OUT_IS_LOGGED,
            "noIdentifier" to UsageReportingCopy.NO_IDENTIFIER,
            "title" to UsageReportingCopy.TITLE,
            "turnOn" to UsageReportingCopy.TURN_ON,
            "notNow" to UsageReportingCopy.NOT_NOW,
            "seeWhatIsSent" to UsageReportingCopy.SEE_WHAT_IS_SENT,
        ).forEach { (swiftName, kotlinText) ->
            assertEquals(
                "UsageReportingCopy.$swiftName has drifted from its Kotlin twin",
                normalize(kotlinText),
                normalize(swiftLiteral(swift, swiftName)),
            )
        }
    }

    /** Handles both `= "..."` and the `= """ ... """` multi-line form. */
    private fun swiftLiteral(source: String, name: String): String {
        Regex("""static let $name\s*=\s*""\"(.*?)""\"""", RegexOption.DOT_MATCHES_ALL)
            .find(source)
            ?.let { return it.groupValues[1] }
        return Regex("""static let $name\s*=\s*"((?:[^"\\]|\\.)*)"""")
            .find(source)
            ?.groupValues
            ?.get(1)
            ?: error("Could not find UsageReportingCopy.$name in the Swift source")
    }

    /**
     * Collapses the two languages' line-continuation syntax so the comparison is
     * about the words. Swift's `"""` blocks end lines with a backslash; Kotlin
     * concatenates with `+` and explicit spaces.
     */
    private fun normalize(text: String): String =
        text.replace("\\\n", " ").replace(Regex("\\s+"), " ").trim()
}
