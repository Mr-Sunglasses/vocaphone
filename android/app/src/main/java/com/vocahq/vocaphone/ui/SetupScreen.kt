package com.vocahq.vocaphone.ui

import android.Manifest
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.currentStateAsState
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
    // Resume from the first real read, not the ViewModel's startup placeholder.
    // Keep saved page state outside this branch until the read has completed.
    if (!status.isLoaded) {
        Column(
            modifier = modifier.fillMaxSize().padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
        ) {
            CircularProgressIndicator()
            Text("Checking your setup…", modifier = Modifier.padding(top = 16.dp))
        }
        return
    }
    val context = LocalContext.current
    val activity = context.findActivity()
    val requestPermission = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { onRefreshSetup() }
    val askUsageReporting = BuildConfig.TELEMETRY && !settings.telemetryAsked
    var askingUsageReporting by remember { mutableStateOf(false) }
    val recentlyReady = rememberRecentlyReadySteps(status)

    var stage by rememberSaveable { mutableStateOf(SetupPage.resume(status)) }
    val scrollState = rememberScrollState()
    LaunchedEffect(stage) { scrollState.scrollTo(0) }
    BackHandler(enabled = stage != SetupPage.KEYBOARD) { stage = stage.previous() }

    Column(
        modifier = modifier.fillMaxSize(),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Column(
            modifier = Modifier
                .weight(1f)
                .widthIn(max = AppContentMaxWidth)
                .fillMaxWidth()
                .verticalScroll(scrollState)
                .padding(horizontal = 24.dp)
                .padding(top = 24.dp, bottom = 32.dp),
            verticalArrangement = Arrangement.spacedBy(24.dp),
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        if (stage == SetupPage.READY) {
                            if (status.isReadyToDictate) "Setup complete" else "Setup needs attention"
                        } else "Step ${stage.ordinal + 1} of 4",
                        style = MaterialTheme.typography.labelLarge,
                        color = MaterialTheme.colorScheme.primary,
                    )
                    if (stage != SetupPage.KEYBOARD) {
                        TextButton(onClick = { stage = stage.previous() }) { Text("Back") }
                    }
                }
                LinearProgressIndicator(
                    progress = { status.completedStepCount.toFloat() / status.stepCount },
                    modifier = Modifier.fillMaxWidth(),
                )
                Text(
                    if (stage == SetupPage.READY && !status.isReadyToDictate) "Let’s get you ready" else stage.title,
                    style = MaterialTheme.typography.headlineLarge,
                    modifier = Modifier.semantics { heading() },
                )
                Text(
                    if (stage == SetupPage.READY && !status.isReadyToDictate)
                        "A permission, keyboard, or speech source needs attention." else stage.detail,
                    style = MaterialTheme.typography.bodyLarge,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }

            when (stage) {
                SetupPage.KEYBOARD -> {
                    Notice {
                        Text("Your voice, wherever you type", style = MaterialTheme.typography.titleMedium)
                        Text("Open a text field, tap the microphone on VocaPhone, then speak. Your words become text at the cursor.")
                    }
                    ImeSetupCard(status.ime, prominentAction = true)
                    SetupCopy.keyboardTapHint(status.ime)?.let { hint ->
                        Text(hint, style = MaterialTheme.typography.bodyMedium)
                    }
                    Text(
                        "Android shows a standard warning when you enable a keyboard. VocaPhone does not send your everyday typing to a server. You can switch keyboards at any time.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                SetupPage.MICROPHONE, SetupPage.NOTIFICATIONS -> {
                    val step = if (stage == SetupPage.MICROPHONE) SetupStep.MICROPHONE else SetupStep.NOTIFICATIONS
                    SetupPermissionRow(
                        step = step,
                        permission = if (stage == SetupPage.MICROPHONE) Manifest.permission.RECORD_AUDIO
                            else Manifest.permission.POST_NOTIFICATIONS,
                        satisfied = status.isSatisfied(step),
                        nextStep = step,
                        recentlyReady = recentlyReady,
                        activity = activity,
                        requestPermission = requestPermission::launch,
                        prominentAction = true,
                    )
                    Notice {
                        Text(
                            if (stage == SetupPage.MICROPHONE) "You choose when to record" else "Stay in control",
                            style = MaterialTheme.typography.titleMedium,
                        )
                        Text(
                            if (stage == SetupPage.MICROPHONE)
                                "Recording starts when you tap the microphone. You can finish or cancel from the keyboard."
                            else "The recording notification lets you see when the microphone is active and cancel recording outside the keyboard.",
                        )
                    }
                }
                SetupPage.SOURCE -> {
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
                SetupPage.READY -> {
                    if (status.isReadyToDictate) {
                        Notice {
                            Text("Try your keyboard", style = MaterialTheme.typography.titleMedium)
                            Text("Tap the field below to bring up VocaPhone, then tap the microphone and speak. Finish recording and your words appear in the field.")
                            // A sentence to read out, because "say a short
                            // sentence" leaves the user composing one on the
                            // spot at the first moment they use the product,
                            // and this step is already labelled optional twice.
                            // It is a suggestion, not a target: nothing here
                            // compares what came back against it, so an engine
                            // that writes "2 p.m." has not failed anything.
                            Text(
                                "Not sure what to say? Try \u201CLet\u2019s meet tomorrow at 2PM\u201D.",
                                style = MaterialTheme.typography.bodyMedium,
                            )
                        }
                        // Deliberately not saved: this field may contain a private transcript.
                        var practiceText by remember { mutableStateOf("") }
                        OutlinedTextField(
                            value = practiceText,
                            onValueChange = { practiceText = it },
                            label = { Text("Try voice typing") },
                            placeholder = { Text("Your words appear here") },
                            modifier = Modifier.fillMaxWidth(),
                            minLines = 3,
                        )
                        Text("Practice is optional. You can also start with the dictation screen.",
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                    } else {
                        Notice { Text("A setup requirement changed. Review it before you start dictating.") }
                    }
                }
            }
        }

        // A bar, not a continuation of the page. Without the divider and its own
        // surface, the scroll view's clipped last line sat flush against this
        // caption: on a short viewport the privacy paragraph was cut mid-word
        // and the "0 of 4 requirements ready" line read as its final sentence.
        Surface(
            modifier = Modifier.fillMaxWidth(),
            color = MaterialTheme.colorScheme.surface,
        ) {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
                Column(
                    modifier = Modifier
                        .widthIn(max = AppContentMaxWidth)
                        .fillMaxWidth()
                        .padding(horizontal = 24.dp)
                        .padding(top = 16.dp, bottom = 16.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
            if (stage.isSatisfied(status) || stage == SetupPage.READY) {
                PrimaryButton(
                    text = when {
                        stage == SetupPage.READY && !status.isReadyToDictate -> "Review remaining setup"
                        stage == SetupPage.READY -> SetupCopy.START
                        else -> "Continue"
                    },
                    onClick = {
                        if (stage != SetupPage.READY) stage = stage.next()
                        else if (!status.isReadyToDictate) stage = SetupPage.resume(status)
                        else if (askUsageReporting) askingUsageReporting = true
                        else onFinish()
                    },
                    modifier = Modifier.fillMaxWidth(),
                )
            }
            Text(
                if (stage == SetupPage.READY) "You can change your setup in Settings."
                else "${status.completedStepCount} of ${status.stepCount} requirements ready. Your progress is kept when you leave.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
                }
            }
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
                if (status.isReadyToDictate) onFinish() else stage = SetupPage.resume(status)
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
    prominentAction: Boolean = false,
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
    val onAction = {
        if (activity != null) {
            SetupPermissions.requestOrOpenSettings(activity, permission, requestPermission)
        } else {
            requestPermission(permission)
        }
    }
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        ChecklistRow(
            title = step.label,
            detail = detail,
            satisfied = satisfied,
            actionLabel = label,
            onAction = onAction,
            actionColor = actionColor,
            compact = if (prominentAction) !satisfied else compact,
        )
        if (prominentAction && !satisfied) {
            PrimaryButton(
                text = if (label == "Grant") "Allow ${step.label.lowercase()}" else "Open app settings",
                onClick = onAction,
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
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
internal fun ImeSetupCard(
    status: ImeSetupStatus,
    modifier: Modifier = Modifier,
    prominentAction: Boolean = false,
) {
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
        val onAction = {
            if (status.enabled) ImeSetup.showPicker(context) else ImeSetup.openSettings(context)
        }
        if (prominentAction) {
            PrimaryButton(text = action, onClick = onAction, modifier = Modifier.fillMaxWidth())
        } else {
            SecondaryButton(text = action, onClick = onAction, modifier = Modifier.fillMaxWidth())
        }
    }
}
