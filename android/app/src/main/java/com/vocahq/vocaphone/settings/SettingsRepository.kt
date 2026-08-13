package com.vocahq.vocaphone.settings

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.intPreferencesKey
import androidx.datastore.preferences.core.longPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.core.stringSetPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import com.vocahq.vocaphone.core.MicrophonePreference
import com.vocahq.vocaphone.core.ModelLanguageSupport
import com.vocahq.vocaphone.local.LocalModelCatalog
import com.vocahq.vocaphone.local.LocalModelDescriptor
import com.vocahq.vocaphone.core.TranscriptionLanguage
import com.vocahq.vocaphone.core.TranscriptionQuality
import com.vocahq.vocaphone.core.WritingStyle
import com.vocahq.vocaphone.security.TokenVault
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map

/** How long a failed recording is kept so the user can still press Retry. */
enum class AudioRetention(val hours: Int) {
    ONE_HOUR(1),
    SIX_HOURS(6),
    ONE_DAY(24),
    ;

    val displayName: String
        get() = when (this) {
            ONE_HOUR -> "1 hour"
            SIX_HOURS -> "6 hours"
            ONE_DAY -> "24 hours"
        }

    companion object {
        val DEFAULT = SIX_HOURS
        fun fromHours(hours: Int?): AudioRetention =
            entries.firstOrNull { it.hours == hours } ?: DEFAULT
    }
}

data class VocaPhoneSettings(
    val gatewayUrl: String = "",
    val hasToken: Boolean = false,
    val language: TranscriptionLanguage = TranscriptionLanguage.DEFAULT,
    val style: WritingStyle = WritingStyle.DEFAULT,
    val microphone: MicrophonePreference = MicrophonePreference.DEFAULT,
    val audioRetention: AudioRetention = AudioRetention.DEFAULT,
    val onboardingComplete: Boolean = false,
    val lastEngine: String = "",
    val lastEngineReady: Boolean = false,
    val lastStreamingSupported: Boolean = false,
    val lastEngineCheckedAtMillis: Long? = null,
    /**
     * Languages the gateway's loaded model covers, empty when it made no claim.
     * Drives which options the language picker offers rather than what it hides.
     */
    val modelLanguages: Set<String> = emptySet(),
    val modelDetectsLanguage: Boolean = false,
    val localTranscriptionEnabled: Boolean = false,
    val localModelId: String = "",
    /** Governs the on-device engines only; the gateway decides for itself. */
    val transcriptionQuality: TranscriptionQuality = TranscriptionQuality.DEFAULT,
    /**
     * Names and jargon to bias an on-device Whisper model toward, as the user
     * typed them. Parsed by [com.vocahq.vocaphone.core.CustomVocabulary] rather
     * than stored pre-split, so the text they see back is the text they wrote.
     */
    val customVocabulary: String = "",
) {

    /**
     * The language to actually send. A stored choice goes stale when the gateway
     * switches to a model that cannot honour it, and sending it anyway produces
     * the wrong-language failure this whole mechanism exists to prevent.
     */
    val effectiveLanguage: TranscriptionLanguage
        get() = ModelLanguageSupport.resolve(
            language,
            activeModelLanguages,
            activeModelDetectsLanguage,
        )

    /**
     * The language claim that governs the picker. With on-device transcription on
     * the gateway's last engine report is irrelevant and often wrong in both
     * directions: it can hide languages the local model supports, or offer ones
     * it does not.
     */
    private val localModel: LocalModelDescriptor?
        get() = if (localTranscriptionEnabled) LocalModelCatalog.find(localModelId) else null

    val activeModelLanguages: Set<String>
        get() = localModel?.languageCodes ?: modelLanguages

    val activeModelDetectsLanguage: Boolean
        get() = localModel?.detectsLanguage ?: modelDetectsLanguage
    val isConfigured: Boolean get() = gatewayUrl.isNotEmpty() && hasToken
    val hasLocalModelSelection: Boolean get() = localModelId.isNotEmpty()
}

private val Context.dataStore: DataStore<Preferences> by preferencesDataStore(name = "vocaphone")

/**
 * Every user-visible preference plus the sealed gateway token. The plaintext
 * token is only ever produced on demand by [token]; it is never part of the
 * observable settings state.
 */
class SettingsRepository(private val context: Context) {

    val settings: Flow<VocaPhoneSettings> = context.dataStore.data.map { it.toSettings() }

    suspend fun current(): VocaPhoneSettings = settings.first()

    suspend fun token(): String? {
        val preferences = context.dataStore.data.first()
        val ciphertext = preferences[Keys.TOKEN_CIPHERTEXT] ?: return null
        val nonce = preferences[Keys.TOKEN_NONCE] ?: return null
        return TokenVault.open(TokenVault.SealedToken(ciphertext, nonce))
    }

    suspend fun setGateway(url: String, token: String) {
        val sealed = TokenVault.seal(token)
        context.dataStore.edit { preferences ->
            preferences[Keys.GATEWAY_URL] = url
            preferences[Keys.TOKEN_CIPHERTEXT] = sealed.ciphertext
            preferences[Keys.TOKEN_NONCE] = sealed.nonce
            preferences.clearEngineStatus()
        }
    }

    /** Corrects the address while leaving the sealed token exactly as it is. */
    suspend fun setGatewayUrl(url: String) {
        context.dataStore.edit { preferences ->
            preferences[Keys.GATEWAY_URL] = url
            preferences.clearEngineStatus()
        }
    }

    suspend fun clearGateway() {
        context.dataStore.edit { preferences ->
            preferences.remove(Keys.GATEWAY_URL)
            preferences.remove(Keys.TOKEN_CIPHERTEXT)
            preferences.remove(Keys.TOKEN_NONCE)
            preferences.remove(Keys.LAST_ENGINE)
            preferences.remove(Keys.LAST_ENGINE_READY)
            preferences.remove(Keys.LAST_STREAMING)
            preferences.remove(Keys.LAST_ENGINE_CHECKED_AT)
            preferences.remove(Keys.MODEL_LANGUAGES)
            preferences.remove(Keys.MODEL_DETECTS_LANGUAGE)
        }
        TokenVault.clear()
    }

    suspend fun setLanguage(language: TranscriptionLanguage) = put(Keys.LANGUAGE, language.wireValue)

    suspend fun setStyle(style: WritingStyle) = put(Keys.STYLE, style.wireValue)

    suspend fun setMicrophone(preference: MicrophonePreference) =
        put(Keys.MICROPHONE, preference.storedValue)

    suspend fun setAudioRetention(retention: AudioRetention) = put(Keys.RETENTION_HOURS, retention.hours)

    suspend fun setOnboardingComplete(complete: Boolean) = put(Keys.ONBOARDING_COMPLETE, complete)

    suspend fun setLocalTranscriptionEnabled(enabled: Boolean) =
        put(Keys.LOCAL_TRANSCRIPTION_ENABLED, enabled)

    suspend fun setLocalModel(modelId: String) = put(Keys.LOCAL_MODEL_ID, modelId)

    suspend fun setTranscriptionQuality(quality: TranscriptionQuality) =
        put(Keys.TRANSCRIPTION_QUALITY, quality.storedValue)

    suspend fun setCustomVocabulary(vocabulary: String) =
        put(Keys.CUSTOM_VOCABULARY, vocabulary)

    suspend fun recordEngineStatus(
        engine: String,
        ready: Boolean,
        streamingSupported: Boolean,
        checkedAtMillis: Long = System.currentTimeMillis(),
        modelLanguages: Set<String> = emptySet(),
        modelDetectsLanguage: Boolean = false,
    ) {
        context.dataStore.edit { preferences ->
            preferences[Keys.LAST_ENGINE] = engine
            preferences[Keys.LAST_ENGINE_READY] = ready
            preferences[Keys.LAST_STREAMING] = streamingSupported
            preferences[Keys.LAST_ENGINE_CHECKED_AT] = checkedAtMillis
            preferences[Keys.MODEL_LANGUAGES] = modelLanguages
            preferences[Keys.MODEL_DETECTS_LANGUAGE] = modelDetectsLanguage
        }
    }

    private suspend fun <T> put(key: Preferences.Key<T>, value: T) {
        context.dataStore.edit { it[key] = value }
    }

    private fun Preferences.toSettings() = VocaPhoneSettings(
        gatewayUrl = this[Keys.GATEWAY_URL].orEmpty(),
        hasToken = this[Keys.TOKEN_CIPHERTEXT] != null,
        language = TranscriptionLanguage.fromWire(this[Keys.LANGUAGE]),
        style = WritingStyle.fromWire(this[Keys.STYLE]),
        microphone = MicrophonePreference.fromStored(this[Keys.MICROPHONE]),
        audioRetention = AudioRetention.fromHours(this[Keys.RETENTION_HOURS]),
        onboardingComplete = this[Keys.ONBOARDING_COMPLETE] ?: false,
        lastEngine = this[Keys.LAST_ENGINE].orEmpty(),
        lastEngineReady = this[Keys.LAST_ENGINE_READY] ?: false,
        lastStreamingSupported = this[Keys.LAST_STREAMING] ?: false,
        lastEngineCheckedAtMillis = this[Keys.LAST_ENGINE_CHECKED_AT],
        modelLanguages = this[Keys.MODEL_LANGUAGES].orEmpty(),
        modelDetectsLanguage = this[Keys.MODEL_DETECTS_LANGUAGE] ?: false,
        localTranscriptionEnabled = this[Keys.LOCAL_TRANSCRIPTION_ENABLED] ?: false,
        localModelId = this[Keys.LOCAL_MODEL_ID].orEmpty(),
        transcriptionQuality = TranscriptionQuality.fromStored(this[Keys.TRANSCRIPTION_QUALITY]),
        customVocabulary = this[Keys.CUSTOM_VOCABULARY].orEmpty(),
    )

    private object Keys {
        val GATEWAY_URL = stringPreferencesKey("gateway_url")
        val TOKEN_CIPHERTEXT = stringPreferencesKey("gateway_token_ciphertext")
        val TOKEN_NONCE = stringPreferencesKey("gateway_token_nonce")
        val LANGUAGE = stringPreferencesKey("transcription_language")
        val STYLE = stringPreferencesKey("writing_style")
        val MICROPHONE = stringPreferencesKey("microphone_preference")
        val RETENTION_HOURS = intPreferencesKey("audio_retention_hours")
        val ONBOARDING_COMPLETE = booleanPreferencesKey("onboarding_complete")
        val LAST_ENGINE = stringPreferencesKey("last_engine")
        val LAST_ENGINE_READY = booleanPreferencesKey("last_engine_ready")
        val LAST_STREAMING = booleanPreferencesKey("last_streaming_supported")
        val LAST_ENGINE_CHECKED_AT = longPreferencesKey("last_engine_checked_at")
        val MODEL_LANGUAGES = stringSetPreferencesKey("model_languages")
        val MODEL_DETECTS_LANGUAGE = booleanPreferencesKey("model_detects_language")
        val LOCAL_TRANSCRIPTION_ENABLED = booleanPreferencesKey("local_transcription_enabled")
        val LOCAL_MODEL_ID = stringPreferencesKey("local_model_id")
        val TRANSCRIPTION_QUALITY = stringPreferencesKey("transcription_quality")
        val CUSTOM_VOCABULARY = stringPreferencesKey("custom_vocabulary")
    }

    private fun androidx.datastore.preferences.core.MutablePreferences.clearEngineStatus() {
        remove(Keys.LAST_ENGINE)
        remove(Keys.LAST_ENGINE_READY)
        remove(Keys.LAST_STREAMING)
        remove(Keys.LAST_ENGINE_CHECKED_AT)
        remove(Keys.MODEL_LANGUAGES)
        remove(Keys.MODEL_DETECTS_LANGUAGE)
    }
}
