package com.vocahq.vocaphone.ui

import com.vocahq.vocaphone.data.DictationRecordEntity
import java.time.LocalDate
import java.time.ZoneId
import java.time.ZonedDateTime
import java.util.Locale
import org.junit.Assert.assertEquals
import org.junit.Test

class HistoryGroupingTest {

    private val today = LocalDate.of(2026, 10, 3)

    private fun record(
        transcript: String? = "hello",
        language: String = "auto",
        audioPath: String? = null,
        createdAt: Long = 0L,
        errorMessage: String? = null,
    ) = DictationRecordEntity(
        sessionId = transcript ?: "failed",
        createdAt = createdAt,
        updatedAt = createdAt,
        language = language,
        style = "formal",
        state = "completed",
        transcript = transcript,
        errorMessage = errorMessage,
        audioPath = audioPath,
    )

    @Test
    fun `days read as today, yesterday, a weekday date, or a dated year`() {
        assertEquals("Today", historyDayLabel(today, today, Locale.US))
        assertEquals("Yesterday", historyDayLabel(today.minusDays(1), today, Locale.US))
        assertEquals("Mon 28 Sep", historyDayLabel(LocalDate.of(2026, 9, 28), today, Locale.US))
        assertEquals("28 Sep 2025", historyDayLabel(LocalDate.of(2025, 9, 28), today, Locale.US))
    }

    @Test
    fun `a dictation lands on the local day it was made`() {
        val zone = ZoneId.of("Asia/Kolkata")
        val lateEvening = ZonedDateTime.of(2026, 10, 2, 23, 50, 0, 0, zone).toInstant().toEpochMilli()
        assertEquals(LocalDate.of(2026, 10, 2), historyDay(lateEvening, zone))
    }

    @Test
    fun `the row only mentions what is out of the ordinary`() {
        assertEquals("7:50", historyRowMeta("7:50", record()))
        assertEquals("7:50 · Hindi", historyRowMeta("7:50", record(language = "hi")))
        assertEquals(
            "7:50 · audio kept for Retry",
            historyRowMeta("7:50", record(audioPath = "/data/audio.m4a")),
        )
    }

    @Test
    fun `search matches transcripts and failure messages, ignoring case`() {
        val records = listOf(
            record(transcript = "Meet at the station"),
            record(transcript = null, errorMessage = "Gateway did not answer"),
            record(transcript = "Buy milk"),
        )
        assertEquals(records, filterHistory(records, "  "))
        assertEquals(listOf(records[0]), filterHistory(records, "STATION"))
        assertEquals(listOf(records[1]), filterHistory(records, "gateway"))
    }

    @Test
    fun `the search field stays while a query is set`() {
        assertEquals(false, showHistorySearch(HISTORY_SEARCH_THRESHOLD - 1, ""))
        assertEquals(true, showHistorySearch(HISTORY_SEARCH_THRESHOLD, ""))
        // Deleting a match can drop the count under the threshold; the field
        // that holds the filter must not vanish with it.
        assertEquals(true, showHistorySearch(HISTORY_SEARCH_THRESHOLD - 1, "station"))
    }
}
