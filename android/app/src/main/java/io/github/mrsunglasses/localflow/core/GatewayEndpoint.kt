package io.github.mrsunglasses.localflow.core

import java.net.URI

/**
 * Local Flow is built around gateways the user runs themselves, so plain HTTP
 * has to stay available for LAN, mDNS and tailnet hosts. It is refused for hosts
 * that are reachable from the public internet, where an unencrypted bearer token
 * and transcript would be exposed.
 */
object GatewayEndpoint {

    sealed interface Validation {
        data class Valid(val url: String, val cleartext: Boolean) : Validation
        data class Invalid(val reason: String) : Validation
    }

    fun validate(value: String): Validation {
        val trimmed = value.trim()
        if (trimmed.isEmpty()) return Validation.Invalid("Enter your gateway address.")

        val uri = try {
            URI(trimmed)
        } catch (_: IllegalArgumentException) {
            return Validation.Invalid("This is not a valid address.")
        }

        val scheme = uri.scheme?.lowercase()
        if (scheme != "http" && scheme != "https") {
            return Validation.Invalid("The address must start with http:// or https://.")
        }
        val host = uri.host?.lowercase()
        if (host.isNullOrEmpty()) return Validation.Invalid("The address is missing a host name.")
        if (uri.userInfo != null) {
            return Validation.Invalid("Remove the user name from the address; the token authenticates you.")
        }
        if (!uri.query.isNullOrEmpty() || !uri.fragment.isNullOrEmpty()) {
            return Validation.Invalid("Remove the query or fragment from the address.")
        }

        val cleartext = scheme == "http"
        if (cleartext && !isPrivateHost(host)) {
            return Validation.Invalid(
                "$host is reachable from the public internet, so it needs https://."
            )
        }

        val port = if (uri.port == -1) "" else ":${uri.port}"
        val path = uri.path.orEmpty().trimEnd('/')
        return Validation.Valid("$scheme://$host$port$path", cleartext)
    }

    fun isCleartext(url: String): Boolean = url.startsWith("http://", ignoreCase = true)

    /**
     * True when traffic to [host] cannot leave a network the user controls: a
     * loopback or private address, an unqualified or mDNS name, or a Tailscale
     * MagicDNS name whose traffic is already inside a WireGuard tunnel.
     */
    fun isPrivateHost(host: String): Boolean {
        val name = host.trim('[', ']').lowercase().trimEnd('.')
        if (name.isEmpty()) return false
        if (name == "localhost") return true
        if (isPrivateIPv4(name)) return true
        if (isPrivateIPv6(name)) return true
        if (looksLikeIPv4(name) || name.contains(':')) return false
        if (name.endsWith(".local") || name.endsWith(".internal") || name.endsWith(".home.arpa")) {
            return true
        }
        // Tailscale MagicDNS names are fully qualified but only resolve, and only
        // carry traffic, inside the user's own tailnet.
        if (name == "ts.net" || name.endsWith(".ts.net")) return true
        // An unqualified single-label host can only be resolved by the local
        // network's own resolver.
        return !name.contains('.')
    }

    private fun looksLikeIPv4(host: String): Boolean =
        host.split('.').let { parts ->
            parts.size == 4 && parts.all { it.isNotEmpty() && it.all(Char::isDigit) }
        }

    private fun isPrivateIPv4(host: String): Boolean {
        if (!looksLikeIPv4(host)) return false
        val octets = host.split('.').map { it.toIntOrNull() ?: return false }
        if (octets.any { it !in 0..255 }) return false
        val (a, b) = octets[0] to octets[1]
        return when {
            a == 127 -> true                       // loopback
            a == 10 -> true                        // RFC 1918
            a == 172 && b in 16..31 -> true        // RFC 1918
            a == 192 && b == 168 -> true           // RFC 1918
            a == 169 && b == 254 -> true           // link-local
            a == 100 && b in 64..127 -> true       // CGNAT, used by Tailscale
            else -> false
        }
    }

    private fun isPrivateIPv6(host: String): Boolean {
        if (!host.contains(':')) return false
        val normalized = host.substringBefore('%')
        if (normalized == "::1") return true
        val leading = normalized.substringBefore(':').padStart(4, '0')
        val prefix = leading.take(2).toIntOrNull(16) ?: return false
        // fc00::/7 unique local, fe80::/10 link local.
        return prefix in 0xfc..0xfd || (prefix == 0xfe && leading[2] in '8'..'b')
    }
}
