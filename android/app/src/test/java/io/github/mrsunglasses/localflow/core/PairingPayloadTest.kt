package io.github.mrsunglasses.localflow.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PairingPayloadTest {

    @Test
    fun `round trip encode and parse`() {
        val raw = PairingPayload.encode(
            "  HTTP://192.168.1.75:8765/  ",
            "  test-token-with-at-least-thirty-two-characters  ",
        )
        val result = PairingPayload.parse(raw) as PairingPayload.Result.Ok
        assertEquals("http://192.168.1.75:8765", result.parsed.url)
        assertEquals("test-token-with-at-least-thirty-two-characters", result.parsed.token)
    }

    @Test
    fun `rejects garbage and wrong version`() {
        assertTrue(PairingPayload.parse("not-json") is PairingPayload.Result.Err)
        assertTrue(PairingPayload.parse("   ") is PairingPayload.Result.Err)
        assertTrue(
            PairingPayload.parse(
                """{"v":99,"url":"http://192.168.1.1:8765","token":"test-token-with-at-least-thirty-two-characters"}""",
            ) is PairingPayload.Result.Err,
        )
    }

    @Test
    fun `rejects public cleartext hosts via GatewayEndpoint`() {
        val result = PairingPayload.parse(
            """{"v":1,"url":"http://flow.example.com:8765","token":"test-token-with-at-least-thirty-two-characters"}""",
        ) as PairingPayload.Result.Err
        assertTrue(result.reason.contains("https://"))
    }

    @Test
    fun `accepts lan and tailscale cleartext`() {
        val lan = PairingPayload.parse(
            """{"v":1,"url":"http://192.168.1.20:8765","token":"test-token-with-at-least-thirty-two-characters"}""",
        ) as PairingPayload.Result.Ok
        assertEquals("http://192.168.1.20:8765", lan.parsed.url)

        val tail = PairingPayload.parse(
            """{"v":1,"url":"http://homelab.tail1234.ts.net:8765","token":"test-token-with-at-least-thirty-two-characters"}""",
        ) as PairingPayload.Result.Ok
        assertEquals("http://homelab.tail1234.ts.net:8765", tail.parsed.url)
    }

    @Test
    fun `rejects missing token or short token`() {
        assertTrue(
            PairingPayload.parse("""{"v":1,"url":"http://192.168.1.20:8765","token":""}""")
                is PairingPayload.Result.Err,
        )
        assertTrue(
            PairingPayload.parse("""{"v":1,"url":"http://192.168.1.20:8765","token":"tooshort"}""")
                is PairingPayload.Result.Err,
        )
    }
}
