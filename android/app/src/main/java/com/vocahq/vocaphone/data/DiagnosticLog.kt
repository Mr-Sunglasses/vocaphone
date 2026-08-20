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

    /**
     * Why a previous process of this app ended, read back from the system.
     *
     * A process the system kills writes nothing on its way out, so until this
     * existed the only trace of one was a hole: a dictation logged up to
     * TRANSCRIBING, then a bare IDLE from the freshly built controller, with
     * every event that distinguishes a crash from a cancel absent. That shape
     * is common to a native crash, a low-memory kill, an ANR, and an OEM
     * background-process sweep, and no amount of reading the log tells them
     * apart. The system knows which it was and keeps the answer for the next
     * process to ask.
     *
     * [atMillis] is when the process died, not when this line was written, so
     * an exit sorts into the gap it explains rather than to the end. It is the
     * one event here that can appear out of order in the file.
     *
     * `ApplicationExitInfo.getDescription` is deliberately not recorded. It is
     * free text from the system or the OEM, and this log's whole contract is
     * that no call site can put free text in it.
     */
    @Synchronized
    fun recordExit(
        reason: String,
        importance: String,
        footprint: String,
        signal: String,
        atMillis: Long,
    ) {
        append(
            event = "exit",
            value = reason,
            source = null,
            atMillis = atMillis,
            details = listOf(
                "importance" to importance.takeIf { it in EXIT_IMPORTANCES },
                "rss" to footprint.takeIf { it in EXIT_FOOTPRINTS },
                "signal" to signal.takeIf { it in EXIT_SIGNALS },
            ),
        )
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

    /**
     * @param atMillis when the event happened, for the events that describe
     *   something older than the call. Defaults to now.
     * @param details extra `key=value` fields for the events that need more
     *   than one dimension to be worth reading. A null value is dropped, so a
     *   caller whose allowlist rejected its input omits the field rather than
     *   writing something unvetted, and [safe] still runs over whatever
     *   survives.
     */
    private fun append(
        event: String,
        value: String,
        source: String?,
        atMillis: Long? = null,
        details: List<Pair<String, String?>> = emptyList(),
    ) {
        val fields = listOf(
            "ts=${atMillis ?: nowMillis()}",
            "build=${safe(buildVersion)}",
            "event=${knownEvent(event)}",
            "value=${knownValue(event, value)}",
            "source=${knownSource(source)}",
        ) + details.mapNotNull { (key, detail) ->
            detail?.let { "${safe(key)}=${safe(it)}" }
        }
        val line = fields.joinToString(" ") + "\n"

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
        "exit" -> value.takeIf { it in EXIT_REASONS } ?: "unknown"
        else -> "unknown"
    }

    private fun knownSource(value: String?): String =
        value?.takeIf { it in SOURCES } ?: "none"

    // Internal rather than private so the mappers that feed this log can be
    // tested against the vocabularies themselves. A mapper and an allowlist
    // that drift turn every event into "unknown" and nothing fails.
    internal companion object {
        const val MAX_EVENTS = 200
        const val MAX_BYTES = 48 * 1024
        const val MAX_VALUE_LENGTH = 64
        val EVENTS = setOf("state", "error", "action", "timing", "exit")
        val SOURCES = setOf("IME", "COMPANION_APP", "none")
        /**
         * `ApplicationExitInfo.REASON_*`, named rather than numbered so a
         * pasted log reads without the SDK next to it. `crash` is a Java
         * exception that reached the top; `crash_native` is a signal ggml,
         * whisper.cpp or ONNX Runtime died on.
         */
        val EXIT_REASONS = setOf(
            "exit_self",
            "signaled",
            "low_memory",
            "crash",
            "crash_native",
            "anr",
            "initialization_failure",
            "permission_change",
            "excessive_resource_usage",
            "user_requested",
            "user_stopped",
            "dependency_died",
            "other",
            "freezer",
            "package_state_change",
            "package_updated",
            "unknown",
        )
        /**
         * How the system saw the process when it ended.
         *
         * This is what separates a bug from housekeeping. A process killed
         * while cached is Android reclaiming memory it is entitled to; the same
         * reason code against a foreground service is the keyboard being killed
         * mid-dictation, which is what a user reports as a crash.
         */
        val EXIT_IMPORTANCES = setOf(
            "foreground",
            "foreground_service",
            "visible",
            "perceptible",
            "service",
            "cached",
            "gone",
            "unknown",
        )
        /** Resident set size at exit, bucketed: a model that did not fit says so here. */
        val EXIT_FOOTPRINTS = setOf(
            "under_256mb",
            "under_512mb",
            "under_1gb",
            "under_2gb",
            "under_4gb",
            "over_4gb",
            "unknown",
        )
        /**
         * The signal a `signaled` exit died on.
         *
         * `sigill` is the one worth naming on its own: it means a ggml CPU
         * backend built for instructions this phone does not have was allowed
         * to run, which is a different bug from a bad pointer.
         */
        val EXIT_SIGNALS = setOf(
            "sigill",
            "sigabrt",
            "sigbus",
            "sigsegv",
            "sigkill",
            "sigquit",
            "other",
            "none",
        )
        // Microphone failures are split by cause: after the fact, the call or
        // the screen recording that took the input is long gone, and "audio" on
        // its own cannot tell those apart from a broken recorder.
        val ERROR_CATEGORIES = setOf(
            "audio",
            "audio_focus_lost",
            "audio_silenced",
            "audio_capture_lost",
            // Upkeep on the application scope threw: model verification,
            // expired-audio purging, exit reporting or telemetry. Coarse on
            // purpose -- it says the app survived something it used to die on,
            // and the exit that no longer happens is the rest of the story.
            "background",
            "gateway",
            "insertion",
            "settings",
            "setup",
            "unknown",
        )
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
            "local_incremental_dropped_chunk",
            "local_incremental_unstable_gain",
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
