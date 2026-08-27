package com.vocahq.vocaphone.ui

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat

/**
 * Permission handoff for setup: track whether we have already asked, and open
 * the app Settings page once Android will no longer show its own dialog.
 */
internal object SetupPermissions {
    private const val PREFS = "setup_permissions_asked"

    fun openAppSettings(context: Context) {
        context.startActivity(
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                data = Uri.fromParts("package", context.packageName, null)
            },
        )
    }

    fun markAsked(context: Context, permission: String) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(permission, true)
            .apply()
    }

    fun wasAsked(context: Context, permission: String): Boolean =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getBoolean(permission, false)

    /**
     * True when the runtime dialog will not appear again: we have already asked,
     * the permission is still missing, and rationale is false.
     */
    fun needsAppSettings(
        granted: Boolean,
        asked: Boolean,
        showRationale: Boolean,
    ): Boolean = !granted && asked && !showRationale

    fun needsAppSettings(activity: Activity, permission: String): Boolean =
        needsAppSettings(
            granted = ContextCompat.checkSelfPermission(activity, permission) ==
                PackageManager.PERMISSION_GRANTED,
            asked = wasAsked(activity, permission),
            showRationale = ActivityCompat.shouldShowRequestPermissionRationale(
                activity,
                permission,
            ),
        )

    fun grantOrOpenLabel(activity: Activity, permission: String): String =
        if (needsAppSettings(activity, permission)) "Open" else "Grant"

    fun requestOrOpenSettings(
        activity: Activity,
        permission: String,
        request: (String) -> Unit,
    ) {
        if (needsAppSettings(activity, permission)) {
            openAppSettings(activity)
        } else {
            markAsked(activity, permission)
            request(permission)
        }
    }
}

internal tailrec fun Context.findActivity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.findActivity()
    else -> null
}
