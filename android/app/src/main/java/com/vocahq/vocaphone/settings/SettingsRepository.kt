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
import com.vocahq.vocaphone.core.ChineseScript
import com.vocahq.vocaphone.core.DictationTone
import com.vocahq.vocaphone.core.MaximumRecordingLength
import com.vocahq.vocaphone.core.MicrophonePreference
import com.vocahq.vocaphone.core.ModelLanguageSupport
import com.vocahq.vocaphone.core.ModelTranslationSupport
import com.vocahq.vocaphone.core.Snippet
import com.vocahq.vocaphone.local.GrammarModelConsent
import com.vocahq.vocaphone.local.LocalModelCatalog
import com.vocahq.vocaphone.local.LocalModelDescriptor
import com.vocahq.vocaphone.core.TranscriptionLanguage
import com.vocahq.vocaphone.core.TranscriptionQuality
import com.vocahq.vocaphone.core.WritingStyle
import com.vocahq.vocaphone.security.TokenVault
import java.util.UUID
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

/** When the floating mic bubble is allowed to appear. X builds only. */
enum class BubbleBehavior {
    EVERY_EDITABLE_FIELD,
    OFF,
    ;

    val displayName: String
        get() = when (this) {
            EVERY_EDITABLE_FIELD -> "Every eligible text field"
            OFF -> "Never (app only)"
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
    /**
     * The language dictation should come out in, or
     * [ModelTranslationSupport.OFF] to keep the language that was spoken.
     *
     * Deliberately a second setting rather than a meaning layered onto
     * [language]. That row says what is being spoken, which is what a decoder
     * needs; this one says what should come back, which only two models can
     * honour at all.
     */
    val translateTo: TranscriptionLanguage = ModelTranslationSupport.OFF,
    val style: WritingStyle = WritingStyle.DEFAULT,
    /**
     * Whether hesitation sounds, false starts, and missing sentence punctuation
     * are repaired before the writing style is applied.
     *
     * On by default, and one of the dictation settings that changes the words
     * in a transcript rather than its formatting. It earns that because the
     * words it removes are not words: "um" is a sound someone makes while
     * deciding what to say, and nobody dictating meant to type it. Never
     * applied to [WritingStyle.RAW], which promises the model's own output.
     */
    val repairSpeech: Boolean = true,
    /**
     * Whether the on-device grammar model corrects common English grammar and
     * spelling slips after Clean up speech. Off by default: it is a 28 MB
     * download, it can change a sentence that was right, and it only applies
     * to on-device transcription in English. On only once the model has been
     * downloaded and verified; see [com.vocahq.vocaphone.grammar.GrammarCorrector].
     */
    val fixGrammar: Boolean = false,
    /**
     * Whether the person agreed to download the grammar model, from Fix grammar
     * or Writing check's download offer. App start fetches a missing model
     * (a moved pin, a failed attempt) only while this or [fixGrammar] is on;
     * [typingGrammar] alone never downloads it. See
     * [com.vocahq.vocaphone.local.GrammarModelConsent].
     */
    val grammarModelRequested: Boolean = false,
    /**
     * "Only sure fixes": the grammar model offers and applies only the edits
     * it is surest of (a higher KEEP bias). Off means "Balanced". Applies to
     * dictation and to typed text alike.
     */
    val grammarSureOnly: Boolean = false,
    /** Whether dictated English number words are written as digits. Off by default. */
    val numbersAsDigits: Boolean = false,
    /**
     * Whether a dictation finishes by itself after a pause in speech. Off by
     * default: people pause to think. See [com.vocahq.vocaphone.core.PauseDetector].
     */
    val stopAfterPause: Boolean = false,
    /**
     * The longest one dictation records before it stops by itself. A gateway
     * route is also held to [gatewayMaximumDurationSeconds]; see
     * [com.vocahq.vocaphone.core.RecordingLimit].
     */
    val maximumRecordingLength: MaximumRecordingLength = MaximumRecordingLength.DEFAULT,
    /**
     * Whether "crying emoji" becomes 😭.
     *
     * Off by default, matching Write numbers as digits. Saying "emoji" out
     * loud is deliberate, but a default-on converter still rewrites the times
     * someone is talking *about* an emoji rather than asking for one. Opt in.
     */
    val spokenEmoji: Boolean = false,
    /** Which characters Chinese dictation is written in. See [ChineseScript]. */
    val chineseScript: ChineseScript = ChineseScript.DEFAULT,
    val dictationTone: DictationTone = DictationTone.DEFAULT,
    val microphone: MicrophonePreference = MicrophonePreference.DEFAULT,
    val audioRetention: AudioRetention = AudioRetention.DEFAULT,
    val modelIdleTimeout: ModelIdleTimeout = ModelIdleTimeout.DEFAULT,
    val onboardingComplete: Boolean = false,
    /** The first-run page to reopen on; blank until the welcome has been left. */
    val onboardingStage: String = "",
    /** The opening animation has been acknowledged, even if setup is unfinished. */
    val onboardingIntroSeen: Boolean = false,
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
    /**
     * The `maximum_duration_seconds` the gateway last reported from `/health`,
     * or null when it has not been checked or is too old to report one.
     */
    val gatewayMaximumDurationSeconds: Int? = null,
    /** First-run default is this phone. Gateway is opt-in from setup or settings. */
    val localTranscriptionEnabled: Boolean = true,
    val localModelId: String = "",
    /**
     * The model the retired-model migration moved this phone onto, or empty.
     * The picker offers it back as a one-tap download while it is still the
     * selection and not on the phone, because the migration changes the
     * setting but cannot fetch hundreds of megabytes on its own.
     */
    val retiredModelReplacement: String = "",
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
    val keyboardHeight: KeyboardHeight = KeyboardHeight.DEFAULT,
    val splitKeyboard: SplitKeyboard = SplitKeyboard.DEFAULT,
    /** Material You wallpaper colors. Off keeps the brand teal. */
    val dynamicColorEnabled: Boolean = false,
    val suggestionsEnabled: Boolean = true,
    val correctionsEnabled: Boolean = true,
    /**
     * "Check while typing": Writing check in the keyboard. After a pause the
     * field is checked on the phone, with the rules and, once it is
     * downloaded, the grammar model [fixGrammar] uses; suggestions appear in
     * the strip and its panel. Off by default; never changes text without a
     * tap unless [typoAutoFix] is on. See [com.vocahq.vocaphone.ime.WritingCheckSession].
     */
    val typingGrammar: Boolean = false,
    /** Writing check's blue group: wordy and redundant phrases, passive voice, long sentences. */
    val writingClarity: Boolean = true,
    /** Writing check's green group: weak intensifiers, a word used too often. Off by default. */
    val writingEngagement: Boolean = false,
    /** Writing check's purple group: hedging. Off by default. */
    val writingDelivery: Boolean = false,
    /** Writing check suggests the serial (Oxford) comma, "eggs, milk, and bread". A style choice, off by default. */
    val writingSerialComma: Boolean = false,
    /** Whether the panel says how the text sounds (friendly, formal, urgent...). */
    val writingTone: Boolean = true,
    /**
     * "Fix obvious typos as I type": a known misspelling or missing apostrophe
     * ("recieve", "dont") is corrected after a pause, with an undo in the
     * strip. Off by default: it is the one change Writing check makes without
     * a tap.
     */
    val typoAutoFix: Boolean = false,
    val numberKeyHintsEnabled: Boolean = true,
    val longPressSymbolsEnabled: Boolean = false,
    /** Arm shift at the start of a field and after a sentence ends. */
    val autoCapitalizeEnabled: Boolean = true,
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
    /** Trigger phrases dictated text is expanded against, after formatting. */
    val snippets: List<Snippet> = emptyList(),
    /**
     * Whether a finished floating-mic dictation is written into the focused
     * field by itself. Off leaves it in History for a manual copy. X build only.
     */
    val automaticInsertion: Boolean = true,
    /** Whether the floating bubble may appear over an editable field. X build only. */
    val bubbleBehavior: BubbleBehavior = BubbleBehavior.EVERY_EDITABLE_FIELD,
    /** Apps the bubble stays out of and reads nothing in. X build only. */
    val excludedPackages: Set<String> = emptySet(),
    /**
     * The prominent accessibility disclosure has been read and accepted. the X build
     * only — the keyboard build never asks for accessibility access.
     */
    val disclosureAccepted: Boolean = false,
) {

    /**
     * The language to actually send. A stored choice goes stale when the gateway
     * switches to a model that cannot honour it, and sending it anyway produces
     * the wrong-language failure this whole mechanism exists to prevent.
     */
    val effectiveLanguage: TranscriptionLanguage
        get() = ModelLanguageSupport.resolve(language, activeModelLanguages)

    /** Languages the active model can translate into; empty when it cannot. */
    val activeModelTranslationTargets: Set<String>
        get() = localModel?.translationTargets.orEmpty()

    /** Whether translating needs [language] set to something other than Automatic. */
    val activeModelTranslationNeedsSource: Boolean
        get() = localModel?.translationNeedsExplicitSource ?: false

    /** The picker's own selection, corrected for a model that cannot honour it. */
    val effectiveTranslateTo: TranscriptionLanguage
        get() = ModelTranslationSupport.resolve(translateTo, activeModelTranslationTargets)

    /**
     * What the engines take: a language code, or empty for no translation.
     *
     * Gateway transcription is empty by construction — [activeModelTranslationTargets]
     * is empty without a local model — because translation lives entirely in
     * the on-device engines and the gateway protocol has no field for it.
     */
    val translationTarget: String
        get() = ModelTranslationSupport.target(translateTo, activeModelTranslationTargets)

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
     * On-device transcription is switched on but the stored model is not in the
     * catalog.
     *
     * Either a selection this build no longer ships, or one the launch
     * migration has not reached yet -- it runs in a coroutine, and a dictation
     * can start first. The local route cannot run in that state, and the
     * failure it produces without this is the expensive kind: the microphone
     * opens, a full dictation is recorded, and delivery fails at the end on a
     * model that was never going to load.
     */
    /**
     * The selection is a replacement the retired-model migration chose, and it
     * still has to be downloaded. Read together with the download state, which
     * this settings object does not know.
     */
    val selectionIsRetiredModelReplacement: Boolean
        get() = localTranscriptionEnabled && localModelId.isNotEmpty() &&
            localModelId == retiredModelReplacement

    val localModelMissing: Boolean
        get() = localTranscriptionEnabled && LocalModelCatalog.find(localModelId) == null

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
            preferences.remove(Keys.GATEWAY_MAX_DURATION_SECONDS)
        }
        TokenVault.clear()
    }

    suspend fun setLanguage(language: TranscriptionLanguage) = put(Keys.LANGUAGE, language.wireValue)

    suspend fun setTranslateTo(language: TranscriptionLanguage) =
        put(Keys.TRANSLATE_TO, language.wireValue)

    suspend fun setStyle(style: WritingStyle) = put(Keys.STYLE, style.wireValue)

    suspend fun setDictationTone(tone: DictationTone) = put(Keys.DICTATION_TONE, tone.id)

    suspend fun setMicrophone(preference: MicrophonePreference) =
        put(Keys.MICROPHONE, preference.storedValue)

    suspend fun setAudioRetention(retention: AudioRetention) = put(Keys.RETENTION_HOURS, retention.hours)

    suspend fun setAutomaticInsertion(enabled: Boolean) = put(Keys.AUTOMATIC_INSERTION, enabled)

    suspend fun setBubbleBehavior(behavior: BubbleBehavior) = put(Keys.BUBBLE_BEHAVIOR, behavior.name)

    suspend fun setExcludedPackages(packages: Set<String>) = put(Keys.EXCLUDED_PACKAGES, packages)

    suspend fun setDisclosureAccepted(accepted: Boolean) = put(Keys.DISCLOSURE_ACCEPTED, accepted)

    suspend fun setModelIdleTimeout(timeout: ModelIdleTimeout) =
        put(Keys.MODEL_IDLE_TIMEOUT, timeout.storedValue)

    suspend fun setOnboardingComplete(complete: Boolean) = put(Keys.ONBOARDING_COMPLETE, complete)

    suspend fun setOnboardingStage(stage: String) = put(Keys.ONBOARDING_STAGE, stage)

    suspend fun setOnboardingIntroSeen(seen: Boolean) = put(Keys.ONBOARDING_INTRO_SEEN, seen)


    suspend fun setLocalTranscriptionEnabled(enabled: Boolean) =
        put(Keys.LOCAL_TRANSCRIPTION_ENABLED, enabled)

    /**
     * Any selection that is not the retired-model migration's own clears its
     * marker: from then on the model is one the person chose, and "Your voice
     * model was updated" would be a false explanation if it went missing.
     */
    suspend fun setLocalModel(modelId: String) {
        context.dataStore.edit { preferences ->
            preferences[Keys.LOCAL_MODEL_ID] = modelId
            preferences.remove(Keys.RETIRED_MODEL_REPLACEMENT)
        }
    }

    /**
     * Move the selection off a retired model and remember that it was the
     * migration, not the user, that chose [replacementId]. One transaction, so
     * the notice can never name a model that is not the selection.
     */
    suspend fun replaceRetiredLocalModel(replacementId: String) {
        context.dataStore.edit { preferences ->
            preferences[Keys.LOCAL_MODEL_ID] = replacementId
            preferences[Keys.RETIRED_MODEL_REPLACEMENT] = replacementId
        }
    }

    /**
     * Forget the on-device selection and switch the route off with it, in one
     * transaction.
     *
     * Two separate writes can be interrupted between them -- by a cancelled
     * migration, or by the process dying -- and the half-applied state is the
     * broken one: no model selected with on-device transcription still enabled,
     * which records a dictation and then fails at delivery. Neither key means
     * anything without the other, so neither is written without the other.
     */
    suspend fun clearLocalModelSelection() {
        context.dataStore.edit { preferences ->
            preferences[Keys.LOCAL_MODEL_ID] = ""
            preferences[Keys.LOCAL_TRANSCRIPTION_ENABLED] = false
            preferences.remove(Keys.RETIRED_MODEL_REPLACEMENT)
        }
    }

    suspend fun setTranscriptionQuality(quality: TranscriptionQuality) =
        put(Keys.TRANSCRIPTION_QUALITY, quality.storedValue)

    suspend fun setCustomVocabulary(vocabulary: String) =
        put(Keys.CUSTOM_VOCABULARY, vocabulary)

    suspend fun setSyncWhisperDictionary(enabled: Boolean) =
        put(Keys.SYNC_WHISPER_DICTIONARY, enabled)

    suspend fun setRepairSpeech(enabled: Boolean) = put(Keys.REPAIR_SPEECH, enabled)

    suspend fun setFixGrammar(enabled: Boolean) = put(Keys.FIX_GRAMMAR, enabled)

    /** Records that the person agreed to download the grammar model. */
    suspend fun setGrammarModelRequested() = put(Keys.GRAMMAR_MODEL_REQUESTED, true)

    /**
     * The person stopped a grammar model download: forget the agreement, and
     * turn Fix grammar off with it, in one transaction, since it does nothing
     * without the model and would otherwise ask for it again at the next start.
     */
    suspend fun withdrawGrammarModelRequest() {
        context.dataStore.edit { preferences ->
            preferences[Keys.GRAMMAR_MODEL_REQUESTED] = false
            preferences[Keys.FIX_GRAMMAR] = false
        }
    }

    /**
     * Writes [VocaPhoneSettings.grammarModelRequested] for someone whose build
     * never did ([GrammarModelConsent.requested]); a stored value is kept.
     * [filesOnPhone] has to be read before the retired grammar folders are swept.
     */
    suspend fun migrateGrammarModelRequested(filesOnPhone: Boolean) {
        context.dataStore.edit { preferences ->
            preferences[Keys.GRAMMAR_MODEL_REQUESTED] = GrammarModelConsent.requested(
                stored = preferences[Keys.GRAMMAR_MODEL_REQUESTED],
                fixGrammar = preferences[Keys.FIX_GRAMMAR] ?: false,
                filesOnPhone = filesOnPhone,
            )
        }
    }

    suspend fun setGrammarSureOnly(enabled: Boolean) = put(Keys.GRAMMAR_SURE_ONLY, enabled)

    suspend fun setNumbersAsDigits(enabled: Boolean) = put(Keys.NUMBERS_AS_DIGITS, enabled)

    suspend fun setChineseScript(script: ChineseScript) = put(Keys.CHINESE_SCRIPT, script.storedValue)

    suspend fun setStopAfterPause(enabled: Boolean) = put(Keys.STOP_AFTER_PAUSE, enabled)

    suspend fun setMaximumRecordingLength(length: MaximumRecordingLength) =
        put(Keys.MAXIMUM_RECORDING_MINUTES, length.minutes)

    suspend fun setSpokenEmoji(enabled: Boolean) = put(Keys.SPOKEN_EMOJI, enabled)

    suspend fun setNumberRowEnabled(enabled: Boolean) = put(Keys.NUMBER_ROW, enabled)

    suspend fun setKeyboardHeight(height: KeyboardHeight) = put(Keys.KEYBOARD_HEIGHT, height.storedValue)

    suspend fun setSplitKeyboard(mode: SplitKeyboard) = put(Keys.SPLIT_KEYBOARD, mode.storedValue)

    suspend fun setDynamicColorEnabled(enabled: Boolean) = put(Keys.DYNAMIC_COLOR, enabled)

    suspend fun setSuggestionsEnabled(enabled: Boolean) = put(Keys.SUGGESTIONS, enabled)

    suspend fun setCorrectionsEnabled(enabled: Boolean) = put(Keys.CORRECTIONS, enabled)

    suspend fun setTypingGrammar(enabled: Boolean) = put(Keys.TYPING_GRAMMAR, enabled)

    suspend fun setWritingClarity(enabled: Boolean) = put(Keys.WRITING_CLARITY, enabled)

    suspend fun setWritingEngagement(enabled: Boolean) = put(Keys.WRITING_ENGAGEMENT, enabled)

    suspend fun setWritingDelivery(enabled: Boolean) = put(Keys.WRITING_DELIVERY, enabled)

    suspend fun setWritingSerialComma(enabled: Boolean) = put(Keys.WRITING_SERIAL_COMMA, enabled)

    suspend fun setWritingTone(enabled: Boolean) = put(Keys.WRITING_TONE, enabled)

    suspend fun setTypoAutoFix(enabled: Boolean) = put(Keys.TYPO_AUTO_FIX, enabled)

    suspend fun setNumberKeyHintsEnabled(enabled: Boolean) = put(Keys.NUMBER_KEY_HINTS, enabled)

    suspend fun setLongPressSymbolsEnabled(enabled: Boolean) = put(Keys.LONG_PRESS_SYMBOLS, enabled)

    suspend fun setAutoCapitalizeEnabled(enabled: Boolean) = put(Keys.AUTO_CAPITALIZE, enabled)

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

    // A blank expansion would silently delete its trigger from every later
    // transcript, so it never reaches storage; the expansion is otherwise kept
    // as typed, since leading or trailing spaces can be the point of it.
    suspend fun addSnippet(trigger: String, expansion: String) {
        val cleaned = trigger.trim()
        if (cleaned.isEmpty() || expansion.isBlank()) return
        context.dataStore.edit { preferences ->
            val current = Snippet.decode(preferences[Keys.SNIPPETS])
            val added = Snippet(id = UUID.randomUUID().toString(), trigger = cleaned, expansion = expansion)
            preferences[Keys.SNIPPETS] = Snippet.encode(current + added)
        }
    }

    suspend fun updateSnippet(id: String, trigger: String, expansion: String) {
        val cleaned = trigger.trim()
        if (cleaned.isEmpty() || expansion.isBlank()) return
        context.dataStore.edit { preferences ->
            val current = Snippet.decode(preferences[Keys.SNIPPETS])
            val next = current.map {
                if (it.id == id) it.copy(trigger = cleaned, expansion = expansion) else it
            }
            preferences[Keys.SNIPPETS] = Snippet.encode(next)
        }
    }

    suspend fun deleteSnippet(id: String) {
        context.dataStore.edit { preferences ->
            val current = Snippet.decode(preferences[Keys.SNIPPETS])
            preferences[Keys.SNIPPETS] = Snippet.encode(current.filter { it.id != id })
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
        maximumDurationSeconds: Int? = null,
    ) {
        context.dataStore.edit { preferences ->
            preferences[Keys.LAST_ENGINE] = engine
            preferences[Keys.LAST_ENGINE_READY] = ready
            preferences[Keys.LAST_STREAMING] = streamingSupported
            preferences[Keys.LAST_ENGINE_CHECKED_AT] = checkedAtMillis
            preferences[Keys.MODEL_LANGUAGES] = modelLanguages
            preferences[Keys.MODEL_DETECTS_LANGUAGE] = modelDetectsLanguage
            // Removed rather than kept when absent: an older gateway that
            // replaced a newer one at the same address accepts only its own.
            if (maximumDurationSeconds != null) {
                preferences[Keys.GATEWAY_MAX_DURATION_SECONDS] = maximumDurationSeconds
            } else {
                preferences.remove(Keys.GATEWAY_MAX_DURATION_SECONDS)
            }
        }
    }

    private suspend fun <T> put(key: Preferences.Key<T>, value: T) {
        context.dataStore.edit { it[key] = value }
    }

    private fun Preferences.toSettings() = VocaPhoneSettings(
        gatewayUrl = this[Keys.GATEWAY_URL].orEmpty(),
        hasToken = this[Keys.TOKEN_CIPHERTEXT] != null,
        language = TranscriptionLanguage.fromWire(this[Keys.LANGUAGE]),
        translateTo = TranscriptionLanguage.fromWire(this[Keys.TRANSLATE_TO]),
        style = WritingStyle.fromWire(this[Keys.STYLE]),
        dictationTone = DictationTone.fromStored(this[Keys.DICTATION_TONE]),
        microphone = MicrophonePreference.fromStored(this[Keys.MICROPHONE]),
        audioRetention = AudioRetention.fromHours(this[Keys.RETENTION_HOURS]),
        modelIdleTimeout = ModelIdleTimeout.fromStored(this[Keys.MODEL_IDLE_TIMEOUT]),
        onboardingComplete = this[Keys.ONBOARDING_COMPLETE] ?: false,
        onboardingStage = this[Keys.ONBOARDING_STAGE].orEmpty(),
        onboardingIntroSeen = this[Keys.ONBOARDING_INTRO_SEEN] ?: false,
        lastEngine = this[Keys.LAST_ENGINE].orEmpty(),
        lastEngineReady = this[Keys.LAST_ENGINE_READY] ?: false,
        lastStreamingSupported = this[Keys.LAST_STREAMING] ?: false,
        lastEngineCheckedAtMillis = this[Keys.LAST_ENGINE_CHECKED_AT],
        modelLanguages = this[Keys.MODEL_LANGUAGES].orEmpty(),
        modelDetectsLanguage = this[Keys.MODEL_DETECTS_LANGUAGE] ?: false,
        gatewayMaximumDurationSeconds = this[Keys.GATEWAY_MAX_DURATION_SECONDS],
        localTranscriptionEnabled = this[Keys.LOCAL_TRANSCRIPTION_ENABLED] ?: true,
        localModelId = this[Keys.LOCAL_MODEL_ID].orEmpty(),
        retiredModelReplacement = this[Keys.RETIRED_MODEL_REPLACEMENT].orEmpty(),
        transcriptionQuality = TranscriptionQuality.fromStored(this[Keys.TRANSCRIPTION_QUALITY]),
        customVocabulary = this[Keys.CUSTOM_VOCABULARY].orEmpty(),
        syncWhisperDictionary = this[Keys.SYNC_WHISPER_DICTIONARY] ?: true,
        repairSpeech = this[Keys.REPAIR_SPEECH] ?: true,
        fixGrammar = this[Keys.FIX_GRAMMAR] ?: false,
        grammarModelRequested = this[Keys.GRAMMAR_MODEL_REQUESTED] ?: false,
        grammarSureOnly = this[Keys.GRAMMAR_SURE_ONLY] ?: false,
        numbersAsDigits = this[Keys.NUMBERS_AS_DIGITS] ?: false,
        stopAfterPause = this[Keys.STOP_AFTER_PAUSE] ?: false,
        maximumRecordingLength = MaximumRecordingLength.fromMinutes(this[Keys.MAXIMUM_RECORDING_MINUTES]),
        spokenEmoji = this[Keys.SPOKEN_EMOJI] ?: false,
        chineseScript = ChineseScript.fromStored(this[Keys.CHINESE_SCRIPT]),
        numberRowEnabled = this[Keys.NUMBER_ROW] ?: true,
        keyboardHeight = KeyboardHeight.fromStored(this[Keys.KEYBOARD_HEIGHT]),
        splitKeyboard = SplitKeyboard.fromStored(this[Keys.SPLIT_KEYBOARD]),
        dynamicColorEnabled = this[Keys.DYNAMIC_COLOR] ?: false,
        suggestionsEnabled = this[Keys.SUGGESTIONS] ?: true,
        correctionsEnabled = this[Keys.CORRECTIONS] ?: true,
        typingGrammar = this[Keys.TYPING_GRAMMAR] ?: false,
        writingClarity = this[Keys.WRITING_CLARITY] ?: true,
        writingEngagement = this[Keys.WRITING_ENGAGEMENT] ?: false,
        writingDelivery = this[Keys.WRITING_DELIVERY] ?: false,
        writingSerialComma = this[Keys.WRITING_SERIAL_COMMA] ?: false,
        writingTone = this[Keys.WRITING_TONE] ?: true,
        typoAutoFix = this[Keys.TYPO_AUTO_FIX] ?: false,
        numberKeyHintsEnabled = this[Keys.NUMBER_KEY_HINTS] ?: true,
        longPressSymbolsEnabled = this[Keys.LONG_PRESS_SYMBOLS] ?: false,
        autoCapitalizeEnabled = this[Keys.AUTO_CAPITALIZE] ?: true,
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
        snippets = Snippet.decode(this[Keys.SNIPPETS]),
        automaticInsertion = this[Keys.AUTOMATIC_INSERTION] ?: true,
        bubbleBehavior = this[Keys.BUBBLE_BEHAVIOR]?.let { name ->
            BubbleBehavior.entries.firstOrNull { it.name == name }
        } ?: BubbleBehavior.EVERY_EDITABLE_FIELD,
        excludedPackages = this[Keys.EXCLUDED_PACKAGES].orEmpty(),
        disclosureAccepted = this[Keys.DISCLOSURE_ACCEPTED] ?: false,
    )

    private object Keys {
        val GATEWAY_URL = stringPreferencesKey("gateway_url")
        val TOKEN_CIPHERTEXT = stringPreferencesKey("gateway_token_ciphertext")
        val TOKEN_NONCE = stringPreferencesKey("gateway_token_nonce")
        val LANGUAGE = stringPreferencesKey("transcription_language")
        val TRANSLATE_TO = stringPreferencesKey("translate_to")
        val STYLE = stringPreferencesKey("writing_style")
        val DICTATION_TONE = stringPreferencesKey("dictation_tone")
        val MICROPHONE = stringPreferencesKey("microphone_preference")
        val RETENTION_HOURS = intPreferencesKey("audio_retention_hours")
        val MODEL_IDLE_TIMEOUT = stringPreferencesKey("model_idle_timeout")
        val ONBOARDING_COMPLETE = booleanPreferencesKey("onboarding_complete")
        val ONBOARDING_STAGE = stringPreferencesKey("onboarding_stage")
        val ONBOARDING_INTRO_SEEN = booleanPreferencesKey("onboarding_intro_seen")
        val LAST_ENGINE = stringPreferencesKey("last_engine")
        val LAST_ENGINE_READY = booleanPreferencesKey("last_engine_ready")
        val LAST_STREAMING = booleanPreferencesKey("last_streaming_supported")
        val LAST_ENGINE_CHECKED_AT = longPreferencesKey("last_engine_checked_at")
        val MODEL_LANGUAGES = stringSetPreferencesKey("model_languages")
        val MODEL_DETECTS_LANGUAGE = booleanPreferencesKey("model_detects_language")
        val GATEWAY_MAX_DURATION_SECONDS = intPreferencesKey("gateway_maximum_duration_seconds")
        val LOCAL_TRANSCRIPTION_ENABLED = booleanPreferencesKey("local_transcription_enabled")
        val LOCAL_MODEL_ID = stringPreferencesKey("local_model_id")
        val RETIRED_MODEL_REPLACEMENT = stringPreferencesKey("retired_model_replacement")
        val TRANSCRIPTION_QUALITY = stringPreferencesKey("transcription_quality")
        val CUSTOM_VOCABULARY = stringPreferencesKey("custom_vocabulary")
        val SYNC_WHISPER_DICTIONARY = booleanPreferencesKey("sync_whisper_dictionary")
        val REPAIR_SPEECH = booleanPreferencesKey("repair_speech")
        val FIX_GRAMMAR = booleanPreferencesKey("fix_grammar")
        val GRAMMAR_MODEL_REQUESTED = booleanPreferencesKey("grammar_model_requested")
        val GRAMMAR_SURE_ONLY = booleanPreferencesKey("grammar_sure_only")
        val NUMBERS_AS_DIGITS = booleanPreferencesKey("numbers_as_digits")
        val CHINESE_SCRIPT = stringPreferencesKey("chinese_script")
        val STOP_AFTER_PAUSE = booleanPreferencesKey("stop_after_pause")
        val MAXIMUM_RECORDING_MINUTES = intPreferencesKey("maximum_recording_minutes")
        val SPOKEN_EMOJI = booleanPreferencesKey("spoken_emoji")
        val NUMBER_ROW = booleanPreferencesKey("keyboard_number_row")
        val KEYBOARD_HEIGHT = stringPreferencesKey("keyboard_height")
        val SPLIT_KEYBOARD = stringPreferencesKey("keyboard_split")
        val DYNAMIC_COLOR = booleanPreferencesKey("keyboard_dynamic_color")
        val SUGGESTIONS = booleanPreferencesKey("keyboard_suggestions")
        val CORRECTIONS = booleanPreferencesKey("keyboard_corrections")
        val TYPING_GRAMMAR = booleanPreferencesKey("keyboard_typing_grammar")
        val WRITING_CLARITY = booleanPreferencesKey("writing_clarity")
        val WRITING_ENGAGEMENT = booleanPreferencesKey("writing_engagement")
        val WRITING_DELIVERY = booleanPreferencesKey("writing_delivery")
        val WRITING_SERIAL_COMMA = booleanPreferencesKey("writing_serial_comma")
        val WRITING_TONE = booleanPreferencesKey("writing_tone")
        val TYPO_AUTO_FIX = booleanPreferencesKey("typo_auto_fix")
        val NUMBER_KEY_HINTS = booleanPreferencesKey("keyboard_number_key_hints")
        val LONG_PRESS_SYMBOLS = booleanPreferencesKey("keyboard_long_press_symbols")
        val AUTO_CAPITALIZE = booleanPreferencesKey("keyboard_auto_capitalize")
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
        val SNIPPETS = stringPreferencesKey("snippets")
        val AUTOMATIC_INSERTION = booleanPreferencesKey("automatic_insertion")
        val BUBBLE_BEHAVIOR = stringPreferencesKey("bubble_behavior")
        val EXCLUDED_PACKAGES = stringSetPreferencesKey("excluded_packages")
        val DISCLOSURE_ACCEPTED = booleanPreferencesKey("disclosure_accepted")
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
        remove(Keys.GATEWAY_MAX_DURATION_SECONDS)
    }
}
