package io.github.mrsunglasses.localflow.core

import org.json.JSONObject

/**
 * Shared phone-pairing document encoded in the gateway WebUI QR.
 *
 * Wire format (version 1):
 * `{"v":1,"url":"http://192.168.1.20:8765","token":"..."}`
 */
object PairingPayload {

    const val VERSION = 1

    data class Parsed(val url: String, val token: String)

    sealed interface Result {
        data class Ok(val parsed: Parsed) : Result
        data class Err(val reason: String) : Result
    }

    fun parse(raw: String): Result {
        val text = raw.trim()
        if (text.isEmpty()) return Result.Err("The pairing code is empty.")

        val data = try {
            JSONObject(text)
        } catch (_: Exception) {
            return Result.Err("This is not a Local Flow pairing code.")
        }

        val version = when {
            data.has("v") -> data.optInt("v", -1)
            data.has("version") -> data.optInt("version", -1)
            else -> -1
        }
        if (version != VERSION) {
            return Result.Err("This pairing code uses an unsupported version.")
        }

        val url = data.optString("url", "").trim()
        val token = data.optString("token", "").trim()
        if (url.isEmpty()) return Result.Err("The pairing code is missing a gateway address.")
        if (token.isEmpty()) return Result.Err("The pairing code is missing a bearer token.")
        if (token.length < 32) {
            return Result.Err("The pairing token looks too short to be valid.")
        }

        return when (val validation = GatewayEndpoint.validate(url)) {
            is GatewayEndpoint.Validation.Invalid -> Result.Err(validation.reason)
            is GatewayEndpoint.Validation.Valid -> Result.Ok(Parsed(validation.url, token))
        }
    }

    /** Encode for tests and any host-side previews that share this format. */
    fun encode(url: String, token: String): String {
        val validation = GatewayEndpoint.validate(url)
        require(validation is GatewayEndpoint.Validation.Valid) {
            (validation as GatewayEndpoint.Validation.Invalid).reason
        }
        require(token.isNotBlank()) { "Token must not be empty." }
        return JSONObject()
            .put("v", VERSION)
            .put("url", validation.url)
            .put("token", token.trim())
            .toString()
    }
}
