package com.vocahq.vocaphone.ui

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.vocahq.vocaphone.R
import com.vocahq.vocaphone.local.LocalModelDescriptor
import com.vocahq.vocaphone.settings.VocaPhoneSettings

private val AboutTeal = Color(0xFF0F6B57)
private val AboutCream = Color(0xFFF2F6F2)

/**
 * Settings → About. Shared family language, Material 3 Settings chrome.
 * Header, Part of VocaHQ, Talk to us, then Phone-only Privacy and Device.
 */
@Composable
fun AboutPage(
    appInfo: AppInfo,
    settings: VocaPhoneSettings,
    setup: SetupStatus,
    localModel: LocalModelDescriptor?,
    onDevice: OnDeviceDiagnostics,
    diagnosticEvents: () -> String,
    onClearDiagnosticEvents: () -> Unit,
) {
    val context = LocalContext.current

    Column(
        modifier = Modifier.fillMaxWidth(),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Image(
            painter = painterResource(R.drawable.ic_vocaphone_logo),
            contentDescription = "VocaPhone",
            modifier = Modifier
                .padding(top = 8.dp, bottom = 4.dp)
                .size(80.dp),
            contentScale = ContentScale.Fit,
        )
        Text(
            ABOUT_WORDMARK,
            style = MaterialTheme.typography.headlineMedium,
            fontWeight = FontWeight.Bold,
        )
        if (appInfo.versionName.isNotEmpty()) {
            Text(
                "Version ${appInfo.versionName} (${appInfo.versionCode})",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Text(
            ABOUT_TAGLINE,
            style = MaterialTheme.typography.bodyMedium,
            textAlign = TextAlign.Center,
        )
        TextButton(onClick = { context.openHttpUrl(WEBSITE_URL) }) {
            Text("vocaphone.vocahq.com")
        }
    }

    Section(
        title = "Part of VocaHQ",
        supporting = ABOUT_FAMILY_NOTE,
    ) {
        FlowRow(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(4.dp),
            verticalArrangement = Arrangement.spacedBy(0.dp),
        ) {
            ABOUT_FAMILY_LINKS.forEach { link ->
                AboutLinkButton(link, context)
            }
        }
    }

    Section(
        title = "Talk to us",
        supporting = ABOUT_FEEDBACK_NOTE,
    ) {
        ReportBugButton(
            label = ABOUT_REPORT_BUG,
            onClick = { context.openHttpUrl(NEW_ISSUE_URL) },
            modifier = Modifier.fillMaxWidth(),
        )
        FlowRow(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(4.dp),
            verticalArrangement = Arrangement.spacedBy(0.dp),
        ) {
            ABOUT_CONTACT_LINKS.forEach { link ->
                AboutLinkButton(link, context)
            }
        }
    }

    Section(title = "Privacy") {
        Text(
            ABOUT_PRIVACY_NOTE,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }

    Section("Device") {
        InfoRow("Android", "${appInfo.androidRelease} (SDK ${appInfo.sdkInt})")
        InfoRow("Device", appInfo.device)
        InfoRow("Installed from", appInfo.installedFrom)
        InfoRow("Package", appInfo.packageName)
        InfoRow(
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
        InfoRow(
            "RAM",
            "${formatBytes(onDevice.totalRamBytes)} total, " +
                "${formatBytes(onDevice.availRamBytes)} free",
        )
        InfoRow(
            "Storage",
            "${formatBytes(onDevice.availStorageBytes)} free of " +
                formatBytes(onDevice.totalStorageBytes),
        )
        InfoRow(
            "Models",
            if (onDevice.downloadedModelIds.isEmpty()) {
                "None downloaded"
            } else {
                "${formatBytes(onDevice.modelStorageBytes)} · " +
                    "${onDevice.downloadedModelIds.size} downloaded"
            },
        )
        InfoRow(
            "CPU",
            buildString {
                append("${onDevice.cpuCores} cores")
                if (onDevice.abi.isNotEmpty()) append(" · ${onDevice.abi}")
                if (onDevice.soc.isNotEmpty()) append(" · ${onDevice.soc}")
            },
        )
        InfoRow(
            "Setup",
            if (setup.isReadyToDictate) {
                "complete"
            } else {
                "${setup.completedStepCount} of ${setup.stepCount} steps"
            },
        )
        Text(
            ABOUT_DIAGNOSTICS_NOTE,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            SecondaryButton(
                text = ABOUT_COPY_DIAGNOSTICS,
                onClick = {
                    context.copyDiagnostics(
                        diagnosticsReport(
                            appInfo,
                            settings,
                            setup,
                            diagnosticEvents(),
                            onDevice,
                        ),
                    )
                },
                modifier = Modifier.weight(1f),
            )
            SecondaryButton(
                text = ABOUT_CLEAR_EVENT_LOG,
                onClick = onClearDiagnosticEvents,
                modifier = Modifier.weight(1f),
            )
        }
    }
}

/** Official VocaDesign marks at 16 dp. Family links are text only. */
@Composable
private fun AboutLinkButton(link: AboutLink, context: Context) {
    TextButton(
        onClick = { context.openHttpUrl(link.url) },
        colors = ButtonDefaults.textButtonColors(contentColor = AboutTeal),
    ) {
        val icon = link.icon
        if (icon != null) {
            Icon(
                painter = painterResource(icon),
                contentDescription = null,
                modifier = Modifier.size(16.dp),
                tint = AboutTeal,
            )
            Spacer(Modifier.width(8.dp))
        }
        Text(link.label)
    }
}

@Composable
private fun ReportBugButton(
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Button(
        onClick = onClick,
        modifier = modifier.height(48.dp),
        colors = ButtonDefaults.buttonColors(
            containerColor = AboutTeal,
            contentColor = AboutCream,
        ),
    ) {
        Icon(
            painter = painterResource(R.drawable.ic_social_github),
            contentDescription = null,
            modifier = Modifier.size(16.dp),
            tint = AboutCream,
        )
        Spacer(Modifier.width(8.dp))
        Text(label)
    }
}

private fun Context.copyDiagnostics(text: String) {
    val clipboard = getSystemService(ClipboardManager::class.java) ?: return
    clipboard.setPrimaryClip(ClipData.newPlainText("VocaPhone diagnostics", text))
}
