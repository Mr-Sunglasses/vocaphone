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
import com.vocahq.vocaphone.core.DictationTone
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
    const val IMAGE_PREFIX = "\u001fIMG\u001f"

    fun remember(existing: List<String>, incoming: String): List<String> {
        // Image tokens start with U+001F, which Java treats as whitespace.
        val text = if (isImage(incoming)) incoming.take(MAX_ITEM_CHARS)
        else incoming.trim().take(MAX_ITEM_CHARS)
        if (text.isEmpty()) return existing
        return (listOf(text) + existing.filter { it != text }).take(MAX_ITEMS)
    }

    fun encode(items: List<String>): String = items.joinToString(SEPARATOR)

    fun decode(stored: String?): List<String> =
        stored?.split(SEPARATOR)?.filter { it.isNotEmpty() }.orEmpty()

    fun isImage(stored: String): Boolean = stored.startsWith(IMAGE_PREFIX)

    fun encodeImage(mime: String, relativePath: String): String =
        "$IMAGE_PREFIX$mime\u001f$relativePath"

    fun parseImage(stored: String): Pair<String, String>? {
        if (!isImage(stored)) return null
        val rest = stored.removePrefix(IMAGE_PREFIX)
        val sep = rest.indexOf('\u001f')
        if (sep <= 0 || sep == rest.lastIndex) return null
        return rest.substring(0, sep) to rest.substring(sep + 1)
    }

    fun preview(stored: String): String =
        if (isImage(stored)) "Image" else stored.replace('\n', ' ')

    fun imagePaths(items: List<String>): Set<String> =
        items.mapNotNull { parseImage(it)?.second }.toSet()
}

enum class SplitKeyboard(val storedValue: String) {
    AUTO("auto"),
    ALWAYS("always"),
    NEVER("never"),
    ;

    val displayName: String
        get() = when (this) {
            AUTO -> "Auto"
            ALWAYS -> "Always"
            NEVER -> "Never"
        }

    companion object {
        val DEFAULT = AUTO

        fun fromStored(value: String?): SplitKeyboard =
            entries.firstOrNull { it.storedValue == value } ?: DEFAULT
    }
}

enum class KeyboardHeight(
    val storedValue: String,
    val keyHeightDp: Int,
    val dictationBarDp: Int,
) {
    COMPACT("compact", 42, 52),
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
            entries.firstOrNull { it.storedValue == value } ?: COMPACT
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

    val detail: String
        get() = when (this) {
            ONE_HOUR -> "Keep a failed recording for 1 hour so Retry still works."
            SIX_HOURS -> "Keep a failed recording for 6 hours so Retry still works."
            ONE_DAY -> "Keep a failed recording for 24 hours so Retry still works."
        }

    companion object {
        val DEFAULT = SIX_HOURS
        fun fromHours(hours: Int?): AudioRetention =
            entries.firstOrNull { it.hours == hours } ?: DEFAULT
    }
}

/**
 * How long an on-device model stays in RAM after the last dictation.
 *
 * Unloading frees battery and memory. Keeping it skips the multi-second load
 * on the next tap. [WHILE_OPEN] only unloads if Android trims the process.
 */
enum class ModelIdleTimeout(val storedValue: String, val delayMs: Long) {
    IMMEDIATELY("immediately", 0L),
    THIRTY_SECONDS("30s", 30_000L),
    TWO_MINUTES("2m", 2 * 60 * 1000L),
    TEN_MINUTES("10m", 10 * 60 * 1000L),
    WHILE_OPEN("while_open", -1L),
    ;

    val displayName: String
        get() = when (this) {
            IMMEDIATELY -> "Immediately"
            THIRTY_SECONDS -> "30 seconds"
            TWO_MINUTES -> "2 minutes"
            TEN_MINUTES -> "10 minutes"
            WHILE_OPEN -> "Until the app closes"
        }

    val detail: String
        get() = when (this) {
            IMMEDIATELY -> "Unload as soon as you stop dictating."
            THIRTY_SECONDS -> "Keep the model ready for a quick follow-up."
            TWO_MINUTES -> "A short pause between dictations will not reload."
            TEN_MINUTES -> "Stay warm through a longer break."
            WHILE_OPEN -> "Stay loaded until VocaPhone is killed or Android needs the RAM."
        }

    companion object {
        val DEFAULT = TWO_MINUTES
        fun fromStored(value: String?): ModelIdleTimeout =
            entries.firstOrNull { it.storedValue == value } ?: DEFAULT
    }
}

data class VocaPhoneSettings(
    val gatewayUrl: String = "",
    val hasToken: Boolean = false,
    val language: TranscriptionLanguage = TranscriptionLanguage.DEFAULT,
    val style: WritingStyle = WritingStyle.DEFAULT,
    val dictationTone: DictationTone = DictationTone.DEFAULT,
    val microphone: MicrophonePreference = MicrophonePreference.DEFAULT,
    val audioRetention: AudioRetention = AudioRetention.DEFAULT,
    val modelIdleTimeout: ModelIdleTimeout = ModelIdleTimeout.DEFAULT,
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
    /** First-run default is this phone. Gateway is opt-in from setup or settings. */
    val localTranscriptionEnabled: Boolean = true,
    val localModelId: String = "",
    /** Governs the on-device engines only; the gateway decides for itself. */
    val transcriptionQuality: TranscriptionQuality = TranscriptionQuality.DEFAULT,
    /**
     * Names and jargon to bias an on-device Whisper model toward, as the user
     * typed them. Parsed by [com.vocahq.vocaphone.core.CustomVocabulary] rather
     * than stored pre-split, so the text they see back is the text they wrote.
     */
    val customVocabulary: String = "",
    /**
     * When true (the default), Whisper is biased with [personalDictionary]
     * instead of [customVocabulary]. Turn it off to keep a separate list.
     */
    val syncWhisperDictionary: Boolean = true,
    val numberRowEnabled: Boolean = true,
    val keyboardHeight: KeyboardHeight = KeyboardHeight.COMPACT,
    val splitKeyboard: SplitKeyboard = SplitKeyboard.DEFAULT,
    val suggestionsEnabled: Boolean = true,
    val correctionsEnabled: Boolean = true,
    val numberKeyHintsEnabled: Boolean = true,
    val longPressSymbolsEnabled: Boolean = false,
    /**
     * Words the suggestion strip should complete, as the user typed or pasted
     * them. Newlines or commas; the keyboard parses the text on read.
     */
    val personalDictionary: String = "",
    val asciiEmojiEnabled: Boolean = true,
    val swipeTypingEnabled: Boolean = true,
    val clipboardChipEnabled: Boolean = true,
    val clipboardHistoryEnabled: Boolean = true,
    val clipboardHistory: List<String> = emptyList(),
    /** Last clip the user dismissed. The chip stays down until a different copy. */
    val dismissedClipboardText: String = "",
    val emojiRecents: List<String> = emptyList(),
    /**
     * Anonymous usage reporting. Off until the user turns it on; see
     * [com.vocahq.vocaphone.telemetry.TelemetryConfig] for what is sent and why
     * there is no install identifier behind it.
     */
    val telemetryEnabled: Boolean = false,
    /**
     * Whether the onboarding step that offers usage reporting has been shown.
     * Separate from [telemetryEnabled] because "declined" and "never asked"
     * have to be told apart: without this, someone who said no would be asked
     * again on every trip through guided setup.
     */
    val telemetryAsked: Boolean = false,
) {

    /**
     * The language to actually send. A stored choice goes stale when the gateway
     * switches to a model that cannot honour it, and sending it anyway produces
     * the wrong-language failure this whole mechanism exists to prevent.
     */
    val effectiveLanguage: TranscriptionLanguage
        get() = ModelLanguageSupport.resolve(language, activeModelLanguages)

    /**
     * The language claim that governs the picker. With on-device transcription on
     * the gateway's last engine report is irrelevant and often wrong in both
     * directions: it can hide languages the local model supports, or offer ones
     * it does not.
     */
    private val localModel: LocalModelDescriptor?
        get() = if (localTranscriptionEnabled) LocalModelCatalog.find(localModelId) else null

    val activeModelLanguages: Set<String>
        get() = localModel?.selectableLanguageCodes ?: modelLanguages

    val activeModelDetectsLanguage: Boolean
        get() = localModel?.detectsLanguage ?: modelDetectsLanguage
    val isConfigured: Boolean get() = gatewayUrl.isNotEmpty() && hasToken
    val hasLocalModelSelection: Boolean get() = localModelId.isNotEmpty()

    /**
     * Words actually handed to Whisper. The personal dictionary is the default
     * source so names taught on the strip also bias dictation.
     */
    val whisperVocabulary: String
        get() = if (syncWhisperDictionary) personalDictionary else customVocabulary
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

    suspend fun setDictationTone(tone: DictationTone) = put(Keys.DICTATION_TONE, tone.id)

    suspend fun setMicrophone(preference: MicrophonePreference) =
        put(Keys.MICROPHONE, preference.storedValue)

    suspend fun setAudioRetention(retention: AudioRetention) = put(Keys.RETENTION_HOURS, retention.hours)

    suspend fun setModelIdleTimeout(timeout: ModelIdleTimeout) =
        put(Keys.MODEL_IDLE_TIMEOUT, timeout.storedValue)

    suspend fun setOnboardingComplete(complete: Boolean) = put(Keys.ONBOARDING_COMPLETE, complete)

    suspend fun setLocalTranscriptionEnabled(enabled: Boolean) =
        put(Keys.LOCAL_TRANSCRIPTION_ENABLED, enabled)

    suspend fun setLocalModel(modelId: String) = put(Keys.LOCAL_MODEL_ID, modelId)

    suspend fun setTranscriptionQuality(quality: TranscriptionQuality) =
        put(Keys.TRANSCRIPTION_QUALITY, quality.storedValue)

    suspend fun setCustomVocabulary(vocabulary: String) =
        put(Keys.CUSTOM_VOCABULARY, vocabulary)

    suspend fun setSyncWhisperDictionary(enabled: Boolean) =
        put(Keys.SYNC_WHISPER_DICTIONARY, enabled)

    suspend fun setNumberRowEnabled(enabled: Boolean) = put(Keys.NUMBER_ROW, enabled)

    suspend fun setKeyboardHeight(height: KeyboardHeight) = put(Keys.KEYBOARD_HEIGHT, height.storedValue)

    suspend fun setSplitKeyboard(mode: SplitKeyboard) = put(Keys.SPLIT_KEYBOARD, mode.storedValue)

    suspend fun setSuggestionsEnabled(enabled: Boolean) = put(Keys.SUGGESTIONS, enabled)

    suspend fun setCorrectionsEnabled(enabled: Boolean) = put(Keys.CORRECTIONS, enabled)

    suspend fun setNumberKeyHintsEnabled(enabled: Boolean) = put(Keys.NUMBER_KEY_HINTS, enabled)

    suspend fun setLongPressSymbolsEnabled(enabled: Boolean) = put(Keys.LONG_PRESS_SYMBOLS, enabled)

    suspend fun setPersonalDictionary(words: String) = put(Keys.PERSONAL_DICTIONARY, words)

    /**
     * Appends one word in a single DataStore edit so two rapid strip taps
     * cannot drop the first. The keyboard only hands over words it already
     * treated as savable.
     */
    suspend fun addPersonalWord(word: String) {
        val cleaned = word.trim()
        if (cleaned.length < 3) return
        context.dataStore.edit { preferences ->
            val current = preferences[Keys.PERSONAL_DICTIONARY].orEmpty()
            val existing = current.split('\n', ',')
                .map { it.trim() }
                .filter { it.isNotEmpty() && !it.equals(cleaned, ignoreCase = true) }
            preferences[Keys.PERSONAL_DICTIONARY] =
                (listOf(cleaned) + existing).take(2_000).joinToString(", ")
        }
    }

    suspend fun setAsciiEmojiEnabled(enabled: Boolean) = put(Keys.ASCII_EMOJI, enabled)

    suspend fun setSwipeTypingEnabled(enabled: Boolean) = put(Keys.SWIPE_TYPING, enabled)

    suspend fun setClipboardChipEnabled(enabled: Boolean) = put(Keys.CLIPBOARD_CHIP, enabled)

    suspend fun setClipboardHistoryEnabled(enabled: Boolean) = put(Keys.CLIPBOARD_HISTORY_ENABLED, enabled)

    suspend fun setDismissedClipboardText(text: String) = put(Keys.DISMISSED_CLIPBOARD, text)

    suspend fun recordClipboardHistory(text: String) {
        var next: List<String> = emptyList()
        context.dataStore.edit { preferences ->
            val current = ClipboardHistory.decode(preferences[Keys.CLIPBOARD_HISTORY])
            next = ClipboardHistory.remember(current, text)
            preferences[Keys.CLIPBOARD_HISTORY] = ClipboardHistory.encode(next)
        }
        ClipboardImages.prune(context, ClipboardHistory.imagePaths(next))
    }

    suspend fun removeClipboardHistory(text: String) {
        var next: List<String> = emptyList()
        context.dataStore.edit { preferences ->
            next = ClipboardHistory.decode(preferences[Keys.CLIPBOARD_HISTORY]).filter { it != text }
            preferences[Keys.CLIPBOARD_HISTORY] = ClipboardHistory.encode(next)
        }
        ClipboardImages.prune(context, ClipboardHistory.imagePaths(next))
    }

    suspend fun clearClipboardHistory() {
        context.dataStore.edit { it.remove(Keys.CLIPBOARD_HISTORY) }
        ClipboardImages.prune(context, emptySet())
    }

    suspend fun recordEmojiRecent(emoji: String) {
        context.dataStore.edit { preferences ->
            val current = decodeEmojiRecents(preferences[Keys.EMOJI_RECENTS])
            val next = listOf(emoji) + current.filter { it != emoji }
            preferences[Keys.EMOJI_RECENTS] = next.take(MAX_EMOJI_RECENTS).joinToString("\n")
        }
    }

    suspend fun setTelemetryEnabled(enabled: Boolean) = put(Keys.TELEMETRY_ENABLED, enabled)

    suspend fun setTelemetryAsked(asked: Boolean) = put(Keys.TELEMETRY_ASKED, asked)

    /**
     * Claims a one-shot telemetry milestone, returning true only the first time
     * it is claimed on this install.
     *
     * Aptabase rotates its anonymous user hash every 24 hours, so per-user
     * funnels are impossible and the funnel is reconstructed from ratios of
     * once-ever counters instead. That arithmetic is wrong the moment a
     * milestone fires twice, so the check and the write happen inside a single
     * `edit` block: two coroutines reaching first-launch together must not both
     * come away believing they were first.
     *
     * The stored value is a set of opaque milestone keys. It is not an
     * identifier and never leaves the phone.
     */
    suspend fun claimTelemetryMilestone(key: String): Boolean {
        var claimed = false
        context.dataStore.edit { preferences ->
            val seen = preferences[Keys.TELEMETRY_MILESTONES].orEmpty()
            claimed = key !in seen
            if (claimed) preferences[Keys.TELEMETRY_MILESTONES] = seen + key
        }
        return claimed
    }

    /**
     * Moves the process-exit watermark to [newest] and returns where it was.
     *
     * The system hands back the same exits on every query, so something has to
     * remember which of them the diagnostic log already has. That cannot be the
     * log itself: it is bounded, and the user can clear it from About, either
     * of which would make a week-old crash reappear as though it had just
     * happened. Read and write share one `edit` for the same reason the
     * telemetry milestones above do — two processes starting together must not
     * both come away thinking they were first to see an exit.
     */
    suspend fun claimProcessExitsUpTo(newest: Long): Long {
        var previous = 0L
        context.dataStore.edit { preferences ->
            previous = preferences[Keys.LAST_REPORTED_EXIT_AT] ?: 0L
            if (newest > previous) preferences[Keys.LAST_REPORTED_EXIT_AT] = newest
        }
        return previous
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
        dictationTone = DictationTone.fromStored(this[Keys.DICTATION_TONE]),
        microphone = MicrophonePreference.fromStored(this[Keys.MICROPHONE]),
        audioRetention = AudioRetention.fromHours(this[Keys.RETENTION_HOURS]),
        modelIdleTimeout = ModelIdleTimeout.fromStored(this[Keys.MODEL_IDLE_TIMEOUT]),
        onboardingComplete = this[Keys.ONBOARDING_COMPLETE] ?: false,
        lastEngine = this[Keys.LAST_ENGINE].orEmpty(),
        lastEngineReady = this[Keys.LAST_ENGINE_READY] ?: false,
        lastStreamingSupported = this[Keys.LAST_STREAMING] ?: false,
        lastEngineCheckedAtMillis = this[Keys.LAST_ENGINE_CHECKED_AT],
        modelLanguages = this[Keys.MODEL_LANGUAGES].orEmpty(),
        modelDetectsLanguage = this[Keys.MODEL_DETECTS_LANGUAGE] ?: false,
        localTranscriptionEnabled = this[Keys.LOCAL_TRANSCRIPTION_ENABLED] ?: true,
        localModelId = this[Keys.LOCAL_MODEL_ID].orEmpty(),
        transcriptionQuality = TranscriptionQuality.fromStored(this[Keys.TRANSCRIPTION_QUALITY]),
        customVocabulary = this[Keys.CUSTOM_VOCABULARY].orEmpty(),
        syncWhisperDictionary = this[Keys.SYNC_WHISPER_DICTIONARY] ?: true,
        numberRowEnabled = this[Keys.NUMBER_ROW] ?: true,
        keyboardHeight = KeyboardHeight.fromStored(this[Keys.KEYBOARD_HEIGHT]),
        splitKeyboard = SplitKeyboard.fromStored(this[Keys.SPLIT_KEYBOARD]),
        suggestionsEnabled = this[Keys.SUGGESTIONS] ?: true,
        correctionsEnabled = this[Keys.CORRECTIONS] ?: true,
        numberKeyHintsEnabled = this[Keys.NUMBER_KEY_HINTS] ?: true,
        longPressSymbolsEnabled = this[Keys.LONG_PRESS_SYMBOLS] ?: false,
        personalDictionary = this[Keys.PERSONAL_DICTIONARY].orEmpty(),
        asciiEmojiEnabled = this[Keys.ASCII_EMOJI] ?: true,
        swipeTypingEnabled = this[Keys.SWIPE_TYPING] ?: true,
        clipboardChipEnabled = this[Keys.CLIPBOARD_CHIP] ?: true,
        clipboardHistoryEnabled = this[Keys.CLIPBOARD_HISTORY_ENABLED] ?: true,
        clipboardHistory = ClipboardHistory.decode(this[Keys.CLIPBOARD_HISTORY]),
        dismissedClipboardText = this[Keys.DISMISSED_CLIPBOARD].orEmpty(),
        emojiRecents = decodeEmojiRecents(this[Keys.EMOJI_RECENTS]),
        telemetryEnabled = this[Keys.TELEMETRY_ENABLED]
            ?: com.vocahq.vocaphone.telemetry.TelemetryConfig.DEFAULT_ENABLED,
        telemetryAsked = this[Keys.TELEMETRY_ASKED] ?: false,
    )

    private object Keys {
        val GATEWAY_URL = stringPreferencesKey("gateway_url")
        val TOKEN_CIPHERTEXT = stringPreferencesKey("gateway_token_ciphertext")
        val TOKEN_NONCE = stringPreferencesKey("gateway_token_nonce")
        val LANGUAGE = stringPreferencesKey("transcription_language")
        val STYLE = stringPreferencesKey("writing_style")
        val DICTATION_TONE = stringPreferencesKey("dictation_tone")
        val MICROPHONE = stringPreferencesKey("microphone_preference")
        val RETENTION_HOURS = intPreferencesKey("audio_retention_hours")
        val MODEL_IDLE_TIMEOUT = stringPreferencesKey("model_idle_timeout")
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
        val SYNC_WHISPER_DICTIONARY = booleanPreferencesKey("sync_whisper_dictionary")
        val NUMBER_ROW = booleanPreferencesKey("keyboard_number_row")
        val KEYBOARD_HEIGHT = stringPreferencesKey("keyboard_height")
        val SPLIT_KEYBOARD = stringPreferencesKey("keyboard_split")
        val SUGGESTIONS = booleanPreferencesKey("keyboard_suggestions")
        val CORRECTIONS = booleanPreferencesKey("keyboard_corrections")
        val NUMBER_KEY_HINTS = booleanPreferencesKey("keyboard_number_key_hints")
        val LONG_PRESS_SYMBOLS = booleanPreferencesKey("keyboard_long_press_symbols")
        val PERSONAL_DICTIONARY = stringPreferencesKey("keyboard_personal_dictionary")
        val ASCII_EMOJI = booleanPreferencesKey("keyboard_ascii_emoji")
        val SWIPE_TYPING = booleanPreferencesKey("keyboard_swipe_typing")
        val CLIPBOARD_CHIP = booleanPreferencesKey("keyboard_clipboard_chip")
        val CLIPBOARD_HISTORY_ENABLED = booleanPreferencesKey("keyboard_clipboard_history")
        val CLIPBOARD_HISTORY = stringPreferencesKey("keyboard_clipboard_history_items")
        val DISMISSED_CLIPBOARD = stringPreferencesKey("keyboard_clipboard_dismissed")
        val EMOJI_RECENTS = stringPreferencesKey("keyboard_emoji_recents")
        val TELEMETRY_ENABLED = booleanPreferencesKey("telemetry_enabled")
        val TELEMETRY_ASKED = booleanPreferencesKey("telemetry_asked")
        val TELEMETRY_MILESTONES = stringSetPreferencesKey("telemetry_milestones")
        val LAST_REPORTED_EXIT_AT = longPreferencesKey("last_reported_process_exit_at")
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
