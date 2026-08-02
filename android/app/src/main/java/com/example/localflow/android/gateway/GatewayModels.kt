package com.example.localflow.android.gateway

import org.json.JSONObject

data class GatewayHealth(
    val status: String,
    val engineReady: Boolean,
    val engine: String,
    /** Absent on gateways older than the streaming negotiation change. */
    val streamingSupported: Boolean?,
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
