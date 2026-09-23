package com.vocahq.vocaphone.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class DictationLatencyTest {

    private fun line(ts: Long, event: String, value: String) =
        "ts=$ts build=1.0 event=$event value=$value source=IME"

    private fun dictation(at: Long, listening: Long, stopAt: Long, inserted: Long) = listOf(
        line(at, "action", "start"),
        line(at + listening, "state", "LISTENING"),
        line(stopAt, "timing", "finish_requested"),
        line(stopAt + 20, "timing", "capture_stopped"),
        line(stopAt + inserted - 10, "timing", "transcript_ready"),
        line(stopAt + inserted, "timing", "insertion_completed"),
    )

    @Test
    fun `pairs each span inside one dictation`() {
        val log = dictation(at = 1_000, listening = 300, stopAt = 5_000, inserted = 800)
            .joinToString("\n")

        val summary = DictationLatency.summarize(log).associateBy { it.label }

        assertEquals(300L, summary.getValue("Tap -> listening").medianMillis)
        assertEquals(20L, summary.getValue("Stop -> mic off").medianMillis)
        assertEquals(790L, summary.getValue("Stop -> transcript").medianMillis)
        assertEquals(800L, summary.getValue("Stop -> inserted").medianMillis)
    }

    @Test
    fun `median and p95 are nearest-rank over every dictation`() {
        val log = (1..20).flatMap { n ->
            dictation(at = n * 100_000L, listening = n * 10L, stopAt = n * 100_000L + 5_000, inserted = 500)
        }.joinToString("\n")

        val tap = DictationLatency.summarize(log).first { it.label == "Tap -> listening" }

        assertEquals(20, tap.count)
        assertEquals(100L, tap.medianMillis)
        assertEquals(190L, tap.p95Millis)
    }

    @Test
    fun `a cancelled dictation does not pair with the next one`() {
        val log = listOf(
            line(1_000, "timing", "finish_requested"),
            line(1_100, "action", "cancel"),
            line(9_000, "timing", "insertion_completed"),
            line(10_000, "action", "start"),
            line(10_250, "state", "LISTENING"),
        ).joinToString("\n")

        val summary = DictationLatency.summarize(log).associateBy { it.label }

        assertTrue("Stop -> inserted" !in summary)
        assertEquals(250L, summary.getValue("Tap -> listening").medianMillis)
    }

    @Test
    fun `a start that failed before listening is not measured`() {
        val log = listOf(
            line(1_000, "action", "start"),
            line(1_050, "state", "FAILED"),
            line(3_000, "state", "LISTENING"),
        ).joinToString("\n")

        assertTrue(DictationLatency.summarize(log).isEmpty())
    }

    @Test
    fun `unknown and malformed lines are skipped`() {
        val log = listOf(
            "not a log line",
            "ts=abc event=action value=start",
            line(1_000, "action", "start"),
            line(1_120, "state", "LISTENING"),
        ).joinToString("\n")

        assertEquals(
            listOf("Tap -> listening: 120 ms median, 120 ms p95 (n=1)"),
            DictationLatency.reportLines(log),
        )
    }
}
