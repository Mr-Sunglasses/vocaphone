package com.vocahq.vocaphone.ui

/**
 * Copy for the on-phone vs gateway choice.
 *
 * These two paths are mutually exclusive. Showing the unused one as
 * "not configured" or "unknown / not ready" made a working local install look
 * broken, so the unused side only ever says that it is off.
 */
data class SpeechSourceCopy(
    val localSelected: Boolean,
    val localDetail: String,
    val gatewayDetail: String,
    val inactiveHint: String,
    val engineLabel: String,
)

data class SpeechSourceSelection(
    val localEnabled: Boolean,
    val openGateway: Boolean,
)

/** Tile tap: stay on this phone, or flip to gateway and open setup if needed. */
fun speechSourceSelection(
    wantLocal: Boolean,
    gatewayConfigured: Boolean,
): SpeechSourceSelection = SpeechSourceSelection(
    localEnabled = wantLocal,
    openGateway = !wantLocal && !gatewayConfigured,
)

fun speechSourceCopy(
    localEnabled: Boolean,
    localModelName: String?,
    gatewayConfigured: Boolean,
    gatewayUrl: String,
    lastEngine: String = "",
    lastEngineReady: Boolean = false,
): SpeechSourceCopy {
    val localDetail = localModelName ?: "No model on this phone yet"
    val gatewayDetail = if (gatewayConfigured) gatewayUrl else "Not configured"
    return SpeechSourceCopy(
        localSelected = localEnabled,
        localDetail = localDetail,
        gatewayDetail = gatewayDetail,
        inactiveHint = if (localEnabled) {
            "Gateway is off while you use a model on this phone."
        } else {
            "On-device models are off while you use a gateway."
        },
        engineLabel = if (localEnabled) {
            localModelName?.let { "On this phone · $it" } ?: "On this phone"
        } else {
            lastEngine.ifEmpty { "unknown" } +
                if (lastEngineReady) " (ready)" else " (not ready)"
        },
    )
}
