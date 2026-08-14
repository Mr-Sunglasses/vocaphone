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

internal object ClipboardHistory {
    const val MAX_ITEMS = 20
    const val MAX_ITEM_CHARS = 4_000
    const val SEPARATOR = "\u001e"

    fun remember(existing: List<String>, incoming: String): List<String> {
        val text = incoming.trim().take(MAX_ITEM_CHARS)
        if (text.isEmpty()) return existing
        return (listOf(text) + existing.filter { it != text }).take(MAX_ITEMS)
    }

    fun encode(items: List<String>): String = items.joinToString(SEPARATOR)

    fun decode(stored: String?): List<String> =
        stored?.split(SEPARATOR)?.filter { it.isNotEmpty() }.orEmpty()
}

enum class KeyboardHeight(
    val storedValue: String,
    val keyHeightDp: Int,
    val dictationBarDp: Int,
) {
    COMPACT("compact", 42, 48),
    DEFAULT("default", 48, 52),
    TALL("tall", 56, 58),
    ;

    val displayName: String
        get() = when (this) {
            COMPACT -> "Compact"
            DEFAULT -> "Default"
            TALL -> "Tall"
        }

    companion object {
        fun fromStored(value: String?): KeyboardHeight =
            entries.firstOrNull { it.storedValue == value } ?: DEFAULT
    }
}

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
    val numberRowEnabled: Boolean = false,
    val keyboardHeight: KeyboardHeight = KeyboardHeight.DEFAULT,
    val suggestionsEnabled: Boolean = true,
    val correctionsEnabled: Boolean = true,
    val numberKeyHintsEnabled: Boolean = true,
    val asciiEmojiEnabled: Boolean = true,
    val swipeTypingEnabled: Boolean = true,
    val clipboardChipEnabled: Boolean = true,
    val clipboardHistoryEnabled: Boolean = true,
    val clipboardHistory: List<String> = emptyList(),
    val emojiRecents: List<String> = emptyList(),
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

    suspend fun setNumberRowEnabled(enabled: Boolean) = put(Keys.NUMBER_ROW, enabled)

    suspend fun setKeyboardHeight(height: KeyboardHeight) = put(Keys.KEYBOARD_HEIGHT, height.storedValue)

    suspend fun setSuggestionsEnabled(enabled: Boolean) = put(Keys.SUGGESTIONS, enabled)

    suspend fun setCorrectionsEnabled(enabled: Boolean) = put(Keys.CORRECTIONS, enabled)

    suspend fun setNumberKeyHintsEnabled(enabled: Boolean) = put(Keys.NUMBER_KEY_HINTS, enabled)

    suspend fun setAsciiEmojiEnabled(enabled: Boolean) = put(Keys.ASCII_EMOJI, enabled)

    suspend fun setSwipeTypingEnabled(enabled: Boolean) = put(Keys.SWIPE_TYPING, enabled)

    suspend fun setClipboardChipEnabled(enabled: Boolean) = put(Keys.CLIPBOARD_CHIP, enabled)

    suspend fun setClipboardHistoryEnabled(enabled: Boolean) = put(Keys.CLIPBOARD_HISTORY_ENABLED, enabled)

    suspend fun recordClipboardHistory(text: String) {
        context.dataStore.edit { preferences ->
            val current = ClipboardHistory.decode(preferences[Keys.CLIPBOARD_HISTORY])
            preferences[Keys.CLIPBOARD_HISTORY] = ClipboardHistory.encode(
                ClipboardHistory.remember(current, text),
            )
        }
    }

    suspend fun removeClipboardHistory(text: String) {
        context.dataStore.edit { preferences ->
            val next = ClipboardHistory.decode(preferences[Keys.CLIPBOARD_HISTORY]).filter { it != text }
            preferences[Keys.CLIPBOARD_HISTORY] = ClipboardHistory.encode(next)
        }
    }

    suspend fun clearClipboardHistory() {
        context.dataStore.edit { it.remove(Keys.CLIPBOARD_HISTORY) }
    }

    suspend fun recordEmojiRecent(emoji: String) {
        context.dataStore.edit { preferences ->
            val current = decodeEmojiRecents(preferences[Keys.EMOJI_RECENTS])
            val next = listOf(emoji) + current.filter { it != emoji }
            preferences[Keys.EMOJI_RECENTS] = next.take(MAX_EMOJI_RECENTS).joinToString("\n")
        }
    }

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
        numberRowEnabled = this[Keys.NUMBER_ROW] ?: false,
        keyboardHeight = KeyboardHeight.fromStored(this[Keys.KEYBOARD_HEIGHT]),
        suggestionsEnabled = this[Keys.SUGGESTIONS] ?: true,
        correctionsEnabled = this[Keys.CORRECTIONS] ?: true,
        numberKeyHintsEnabled = this[Keys.NUMBER_KEY_HINTS] ?: true,
        asciiEmojiEnabled = this[Keys.ASCII_EMOJI] ?: true,
        swipeTypingEnabled = this[Keys.SWIPE_TYPING] ?: true,
        clipboardChipEnabled = this[Keys.CLIPBOARD_CHIP] ?: true,
        clipboardHistoryEnabled = this[Keys.CLIPBOARD_HISTORY_ENABLED] ?: true,
        clipboardHistory = ClipboardHistory.decode(this[Keys.CLIPBOARD_HISTORY]),
        emojiRecents = decodeEmojiRecents(this[Keys.EMOJI_RECENTS]),
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
        val NUMBER_ROW = booleanPreferencesKey("keyboard_number_row")
        val KEYBOARD_HEIGHT = stringPreferencesKey("keyboard_height")
        val SUGGESTIONS = booleanPreferencesKey("keyboard_suggestions")
        val CORRECTIONS = booleanPreferencesKey("keyboard_corrections")
        val NUMBER_KEY_HINTS = booleanPreferencesKey("keyboard_number_key_hints")
        val ASCII_EMOJI = booleanPreferencesKey("keyboard_ascii_emoji")
        val SWIPE_TYPING = booleanPreferencesKey("keyboard_swipe_typing")
        val CLIPBOARD_CHIP = booleanPreferencesKey("keyboard_clipboard_chip")
        val CLIPBOARD_HISTORY_ENABLED = booleanPreferencesKey("keyboard_clipboard_history")
        val CLIPBOARD_HISTORY = stringPreferencesKey("keyboard_clipboard_history_items")
        val EMOJI_RECENTS = stringPreferencesKey("keyboard_emoji_recents")
    }

    private companion object {
        const val MAX_EMOJI_RECENTS = 30

        fun decodeEmojiRecents(stored: String?): List<String> =
            stored?.split('\n')?.filter { it.isNotEmpty() }.orEmpty()
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
