package com.vocahq.vocaphone.data

import java.nio.file.Files
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DiagnosticLogTest {

    @Test
    fun `log keeps only allowlisted operational fields`() {
        val directory = Files.createTempDirectory("vocaphone-diagnostics").toFile()
        try {
            val log = DiagnosticLog(
                file = directory.resolve("events.log"),
                buildVersion = "0.1.0-test",
                nowMillis = { 1234L },
            )

            log.recordState("LISTENING", "IME")
            log.recordError("settings", "IME")
            log.recordError("https://token@homelab.example:8765", "IME")
            log.recordAction("transcript=never persist this", "IME")

            val output = log.read()
            assertTrue(output.contains("ts=1234"))
            assertTrue(output.contains("event=state value=LISTENING source=IME"))
            assertTrue(output.contains("event=error value=settings source=IME"))
            assertTrue(output.contains("event=error value=unknown source=IME"))
            assertTrue(output.contains("event=action value=unknown source=IME"))
            assertFalse(output.contains("homelab"))
            assertFalse(output.contains("transcript"))
            assertFalse(output.contains("token"))
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun `log is bounded by event count`() {
        val directory = Files.createTempDirectory("vocaphone-diagnostics").toFile()
        try {
            val log = DiagnosticLog(directory.resolve("events.log"), buildVersion = "test")
            repeat(250) { log.recordAction("start", "COMPANION_APP") }

            assertTrue(log.read().lineSequence().count { it.isNotBlank() } <= 200)
        } finally {
            directory.deleteRecursively()
        }
    }
}
