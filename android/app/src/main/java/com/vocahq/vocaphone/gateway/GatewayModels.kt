package com.vocahq.vocaphone.gateway

import org.json.JSONObject

data class GatewayHealth(
    val status: String,
    val engineReady: Boolean,
    val engine: String,
    /** Absent on gateways older than the streaming negotiation change. */
    val streamingSupported: Boolean?,
    /**
     * Languages the loaded model covers. Empty means the gateway made no claim —
     * an older build, no model selected, or an imported one — and the language
     * picker must stay fully open rather than locking the user out.
     */
    val languages: Set<String>,
    /** True when the model picks the language itself and cannot be pinned. */
    val detectsLanguageAutomatically: Boolean,
) {
    companion object {
        fun from(json: JSONObject) = GatewayHealth(
            status = json.optString("status", "unknown"),
            engineReady = json.optBoolean("engine_ready", false),
            engine = json.optString("engine", "unknown"),
            streamingSupported = if (json.has("streaming_supported")) {
                json.optBoolean("streaming_supported", false)
            } else {
                null
            },
            languages = json.optJSONArray("languages")?.let { array ->
                (0 until array.length()).mapNotNull { array.optString(it).takeIf(String::isNotEmpty) }
            }.orEmpty().toSet(),
            detectsLanguageAutomatically = json.optBoolean("detects_language_automatically", false),
        )
    }
}

data class GatewaySession(
    val sessionId: String,
    val jobId: String,
    val state: String,
    val transcript: String?,
    val errorCode: String?,
) {
    companion object {
        fun from(json: JSONObject) = GatewaySession(
            sessionId = json.optString("session_id"),
            jobId = json.optString("job_id"),
            state = json.optString("state"),
            transcript = json.optString("transcript").takeIf { it.isNotEmpty() && !json.isNull("transcript") },
            errorCode = json.optString("error_code").takeIf { it.isNotEmpty() && !json.isNull("error_code") },
        )
    }
}

/**
 * Every failure the user can be shown. [recoverable] decides whether the audio
 * is kept for Retry or discarded straight away.
 */
class GatewayException(
    val code: String,
    val userMessage: String,
    val recoverable: Boolean,
    cause: Throwable? = null,
) : Exception(userMessage, cause) {

    companion object {
        fun fromStatus(status: Int, code: String?): GatewayException {
            val resolved = code ?: "http_$status"
            return when {
                // Keyed on the code rather than the status: the gateway loaded a model
                // that cannot transcribe the chosen language, so a Retry would replay
                // the same pairing and fail identically. Point at the fix instead.
                resolved == "language_unsupported" -> GatewayException(
                    resolved,
                    "Your gateway's model does not support this language. " +
                        "Choose Automatic or another language, or load a matching model.",
                    recoverable = false,
                )

                status == 401 || status == 403 -> GatewayException(
                    resolved,
                    "Your gateway rejected the token. Check it in Settings.",
                    recoverable = false,
                )

                status == 413 -> GatewayException(
                    resolved,
                    "The recording is longer than your gateway accepts.",
                    recoverable = false,
                )

                status == 415 || status == 422 -> GatewayException(
                    resolved,
                    "Your gateway could not read the recording.",
                    recoverable = false,
                )

                status == 404 -> GatewayException(
                    resolved,
                    "Your gateway no longer has this dictation.",
                    recoverable = false,
                )

                status == 429 || status in 500..599 -> GatewayException(
                    resolved,
                    "Your gateway is busy or unavailable. Try again.",
                    recoverable = true,
                )

                else -> GatewayException(resolved, "Gateway error $status.", recoverable = false)
            }
        }

        fun unreachable(cause: Throwable? = null) = GatewayException(
            "gateway_unreachable",
            "Could not reach your gateway. Check the address and your network.",
            recoverable = true,
            cause = cause,
        )

        fun emptyTranscript() = GatewayException(
            "empty_transcript",
            "Nothing was transcribed. Try dictating again.",
            recoverable = false,
        )
    }
}
