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
            log.recordTiming("finish_requested", "IME")
            log.recordError("settings", "IME")
            log.recordError("https://token@homelab.example:8765", "IME")
            log.recordAction("transcript=never persist this", "IME")

            val output = log.read()
            assertTrue(output.contains("ts=1234"))
            assertTrue(output.contains("event=state value=LISTENING source=IME"))
            assertTrue(output.contains("event=timing value=finish_requested source=IME"))
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

    /**
     * A microphone failure is only diagnosable after the fact if the log says
     * which one it was: the call or the screen recording that took the input is
     * gone by the time anyone reads this.
     */
    @Test
    fun `microphone failures are logged by cause rather than as one category`() {
        val directory = Files.createTempDirectory("vocaphone-diagnostics").toFile()
        try {
            val log = DiagnosticLog(directory.resolve("events.log"), nowMillis = { 99L })

            log.recordError("audio_focus_lost", "IME")
            log.recordError("audio_silenced", "COMPANION_APP")
            log.recordError("audio_capture_lost", "IME")

            val output = log.read()
            assertTrue(output.contains("event=error value=audio_focus_lost source=IME"))
            assertTrue(output.contains("event=error value=audio_silenced source=COMPANION_APP"))
            assertTrue(output.contains("event=error value=audio_capture_lost source=IME"))
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun `timing stages reject arbitrary values`() {
        val directory = Files.createTempDirectory("vocaphone-diagnostics").toFile()
        try {
            val log = DiagnosticLog(directory.resolve("events.log"), nowMillis = { 4321L })
            log.recordTiming("transcript_ready", "COMPANION_APP")
            log.recordTiming("transcript=private", "COMPANION_APP")

            val output = log.read()
            assertTrue(output.contains("ts=4321"))
            assertTrue(output.contains("event=timing value=transcript_ready"))
            assertTrue(output.contains("event=timing value=unknown"))
            assertFalse(output.contains("private"))
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
