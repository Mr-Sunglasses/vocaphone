package com.vocahq.vocaphone.gateway

import java.io.File
import java.io.IOException
import java.util.UUID
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.Call
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.asRequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import org.json.JSONArray
import org.json.JSONObject

/**
 * The complete iOS gateway contract, unchanged: `/health`, `/v1/models`, the
 * session lifecycle, and the `/v1/stream` WebSocket.
 */
class GatewayClient(
    baseUrl: String,
    private val token: String,
    private val httpClient: OkHttpClient = defaultClient(),
) {
    val baseUrl: HttpUrl = requireNotNull(baseUrl.toHttpUrlOrNull()) {
        "The gateway address is not a valid URL."
    }

    suspend fun health(): GatewayHealth = withContext(Dispatchers.IO) {
        val request = Request.Builder().url(endpoint("health")).build()
        GatewayHealth.from(execute(request, timeoutSeconds = 5, authenticated = false).asJsonObject())
    }

    /** Confirms the token is accepted; the response itself is the engine list. */
    suspend fun verifyAuthentication(): List<String> = withContext(Dispatchers.IO) {
        val request = Request.Builder().url(endpoint("v1", "models")).build()
        val body = execute(request, timeoutSeconds = 10).asString()
        val models = JSONArray(body)
        List(models.length()) { models.getJSONObject(it).optString("id") }
    }

    suspend fun createSession(
        sessionId: UUID,
        language: String,
        style: String,
    ): GatewaySession = withContext(Dispatchers.IO) {
        val payload = JSONObject()
            .put("client_session_id", sessionId.toString())
            .put("language", language)
            .put("style", style)
        val request = Request.Builder()
            .url(endpoint("v1", "sessions"))
            .post(payload.toString().toRequestBody(JSON_MEDIA_TYPE))
            .build()
        GatewaySession.from(execute(request, timeoutSeconds = 15).asJsonObject())
    }

    suspend fun uploadAudio(sessionId: UUID, wavFile: File): GatewaySession =
        withContext(Dispatchers.IO) {
            // Streamed from disk: holding the recording in memory would double it
            // exactly when the network is already struggling.
            val body: RequestBody = wavFile.asRequestBody(WAV_MEDIA_TYPE)
            val request = Request.Builder()
                .url(endpoint("v1", "sessions", sessionId.toString(), "audio"))
                .put(body)
                .build()
            GatewaySession.from(execute(request, timeoutSeconds = 60).asJsonObject())
        }

    suspend fun finish(sessionId: UUID): GatewaySession = withContext(Dispatchers.IO) {
        val request = Request.Builder()
            .url(endpoint("v1", "sessions", sessionId.toString(), "finish"))
            .post(EMPTY_BODY)
            .build()
        GatewaySession.from(execute(request, timeoutSeconds = 120).asJsonObject())
    }

    suspend fun delete(sessionId: UUID) = withContext(Dispatchers.IO) {
        val request = Request.Builder()
            .url(endpoint("v1", "sessions", sessionId.toString()))
            .delete()
            .build()
        // A gateway that has already forgotten the session is the outcome we want.
        runCatching { execute(request, timeoutSeconds = 15) }
        Unit
    }

    /**
     * Opens the streaming socket and completes the `start`/`ready` handshake.
     * Support is negotiated on the authenticated socket itself: a separate health
     * preflight noticeably delays recording on mDNS hostnames that advertise an
     * unreachable address.
     */
    fun openStream(
        sessionId: UUID,
        language: String,
        style: String,
        sampleRate: Int,
    ): GatewayAudioStream = GatewayAudioStream(
        client = httpClient.newBuilder()
            .readTimeout(0, TimeUnit.MILLISECONDS)
            .connectTimeout(8, TimeUnit.SECONDS)
            .pingInterval(20, TimeUnit.SECONDS)
            .build(),
        url = webSocketEndpoint(),
        token = token,
        sessionId = sessionId,
        language = language,
        style = style,
        sampleRate = sampleRate,
    )

    private fun endpoint(vararg segments: String): HttpUrl =
        baseUrl.newBuilder().apply { segments.forEach { addPathSegment(it) } }.build()

    private fun webSocketEndpoint(): HttpUrl = endpoint("v1", "stream")

    private fun execute(
        request: Request,
        timeoutSeconds: Long,
        authenticated: Boolean = true,
    ): Response {
        val authorized = if (authenticated) {
            request.newBuilder().header("Authorization", "Bearer $token").build()
        } else {
            request
        }
        val call: Call = httpClient.newBuilder()
            .callTimeout(timeoutSeconds, TimeUnit.SECONDS)
            .readTimeout(timeoutSeconds, TimeUnit.SECONDS)
            .build()
            .newCall(authorized)

        val response = try {
            call.execute()
        } catch (error: IOException) {
            throw GatewayException.unreachable(error)
        }
        if (!response.isSuccessful) {
            val code = runCatching {
                JSONObject(response.body.string()).getJSONObject("error").optString("code")
            }.getOrNull()?.takeIf { it.isNotEmpty() }
            response.close()
            throw GatewayException.fromStatus(response.code, code)
        }
        return response
    }

    private fun Response.asString(): String = use { it.body.string() }

    private fun Response.asJsonObject(): JSONObject = JSONObject(asString())

    companion object {
        val JSON_MEDIA_TYPE = "application/json".toMediaType()
        val WAV_MEDIA_TYPE = "audio/wav".toMediaType()
        private val EMPTY_BODY = ByteArray(0).toRequestBody(null)

        fun defaultClient(): OkHttpClient = OkHttpClient.Builder()
            .connectTimeout(8, TimeUnit.SECONDS)
            .retryOnConnectionFailure(true)
            .build()
    }
}
