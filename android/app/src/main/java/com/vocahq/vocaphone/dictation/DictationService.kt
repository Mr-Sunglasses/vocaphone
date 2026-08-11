package com.vocahq.vocaphone.dictation

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
import com.vocahq.vocaphone.VocaPhoneApplication
import com.vocahq.vocaphone.R
import com.vocahq.vocaphone.core.DictationPhase
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Holds the microphone foreground-service type for the whole dictation and shows
 * the ongoing recording notification Android requires while it does.
 */
class DictationService : Service() {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var observer: Job? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val controller = VocaPhoneApplication.container(this).dictation
        when (intent?.action) {
            ACTION_START -> {
                // Called before any capture begins: Android requires the microphone
                // foreground service to be visible for the whole recording.
                startForeground(
                    NOTIFICATION_ID,
                    notification("Listening"),
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE,
                )
                val source = intent.getStringExtra(EXTRA_SOURCE)
                    ?.let { runCatching { DictationSource.valueOf(it) }.getOrNull() }
                    ?: DictationSource.COMPANION_APP
                controller.start(source)
                observeUntilIdle()
            }

            ACTION_FINISH -> {
                controller.finish()
                stopUnlessHoldingMicrophone()
            }

            ACTION_CANCEL -> {
                controller.cancel()
                stopUnlessHoldingMicrophone()
            }

            else -> stopSelf()
        }
        return START_NOT_STICKY
    }

    /**
     * The microphone is released as soon as capture ends, and this service stops
     * itself there — so Finish and Cancel sent during upload or transcription
     * arrive at a *new* instance with no recording to hold. It has no observer
     * to stop it later, and a started service runs until something does, so
     * every cancel after the microphone was released leaked one.
     */
    private fun stopUnlessHoldingMicrophone() {
        if (observer == null) stopSelf()
    }

    private fun observeUntilIdle() {
        observer?.cancel()
        val controller = VocaPhoneApplication.container(this).dictation
        observer = scope.launch {
            // Capture starts a moment after `start` returns, so the service must
            // wait for the microphone to actually be held before it treats an idle
            // state as the end of the dictation. The timeout is the last resort;
            // a start that resolves without ever recording says so, and waiting
            // it out held a microphone foreground service — an ongoing "VocaPhone
            // is recording" notification and the system's microphone indicator —
            // for ten seconds over a dictation that never began. Tapping the mic
            // before the gateway is configured did exactly that.
            val settled = withTimeoutOrNull(START_TIMEOUT_MILLIS) {
                controller.state.first { DictationStartWatch.hasSettled(it.phase) }
            }
            if (settled?.phase?.holdsMicrophone == true) {
                controller.state
                    .onEach { notificationManager().notify(NOTIFICATION_ID, notification(it.statusText)) }
                    .first { !it.phase.holdsMicrophone }
            }
            // The microphone is released the moment capture ends; delivery and
            // insertion continue without a foreground service.
            stopForegroundAndSelf()
        }
    }

    private fun stopForegroundAndSelf() {
        observer?.cancel()
        observer = null
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }

    private fun notification(status: String): Notification {
        val open = PendingIntent.getActivity(
            this,
            0,
            packageManager.getLaunchIntentForPackage(packageName),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val cancel = PendingIntent.getService(
            this,
            1,
            Intent(this, DictationService::class.java).setAction(ACTION_CANCEL),
            PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_dictation)
            .setContentTitle("VocaPhone is recording")
            .setContentText(status)
            .setOngoing(true)
            .setSilent(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .setContentIntent(open)
            .addAction(R.drawable.ic_cancel, "Cancel", cancel)
            .build()
    }

    private fun createChannel() {
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Recording",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Shown while VocaPhone is holding the microphone."
            setShowBadge(false)
        }
        notificationManager().createNotificationChannel(channel)
    }

    private fun notificationManager() = getSystemService(NotificationManager::class.java)

    companion object {
        const val ACTION_START = "com.vocahq.vocaphone.START"
        const val ACTION_FINISH = "com.vocahq.vocaphone.FINISH"
        const val ACTION_CANCEL = "com.vocahq.vocaphone.CANCEL"
        const val EXTRA_SOURCE = "source"
        private const val CHANNEL_ID = "vocaphone.recording"
        private const val NOTIFICATION_ID = 4101

        /** How long the service waits for capture to begin before giving up. */
        private const val START_TIMEOUT_MILLIS = 10_000L

        /**
         * Starts recording. Newer Android versions refuse some background service
         * starts even when Android rejects a background launch, so the documented
         * fallback is a no-animation activity that starts the service while
         * visible and closes immediately.
         */
        fun start(context: Context, source: DictationSource) {
            val intent = Intent(context, DictationService::class.java)
                .setAction(ACTION_START)
                .putExtra(EXTRA_SOURCE, source.name)
            try {
                ContextCompat.startForegroundService(context, intent)
            } catch (_: ForegroundServiceStartNotAllowedException) {
                context.startActivity(
                    Intent(context, DictationLauncherActivity::class.java)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_ANIMATION)
                        .putExtra(EXTRA_SOURCE, source.name)
                )
            }
        }

        fun send(context: Context, action: String) {
            context.startService(Intent(context, DictationService::class.java).setAction(action))
        }
    }
}

/**
 * Whether a start attempt has resolved, either way.
 *
 * [DictationService] holds a microphone foreground service from before capture
 * begins until it can see the microphone actually being held, so it needs to
 * recognise the outcomes that never reach the microphone at all — otherwise the
 * only thing that ends the wait is a timeout the user spends looking at a
 * recording notification.
 */
internal object DictationStartWatch {
    fun hasSettled(phase: DictationPhase): Boolean = when (phase) {
        // Capture is running, which is what the service exists to cover.
        DictationPhase.LISTENING, DictationPhase.FINALIZING -> true
        // Resolved without ever recording: a permission to repair, or a
        // microphone that could not be opened.
        DictationPhase.PERMISSION_REPAIR, DictationPhase.FAILED -> true
        else -> false
    }
}

/**
 * The predetermined fallback path only: visible for a single frame so the
 * microphone service can be started from the foreground.
 */
class DictationLauncherActivity : android.app.Activity() {
    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        // Theme.VocaPhone.Invisible suppresses the transition; there is nothing to
        // animate and nothing for the user to see.
        val source = intent.getStringExtra(DictationService.EXTRA_SOURCE)
            ?.let { runCatching { DictationSource.valueOf(it) }.getOrNull() }
            ?: DictationSource.COMPANION_APP
        ContextCompat.startForegroundService(
            this,
            Intent(this, DictationService::class.java)
                .setAction(DictationService.ACTION_START)
                .putExtra(DictationService.EXTRA_SOURCE, source.name),
        )
        finish()
    }
}
