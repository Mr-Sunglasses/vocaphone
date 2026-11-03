package com.vocahq.vocaphone.settings

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import com.vocahq.vocaphone.core.CorrectionSuggestion
import com.vocahq.vocaphone.core.CorrectionSuggestions
import com.vocahq.vocaphone.core.CustomVocabulary
import com.vocahq.vocaphone.core.LearnedCorrection
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map

/** "Learn from my corrections": on, and what has been learned so far. */
data class CorrectionLearningState(
    val enabled: Boolean = true,
    /** Newest first. */
    val suggestions: List<CorrectionSuggestion> = emptyList(),
    val dismissedCount: Int = 0,
)

private val Context.correctionLearningStore: DataStore<Preferences> by preferencesDataStore(name = "correction_learning")

/**
 * The spellings the keyboard learned from the user's fixes to dictated text
 * ([com.vocahq.vocaphone.core.CorrectionWatch]), and the ones they dismissed.
 *
 * Only "heard → corrected" pairs are stored, never the text they were found
 * in. Its own small store beside the settings: Add writes the custom word
 * and replacement through [SettingsRepository.learnCorrection].
 */
class CorrectionLearningStore(
    private val context: Context,
    private val settings: SettingsRepository,
) {
    val state: Flow<CorrectionLearningState> = context.correctionLearningStore.data.map { preferences ->
        CorrectionLearningState(
            enabled = preferences[Keys.ENABLED] ?: true,
            suggestions = CorrectionSuggestion.decode(preferences[Keys.SUGGESTIONS]),
            dismissedCount = CorrectionSuggestion.decodeKeys(preferences[Keys.DISMISSED]).size,
        )
    }

    val enabled: Flow<Boolean> = state.map { it.enabled }

    suspend fun setEnabled(enabled: Boolean) {
        context.correctionLearningStore.edit { it[Keys.ENABLED] = enabled }
    }

    /**
     * Fixes the keyboard found in one dictation. Each is suggested, or added
     * at once when the user has made it often enough (see
     * [CorrectionSuggestions]). Nothing happens with learning turned off.
     */
    suspend fun receive(found: List<LearnedCorrection>, now: Long = System.currentTimeMillis()) {
        if (found.isEmpty()) return
        val current = settings.current()
        val vocabulary = CustomVocabulary.terms(current.whisperVocabulary)
        var added: List<CorrectionSuggestion> = emptyList()
        context.correctionLearningStore.edit { preferences ->
            if (preferences[Keys.ENABLED] == false) return@edit
            val received = CorrectionSuggestions.receive(
                found = found,
                suggestions = CorrectionSuggestion.decode(preferences[Keys.SUGGESTIONS]),
                dismissed = CorrectionSuggestion.decodeKeys(preferences[Keys.DISMISSED]),
                now = now,
            ) { heard, corrected ->
                CorrectionSuggestions.isListed(heard, corrected, current.replacements, vocabulary)
            }
            preferences[Keys.SUGGESTIONS] = CorrectionSuggestion.encode(received.suggestions)
            added = received.added
        }
        // A fix that could not be added on its own (see
        // [SettingsRepository.learnCorrection]) stays a suggestion for the
        // user to decide.
        val unlearned = added.filterNot { settings.learnCorrection(it, explicit = false) }
        if (unlearned.isNotEmpty()) {
            context.correctionLearningStore.edit { preferences ->
                val suggestions = CorrectionSuggestion.decode(preferences[Keys.SUGGESTIONS])
                val keys = suggestions.map { it.key }.toSet()
                preferences[Keys.SUGGESTIONS] =
                    CorrectionSuggestion.encode(suggestions + unlearned.filter { it.key !in keys })
            }
        }
    }

    /** Add: the word and, when due, a replacement. */
    suspend fun accept(key: String) {
        val suggestion = take(key) ?: return
        settings.learnCorrection(suggestion)
    }

    /** Dismiss: gone, and not suggested again. */
    suspend fun dismiss(key: String) {
        context.correctionLearningStore.edit { preferences ->
            val remaining = CorrectionSuggestion.decode(preferences[Keys.SUGGESTIONS]).filter { it.key != key }
            preferences[Keys.SUGGESTIONS] = CorrectionSuggestion.encode(remaining)
            val dismissed = CorrectionSuggestion.decodeKeys(preferences[Keys.DISMISSED])
            preferences[Keys.DISMISSED] = CorrectionSuggestion.encodeKeys(CorrectionSuggestions.dismissing(key, dismissed))
        }
    }

    /** Forgets every suggestion and dismissal. Words already added stay in their lists. */
    suspend fun clear() {
        context.correctionLearningStore.edit { preferences ->
            preferences.remove(Keys.SUGGESTIONS)
            preferences.remove(Keys.DISMISSED)
        }
    }

    suspend fun current(): CorrectionLearningState = state.first()

    private suspend fun take(key: String): CorrectionSuggestion? {
        var taken: CorrectionSuggestion? = null
        context.correctionLearningStore.edit { preferences ->
            val suggestions = CorrectionSuggestion.decode(preferences[Keys.SUGGESTIONS])
            taken = suggestions.firstOrNull { it.key == key }
            preferences[Keys.SUGGESTIONS] = CorrectionSuggestion.encode(suggestions.filter { it.key != key })
        }
        return taken
    }

    private object Keys {
        val ENABLED = booleanPreferencesKey("learn_from_corrections")
        val SUGGESTIONS = stringPreferencesKey("correction_suggestions")
        val DISMISSED = stringPreferencesKey("dismissed_corrections")
    }
}
