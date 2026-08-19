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
     * The application scope's exception handler writes this and nothing else,
     * so if the category ever falls out of the allowlist the log silently reads
     * `value=unknown` and the one line explaining a survived crash is gone.
     * `source` is deliberately absent: SOURCES names where a dictation came
     * from, and background upkeep did not come from one.
     */
    @Test
    fun `background upkeep failures survive the allowlist`() {
        val directory = Files.createTempDirectory("vocaphone-diagnostics").toFile()
        try {
            val log = DiagnosticLog(directory.resolve("events.log"), nowMillis = { 7L })

            log.recordError("background", null)

            assertTrue(log.read().contains("event=error value=background source=none"))
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

    /**
     * The exit line is the one that carries more than one value, and every one
     * of them is an allowlist away from the free text the system offers. An
     * unvetted field is dropped rather than written.
     */
    @Test
    fun `process exits record their dimensions and reject anything else`() {
        val directory = Files.createTempDirectory("vocaphone-diagnostics").toFile()
        try {
            val log = DiagnosticLog(directory.resolve("events.log"), nowMillis = { 5_000L })

            log.recordExit(
                reason = "crash_native",
                importance = "foreground_service",
                footprint = "under_1gb",
                signal = "sigsegv",
                atMillis = 4_321L,
            )
            log.recordExit(
                reason = "Native crash (see logcat)",
                importance = "com.oem.killer said so",
                footprint = "703992 kB",
                signal = "11",
                atMillis = 4_400L,
            )

            val lines = log.read().lines().filter { it.isNotBlank() }
            assertTrue(
                lines[0].contains(
                    "event=exit value=crash_native source=none " +
                        "importance=foreground_service rss=under_1gb signal=sigsegv",
                ),
            )
            // An exit is dated when the process died, so it sorts into the gap
            // it explains rather than to when it happened to be read back.
            assertTrue(lines[0].startsWith("ts=4321 "))
            assertTrue(lines[1].contains("event=exit value=unknown source=none"))
            assertFalse(lines[1].contains("importance="))
            assertFalse(lines[1].contains("rss="))
            assertFalse(lines[1].contains("signal="))
            assertFalse(log.read().contains("logcat"))
            assertFalse(log.read().contains("oem"))
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
