package com.vocahq.vocaphone.core

import java.text.BreakIterator
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
    val lastUsedAtMillis: Long = 0,
    val currentStreak: Int = 0,
    val bestStreak: Int = 0,
    val dailyWords: Map<String, Int> = emptyMap(),
) {

    /**
     * Words per minute of *recorded audio*, pauses included, which is why the
     * screen calls it speaking speed rather than anything implying effort.
     * VocaMac computes it the same way; the three Voca apps must agree.
     */
    val averageWordsPerMinute: Double
        get() = if (totalAudioMillis <= 0) 0.0 else totalWords / (totalAudioMillis / 60_000.0)

    val hasAny: Boolean get() = totalTranscriptions > 0

    /**
     * One successful dictation.
     *
     * [durationMillis] is nullable because the controller's recording length is:
     * a dictation whose duration was never observed still transcribed real
     * words, so it is counted with zero added to the audio total rather than
     * dropped. An empty or whitespace-only transcript is not counted at all.
     */
    fun record(transcript: String, durationMillis: Long?, now: Long): UsageStats {
        val words = wordCount(transcript)
        if (words == 0) return this

        val key = dayKey(now)
        val daily = dailyWords.toMutableMap()
        daily[key] = (daily[key] ?: 0) + words

        val streak = advanceStreak(currentStreak, lastUsedAtMillis, now)
        return copy(
            totalWords = totalWords + words,
            totalTranscriptions = totalTranscriptions + 1,
            totalAudioMillis = totalAudioMillis + (durationMillis?.coerceAtLeast(0) ?: 0),
            lastUsedAtMillis = maxOf(lastUsedAtMillis, now),
            currentStreak = streak,
            bestStreak = maxOf(bestStreak, streak),
            dailyWords = pruneDaily(daily),
        )
    }

    companion object {
        const val DAILY_LIMIT = 7

        /**
         * Words as a reader would count them, using the text tokenizer rather
         * than splitting on spaces.
         *
         * VocaPhone transcribes 54 languages. Space-splitting counts a Chinese,
         * Japanese or Thai utterance as a single word, so the one number on the
         * screen would be wrong for a large share of users. Segments without a
         * letter or digit — stray punctuation, the spaces themselves — are not
         * words.
         *
         * How well a space-less script is segmented is the platform's business,
         * not ours. On a device this class is backed by ICU and uses its
         * dictionaries; the desktop JVM that runs the unit tests has no Chinese
         * dictionary and returns one word for a whole Han sentence. That is why
         * the tests assert counts only for scripts both agree on, and why this
         * uses [Locale.ROOT]: the segmentation should follow the text, not the
         * language the interface happens to be in.
         */
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

        /**
         * Whole local days from one instant to another, measured between day
         * starts so that two dictations twenty minutes apart across midnight are
         * one day apart rather than zero.
         */
        fun dayDelta(fromMillis: Long, toMillis: Long, zone: TimeZone = TimeZone.getDefault()): Int {
            val from = startOfDay(fromMillis, zone)
            val to = startOfDay(toMillis, zone)
            val days = (to - from).toDouble() / MILLIS_PER_DAY
            return Math.round(days).toInt()
        }

        fun advanceStreak(current: Int, lastUsedAtMillis: Long, now: Long): Int {
            if (lastUsedAtMillis <= 0L) return 1
            return when (dayDelta(lastUsedAtMillis, now)) {
                in Int.MIN_VALUE..0 -> current.coerceAtLeast(1)
                1 -> current.coerceAtLeast(0) + 1
                else -> 1
            }
        }

        fun pruneDaily(daily: Map<String, Int>): Map<String, Int> {
            if (daily.size <= DAILY_LIMIT) return daily.toMap()
            return daily.entries
                .sortedByDescending { it.key }
                .take(DAILY_LIMIT)
                .associate { it.key to it.value }
        }

        fun encode(stats: UsageStats): String = JSONObject().apply {
            put("totalWords", stats.totalWords)
            put("totalTranscriptions", stats.totalTranscriptions)
            put("totalAudioMillis", stats.totalAudioMillis)
            put("lastUsedAtMillis", stats.lastUsedAtMillis)
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
                UsageStats(
                    totalWords = json.optLong("totalWords", 0).coerceAtLeast(0),
                    totalTranscriptions = json.optLong("totalTranscriptions", 0).coerceAtLeast(0),
                    totalAudioMillis = json.optLong("totalAudioMillis", 0).coerceAtLeast(0),
                    lastUsedAtMillis = json.optLong("lastUsedAtMillis", 0).coerceAtLeast(0),
                    currentStreak = json.optInt("currentStreak", 0).coerceAtLeast(0),
                    bestStreak = json.optInt("bestStreak", 0).coerceAtLeast(0),
                    dailyWords = decodeDaily(json.optJSONObject("daily")),
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

        private const val MILLIS_PER_DAY = 24.0 * 60.0 * 60.0 * 1_000.0

        private fun startOfDay(millis: Long, zone: TimeZone): Long {
            val calendar = Calendar.getInstance(zone, Locale.ROOT)
            calendar.timeInMillis = millis
            calendar.set(Calendar.HOUR_OF_DAY, 0)
            calendar.set(Calendar.MINUTE, 0)
            calendar.set(Calendar.SECOND, 0)
            calendar.set(Calendar.MILLISECOND, 0)
            return calendar.timeInMillis
        }
    }
}
