package io.github.mrsunglasses.localflow.settings

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.intPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.core.stringSetPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import io.github.mrsunglasses.localflow.core.TranscriptionLanguage
import io.github.mrsunglasses.localflow.core.WritingStyle
import io.github.mrsunglasses.localflow.security.TokenVault
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

/** When the floating bubble is allowed to appear. */
enum class BubbleBehavior {
    EVERY_EDITABLE_FIELD,
    OFF,
    ;

    val displayName: String
        get() = when (this) {
            EVERY_EDITABLE_FIELD -> "Every eligible text field"
            OFF -> "Never (companion app only)"
        }
}

data class LocalFlowSettings(
    val gatewayUrl: String = "",
    val hasToken: Boolean = false,
    val language: TranscriptionLanguage = TranscriptionLanguage.DEFAULT,
    val style: WritingStyle = WritingStyle.DEFAULT,
    val automaticInsertion: Boolean = true,
    val bubbleBehavior: BubbleBehavior = BubbleBehavior.EVERY_EDITABLE_FIELD,
    val audioRetention: AudioRetention = AudioRetention.DEFAULT,
    val excludedPackages: Set<String> = emptySet(),
    val disclosureAccepted: Boolean = false,
    val onboardingComplete: Boolean = false,
    val lastEngine: String = "",
    val lastEngineReady: Boolean = false,
    val lastStreamingSupported: Boolean = false,
) {
    val isConfigured: Boolean get() = gatewayUrl.isNotEmpty() && hasToken
}

private val Context.dataStore: DataStore<Preferences> by preferencesDataStore(name = "localflow")

/**
 * Every user-visible preference plus the sealed gateway token. The plaintext
 * token is only ever produced on demand by [token]; it is never part of the
 * observable settings state.
 */
class SettingsRepository(private val context: Context) {

    val settings: Flow<LocalFlowSettings> = context.dataStore.data.map { it.toSettings() }

    suspend fun current(): LocalFlowSettings = settings.first()

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
        }
        TokenVault.clear()
    }

    suspend fun setLanguage(language: TranscriptionLanguage) = put(Keys.LANGUAGE, language.wireValue)

    suspend fun setStyle(style: WritingStyle) = put(Keys.STYLE, style.wireValue)

    suspend fun setAutomaticInsertion(enabled: Boolean) = put(Keys.AUTOMATIC_INSERTION, enabled)

    suspend fun setBubbleBehavior(behavior: BubbleBehavior) = put(Keys.BUBBLE_BEHAVIOR, behavior.name)

    suspend fun setAudioRetention(retention: AudioRetention) = put(Keys.RETENTION_HOURS, retention.hours)

    suspend fun setExcludedPackages(packages: Set<String>) = put(Keys.EXCLUDED_PACKAGES, packages)

    suspend fun setDisclosureAccepted(accepted: Boolean) = put(Keys.DISCLOSURE_ACCEPTED, accepted)

    suspend fun setOnboardingComplete(complete: Boolean) = put(Keys.ONBOARDING_COMPLETE, complete)

    suspend fun recordEngineStatus(engine: String, ready: Boolean, streamingSupported: Boolean) {
        context.dataStore.edit { preferences ->
            preferences[Keys.LAST_ENGINE] = engine
            preferences[Keys.LAST_ENGINE_READY] = ready
            preferences[Keys.LAST_STREAMING] = streamingSupported
        }
    }

    private suspend fun <T> put(key: Preferences.Key<T>, value: T) {
        context.dataStore.edit { it[key] = value }
    }

    private fun Preferences.toSettings() = LocalFlowSettings(
        gatewayUrl = this[Keys.GATEWAY_URL].orEmpty(),
        hasToken = this[Keys.TOKEN_CIPHERTEXT] != null,
        language = TranscriptionLanguage.fromWire(this[Keys.LANGUAGE]),
        style = WritingStyle.fromWire(this[Keys.STYLE]),
        automaticInsertion = this[Keys.AUTOMATIC_INSERTION] ?: true,
        bubbleBehavior = this[Keys.BUBBLE_BEHAVIOR]?.let { name ->
            BubbleBehavior.entries.firstOrNull { it.name == name }
        } ?: BubbleBehavior.EVERY_EDITABLE_FIELD,
        audioRetention = AudioRetention.fromHours(this[Keys.RETENTION_HOURS]),
        excludedPackages = this[Keys.EXCLUDED_PACKAGES].orEmpty(),
        disclosureAccepted = this[Keys.DISCLOSURE_ACCEPTED] ?: false,
        onboardingComplete = this[Keys.ONBOARDING_COMPLETE] ?: false,
        lastEngine = this[Keys.LAST_ENGINE].orEmpty(),
        lastEngineReady = this[Keys.LAST_ENGINE_READY] ?: false,
        lastStreamingSupported = this[Keys.LAST_STREAMING] ?: false,
    )

    private object Keys {
        val GATEWAY_URL = stringPreferencesKey("gateway_url")
        val TOKEN_CIPHERTEXT = stringPreferencesKey("gateway_token_ciphertext")
        val TOKEN_NONCE = stringPreferencesKey("gateway_token_nonce")
        val LANGUAGE = stringPreferencesKey("transcription_language")
        val STYLE = stringPreferencesKey("writing_style")
        val AUTOMATIC_INSERTION = booleanPreferencesKey("automatic_insertion")
        val BUBBLE_BEHAVIOR = stringPreferencesKey("bubble_behavior")
        val RETENTION_HOURS = intPreferencesKey("audio_retention_hours")
        val EXCLUDED_PACKAGES = stringSetPreferencesKey("excluded_packages")
        val DISCLOSURE_ACCEPTED = booleanPreferencesKey("disclosure_accepted")
        val ONBOARDING_COMPLETE = booleanPreferencesKey("onboarding_complete")
        val LAST_ENGINE = stringPreferencesKey("last_engine")
        val LAST_ENGINE_READY = booleanPreferencesKey("last_engine_ready")
        val LAST_STREAMING = booleanPreferencesKey("last_streaming_supported")
    }
}
