package com.vocahq.vocaphone.telemetry

import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody

/** The outcome of one attempted batch. Determines whether it is worth retrying. */
internal enum class TelemetryDelivery {
    /** The server took it. */
    DELIVERED,

    /**
     * The server refused it and always will — a bad app key, a malformed
     * payload, a schema the server no longer accepts. Retrying is pointless
     * and the batch is dropped.
     */
    REJECTED,

    /** Transient: no network, a 5xx, a timeout. Worth exactly one more try. */
    UNAVAILABLE,
}

internal interface TelemetrySink {
    suspend fun send(batch: List<TelemetryRecord>): TelemetryDelivery
}

/**
 * What the F-Droid flavour, debug builds, and every unit test bind.
 *
 * The F-Droid APK has no way to report: `BuildConfig.TELEMETRY` is false there,
 * R8 sees a constant condition, and [AptabaseSink] is stripped along with the
 * host, the app key, the `App-Key` header, the settings switch and the
 * onboarding step. Verified by scanning the release APK's dex, not assumed —
 * the only telemetry strings that survive are the SDK version constant and one
 * section title, both inert because nothing can construct a request or reach a
 * control. That keeps the flavour clear of the `Tracking` anti-feature without
 * anyone having to trust a runtime check.
 */
internal object NoOpTelemetrySink : TelemetrySink {
    override suspend fun send(batch: List<TelemetryRecord>) = TelemetryDelivery.DELIVERED
}

/**
 * The only code in this app that sends usage data anywhere.
 *
 * Roughly a hundred lines against Aptabase's documented ingest API, rather than
 * its MIT-licensed SDK. The dependency is not the problem — the SDK's
 * `systemProps` is, since it auto-populates `deviceModel` and a full
 * `osVersion` that this app deliberately does not send (see
 * [TelemetrySystemProps]). Owning the request is what makes omitting them a
 * one-line decision instead of a fork, and it keeps "no analytics SDK" true in
 * the README and the Play listing.
 */
internal class AptabaseSink(
    private val host: String = TelemetryConfig.host,
    private val appKey: String = TelemetryConfig.appKey,
    private val client: OkHttpClient = defaultClient(),
) : TelemetrySink {

    override suspend fun send(batch: List<TelemetryRecord>): TelemetryDelivery {
        if (batch.isEmpty()) return TelemetryDelivery.DELIVERED
        val url = host.trimEnd('/') + TelemetryConfig.INGEST_PATH
        val request = Request.Builder()
            .url(url)
            .header("App-Key", appKey)
            // Not set to anything identifying. Aptabase hashes the User-Agent
            // together with the IP and its daily salt to derive the anonymous
            // user, so this string is an input to that hash and nothing else;
            // a version-only value keeps it from carrying device detail.
            .header("User-Agent", TelemetryConfig.SDK_VERSION)
            .post(batch.toRequestBody().toRequestBody(JSON))
            .build()

        return withContext(Dispatchers.IO) {
            try {
                client.newCall(request).execute().use { response ->
                    when {
                        response.isSuccessful -> TelemetryDelivery.DELIVERED
                        // 4xx is the server saying this payload is wrong, not
                        // that it is busy. Retrying a rejected batch just
                        // burns battery on a request that cannot succeed.
                        response.code in 400..499 -> TelemetryDelivery.REJECTED
                        else -> TelemetryDelivery.UNAVAILABLE
                    }
                }
            } catch (_: IOException) {
                TelemetryDelivery.UNAVAILABLE
            }
        }
    }

    private companion object {
        val JSON = "application/json; charset=utf-8".toMediaType()

        /**
         * Short timeouts and no retry-on-failure. Nothing here is worth making
         * a user's phone wait, and OkHttp's own retry would multiply requests
         * that [Telemetry] already bounds.
         */
        fun defaultClient(): OkHttpClient = OkHttpClient.Builder()
            .connectTimeout(10, TimeUnit.SECONDS)
            .readTimeout(10, TimeUnit.SECONDS)
            .writeTimeout(10, TimeUnit.SECONDS)
            .retryOnConnectionFailure(false)
            .build()
    }
}
