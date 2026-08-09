package com.vocahq.vocaphone.ui

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.vocahq.vocaphone.core.MicrophonePreference
import com.vocahq.vocaphone.core.ModelLanguageSupport
import com.vocahq.vocaphone.core.TranscriptionLanguage
import com.vocahq.vocaphone.core.WritingStyle
import com.vocahq.vocaphone.settings.AudioRetention
import com.vocahq.vocaphone.settings.VocaPhoneSettings

@Composable
fun SettingsScreen(
    settings: VocaPhoneSettings,
    setup: SetupStatus,
    microphone: MicrophoneStatus,
    onLanguage: (TranscriptionLanguage) -> Unit,
    onStyle: (WritingStyle) -> Unit,
    onMicrophone: (MicrophonePreference) -> Unit,
    onAudioRetention: (AudioRetention) -> Unit,
    onOpenGateway: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val appInfo = remember { context.readAppInfo() }

    Column(
        modifier = modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(SectionSpacing),
    ) {
        Section(
            title = "Gateway",
            supporting = settings.gatewayUrl.ifEmpty { "Not configured" },
        ) {
            Text(
                buildString {
                    append("Engine: ")
                    append(settings.lastEngine.ifEmpty { "unknown" })
                    append(if (settings.lastEngineReady) " (ready)" else " (not ready)")
                    append("\nStreaming: ")
                    append(if (settings.lastStreamingSupported) "supported" else "batch upload")
                },
                style = MaterialTheme.typography.bodyMedium,
            )
            SecondaryButton("Gateway settings", onClick = onOpenGateway)
            SecondaryButton(
                text = "Open web dashboard",
                onClick = { context.openUrl(settings.gatewayUrl) },
                enabled = settings.gatewayUrl.isNotEmpty(),
            )
            Text(
                "For more customization, including choosing the speech-to-text model, " +
                    "open your gateway's web dashboard.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }

        ImeSetupCard(setup.ime)

        // One row rather than 27 wrapping chips, which pushed every setting below
        // this one off the screen. The full list, with search, lives in a sheet.
        var pickingLanguage by remember { mutableStateOf(false) }
        val languageRestriction = ModelLanguageSupport.restriction(
            settings.modelLanguages,
            settings.modelDetectsLanguage,
        )
        Section(
            "Transcription language",
            supporting = listOfNotNull(settings.effectiveLanguage.detail, languageRestriction)
                .joinToString("\n"),
        ) {
            InfoRow(label = "Language", value = settings.effectiveLanguage.displayName)
            SecondaryButton("Change language", onClick = { pickingLanguage = true })
        }
        if (pickingLanguage) {
            LanguagePickerSheet(
                selected = settings.effectiveLanguage,
                modelLanguages = settings.modelLanguages,
                detectsLanguageAutomatically = settings.modelDetectsLanguage,
                onSelect = onLanguage,
                onDismiss = { pickingLanguage = false },
            )
        }

        Section(
            title = "Writing style",
            supporting = "${settings.style.detail}\n${settings.style.example}",
        ) {
            ChipChoiceRow(
                options = WritingStyle.entries,
                selected = settings.style,
                label = { it.displayName },
                onSelect = onStyle,
            )
        }

        MicrophoneSection(
            selected = settings.microphone,
            status = microphone,
            onSelect = onMicrophone,
        )

        Section(
            title = "Audio retention",
            supporting = "Successful dictations delete their audio immediately. A " +
                "failed one keeps it only this long, so Retry still works.",
        ) {
            ChipChoiceRow(
                options = AudioRetention.entries,
                selected = settings.audioRetention,
                label = { it.displayName },
                onSelect = onAudioRetention,
            )
        }

        Section("Privacy") {
            Text(
                "VocaPhone's keyboard inserts through Android's text connection and " +
                    "does not read the field. Audio and transcripts go only to the " +
                    "gateway you configured. There is no cloud transcription, no " +
                    "analytics, and nothing is written to the clipboard unless you " +
                    "tap Copy.",
                style = MaterialTheme.typography.bodyMedium,
            )
        }

        Section(
            title = "About",
            supporting = "VocaPhone ${appInfo.versionName} (${appInfo.versionCode})",
        ) {
            InfoRow("Android", "${appInfo.androidRelease} (SDK ${appInfo.sdkInt})")
            InfoRow("Device", appInfo.device)
            InfoRow("Installed from", appInfo.installedFrom)
            InfoRow("Package", appInfo.packageName)
            InfoRow(
                "Engine",
                settings.lastEngine.ifEmpty { "unknown" } +
                    if (settings.lastEngineReady) " (ready)" else " (not ready)",
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
                "Diagnostics leave out your gateway's host name and never include " +
                    "the token, so they are safe to paste into a public issue.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                SecondaryButton(
                    text = "Copy diagnostics",
                    onClick = {
                        context.copyDiagnostics(
                            diagnosticsReport(appInfo, settings, setup)
                        )
                    },
                    modifier = Modifier.weight(1f),
                )
                SecondaryButton(
                    text = "Project page",
                    onClick = { context.openUrl(PROJECT_URL) },
                    modifier = Modifier.weight(1f),
                )
            }
        }
    }
}

/**
 * Which microphone dictation asks for. Options the hardware cannot satisfy stay
 * visible but greyed, and the whole row locks while a dictation is running: the
 * input is chosen when the recorder is built, so a mid-recording change would be
 * a promise the current dictation cannot keep.
 */
@Composable
private fun MicrophoneSection(
    selected: MicrophonePreference,
    status: MicrophoneStatus,
    onSelect: (MicrophonePreference) -> Unit,
) {
    val attached = selected in status.available
    Section(
        title = "Microphone",
        supporting = if (attached) selected.detail else selected.unavailableDetail,
    ) {
        ChipChoiceRow(
            options = MicrophonePreference.entries,
            selected = selected,
            label = { it.displayName },
            onSelect = onSelect,
            enabled = { status.changeable && (it in status.available || it == selected) },
        )

        InfoRow("Input in use", status.inUseLabel(selected))

        Text(
            if (!status.changeable) {
                "Finish the current dictation before changing microphones."
            } else {
                "Greyed-out options have no matching microphone connected. " +
                    "Android has the final say on routing, so the input above " +
                    "is what capture actually used."
            },
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

private fun Context.copyDiagnostics(text: String) {
    val clipboard = getSystemService(ClipboardManager::class.java) ?: return
    clipboard.setPrimaryClip(ClipData.newPlainText("VocaPhone diagnostics", text))
}

/** No browser is a plausible state on a stripped-down ROM, so failure is silent. */
private fun Context.openUrl(url: String) {
    runCatching { startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url))) }
}
