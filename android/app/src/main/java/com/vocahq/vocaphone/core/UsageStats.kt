package com.vocahq.vocaphone.core

import java.text.BreakIterator
import java.time.LocalDate
import java.util.Calendar
import java.util.Locale
import java.util.TimeZone
import org.json.JSONObject

/**
 * On-device dictation counters: how much you have dictated, how fast you speak,
 * and how many days in a row you have used it.
 *
 * Counts only. No transcript text, no audio, no gateway, no reporting — the
 * whole type is a handful of numbers plus a bounded map of day totals, and it
 * never leaves the phone.
 *
 * All arithmetic lives here rather than in the repository so that every rule
 * worth checking — word counting, streaks, pruning, lenient decoding — is a pure
 * function with a test, the way [Snippet] and the rest of `core/` are written.
 */
data class UsageStats(
    val totalWords: Long = 0,
    val totalTranscriptions: Long = 0,
    val totalAudioMillis: Long = 0,
    val lastDayKey: String = "",
    val currentStreak: Int = 0,
    val bestStreak: Int = 0,
    val dailyWords: Map<String, Int> = emptyMap(),
) {

    val averageWordsPerMinute: Double
        get() = if (totalAudioMillis <= 0) 0.0 else totalWords / (totalAudioMillis / 60_000.0)

    val hasAny: Boolean get() = totalTranscriptions > 0

    fun currentStreakAt(now: Long): Int {
        if (lastDayKey.isEmpty()) return 0
        val elapsed = daysBetween(lastDayKey, dayKey(now)) ?: return 0
        return when {
            isUnreconcilableFuture(elapsed) -> 0
            elapsed <= 1 -> currentStreak
            else -> 0
        }
    }

    fun record(transcript: String, durationMillis: Long?, now: Long): UsageStats {
        val words = wordCount(transcript)
        if (words == 0) return this

        val key = dayKey(now)
        val daily = dailyWords.toMutableMap()
        daily[key] = (daily[key] ?: 0) + words

        val streak = advanceStreak(currentStreak, lastDayKey, key)
        return copy(
            totalWords = totalWords + words,
            totalTranscriptions = totalTranscriptions + 1,
            totalAudioMillis = totalAudioMillis + (durationMillis?.coerceAtLeast(0) ?: 0),
            lastDayKey = nextDayKey(lastDayKey, key),
            currentStreak = streak,
            bestStreak = maxOf(bestStreak, streak),
            dailyWords = pruneDaily(daily),
        )
    }

    companion object {
        const val DAILY_LIMIT = 7

        fun wordCount(text: String): Int {
            val trimmed = text.trim()
            if (trimmed.isEmpty()) return 0
            val iterator = BreakIterator.getWordInstance(Locale.ROOT)
            iterator.setText(trimmed)
            var count = 0
            var start = iterator.first()
            var end = iterator.next()
            while (end != BreakIterator.DONE) {
                val segment = trimmed.substring(start, end)
                if (segment.any(Char::isLetterOrDigit)) count++
                start = end
                end = iterator.next()
            }
            return count
        }

        fun dayKey(millis: Long, zone: TimeZone = TimeZone.getDefault()): String {
            val calendar = Calendar.getInstance(zone, Locale.ROOT)
            calendar.timeInMillis = millis
            return String.format(
                Locale.ROOT,
                "%04d-%02d-%02d",
                calendar.get(Calendar.YEAR),
                calendar.get(Calendar.MONTH) + 1,
                calendar.get(Calendar.DAY_OF_MONTH),
            )
        }

        fun daysBetween(fromKey: String, toKey: String): Int? = runCatching {
            (LocalDate.parse(toKey).toEpochDay() - LocalDate.parse(fromKey).toEpochDay()).toInt()
        }.getOrNull()

        fun isDayKey(value: String): Boolean =
            value.isNotEmpty() && runCatching { LocalDate.parse(value) }.isSuccess

        fun advanceStreak(current: Int, lastDayKey: String, todayKey: String): Int {
            if (lastDayKey.isEmpty()) return 1
            val elapsed = daysBetween(lastDayKey, todayKey) ?: return 1
            return when {
                isUnreconcilableFuture(elapsed) -> 1
                elapsed <= 0 -> current.coerceAtLeast(1)
                elapsed == 1 -> current.coerceAtLeast(0) + 1
                else -> 1
            }
        }

        /** The stored day after recording on [todayKey], repaired if it cannot be trusted. */
        fun nextDayKey(stored: String, todayKey: String): String {
            if (!isDayKey(stored)) return todayKey
            val elapsed = daysBetween(stored, todayKey)
            if (elapsed != null && isUnreconcilableFuture(elapsed)) return todayKey
            return maxOf(stored, todayKey)
        }

        /**
         * Whether a stored day sits so far ahead of today that it is a wrong
         * clock rather than a streak.
         *
         * A stored day can legitimately be ahead: correcting a clock backwards
         * leaves one there, and a run should survive that — which is why a small
         * negative gap holds the streak rather than breaking it. But a day
         * further ahead than the entire retained window cannot be reconciled with
         * anything the reader can see, and left alone it never expires and never
         * advances, because every later comparison stays negative. A device that
         * once recorded a dictation dated 2099 would otherwise be stuck for good.
         *
         * The boundary is [DAILY_LIMIT] because that is the history the screen
         * can actually show; past it there is nothing to reconcile against.
         */
        private fun isUnreconcilableFuture(elapsed: Int): Boolean = elapsed < -DAILY_LIMIT

        /**
         * The [DAILY_LIMIT] most recent days by date, not by insertion order.
         *
         * Readable labels are ranked first. Sorting on the string alone would
         * put an unreadable key above every real date — "zzz" beats "2026-09-09"
         * — so with the window full a damaged label would survive and evict a
         * genuine day's word count. The map is deliberately not validated when it
         * is decoded, precisely so that a bad label costs nothing; it must not
         * cost a day here instead.
         */
        fun pruneDaily(daily: Map<String, Int>): Map<String, Int> {
            if (daily.size <= DAILY_LIMIT) return daily.toMap()
            return daily.entries
                .sortedWith(
                    compareByDescending<Map.Entry<String, Int>> { isDayKey(it.key) }
                        .thenByDescending { it.key },
                )
                .take(DAILY_LIMIT)
                .associate { it.key to it.value }
        }

        fun encode(stats: UsageStats): String = JSONObject().apply {
            put("totalWords", stats.totalWords)
            put("totalTranscriptions", stats.totalTranscriptions)
            put("totalAudioMillis", stats.totalAudioMillis)
            put("lastDayKey", stats.lastDayKey)
            put("currentStreak", stats.currentStreak)
            put("bestStreak", stats.bestStreak)
            put(
                "daily",
                JSONObject().apply {
                    stats.dailyWords.forEach { (day, words) -> put(day, words) }
                },
            )
        }.toString()

        /**
         * Field by field with defaults, so a payload written by an older or
         * newer build still yields every value it does carry.
         *
         * A whole-object decode that threw would reset somebody's lifetime
         * totals the first time a field was added, which is the one failure this
         * type must not have. The day map is decoded separately for the same
         * reason: a malformed map costs the activity list, not the totals.
         */
        fun decode(stored: String?): UsageStats {
            if (stored.isNullOrBlank()) return UsageStats()
            return runCatching {
                val json = JSONObject(stored)
                val daily = decodeDaily(json.optJSONObject("daily"))
                UsageStats(
                    totalWords = json.optLong("totalWords", 0).coerceAtLeast(0),
                    totalTranscriptions = json.optLong("totalTranscriptions", 0).coerceAtLeast(0),
                    totalAudioMillis = json.optLong("totalAudioMillis", 0).coerceAtLeast(0),
                    // The stored day if it is still readable, else the newest day
                    // the retained map can vouch for — which also covers a
                    // payload written before this field existed.
                    //
                    // Both sources are checked, not just the first. The day map
                    // is deliberately not validated when it is decoded, so its
                    // largest key can itself be unreadable; taking `maxOrNull`
                    // blindly would let the recovery hand back the very kind of
                    // value it is recovering from. Filtering also means one bad
                    // key does not cost the good days beside it.
                    lastDayKey = json.optString("lastDayKey").takeIf(::isDayKey)
                        ?: daily.keys.filter(::isDayKey).maxOrNull().orEmpty(),
                    currentStreak = json.optInt("currentStreak", 0).coerceAtLeast(0),
                    bestStreak = json.optInt("bestStreak", 0).coerceAtLeast(0),
                    dailyWords = daily,
                )
            }.getOrDefault(UsageStats())
        }

        private fun decodeDaily(json: JSONObject?): Map<String, Int> {
            if (json == null) return emptyMap()
            return runCatching {
                buildMap {
                    json.keys().forEach { key ->
                        val words = json.optInt(key, 0)
                        if (words > 0) put(key, words)
                    }
                }.let(::pruneDaily)
            }.getOrDefault(emptyMap())
        }

    }
}
