package com.vocahq.vocaphone

import android.app.Application
import android.content.ComponentCallbacks2
import android.content.Context
import androidx.room.Room
import com.vocahq.vocaphone.audio.DictationTonePlayer
import com.vocahq.vocaphone.data.HistoryRepository
import com.vocahq.vocaphone.data.DiagnosticLog
import com.vocahq.vocaphone.data.ProcessExitReporter
import com.vocahq.vocaphone.data.recentProcessExits
import com.vocahq.vocaphone.data.VocaPhoneDatabase
import com.vocahq.vocaphone.dictation.DictationController
import com.vocahq.vocaphone.local.LocalModelManager
import com.vocahq.vocaphone.local.RetiredModels
import com.vocahq.vocaphone.settings.SettingsRepository
import com.vocahq.vocaphone.telemetry.Telemetry
import com.vocahq.vocaphone.telemetry.TelemetryFlushScheduler
import java.io.File
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

/**
 * The IME, microphone service and companion app all run in one process and
 * share exactly one dictation, so the container is held on the application
 * rather than injected per component.
 */
class AppContainer(context: Context) {

    private val appContext = context.applicationContext

    val settings = SettingsRepository(context)

    val dictationCues = DictationTonePlayer(context)

    private val database = Room
        .databaseBuilder(context, VocaPhoneDatabase::class.java, "vocaphone.db")
        .fallbackToDestructiveMigration(dropAllTables = true)
        .build()

    val history = HistoryRepository(database.dictationRecordDao())

    /** App-private and bounded; it never contains transcript or gateway data. */
    val diagnostics = DiagnosticLog(context)

    /**
     * SupervisorJob keeps one failed job from cancelling its siblings. It does
     * not stop an exception escaping a root `launch`, and an uncaught one there
     * reaches the thread's default handler and takes the process down.
     *
     * Everything on this scope is upkeep or reporting -- model verification,
     * expired-audio purging, exit reporting, telemetry -- and none of it is
     * worth killing the app for. It also runs on every process start, which for
     * this app includes every time the keyboard is raised, so a throw here is a
     * crash the user meets again the moment they try to type. Record it where
     * the bug report will show it and let the app carry on.
     */
    private val backgroundFailures = CoroutineExceptionHandler { _, _ ->
        // No source: SOURCES names where a dictation came from, and this did
        // not come from one. Anything else would be written out as "none".
        diagnostics.recordError("background", null)
    }

    private val applicationScope =
        CoroutineScope(SupervisorJob() + Dispatchers.Default + backgroundFailures)

    /** Survives the companion activity. Model downloads and their follow-up writes use this. */
    internal val workScope: CoroutineScope get() = applicationScope

    /**
     * Why the previous process ended, written into [diagnostics] at start.
     *
     * A killed process cannot log its own death, so without this the log of a
     * crashing device is a dictation that reaches TRANSCRIBING and then a bare
     * IDLE from the rebuilt controller — the same shape whether the cause was a
     * native crash, an out-of-memory kill, or an OEM background sweep.
     */
    private val processExits = ProcessExitReporter(
        diagnostics = diagnostics,
        claimExitsUpTo = settings::claimProcessExitsUpTo,
        recentExits = { appContext.recentProcessExits() },
    )

    /** App-private, no-backup storage: recordings never leave the device except to the gateway. */
    val audioDirectory = File(context.filesDir, "recordings")

    val localModels = LocalModelManager(context.applicationContext)

    /**
     * Anonymous usage reporting. Does nothing at all until the user turns it on,
     * and is compiled out of the F-Droid flavor.
     */
    val telemetry = Telemetry(settings, applicationScope)

    private val telemetryFlush = TelemetryFlushScheduler(telemetry, applicationScope)

    val dictation = DictationController(
        context = context.applicationContext,
        settings = settings,
        history = history,
        diagnostics = diagnostics,
        audioDirectory = audioDirectory,
        localModels = localModels,
        telemetry = telemetry,
        cues = dictationCues,
        scope = applicationScope,
    )

    init {
        applicationScope.launch {
            migrateRetiredModelSelection()
            localModels.refresh()
        }
        telemetryFlush.start()
    }

    /**
     * Move a stored selection off a model that has left the catalog.
     *
     * `local_model_id` holds an id verbatim, so a catalog that stops shipping a
     * row strands whoever had picked it: `LocalModelCatalog.find` returns null
     * and the app silently re-derives a first-run recommendation. Someone who
     * deliberately downloaded Whisper Medium would come back to Tiny, with
     * nothing on screen to say why.
     *
     * Runs before the first [LocalModelManager.refresh] so the manager sees the
     * migrated id, and writes the replacement back rather than translating on
     * every read -- the stored value is shared with the keyboard process, which
     * has no reason to know the catalog's history.
     */
    private suspend fun migrateRetiredModelSelection() {
        val stored = settings.settings.first().localModelId
        when (
            val outcome = RetiredModels.resolve(
                stored = stored,
                totalRamGB = localModels.totalRamGB(),
            )
        ) {
            is RetiredModels.Outcome.Unchanged -> Unit
            is RetiredModels.Outcome.Replaced -> settings.setLocalModel(outcome.id)
            // Nothing that replaces the retired model fits this phone. Clearing
            // the selection alone would leave on-device transcription switched
            // on with nothing behind it, and every dictation would record and
            // then fail. The switch goes off with it, so setup says so before
            // recording rather than after.
            is RetiredModels.Outcome.Cleared -> {
                settings.setLocalModel("")
                settings.setLocalTranscriptionEnabled(false)
            }
        }
    }

    fun purgeExpiredAudio() {
        applicationScope.launch { history.purgeExpiredAudio(audioDirectory) }
    }

    fun reportProcessExits() {
        applicationScope.launch { processExits.report() }
    }
}

class VocaPhoneApplication : Application() {

    private val container by lazy { AppContainer(this) }

    override fun onCreate() {
        super.onCreate()
        // Audio kept for a retry that never happened must not outlive its window,
        // including across a process that was killed mid-dictation.
        container.purgeExpiredAudio()
        // Runs for every process start, which for this app is every time the
        // keyboard is brought up after the last one was reclaimed — so a crash
        // is explained in the log the user pastes, not only after they manage
        // to reproduce it with a cable attached.
        container.reportProcessExits()
    }

    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        if (level >= ComponentCallbacks2.TRIM_MEMORY_BACKGROUND) {
            container.localModels.releaseIfIdle()
        }
    }

    companion object {
        fun container(context: Context): AppContainer =
            (context.applicationContext as VocaPhoneApplication).container
    }
}
