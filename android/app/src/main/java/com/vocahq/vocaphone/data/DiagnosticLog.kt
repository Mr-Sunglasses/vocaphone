package com.vocahq.vocaphone.data

import android.content.Context
import java.io.File

/**
 * A small app-private event log for physical-device debugging.
 *
 * The API deliberately accepts categories rather than arbitrary messages. That
 * makes it impossible for a call site to accidentally persist a transcript,
 * typed text, audio path, gateway URL, or bearer token.
 */
class DiagnosticLog(
    private val file: File,
    private val buildVersion: String = "unknown",
    private val nowMillis: () -> Long = System::currentTimeMillis,
) {
    private var lineCount: Int? = null

    constructor(context: Context) : this(
        file = File(context.filesDir, "diagnostics/events.log"),
        buildVersion = packageVersion(context),
    )

    @Synchronized
    fun recordState(phase: String, source: String?) {
        append(event = "state", value = phase, source = source)
    }

    @Synchronized
    fun recordError(category: String, source: String?) {
        append(event = "error", value = category, source = source)
    }

    @Synchronized
    fun recordAction(action: String, source: String?) {
        append(event = "action", value = action, source = source)
    }

    /** Millisecond timestamps around the content-free dictation pipeline. */
    @Synchronized
    fun recordTiming(stage: String, source: String?) {
        append(event = "timing", value = stage, source = source)
    }

    @Synchronized
    fun read(): String = runCatching { file.takeIf(File::isFile)?.readText().orEmpty() }
        .getOrDefault("")

    @Synchronized
    fun clear() {
        file.delete()
        lineCount = 0
    }

    /** Keep values single-line and bounded even if a future call site is wrong. */
    private fun safe(value: String): String = value
        .filter { it.isLetterOrDigit() || it == '_' || it == '-' || it == '.' }
        .take(MAX_VALUE_LENGTH)
        .ifEmpty { "unknown" }

    private fun append(event: String, value: String, source: String?) {
        val line = listOf(
            "ts=${nowMillis()}",
            "build=${safe(buildVersion)}",
            "event=${knownEvent(event)}",
            "value=${knownValue(event, value)}",
            "source=${knownSource(source)}",
        ).joinToString(" ") + "\n"

        runCatching {
            file.parentFile?.mkdirs()
            val existingCount = lineCount ?: file.takeIf(File::isFile)
                ?.useLines { lines -> lines.count { it.isNotBlank() } }
                .orZero()
            file.appendText(line)
            lineCount = existingCount + 1
            if (lineCount.orZero() > MAX_EVENTS || file.length() > MAX_BYTES) {
                trim()
            }
        }
    }

    private fun trim() {
        val lines = file.readLines().takeLast(MAX_EVENTS).toMutableList()
        while (lines.joinToString("\n").toByteArray(Charsets.UTF_8).size > MAX_BYTES && lines.isNotEmpty()) {
            lines.removeAt(0)
        }
        file.writeText(lines.joinToString("\n") + if (lines.isNotEmpty()) "\n" else "")
        lineCount = lines.size
    }

    private fun knownEvent(value: String): String = value.takeIf { it in EVENTS } ?: "unknown"

    private fun knownValue(event: String, value: String): String = when (event) {
        "state" -> value.takeIf { it in STATES } ?: "unknown"
        "error" -> value.takeIf { it in ERROR_CATEGORIES } ?: "unknown"
        "action" -> value.takeIf { it in ACTIONS } ?: "unknown"
        "timing" -> value.takeIf { it in TIMING_STAGES } ?: "unknown"
        else -> "unknown"
    }

    private fun knownSource(value: String?): String =
        value?.takeIf { it in SOURCES } ?: "none"

    private companion object {
        const val MAX_EVENTS = 200
        const val MAX_BYTES = 48 * 1024
        const val MAX_VALUE_LENGTH = 64
        val EVENTS = setOf("state", "error", "action", "timing")
        val SOURCES = setOf("IME", "COMPANION_APP", "none")
        val ERROR_CATEGORIES = setOf("audio", "gateway", "insertion", "settings", "setup", "unknown")
        val ACTIONS = setOf(
            "start",
            "cancel",
            "finish",
            "ready_to_insert",
            "inserted",
            "insertion_failed",
            "input_rejected",
            "editor_finished",
            "input_unbound",
            "keyboard_destroyed",
            "unknown",
        )
        val TIMING_STAGES = setOf(
            "finish_requested",
            "capture_stopped",
            "stream_handshake_started",
            "stream_ready",
            "batch_fallback",
            "upload_started",
            "upload_completed",
            "transcription_started",
            "local_transcription_started",
            "local_incremental_started",
            "local_incremental_ready",
            "local_incremental_fallback",
            "transcript_ready",
            "insertion_started",
            "insertion_completed",
        )
        val STATES = setOf(
            "IDLE",
            "LISTENING",
            "FINALIZING",
            "UPLOADING",
            "TRANSCRIBING",
            "READY_TO_INSERT",
            "INSERTING",
            "INSERTED",
            "FAILED",
            "PERMISSION_REPAIR",
        )
    }
}

private fun Int?.orZero(): Int = this ?: 0

private fun packageVersion(context: Context): String = runCatching {
    context.packageManager.getPackageInfo(context.packageName, 0).versionName
}.getOrNull().orEmpty().ifEmpty { "unknown" }
