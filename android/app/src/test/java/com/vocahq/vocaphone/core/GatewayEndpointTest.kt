package com.vocahq.vocaphone.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class GatewayEndpointTest {

    private fun valid(value: String) =
        GatewayEndpoint.validate(value) as GatewayEndpoint.Validation.Valid

    private fun invalid(value: String) =
        GatewayEndpoint.validate(value) as GatewayEndpoint.Validation.Invalid

    @Test
    fun `accepts https on a public host`() {
        val result = valid("https://flow.example.com")
        assertEquals("https://flow.example.com", result.url)
        assertFalse(result.cleartext)
    }

    @Test
    fun `accepts cleartext on a private lan address`() {
        assertTrue(valid("http://192.168.1.20:8765").cleartext)
        assertTrue(valid("http://10.0.0.5:8765").cleartext)
        assertTrue(valid("http://172.16.4.1:8765").cleartext)
        assertTrue(valid("http://127.0.0.1:8765").cleartext)
    }

    @Test
    fun `accepts cleartext on mdns and unqualified hosts`() {
        assertTrue(valid("http://homelabone.local:8765").cleartext)
        assertTrue(valid("http://homelabone:8765").cleartext)
    }

    @Test
    fun `accepts cleartext on tailscale magicdns and cgnat addresses`() {
        // MagicDNS names are fully qualified but only carry traffic inside the
        // user's WireGuard-encrypted tailnet.
        assertTrue(valid("http://homelabone.tail1234.ts.net:8765").cleartext)
        assertTrue(valid("http://100.101.102.103:8765").cleartext)
    }

    @Test
    fun `refuses cleartext on a public host`() {
        val result = invalid("http://flow.example.com:8765")
        assertTrue(result.reason.contains("https://"))
        assertTrue(invalid("http://8.8.8.8:8765").reason.contains("https://"))
    }

    @Test
    fun `refuses unsupported schemes credentials and query strings`() {
        assertTrue(invalid("ws://192.168.1.20:8765").reason.contains("http://"))
        assertTrue(invalid("http://user:secret@192.168.1.20:8765").reason.contains("user name"))
        assertTrue(invalid("http://192.168.1.20:8765?token=abc").reason.contains("query"))
        assertTrue(invalid("http://192.168.1.20:8765#top").reason.contains("fragment"))
        assertTrue(invalid("   ").reason.isNotEmpty())
    }

    @Test
    fun `normalizes the stored address`() {
        assertEquals("http://192.168.1.20:8765", valid("  HTTP://192.168.1.20:8765/  ").url)
        assertEquals("https://flow.example.com/gw", valid("https://flow.example.com/gw/").url)
    }

    @Test
    fun `classifies ipv6 loopback and unique local addresses as private`() {
        assertTrue(GatewayEndpoint.isPrivateHost("::1"))
        assertTrue(GatewayEndpoint.isPrivateHost("fd00::1"))
        assertTrue(GatewayEndpoint.isPrivateHost("fe80::1"))
        assertFalse(GatewayEndpoint.isPrivateHost("2001:4860:4860::8888"))
    }

    @Test
    fun `classifies public ipv4 ranges as public`() {
        assertFalse(GatewayEndpoint.isPrivateHost("172.32.0.1"))
        assertFalse(GatewayEndpoint.isPrivateHost("100.128.0.1"))
        assertFalse(GatewayEndpoint.isPrivateHost("192.169.1.1"))
    }
}
