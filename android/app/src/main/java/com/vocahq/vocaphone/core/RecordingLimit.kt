package com.vocahq.vocaphone.core

/**
 * How long one dictation may record before VocaPhone stops it and
 * transcribes what it has. Chosen in Settings › Dictation › Recording.
 *
 * Ten minutes is the longest because it is what every path has been checked
 * at: the on-device engines decode the WAV in bounded windows (Sherpa in
 * chunks of at most fourteen seconds, whisper.cpp in its own thirty-second
 * windows), and ten minutes of 16 kHz mono PCM16 is 19.2 MB, under a
 * gateway's default 25 MiB upload limit.
 */
enum class MaximumRecordingLength(val minutes: Int) {
    ONE(1),
    TWO(2),
    FIVE(5),
    TEN(10),
    ;

    val millis: Long get() = minutes * 60_000L

    val displayName: String get() = if (minutes == 1) "1 minute" else "$minutes minutes"

    companion object {
        /** The five-minute cap every recording had before this was a choice. */
        val DEFAULT = FIVE

        /** Sizes the buffers and deadlines that must hold any recording. */
        val LONGEST = entries.maxBy { it.minutes }

        fun fromMinutes(minutes: Int?): MaximumRecordingLength =
            entries.firstOrNull { it.minutes == minutes } ?: DEFAULT
    }
}

/** Where a recording stops, and whether it warns first. */
object RecordingLimit {
    /**
     * What a gateway that does not report `maximum_duration_seconds` is assumed
     * to accept: vocagateway's default before it reported one. Assuming less
     * than a gateway takes only stops a recording early; assuming more gets
     * the whole recording refused after it was spoken.
     */
    const val UNREPORTED_GATEWAY_SECONDS = 120

    /**
     * Taken off a gateway's limit. The WAV starts when the microphone opens,
     * before the start cue finishes (up to 0.6 s) and "Listening" is shown,
     * which is when the deadline is counted from; the gateway allows only a
     * quarter of a second over its limit.
     */
    const val GATEWAY_MARGIN_MILLIS = 1_000L

    /** How long before the stop the bubble, Dictate screen and notification warn. */
    const val WARNING_LEAD_MILLIS = 60_000L

    /** The gateway's own limit, or the assumed one when it has not said. */
    fun gatewaySeconds(reported: Int?): Int =
        reported?.takeIf { it > 0 } ?: UNREPORTED_GATEWAY_SECONDS

    /**
     * Milliseconds from "Listening" to the automatic stop. On-device
     * transcription is bounded by the user's choice alone; a gateway route by
     * whichever is shorter, that choice or what the gateway accepts.
     */
    fun effectiveMillis(
        choice: MaximumRecordingLength,
        onDevice: Boolean,
        gatewayReportedSeconds: Int?,
    ): Long {
        if (onDevice) return choice.millis
        val gatewayMillis = gatewaySeconds(gatewayReportedSeconds) * 1_000L - GATEWAY_MARGIN_MILLIS
        return minOf(choice.millis, gatewayMillis.coerceAtLeast(1_000L))
    }

    /**
     * When the one-minute warning appears, or null for none. A warning that
     * would arrive in the first half of a recording -- a one- or two-minute
     * limit -- tells someone who has barely started that they are running out
     * of time, so short limits simply stop.
     */
    fun warningAtMillis(limitMillis: Long): Long? =
        if (limitMillis > 2 * WARNING_LEAD_MILLIS) limitMillis - WARNING_LEAD_MILLIS else null

    /**
     * The note under the setting when the gateway, not the choice, is what
     * stops a recording. Null on the on-device route or when the gateway
     * accepts at least the chosen length.
     */
    fun gatewayNote(
        choice: MaximumRecordingLength,
        onDevice: Boolean,
        gatewayReportedSeconds: Int?,
    ): String? {
        if (onDevice) return null
        val seconds = gatewaySeconds(gatewayReportedSeconds)
        if (seconds * 1_000L >= choice.millis) return null
        val accepts = when {
            seconds % 60 != 0 -> "$seconds seconds"
            seconds == 60 -> "1 minute"
            else -> "${seconds / 60} minutes"
        }
        val remedy = if (gatewayReportedSeconds == null) {
            "Update the gateway and test the connection to record longer."
        } else {
            "Raise its duration limit to record longer."
        }
        return "Your gateway accepts up to $accepts. $remedy"
    }
}
