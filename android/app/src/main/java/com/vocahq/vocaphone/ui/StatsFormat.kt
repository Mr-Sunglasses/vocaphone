package com.vocahq.vocaphone.ui

import com.vocahq.vocaphone.core.UsageStats
import java.text.DateFormat
import java.text.NumberFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/**
 * How the statistics read on screen.
 *
 * Pure and injectable rather than inline in the composable, because everything
 * here is a locale or calendar decision — thousands separators, "Yesterday" at
 * the wrong hour, a date formatted in the wrong calendar — and those are the
 * parts worth a test. `android.text.format.DateUtils` is deliberately not used:
 * it is a framework stub under unit tests, which return default values here, so
 * a test covering it would assert nothing.
 */
internal object StatsFormat {

    fun count(value: Long, locale: Locale = Locale.getDefault()): String =
        NumberFormat.getIntegerInstance(locale).format(value)

    fun duration(millis: Long, locale: Locale = Locale.getDefault()): String {
        val seconds = (millis / 1_000).coerceAtLeast(0)
        val hours = seconds / 3_600
        val minutes = (seconds % 3_600) / 60
        val remainder = seconds % 60
        return buildString {
            if (hours > 0) append(String.format(locale, "%dh ", hours))
            if (hours > 0 || minutes > 0) append(String.format(locale, "%dm ", minutes))
            append(String.format(locale, "%ds", remainder))
        }
    }

    fun wordsPerMinute(value: Double, locale: Locale = Locale.getDefault()): String =
        String.format(locale, "%.1f", value)

    fun streak(days: Int, locale: Locale = Locale.getDefault()): String =
        if (days == 1) "1 day" else "${count(days.toLong(), locale)} days"

    fun words(value: Int, locale: Locale = Locale.getDefault()): String =
        if (value == 1) "1 word" else "${count(value.toLong(), locale)} words"

    /**
     * The two days a person names, then a date.
     *
     * Compared as day keys rather than by subtracting 24 hours from the clock,
     * so the label is still right on the days daylight saving makes 23 or 25
     * hours long.
     */
    fun dayLabel(
        key: String,
        nowMillis: Long,
        locale: Locale = Locale.getDefault(),
        zone: TimeZone = TimeZone.getDefault(),
    ): String {
        if (key == UsageStats.dayKey(nowMillis, zone)) return "Today"
        if (key == UsageStats.dayKey(previousDay(nowMillis, zone), zone)) return "Yesterday"
        val millis = parseKey(key, zone) ?: return key
        return DateFormat.getDateInstance(DateFormat.MEDIUM, locale).format(Date(millis))
    }

    fun recentDays(stats: UsageStats): List<Pair<String, Int>> =
        stats.dailyWords.entries.sortedByDescending { it.key }.map { it.key to it.value }

    private fun previousDay(millis: Long, zone: TimeZone): Long {
        val calendar = Calendar.getInstance(zone, Locale.ROOT)
        calendar.timeInMillis = millis
        calendar.add(Calendar.DAY_OF_YEAR, -1)
        return calendar.timeInMillis
    }

    private fun parseKey(key: String, zone: TimeZone): Long? {
        val parts = key.split('-')
        if (parts.size != 3) return null
        val year = parts[0].toIntOrNull() ?: return null
        val month = parts[1].toIntOrNull() ?: return null
        val day = parts[2].toIntOrNull() ?: return null
        if (month !in 1..12 || day !in 1..31) return null
        val calendar = Calendar.getInstance(zone, Locale.ROOT)
        calendar.clear()
        calendar.set(year, month - 1, day, 12, 0, 0)
        return calendar.timeInMillis
    }
}
