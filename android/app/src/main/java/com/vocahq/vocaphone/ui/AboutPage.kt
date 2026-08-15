package com.vocahq.vocaphone.ui

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import androidx.compose.foundation.Image
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.vocahq.vocaphone.R
import com.vocahq.vocaphone.local.LocalModelDescriptor
import com.vocahq.vocaphone.settings.VocaPhoneSettings

/**
 * Settings → About. Hero, family, source links, then the privacy and
 * diagnostics blocks that were already here.
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

    FeaturedCard {
        Column(
            modifier = Modifier.fillMaxWidth(),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Image(
                painter = painterResource(R.drawable.ic_vocaphone_logo),
                contentDescription = null,
                modifier = Modifier.size(88.dp),
            )
            Text("VocaPhone", style = MaterialTheme.typography.headlineSmall)
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
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
            )
            TextButton(onClick = { context.openHttpUrl(WEBSITE_URL) }) {
                Text("vocaphone.vocahq.com")
            }
        }
    }

    Section(
        title = "Part of VocaHQ",
        supporting = ABOUT_FAMILY_NOTE,
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            GitHubButton(
                label = "VocaHQ",
                onClick = { context.openHttpUrl(ORG_URL) },
                modifier = Modifier.weight(1f),
            )
            GitHubButton(
                label = "vocaphone",
                onClick = { context.openHttpUrl(PROJECT_URL) },
                modifier = Modifier.weight(1f),
            )
        }
    }

    Section(
        title = "Feedback",
        supporting = ABOUT_FEEDBACK_NOTE,
    ) {
        PrimaryButton(
            text = "Report a bug or idea",
            onClick = { context.openHttpUrl(NEW_ISSUE_URL) },
            modifier = Modifier.fillMaxWidth(),
        )
    }

    Section("Privacy") {
        Text(
            ABOUT_PRIVACY_NOTE,
            style = MaterialTheme.typography.bodyMedium,
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
        SecondaryButton(
            text = "Copy diagnostics",
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
            modifier = Modifier.fillMaxWidth(),
        )
        TextButton(onClick = onClearDiagnosticEvents) { Text("Clear event log") }
    }
}

/**
 * Primer's default GitHub button: dark on light, light on dark, 6 dp corners,
 * mark plus label.
 */
@Composable
private fun GitHubButton(
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val dark = isSystemInDarkTheme()
    val container = if (dark) Color(0xFFF6F8FA) else Color(0xFF24292F)
    val content = if (dark) Color(0xFF24292F) else Color(0xFFFFFFFF)
    Button(
        onClick = onClick,
        modifier = modifier.height(48.dp),
        shape = RoundedCornerShape(6.dp),
        colors = ButtonDefaults.buttonColors(
            containerColor = container,
            contentColor = content,
        ),
    ) {
        Icon(
            painter = painterResource(R.drawable.ic_github),
            contentDescription = null,
            modifier = Modifier.size(18.dp),
            tint = content,
        )
        Spacer(Modifier.width(8.dp))
        Text(label, fontWeight = FontWeight.SemiBold)
    }
}

private fun Context.copyDiagnostics(text: String) {
    val clipboard = getSystemService(ClipboardManager::class.java) ?: return
    clipboard.setPrimaryClip(ClipData.newPlainText("VocaPhone diagnostics", text))
}
