package com.vocahq.vocaphone.ui

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.widget.Toast
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.vocahq.vocaphone.R
import com.vocahq.vocaphone.local.LocalModelDescriptor
import com.vocahq.vocaphone.settings.VocaPhoneSettings

/**
 * Settings → About: who makes the app and how to reach them. The privacy text
 * moved to Settings → Privacy and the device table to Help and diagnostics, so
 * this page no longer ends in a hardware report and a red button.
 */
@Composable
fun AboutPage(appInfo: AppInfo) {
    val context = LocalContext.current

    Column(
        modifier = Modifier.fillMaxWidth(),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Image(
            painter = painterResource(R.drawable.ic_vocaphone_logo),
            contentDescription = null,
            modifier = Modifier
                .padding(top = 8.dp, bottom = 4.dp)
                .size(72.dp),
            contentScale = ContentScale.Fit,
        )
        Text(
            ABOUT_WORDMARK,
            style = MaterialTheme.typography.headlineSmall,
            fontWeight = FontWeight.SemiBold,
        )
        Text(
            ABOUT_TAGLINE,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
        )
        if (appInfo.versionName.isNotEmpty()) {
            Text(
                "Version ${appInfo.versionName} (${appInfo.versionCode})",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        TextButton(onClick = { context.openHttpUrl(WEBSITE_URL) }) {
            Text("vocaphone.vocahq.com")
        }
    }

    SettingsGroup(title = "Talk to us", footer = ABOUT_FEEDBACK_NOTE) {
        SettingsActionRow(
            title = ABOUT_REPORT_BUG,
            icon = R.drawable.ic_social_github,
            external = true,
            onClick = { context.openHttpUrl(NEW_ISSUE_URL) },
        )
        ABOUT_CONTACT_LINKS.forEach { link ->
            SettingsDivider(inset = true)
            SettingsActionRow(
                title = link.label,
                icon = link.icon,
                external = true,
                onClick = { context.openHttpUrl(link.url) },
            )
        }
    }

    SettingsGroup(title = "Part of VocaHQ", footer = ABOUT_FAMILY_NOTE) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp),
            horizontalArrangement = Arrangement.SpaceEvenly,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            ABOUT_FAMILY_LINKS.forEach { link ->
                val icon = link.icon ?: return@forEach
                IconButton(onClick = { context.openHttpUrl(link.url) }) {
                    Icon(
                        painter = painterResource(icon),
                        contentDescription = link.label,
                        modifier = Modifier.size(26.dp),
                        tint = MaterialTheme.colorScheme.primary,
                    )
                }
            }
        }
    }
}

/**
 * Settings → Help and diagnostics: what a bug report needs, and nothing a
 * person reading About has to wade through.
 */
@Composable
fun HelpPage(
    appInfo: AppInfo,
    settings: VocaPhoneSettings,
    setup: SetupStatus,
    localModel: LocalModelDescriptor?,
    onDevice: OnDeviceDiagnostics,
    diagnosticEvents: () -> String,
    onClearDiagnosticEvents: () -> Unit,
) {
    val context = LocalContext.current
    SettingsGroup(title = "Get help") {
        SettingsActionRow(
            title = ABOUT_REPORT_BUG,
            icon = R.drawable.ic_social_github,
            external = true,
            onClick = { context.openHttpUrl(NEW_ISSUE_URL) },
        )
        SettingsDivider(inset = true)
        SettingsActionRow(
            title = "How to run a gateway",
            icon = R.drawable.ic_connection,
            external = true,
            onClick = { context.openHttpUrl(GATEWAY_GUIDE_URL) },
        )
    }

    SettingsGroup(title = "Diagnostics", footer = ABOUT_DIAGNOSTICS_NOTE) {
        SettingsActionRow(
            title = ABOUT_COPY_DIAGNOSTICS,
            icon = R.drawable.ic_copy,
            onClick = {
                context.copyDiagnostics(
                    diagnosticsReport(appInfo, settings, setup, diagnosticEvents(), onDevice),
                )
                Toast.makeText(context, "Diagnostics copied", Toast.LENGTH_SHORT).show()
            },
        )
        SettingsDivider(inset = true)
        SettingsActionRow(
            title = ABOUT_CLEAR_EVENT_LOG,
            icon = R.drawable.ic_delete,
            destructive = true,
            onClick = {
                onClearDiagnosticEvents()
                Toast.makeText(context, "Event log cleared", Toast.LENGTH_SHORT).show()
            },
        )
    }

    SettingsGroup(title = "This phone") {
        Column(Modifier.padding(vertical = 8.dp)) {
            SettingsInfoRow("Android", "${appInfo.androidRelease} (SDK ${appInfo.sdkInt})")
            SettingsInfoRow("Device", appInfo.device)
            SettingsInfoRow("Installed from", appInfo.installedFrom)
            SettingsInfoRow(
                "Speech",
                speechSourceCopy(
                    localEnabled = settings.localTranscriptionEnabled,
                    localModelName = localModel?.displayName,
                    gatewayConfigured = settings.isConfigured,
                    gatewayUrl = settings.gatewayUrl,
                    lastEngine = settings.lastEngine,
                    lastEngineReady = settings.lastEngineReady,
                ).engineLabel,
            )
            SettingsInfoRow(
                "Memory",
                "${formatBytes(onDevice.availRamBytes)} free of ${formatBytes(onDevice.totalRamBytes)}",
            )
            SettingsInfoRow(
                "Storage",
                "${formatBytes(onDevice.availStorageBytes)} free of ${formatBytes(onDevice.totalStorageBytes)}",
            )
            SettingsInfoRow(
                "Models",
                if (onDevice.downloadedModelIds.isEmpty()) {
                    "None downloaded"
                } else {
                    "${onDevice.downloadedModelIds.size} · ${formatBytes(onDevice.modelStorageBytes)}"
                },
            )
            SettingsInfoRow(
                "Processor",
                buildString {
                    append("${onDevice.cpuCores} cores")
                    if (onDevice.soc.isNotEmpty()) append(" · ${onDevice.soc}")
                },
            )
            SettingsInfoRow(
                "Setup",
                if (setup.isReadyToDictate) {
                    "Complete"
                } else {
                    "${setup.completedStepCount} of ${setup.stepCount} steps"
                },
            )
        }
    }
}

private fun Context.copyDiagnostics(text: String) {
    val clipboard = getSystemService(ClipboardManager::class.java) ?: return
    clipboard.setPrimaryClip(ClipData.newPlainText("VocaPhone diagnostics", text))
}
