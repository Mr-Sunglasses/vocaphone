package com.vocahq.vocaphone.ui

import android.Manifest
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.currentStateAsState
import androidx.compose.ui.unit.dp
import com.vocahq.vocaphone.BuildConfig
import com.vocahq.vocaphone.R
import com.vocahq.vocaphone.core.TranscriptionLanguage
import com.vocahq.vocaphone.local.LocalModelDescriptor
import com.vocahq.vocaphone.local.LocalModelState
import com.vocahq.vocaphone.settings.VocaPhoneSettings
import com.vocahq.vocaphone.telemetry.TelemetryInspectPayload
import kotlinx.coroutines.delay

/** Satisfied or non-spotlight rows collapse to title + check. Ready notice expands briefly. */
internal fun collapseChecklistRow(
    satisfied: Boolean,
    isNextUnfinished: Boolean,
    showingReady: Boolean = false,
): Boolean = !showingReady && (satisfied || !isNextUnfinished)

internal object SetupCopy {
    /** Vector mark. Adaptive mipmaps crash painterResource. */
    val LOGO = R.drawable.ic_vocaphone_logo
    const val TITLE = "Set up VocaPhone"
    const val INTRO = "Turn on the keyboard, allow the microphone, then download a model."
    const val START = "Start dictating"
    const val DOWNLOAD = "Download"
    const val DOWNLOAD_AND_CONTINUE = "Download and continue"
    const val HELP_ME_CHOOSE = "Help me choose"
    const val BROWSE_MODELS = "Browse"
    const val BROWSE_SHEET_TITLE = "Other models"
    const val BROWSE_SHEET_SUPPORTING =
        "These also run on this phone. The recommendation is still the default."
    const val SLOW_ON_PHONES = "Slow on phones"
    const val SLOW_ON_PHONES_DETAIL =
        "This may not perform well on a phone."

    fun keyboardStatus(status: ImeSetupStatus): String = when {
        status.selected -> "VocaPhone is the selected keyboard."
        status.enabled -> "Choose VocaPhone from the keyboard list."
        else -> "Turn on the VocaPhone keyboard."
    }

    fun keyboardAction(status: ImeSetupStatus): String? = when {
        status.selected -> null
        status.enabled -> "Choose VocaPhone keyboard"
        else -> "Enable keyboard"
    }

    /** One wrap-friendly line under the IME card about what to tap next. */
    fun keyboardTapHint(status: ImeSetupStatus): String? = when {
        status.selected -> null
        status.enabled -> "Pick VocaPhone from the list that appears."
        else -> "In keyboard settings, turn on VocaPhone."
    }

    fun stepReady(step: SetupStep): String = when (step) {
        SetupStep.MICROPHONE -> "Microphone ready"
        SetupStep.NOTIFICATIONS -> "Notifications ready"
        SetupStep.KEYBOARD -> "Keyboard ready"
        SetupStep.GATEWAY -> "Speech source ready"
    }

    fun permissionDetail(step: SetupStep): String = when (step) {
        SetupStep.MICROPHONE -> "Only while you dictate."
        SetupStep.NOTIFICATIONS -> "Shown while you record."
        SetupStep.KEYBOARD -> keyboardStatus(ImeSetupStatus())
        SetupStep.GATEWAY -> "The speech source that transcribes your speech."
    }
}

/**
 * Guided setup for the IME path. Short enough to finish without scrolling
 * past a catalog.
 */
@Composable
fun SetupScreen(
    status: SetupStatus,
    settings: VocaPhoneSettings,
    localModels: LocalModelState,
    onOpenGateway: () -> Unit,
    onLanguage: (TranscriptionLanguage) -> Unit,
    onLocalTranscriptionEnabled: (Boolean) -> Unit,
    onLocalModel: (LocalModelDescriptor) -> Unit,
    onDownloadLocalModel: (LocalModelDescriptor) -> Unit,
    onDownloadAndUseLocalModel: (LocalModelDescriptor) -> Unit,
    onCancelLocalModelDownload: () -> Unit,
    onTelemetryDecision: (Boolean) -> Unit,
    telemetryInspect: () -> TelemetryInspectPayload,
    telemetryPendingCount: () -> Int,
    telemetryDeliveryStatus: () -> String,
    onFinish: () -> Unit,
    onRefreshSetup: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val activity = context.findActivity()
    val requestPermission = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { onRefreshSetup() }
    val askUsageReporting = BuildConfig.TELEMETRY && !settings.telemetryAsked
    var askingUsageReporting by remember { mutableStateOf(false) }
    val recentlyReady = rememberRecentlyReadySteps(status)

    Column(
        modifier = modifier.fillMaxSize(),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Column(
            modifier = Modifier
                .weight(1f)
                .widthIn(max = AppContentMaxWidth)
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(SectionSpacing),
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(
                    SetupCopy.INTRO,
                    style = MaterialTheme.typography.bodyLarge,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                SetupProgress(status)
            }

            ImeSetupCard(status.ime)
            SetupCopy.keyboardTapHint(status.ime)?.let { hint ->
                Text(
                    hint,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }

            Section("Permissions") {
                SetupPermissionRow(
                    step = SetupStep.MICROPHONE,
                    permission = Manifest.permission.RECORD_AUDIO,
                    satisfied = status.microphone,
                    nextStep = status.remainingSteps.firstOrNull(),
                    recentlyReady = recentlyReady,
                    activity = activity,
                    requestPermission = requestPermission::launch,
                )
                SetupPermissionRow(
                    step = SetupStep.NOTIFICATIONS,
                    permission = Manifest.permission.POST_NOTIFICATIONS,
                    satisfied = status.notifications,
                    nextStep = status.remainingSteps.firstOrNull(),
                    recentlyReady = recentlyReady,
                    activity = activity,
                    requestPermission = requestPermission::launch,
                )
            }

            Section("Speech") {
                SpeechSourceCard(
                    settings = settings,
                    compact = true,
                    onOpenGateway = onOpenGateway,
                    onLocalTranscriptionEnabled = onLocalTranscriptionEnabled,
                )
                if (settings.localTranscriptionEnabled) {
                    LocalModelPicker(
                        state = localModels,
                        selectedModelId = settings.localModelId,
                        compact = true,
                        onSelect = onLocalModel,
                        onDownload = onDownloadLocalModel,
                        onDownloadAndUse = onDownloadAndUseLocalModel,
                        onCancelDownload = onCancelLocalModelDownload,
                        guidanceLanguage = settings.language.wireValue,
                        onGuidanceLanguage = { onLanguage(TranscriptionLanguage.fromWire(it)) },
                    )
                }
            }
        }

        Column(
            modifier = Modifier
                .widthIn(max = AppContentMaxWidth)
                .fillMaxWidth()
                .padding(horizontal = 16.dp)
                .padding(bottom = 16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            PrimaryButton(
                text = SetupCopy.START,
                onClick = {
                    if (askUsageReporting) askingUsageReporting = true else onFinish()
                },
                enabled = status.isReadyToDictate,
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }

    // The last step of setup rather than a card halfway down it: asking before
    // the user has a working transcript is asking a favour of someone still
    // deciding whether the app is worth their time, and a card in the scroll
    // could be walked past without either answer ever being seen.
    //
    // The BuildConfig check is repeated here even though the dialog checks it
    // too, because the payload view inside it is a separate call. Without it R8
    // keeps that composable — and the ingest path string inside it — in the
    // F-Droid APK, where nothing can ever reach it.
    if (BuildConfig.TELEMETRY && askingUsageReporting) {
        UsageReportingDialog(
            onDecision = { enabled ->
                askingUsageReporting = false
                onTelemetryDecision(enabled)
                onFinish()
            },
            inspect = telemetryInspect,
            pendingCount = telemetryPendingCount,
            deliveryStatus = telemetryDeliveryStatus,
        )
    }
}

@Composable
internal fun SetupPermissionRow(
    step: SetupStep,
    permission: String,
    satisfied: Boolean,
    nextStep: SetupStep?,
    recentlyReady: Set<SetupStep>,
    activity: android.app.Activity?,
    requestPermission: (String) -> Unit,
    actionColor: androidx.compose.ui.graphics.Color = MaterialTheme.colorScheme.primary,
) {
    val showingReady = satisfied && step in recentlyReady
    val compact = collapseChecklistRow(
        satisfied = satisfied,
        isNextUnfinished = nextStep == step,
        showingReady = showingReady,
    )
    val detail = when {
        satisfied -> SetupCopy.stepReady(step)
        else -> SetupCopy.permissionDetail(step)
    }
    // Permission dialogs and Settings pause the activity. Equal SetupStatus
    // after a denial does not recompose on its own, so watch lifecycle and
    // re-read Grant vs Open when we resume.
    val lifecycleState by LocalLifecycleOwner.current.lifecycle.currentStateAsState()
    val label = when {
        activity == null -> "Grant"
        else -> when (lifecycleState) {
            else -> SetupPermissions.grantOrOpenLabel(activity, permission)
        }
    }
    ChecklistRow(
        title = step.label,
        detail = detail,
        satisfied = satisfied,
        actionLabel = label,
        onAction = {
            if (activity != null) {
                SetupPermissions.requestOrOpenSettings(activity, permission, requestPermission)
            } else {
                requestPermission(permission)
            }
        },
        actionColor = actionColor,
        compact = compact,
    )
}

/**
 * Tracks steps that just flipped to satisfied so the row can show a brief
 * ready line and TalkBack can announce it, then collapses again.
 */
@Composable
internal fun rememberRecentlyReadySteps(status: SetupStatus): Set<SetupStep> {
    var recentlyReady by remember { mutableStateOf(emptySet<SetupStep>()) }
    var previous by remember { mutableStateOf(status) }
    LaunchedEffect(status) {
        val newly = SetupStep.entries.filter { status.isSatisfied(it) && !previous.isSatisfied(it) }
        previous = status
        if (newly.isEmpty()) return@LaunchedEffect
        recentlyReady = recentlyReady + newly
        try {
            delay(2_000)
        } finally {
            // Cancellation (another step flipping mid-delay) must still clear,
            // or the ready line and live region stick forever.
            recentlyReady = recentlyReady - newly.toSet()
        }
    }
    return recentlyReady
}

/** Setup handoff for enabling and selecting the system keyboard. */
@Composable
internal fun ImeSetupCard(status: ImeSetupStatus, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val action = SetupCopy.keyboardAction(status)
    if (action == null) {
        Text(
            SetupCopy.keyboardStatus(status),
            modifier = modifier,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        return
    }
    Notice(modifier = modifier) {
        Text("VocaPhone keyboard", style = MaterialTheme.typography.titleSmall)
        Text(
            SetupCopy.keyboardStatus(status),
            style = MaterialTheme.typography.labelLarge,
            color = MaterialTheme.colorScheme.primary,
        )
        SecondaryButton(
            text = action,
            onClick = {
                if (status.enabled) {
                    ImeSetup.showPicker(context)
                } else {
                    ImeSetup.openSettings(context)
                }
            },
            modifier = Modifier.fillMaxWidth(),
        )
    }
}

/** How far through setup the user is, so the list has a visible end. */
@Composable
private fun SetupProgress(status: SetupStatus, modifier: Modifier = Modifier) {
    Column(
        modifier = modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(
            "${status.completedStepCount} of ${status.stepCount} steps done",
            style = MaterialTheme.typography.labelLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        LinearProgressIndicator(
            progress = { status.completedStepCount.toFloat() / status.stepCount },
            modifier = Modifier.fillMaxWidth(),
        )
        // Remaining work is the checklist below. Chips here only repeated it.
    }
}
