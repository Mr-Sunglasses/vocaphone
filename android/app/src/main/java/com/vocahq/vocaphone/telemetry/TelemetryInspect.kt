package com.vocahq.vocaphone.telemetry

import java.time.Instant
import org.json.JSONArray

/** What the "See exactly what's sent" sheet shows. */
data class TelemetryInspectPayload(
    val json: String,
    val isSample: Boolean,
)

/**
 * A typical event in the same shape Aptabase accepts.
 * The UI must label this as a sample. The JSON itself adds no extra fields.
 */
object TelemetrySample {

    fun record(
        clock: Instant = Instant.parse("2026-01-15T12:00:00.000Z"),
        systemProps: TelemetrySystemProps = TelemetrySystemProps(
            locale = "en",
            osName = "Android",
            osVersion = "15",
            isDebug = false,
            appVersion = "0.1.0-beta.19",
            sdkVersion = TelemetryConfig.SDK_VERSION,
        ),
    ): TelemetryRecord = TelemetryRecord(
        eventName = TelemetryEvent.SETUP_STEP_COMPLETED.wire,
        timestamp = clock,
        sessionId = "00000000-0000-4000-8000-000000000001",
        systemProps = systemProps,
        props = mapOf("step" to TelemetrySetupStep.KEYBOARD.wire),
    )

    fun json(record: TelemetryRecord = record()): String =
        JSONArray(listOf(record.toJson())).toString(2)
}
