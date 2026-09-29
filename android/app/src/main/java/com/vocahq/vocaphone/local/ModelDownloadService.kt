package com.vocahq.vocaphone.local

import android.app.ForegroundServiceStartNotAllowedException
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import com.vocahq.vocaphone.R
import com.vocahq.vocaphone.VocaPhoneApplication
import com.vocahq.vocaphone.ui.MainActivity
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch

/**
 * Keeps the process alive while a model downloads, and says how far it is.
 *
 * The download itself stays in [LocalModelManager]: its scope, its mutex, its
 * cancellation and integrity checks, and the state flow every card observes.
 * This service owns none of that. It is a foreground service *while* the
 * manager works — the same relationship `DictationService` has with the
 * dictation controller — and nothing more.
 *
 * Why it exists: setup sends the person to system Settings for the keyboard
 * step, and a backgrounded app with no foreground service is killed within
 * seconds on some OEM builds. A 661 MB download in a plain coroutine did not
 * survive that, and the last setup page then had nothing to show but a vague
 * notice. The notification is also the progress the person can see while they
 * are still in Settings.
 */
class ModelDownloadService : Service() {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var watcher: Job? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val models = VocaPhoneApplication.container(this).localModels
        when (intent?.action) {
            ACTION_CANCEL -> {
                models.cancelDownload()
                return START_NOT_STICKY
            }
            ACTION_START -> {
                createChannel()
                val name = intent.getStringExtra(EXTRA_NAME).orEmpty()
                val modelId = intent.getStringExtra(EXTRA_MODEL_ID)
                if (modelId.isNullOrEmpty()) {
                    stopSelf(startId)
                    return START_NOT_STICKY
                }
                if (!enterForeground(notification(name, models.state.value))) {
                    // Refused. The download still runs as it did before this
                    // service existed; only the shade is missing.
                    stopSelf(startId)
                    return START_NOT_STICKY
                }
                val job = models.activeDownload()
                if (job == null) {
                    watcher?.cancel()
                    watcher = scope.launch { finish(models.state.value.message, startId) }
                } else {
                    watch(job, modelId, name, startId)
                }
            }
            else -> stopSelf(startId)
        }
        return START_NOT_STICKY
    }

    private fun watch(job: Job, modelId: String, name: String, startId: Int) {
        watcher?.cancel()
        val models = VocaPhoneApplication.container(this).localModels
        watcher = scope.launch {
            val progress = launch {
                models.state
                    .filter { it.downloading == modelId }
                    .map { it.progress to downloadProgressLine(it) }
                    .distinctUntilChanged()
                    .collect { notificationManager().notify(NOTIFICATION_ID, notification(name, models.state.value)) }
            }
            job.join()
            progress.cancel()
            finish(models.state.value.message, startId)
        }
    }

    private suspend fun finish(message: String?, startId: Int) {
        notificationManager().notify(NOTIFICATION_ID, finalNotification(message))
        delay(FINAL_LINGER_MILLIS)
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf(startId)
    }

    override fun onDestroy() {
        watcher?.cancel()
        scope.cancel()
        super.onDestroy()
    }

    private fun enterForeground(notification: Notification): Boolean = try {
        startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        true
    } catch (_: SecurityException) {
        false
    } catch (_: IllegalStateException) {
        false
    }

    private fun notification(name: String, state: LocalModelState): Notification =
        builder()
            .setContentTitle(if (name.isBlank()) "Downloading model" else "Downloading $name")
            .setContentText(downloadProgressLine(state))
            .setProgress(100, state.progress.coerceIn(0, 100), state.totalBytes <= 0)
            .setOngoing(true)
            .addAction(R.drawable.ic_cancel, "Cancel", cancelIntent())
            .build()

    private fun finalNotification(message: String?): Notification =
        builder()
            .setContentTitle(message ?: "Model download finished")
            .setOngoing(false)
            .build()

    private fun builder(): NotificationCompat.Builder {
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).setFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_models)
            .setSilent(true)
            .setOnlyAlertOnce(true)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .setContentIntent(open)
    }

    private fun cancelIntent(): PendingIntent = PendingIntent.getService(
        this,
        1,
        Intent(this, ModelDownloadService::class.java).setAction(ACTION_CANCEL),
        PendingIntent.FLAG_IMMUTABLE,
    )

    private fun createChannel() {
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Model downloads",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Progress while a speech model downloads to this phone."
            setShowBadge(false)
        }
        notificationManager().createNotificationChannel(channel)
    }

    private fun notificationManager() = getSystemService(NotificationManager::class.java)

    companion object {
        const val ACTION_START = "com.vocahq.vocaphone.MODEL_DOWNLOAD_START"
        const val ACTION_CANCEL = "com.vocahq.vocaphone.MODEL_DOWNLOAD_CANCEL"
        const val EXTRA_NAME = "name"
        const val EXTRA_MODEL_ID = "modelId"
        private const val CHANNEL_ID = "vocaphone.model_download"
        private const val NOTIFICATION_ID = 4102
        private const val FINAL_LINGER_MILLIS = 1_500L
        /**
         * Starts the service for a download the manager has already begun.
         * Called from a foreground activity (a tap on Download), which Android
         * allows; a refusal is caught inside and the download simply runs
         * without a notification, as it did before.
         */
        fun start(context: Context, modelId: String, modelName: String) {
            val intent = Intent(context, ModelDownloadService::class.java)
                .setAction(ACTION_START)
                .putExtra(EXTRA_MODEL_ID, modelId)
                .putExtra(EXTRA_NAME, modelName)
            try {
                ContextCompat.startForegroundService(context, intent)
            } catch (_: ForegroundServiceStartNotAllowedException) {
                // Not from the foreground after all; the download proceeds unattended.
            } catch (_: SecurityException) {
                // Same.
            }
        }
    }
}
