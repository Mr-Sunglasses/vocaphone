package com.vocahq.vocaphone.telemetry

import android.os.Build
import com.vocahq.vocaphone.BuildConfig
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.util.Locale
import org.json.JSONObject

/**
 * The device and build facts attached to every event.
 *
 * ## Why this is narrower than Aptabase's own SDKs
 *
 * The official Swift and Kotlin SDKs auto-populate `systemProps` with
 * `deviceModel` and a full `osVersion`. Both are omitted or coarsened here, on
 * purpose:
 *
 * - **No `deviceModel` at all.** Play Console already reports the device
 *   distribution for every install, not just opted-in ones, so sending it here
 *   buys nothing — while model plus exact OS build plus locale is a usable
 *   fingerprint at beta population sizes, which would undo most of what the
 *   daily-rotating server-side hash achieves.
 * - **`osVersion` is the major only** — `"15"`, never `"15.1.1"`. Enough to
 *   decide what to keep supporting, not enough to narrow anyone down.
 * - **`locale` is the language subtag only** — `"en"`, never `"en-IN"`. The
 *   region is the identifying half and is not needed to know which languages
 *   matter.
 *
 * Sending less than the SDK sends is trivial when you own the request and
 * requires a fork when you do not. That is the main reason this client is
 * hand-rolled, and `TelemetryTest` fails the build if a field ever creeps back
 * in — see `no device identifier is ever sent` and the `systemProps` allowlist
 * assertion beside it.
 */
data class TelemetrySystemProps(
    val locale: String,
    val osName: String,
    val osVersion: String,
    val isDebug: Boolean,
    val appVersion: String,
    val sdkVersion: String,
) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("locale", locale)
        put("osName", osName)
        put("osVersion", osVersion)
        put("isDebug", isDebug)
        put("appVersion", appVersion)
        put("sdkVersion", sdkVersion)
    }

    companion object {
        /** The complete set of keys that may appear. Asserted by test. */
        val KEYS = setOf("locale", "osName", "osVersion", "isDebug", "appVersion", "sdkVersion")

        fun current(): TelemetrySystemProps = TelemetrySystemProps(
            locale = languageSubtag(Locale.getDefault()),
            osName = "Android",
            osVersion = majorVersion(Build.VERSION.RELEASE),
            isDebug = BuildConfig.DEBUG,
            appVersion = BuildConfig.VERSION_NAME,
            sdkVersion = TelemetryConfig.SDK_VERSION,
        )

        /**
         * `"en"` from `en_IN`, and `"und"` — the ISO 639-2 code for an
         * undetermined language — when the platform gives nothing usable. A
         * fixed placeholder keeps the column parseable rather than mixing
         * empty strings into it.
         */
        fun languageSubtag(locale: Locale): String {
            val language = locale.language.lowercase(Locale.ROOT)
            return if (language.matches(Regex("[a-z]{2,3}"))) language else "und"
        }

        /**
         * `"15"` from `"15"`, `"15.1"` or `"15.1.1"`, and `"0"` when the
         * platform reports something unparseable. Digits only, so the column
         * can be sorted and grouped without cleaning.
         */
        fun majorVersion(release: String?): String {
            val major = release.orEmpty().trim().substringBefore('.').filter { it.isDigit() }
            return major.ifEmpty { "0" }
        }
    }
}

/**
 * One event, in the shape Aptabase's `POST /api/v0/events` accepts.
 *
 * `props` is a `Map<String, String>` only because JSON needs one at the edge.
 * Nothing public can populate it with an arbitrary string: [Telemetry] builds
 * every entry from the enums in `TelemetryEvent.kt`, and the constructor is
 * internal so no call site outside this package can reach it.
 *
 * `@ConsistentCopyVisibility` makes the generated `copy()` internal too.
 * Without it a caller could take a record from the "See what's sent" screen and
 * copy it with different props, which is the same hole as a public constructor
 * wearing a different hat.
 */
@ConsistentCopyVisibility
data class TelemetryRecord internal constructor(
    val eventName: String,
    val timestamp: Instant,
    val sessionId: String,
    val systemProps: TelemetrySystemProps,
    val props: Map<String, String>,
) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("timestamp", ISO8601.format(timestamp.atOffset(ZoneOffset.UTC)))
        put("sessionId", sessionId)
        put("eventName", eventName)
        put("systemProps", systemProps.toJson())
        put("props", JSONObject().apply { props.forEach { (key, value) -> put(key, value) } })
    }

    companion object {
        /**
         * Aptabase's documented timestamp format, milliseconds and a literal Z.
         * Always UTC: a local offset would carry the user's timezone, which is
         * a coarse location and has no business in an anonymous event.
         */
        private val ISO8601: DateTimeFormatter =
            DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.ROOT)
    }
}

/** What actually goes over the wire: a JSON array, at most [TelemetryConfig.MAX_BATCH] long. */
fun List<TelemetryRecord>.toRequestBody(): String =
    joinToString(separator = ",", prefix = "[", postfix = "]") { it.toJson().toString() }
