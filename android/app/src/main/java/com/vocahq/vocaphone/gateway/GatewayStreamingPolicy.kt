package com.vocahq.vocaphone.gateway

/**
 * Avoids an unnecessary WebSocket handshake when a recent health check says
 * the selected model is batch-only. Unknown or stale data still negotiates so
 * a model changed from the gateway dashboard becomes usable automatically.
 */
object GatewayStreamingPolicy {
    const val CAPABILITY_FRESHNESS_MILLIS = 5 * 60 * 1000L

    fun shouldAttemptStreaming(
        supported: Boolean,
        checkedAtMillis: Long?,
        nowMillis: Long = System.currentTimeMillis(),
    ): Boolean {
        val age = checkedAtMillis?.let(nowMillis::minus) ?: return true
        if (age < 0 || age > CAPABILITY_FRESHNESS_MILLIS) return true
        return supported
    }
}
