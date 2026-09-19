package com.vocahq.vocaphone.data

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.core.handlers.ReplaceFileCorruptionHandler
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.emptyPreferences
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import com.vocahq.vocaphone.core.UsageStats
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map

/**
 * Its own file rather than a key in the `vocaphone` settings store.
 *
 * Statistics are written on every dictation, and the settings store holds the
 * encrypted gateway token, the model selection and the onboarding state. Routing
 * a per-dictation write through that file would raise its write rate for no
 * benefit and widen the blast radius of a damaged preferences file from "totals
 * reset" to "set the app up again".
 *
 * The corruption handler is the other half of that: a damaged statistics file
 * becomes an empty one. Counters are worth less than a launchable app.
 *
 * Must stay a top-level property. DataStore permits exactly one active instance
 * per file, and a delegate declared inside a class produces a second one per
 * instance.
 */
private val Context.usageStatsDataStore: DataStore<Preferences> by preferencesDataStore(
    name = "usage_stats",
    corruptionHandler = ReplaceFileCorruptionHandler { emptyPreferences() },
)

/**
 * Reads and writes [UsageStats]. Deliberately thin: every rule lives in
 * [UsageStats] where it is testable without a DataStore.
 */
class UsageStatsRepository(context: Context) {

    private val store = context.applicationContext.usageStatsDataStore

    val stats: Flow<UsageStats> = store.data.map { UsageStats.decode(it[KEY]) }

    /**
     * One successful dictation.
     *
     * A single [DataStore.edit] rather than a read followed by a write: the edit
     * is one atomic read-modify-write, so a dictation landing at the same moment
     * as a reset cannot drop either.
     */
    suspend fun record(
        transcript: String,
        durationMillis: Long?,
        now: Long = System.currentTimeMillis(),
    ) {
        store.edit { preferences ->
            val updated = UsageStats.decode(preferences[KEY]).record(transcript, durationMillis, now)
            preferences[KEY] = UsageStats.encode(updated)
        }
    }

    suspend fun reset() {
        store.edit { preferences -> preferences.remove(KEY) }
    }

    private companion object {
        val KEY = stringPreferencesKey("usage_stats_v1")
    }
}
