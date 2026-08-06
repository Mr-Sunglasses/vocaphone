package io.github.mrsunglasses.localflow.ui

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Checkbox
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import io.github.mrsunglasses.localflow.core.MicrophonePreference
import io.github.mrsunglasses.localflow.core.ModelLanguageSupport
import io.github.mrsunglasses.localflow.core.TranscriptionLanguage
import io.github.mrsunglasses.localflow.core.WritingStyle
import io.github.mrsunglasses.localflow.settings.AudioRetention
import io.github.mrsunglasses.localflow.settings.BubbleBehavior
import io.github.mrsunglasses.localflow.settings.LocalFlowSettings

@Composable
fun SettingsScreen(
    settings: LocalFlowSettings,
    setup: SetupStatus,
    installedApps: List<InstalledApp>,
    microphone: MicrophoneStatus,
    onLoadApps: () -> Unit,
    onLanguage: (TranscriptionLanguage) -> Unit,
    onStyle: (WritingStyle) -> Unit,
    onMicrophone: (MicrophonePreference) -> Unit,
    onAutomaticInsertion: (Boolean) -> Unit,
    onBubbleBehavior: (BubbleBehavior) -> Unit,
    onAudioRetention: (AudioRetention) -> Unit,
    onToggleExcludedApp: (String) -> Unit,
    onOpenGateway: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val appInfo = remember { context.readAppInfo() }
    LaunchedEffect(Unit) { onLoadApps() }

    Column(
        modifier = modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        SectionCard(
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
        }

        // One row rather than 27 wrapping chips, which pushed every setting below
        // this one off the screen. The full list, with search, lives in a sheet.
        var pickingLanguage by remember { mutableStateOf(false) }
        val languageRestriction = ModelLanguageSupport.restriction(
            settings.modelLanguages,
            settings.modelDetectsLanguage,
        )
        SectionCard(
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

        SectionCard(
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

        MicrophoneCard(
            selected = settings.microphone,
            status = microphone,
            onSelect = onMicrophone,
        )

        SectionCard("Insertion") {
            ToggleRow(
                title = "Insert automatically",
                detail = "Write the transcript straight into the focused field. " +
                    "When off, it waits in History for you.",
                checked = settings.automaticInsertion,
                onCheckedChange = onAutomaticInsertion,
            )
        }

        SectionCard("Floating bubble") {
            ChipChoiceRow(
                options = BubbleBehavior.entries,
                selected = settings.bubbleBehavior,
                label = { it.displayName },
                onSelect = onBubbleBehavior,
            )
            Text(
                "The bubble never appears in password or payment fields, on system " +
                    "permission screens, or in the apps you exclude below.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            if (!setup.accessibility || !setup.overlay) {
                Text(
                    "The bubble needs the accessibility service and display-over-other-apps.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.error,
                )
                SecondaryButton(
                    text = "Repair",
                    onClick = {
                        if (!setup.overlay) {
                            context.openOverlaySettings()
                        } else {
                            context.openAccessibilitySettings()
                        }
                    },
                )
            }
        }

        SectionCard(
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

        SectionCard(
            title = "Excluded apps",
            supporting = "${settings.excludedPackages.size} excluded. The bubble stays " +
                "hidden and reads nothing in these apps.",
        ) {
            LazyColumn(
                modifier = Modifier.fillMaxWidth().heightIn(max = 320.dp),
            ) {
                items(installedApps, key = { it.packageName }) { app ->
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable { onToggleExcludedApp(app.packageName) }
                            .padding(vertical = 4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Checkbox(
                            checked = app.packageName in settings.excludedPackages,
                            onCheckedChange = { onToggleExcludedApp(app.packageName) },
                        )
                        Text(app.label, style = MaterialTheme.typography.bodyMedium)
                    }
                }
            }
        }

        SectionCard("Privacy") {
            Text(
                "Audio and transcripts go only to the gateway you configured. There " +
                    "is no cloud transcription, no analytics, and nothing is written " +
                    "to the clipboard unless you tap Copy.",
                style = MaterialTheme.typography.bodyMedium,
            )
        }

        SectionCard(
            title = "About",
            supporting = "Local Flow ${appInfo.versionName} (${appInfo.versionCode})",
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
private fun MicrophoneCard(
    selected: MicrophonePreference,
    status: MicrophoneStatus,
    onSelect: (MicrophonePreference) -> Unit,
) {
    val attached = selected in status.available
    SectionCard(
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
    clipboard.setPrimaryClip(ClipData.newPlainText("Local Flow diagnostics", text))
}

/** No browser is a plausible state on a stripped-down ROM, so failure is silent. */
private fun Context.openUrl(url: String) {
    runCatching { startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url))) }
}

@Composable
private fun ToggleRow(
    title: String,
    detail: String,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.bodyLarge)
            Text(
                detail,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Switch(checked = checked, onCheckedChange = onCheckedChange)
    }
}
