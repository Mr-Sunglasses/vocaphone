package com.vocahq.vocaphone.overlay

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import androidx.core.app.NotificationCompat
import com.vocahq.vocaphone.R
import com.vocahq.vocaphone.core.OverlayNoticePolicy

/**
 * The notification that explains a bubble which never arrived. See
 * [OverlayNoticePolicy] for when it fires and why it is a notification rather
 * than something in the app.
 */
class OverlayPermissionNotice(private val context: Context) {

    private var posted = false

    /** The bubble was wanted and the overlay permission refused it. */
    fun onBubbleBlocked() = apply(overlayGranted = false)

    /** The bubble is about to be shown, so the permission is evidently back. */
    fun onOverlayAvailable() = apply(overlayGranted = true)

    private fun apply(overlayGranted: Boolean) {
        when (OverlayNoticePolicy.decide(overlayGranted, posted)) {
            OverlayNoticePolicy.Action.POST -> {
                android.util.Log.d("VocaPhone", "bubble blocked: no overlay permission")
                if (post()) posted = true
            }

            OverlayNoticePolicy.Action.CANCEL -> {
                runCatching { manager()?.cancel(NOTIFICATION_ID) }
                posted = false
            }

            OverlayNoticePolicy.Action.NOTHING -> Unit
        }
    }

    /**
     * False when the post did not land — most often notifications are denied
     * too, in which case nothing is marked as told and a later attempt can
     * still succeed.
     */
    private fun post(): Boolean {
        val manager = manager() ?: return false
        createChannel(manager)

        val settings = Intent(
            Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
            Uri.fromParts("package", context.packageName, null),
        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val tap = PendingIntent.getActivity(
            context,
            REQUEST_CODE,
            settings,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_warning)
            .setContentTitle("VocaPhone can't show the bubble")
            .setContentText("\"Display over other apps\" is off. Tap to turn it back on.")
            .setStyle(
                NotificationCompat.BigTextStyle().bigText(
                    "VocaPhone needs \"Display over other apps\" to draw the " +
                        "dictation bubble. Android switches it off on a fresh " +
                        "install, so dictation into other apps stays unavailable " +
                        "until it is granted again. Tap to open the setting.",
                )
            )
            .setCategory(NotificationCompat.CATEGORY_ERROR)
            .setAutoCancel(true)
            .setContentIntent(tap)
            .build()

        // Notifications may be denied outright; a blocked bubble is not worth
        // crashing the accessibility service over.
        return runCatching { manager.notify(NOTIFICATION_ID, notification) }.isSuccess
    }

    private fun createChannel(manager: NotificationManager) {
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Bubble unavailable",
            NotificationManager.IMPORTANCE_DEFAULT,
        ).apply {
            description = "Shown when a permission stops the dictation bubble appearing."
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    private fun manager() = context.getSystemService(NotificationManager::class.java)

    private companion object {
        const val CHANNEL_ID = "vocaphone.bubble_blocked"
        const val NOTIFICATION_ID = 4102
        const val REQUEST_CODE = 2
    }
}
