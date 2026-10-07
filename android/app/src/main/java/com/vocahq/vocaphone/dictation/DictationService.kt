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
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import com.vocahq.vocaphone.NotificationIds
import com.vocahq.vocaphone.VocaPhoneApplication
import com.vocahq.vocaphone.R
import com.vocahq.vocaphone.core.DictationFailure
import com.vocahq.vocaphone.core.DictationPhase
import com.vocahq.vocaphone.core.DictationState
import com.vocahq.vocaphone.ui.MainActivity
import java.util.UUID
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

/**
 * Holds a foreground service for the whole dictation and shows the ongoing
 * notification while capture or on-device transcription is running.
 */
class DictationService : Service() {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val mainHandler = Handler(Looper.getMainLooper())
    private var observer: Job? = null
    private var pendingSource: DictationSource? = null
    private var promoteFailures = 0
    private var microphoneForeground = false
    private val promoteRetry = Runnable { promoteMicrophoneForeground() }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val controller = VocaPhoneApplication.container(this).dictation
        when (intent?.action) {
            ACTION_START -> {
                if (microphoneForeground) return START_NOT_STICKY
                val source = intent.getStringExtra(EXTRA_SOURCE)
                    ?.let { runCatching { DictationSource.valueOf(it) }.getOrNull() }
                    ?: DictationSource.COMPANION_APP
                pendingSource = source
                promoteFailures = 0
                mainHandler.removeCallbacks(promoteRetry)
                promoteMicrophoneForeground()
            }

            ACTION_FINISH -> {
                mainHandler.removeCallbacks(promoteRetry)
                pendingSource = null
                controller.finish()
                stopUnlessHoldingMicrophone()
            }

            ACTION_CANCEL -> {
                mainHandler.removeCallbacks(promoteRetry)
                pendingSource = null
                controller.cancel()
                stopUnlessHoldingMicrophone()
            }

            else -> stopSelf()
        }
        return START_NOT_STICKY
    }

    /**
     * startForeground(MICROPHONE) is refused until the app is in an eligible
     * state. HeliBoard can start this service a frame before our IME window
     * counts; retry rather than crash the process.
     */
    private fun promoteMicrophoneForeground() {
        val source = pendingSource
        if (source == null) {
            if (!microphoneForeground && enterMicrophoneForeground()) {
                stopForegroundAndSelf()
            }
            return
        }
        if (enterMicrophoneForeground()) {
            pendingSource = null
            promoteFailures = 0
            VocaPhoneApplication.container(this).dictation.start(source)
            observeUntilIdle()
            return
        }
        promoteFailures++
        if (MicrophoneForegroundPromote.launchesVisibleStarter(source) &&
            MicrophoneForegroundPromote.shouldLaunchVisibleActivity(promoteFailures)
        ) {
            launchVisibleStarter(this, source)
        }
        if (MicrophoneForegroundPromote.shouldRetry(promoteFailures)) {
            mainHandler.postDelayed(promoteRetry, MicrophoneForegroundPromote.RETRY_DELAY_MS)
            return
        }
        // Out of retries. This used to just stop posting them: the service
        // stayed started with no notification and no dictation, and the
        // keyboard went on showing Ready as if the tap had never happened.
        // The first refused startForeground already cleared the system's
        // must-call-startForeground deadline, so stopping here does not trip
        // it; leaving the service up only kept a dead service around.
        pendingSource = null
        promoteFailures = 0
        VocaPhoneApplication.container(this).dictation.microphoneServiceRefused(source)
        stopSelf()
    }

    private fun enterMicrophoneForeground(): Boolean {
        if (microphoneForeground) return true
        return try {
            startForeground(
                NOTIFICATION_ID,
                notification("Listening"),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE,
            )
            microphoneForeground = true
            true
        } catch (_: SecurityException) {
            false
        } catch (_: ForegroundServiceStartNotAllowedException) {
            false
        }
    }

    /**
     * Keep the service alive through delivery and local inference. In particular,
     * Whisper is CPU-heavy; stopping the foreground service at the microphone
     * boundary lets Android treat the same process as background work just as
     * decoding begins. The observer below owns the service lifetime and stops it
     * at a terminal dictation state.
     */
    private fun stopUnlessHoldingMicrophone() {
        if (observer == null) stopSelf()
    }

    private fun observeUntilIdle() {
        observer?.cancel()
        val controller = VocaPhoneApplication.container(this).dictation
        // Assign before starting: a synchronously finished pipeline must still
        // clear the observer and notification rather than leave a completed job.
        val next = scope.launch(start = CoroutineStart.LAZY) {
            try {
                while (true) {
                    val version = controller.sessionVersion.value
                    monitorDictation(
                        controller.activeJob,
                        controller.state,
                        controller.startupRepair,
                    ) { status ->
                        notificationManager().notify(NOTIFICATION_ID, notification(status))
                    }
                    // A repair that resolved without recording (e.g. a model
                    // download) means this attempt produces no audio: release
                    // the mic service instead of showing "Listening" through
                    // a download — but only when no queued session waits on
                    // the pipeline, since the service stays the queued
                    // attempt's only foreground lifetime.
                    if (controller.repairSettledWithoutQueue()) break
                    // A queued start claims the pipeline a beat after the old
                    // one ends. Without re-observing here the service would
                    // stop into that gap and leave the follow-up dictation
                    // recording without its foreground lifetime or mic
                    // notification. The version flow parks the wait until the
                    // next claim, drain, or pipeline end — no spin.
                    if (!controller.sessionInFlight()) break
                    controller.sessionVersion.first { it != version }
                }
            } finally {
                if (observer === coroutineContext[Job]) stopForegroundAndSelf()
            }
        }
        observer = next
        next.start()
    }

    private fun stopForegroundAndSelf() {
        observer?.cancel()
        observer = null
        pendingSource = null
        promoteFailures = 0
        microphoneForeground = false
        mainHandler.removeCallbacks(promoteRetry)
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        mainHandler.removeCallbacks(promoteRetry)
        pendingSource = null
        microphoneForeground = false
        scope.cancel()
        super.onDestroy()
    }

    private fun notification(status: String): Notification {
        // Destination named, and nothing else set.
        //
        // The action and category this used to carry were copied from what
        // `packageManager.getLaunchIntentForPackage` builds internally, and they
        // were doing nothing: an action and a category exist so the system can
        // *resolve* an intent, and resolution does not happen once a component
        // is named. What they did do was make CodeQL read this as an implicit
        // intent handed to a third party (CWE-927), because its rule keys on
        // `setAction` and does not care that the constructor set a component.
        //
        // The rule is crude there but the direction is right: a PendingIntent
        // runs with this app's identity, an intent with an unfilled destination
        // can have one supplied by whoever holds it, and a notification's
        // content intent is held by the system UI. FLAG_IMMUTABLE already closed
        // that door. This leaves nothing for anyone to fill in.
        //
        // FLAG_ACTIVITY_NEW_TASK is not decoration: `getLaunchIntentForPackage`
        // sets it too, and starting an activity from a Service context needs it.
        // With the activity at the root of an existing task it brings that task
        // forward rather than stacking a second copy, which is what tapping an
        // ongoing notification should do.
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).setFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
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
            .setContentTitle("VocaPhone is working")
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
            description = "Shown while VocaPhone is recording or transcribing."
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
        private const val NOTIFICATION_ID = NotificationIds.DICTATION

        /**
         * Starts recording. Newer Android versions refuse some background service
         * starts even when Android rejects a background launch, so the documented
         * fallback is a no-animation activity that starts the service while
         * visible and closes immediately.
         *
         * Not for the keyboard. Its visible window is what makes the service
         * start allowed at all, so a refusal means that window is gone, and a
         * background activity launch from the same process is refused too on
         * Android 14+ — the tap would vanish without a trace. The keyboard is
         * told instead.
         */
        fun start(context: Context, source: DictationSource) {
            val intent = Intent(context, DictationService::class.java)
                .setAction(ACTION_START)
                .putExtra(EXTRA_SOURCE, source.name)
            try {
                ContextCompat.startForegroundService(context, intent)
            } catch (_: ForegroundServiceStartNotAllowedException) {
                startRefused(context, source)
            } catch (_: SecurityException) {
                startRefused(context, source)
            }
        }

        private fun startRefused(context: Context, source: DictationSource) {
            if (MicrophoneForegroundPromote.launchesVisibleStarter(source)) {
                launchVisibleStarter(context, source)
            } else {
                VocaPhoneApplication.container(context).dictation.microphoneServiceRefused(source)
            }
        }

        fun send(context: Context, action: String) {
            context.startService(Intent(context, DictationService::class.java).setAction(action))
        }

        private fun launchVisibleStarter(context: Context, source: DictationSource) {
            context.startActivity(
                Intent(context, DictationLauncherActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_ANIMATION)
                    .putExtra(EXTRA_SOURCE, source.name),
            )
        }
    }
}

/**
 * How long [DictationService] keeps retrying startForeground(MICROPHONE)
 * after a handoff that beat the IME window. Stays under the system timeout
 * for startForegroundService (~5–10 s).
 */
internal object MicrophoneForegroundPromote {
    const val RETRY_DELAY_MS = 50L
    const val MAX_ATTEMPTS = 20
    const val LAUNCH_ACTIVITY_AFTER = 4

    fun shouldRetry(failedTries: Int): Boolean = failedTries < MAX_ATTEMPTS

    fun shouldLaunchVisibleActivity(failedTries: Int): Boolean =
        failedTries == LAUNCH_ACTIVITY_AFTER

    /**
     * Whether a refused start may fall back to [DictationLauncherActivity].
     * Not for the keyboard: see [DictationService.start].
     */
    fun launchesVisibleStarter(source: DictationSource): Boolean = source != DictationSource.IME

    /** Diagnostics category for a refused microphone service. Metadata only. */
    const val ERROR_CATEGORY = "microphone_service"

    const val REFUSED_CODE = "microphone_service_refused"
    const val REFUSED_MESSAGE = "Couldn't start the microphone"

    /**
     * What a refused microphone service shows: a failure the user can read,
     * or null when a dictation already owns the state and must keep it.
     * Not recoverable, because nothing was recorded for Retry to resend; the
     * next step is another tap on the mic.
     */
    fun refusedState(current: DictationState, sessionId: UUID): DictationState? {
        if (current.phase.isBusy) return null
        return DictationState(
            sessionId = sessionId,
            phase = DictationPhase.FAILED,
            language = current.language,
            style = current.style,
            failure = DictationFailure(REFUSED_CODE, REFUSED_MESSAGE, recoverable = false),
        )
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
