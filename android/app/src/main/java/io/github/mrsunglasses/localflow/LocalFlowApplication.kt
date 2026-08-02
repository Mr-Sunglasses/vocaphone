package io.github.mrsunglasses.localflow

import android.app.Application
import android.content.Context
import androidx.room.Room
import io.github.mrsunglasses.localflow.data.HistoryRepository
import io.github.mrsunglasses.localflow.data.LocalFlowDatabase
import io.github.mrsunglasses.localflow.dictation.DictationController
import io.github.mrsunglasses.localflow.settings.SettingsRepository
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/**
 * The bubble, the accessibility service, the microphone service and the
 * companion app all run in one process and share exactly one dictation, so the
 * container is held on the application rather than injected per component.
 */
class AppContainer(context: Context) {

    private val applicationScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    val settings = SettingsRepository(context)

    private val database = Room
        .databaseBuilder(context, LocalFlowDatabase::class.java, "localflow.db")
        .fallbackToDestructiveMigration(dropAllTables = true)
        .build()

    val history = HistoryRepository(database.dictationRecordDao())

    /** App-private, no-backup storage: recordings never leave the device except to the gateway. */
    val audioDirectory = File(context.filesDir, "recordings")

    val dictation = DictationController(
        context = context.applicationContext,
        settings = settings,
        history = history,
        audioDirectory = audioDirectory,
        scope = applicationScope,
    )

    fun purgeExpiredAudio() {
        applicationScope.launch { history.purgeExpiredAudio(audioDirectory) }
    }
}

class LocalFlowApplication : Application() {

    private val container by lazy { AppContainer(this) }

    override fun onCreate() {
        super.onCreate()
        // Audio kept for a retry that never happened must not outlive its window,
        // including across a process that was killed mid-dictation.
        container.purgeExpiredAudio()
    }

    companion object {
        fun container(context: Context): AppContainer =
            (context.applicationContext as LocalFlowApplication).container
    }
}
