package com.vocahq.vocaphone.settings

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import com.vocahq.vocaphone.ime.AutocorrectMemory
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map

private val Context.typingFixStore: DataStore<Preferences> by preferencesDataStore(name = "typing_fixes")

/**
 * The keyboard's autocorrect memory ([AutocorrectMemory]): typed → fix pairs
 * and how often each was picked or undone. Word pairs only, never the text
 * around them; on this phone only, and "Forget learned fixes" clears it.
 */
internal class TypingFixStore(private val context: Context) {
    val memory: Flow<AutocorrectMemory> = context.typingFixStore.data.map { AutocorrectMemory.decode(it[KEY]) }

    suspend fun recordPick(typed: String, picked: String) = update { it.withPick(typed, picked) }

    suspend fun recordRejection(typed: String, fix: String) = update { it.withRejection(typed, fix) }

    suspend fun clear() {
        context.typingFixStore.edit { it.remove(KEY) }
    }

    private suspend fun update(change: (AutocorrectMemory) -> AutocorrectMemory) {
        context.typingFixStore.edit { preferences ->
            preferences[KEY] = change(AutocorrectMemory.decode(preferences[KEY])).encode()
        }
    }

    private companion object {
        val KEY = stringPreferencesKey("pairs")
    }
}
