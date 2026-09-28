package com.vocahq.vocaphone.ui

import android.Manifest
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
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
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.currentStateAsState
import com.vocahq.vocaphone.BuildConfig
import com.vocahq.vocaphone.R
import com.vocahq.vocaphone.core.TranscriptionLanguage
import com.vocahq.vocaphone.local.LocalModelDescriptor
import com.vocahq.vocaphone.local.LocalModelState
import com.vocahq.vocaphone.local.downloadProgressLine
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
    const val REVIEW = "Review remaining setup"
    // The last page while a download-and-use is still in flight. The button
    // carries the same progress line as the card above it, and the
    // "preparing" text matches the keyboard's hint for the same second.
    const val WAITING_TITLE = "Almost there"
    const val WAITING_DETAIL = "Your model is downloading. Dictation opens as soon as it lands."
    const val WAITING_DOWNLOADING = "Downloading"
    const val WAITING_PREPARING = "Preparing model\u2026"
    const val DOWNLOAD = "Download"
    const val DOWNLOAD_AND_CONTINUE = "Download and continue"
    // Named for what they do. "Browse" and "Help me choose" sat side by side
    // with nothing to say which one a person wanting another language should
    // press — the reported case was someone who pressed neither.
    const val HELP_ME_CHOOSE = "Choose language"
    const val BROWSE_MODELS = "All models"
    const val BROWSE_SHEET_TITLE = "All models"
    // Not "the recommendation is still the default": someone here came because
    // the recommendation was wrong for them, and that sentence talked them
    // back into it.
    const val BROWSE_SHEET_SUPPORTING = "Everything that runs on this phone."
    const val DOWNLOAD_CONFIRM_TITLE = "Download this model?"
    const val DOWNLOAD_CONFIRM = "Download"
    fun downloadConfirmBody(name: String, size: String, metered: Boolean): String =
        if (metered) "$name is $size. You are on mobile data — this may cost you."
        else "$name is $size. It downloads once and stays on this phone."
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

    fun preparingModel(name: String): String =
        "Loading $name. You can start speaking; your words appear once it's ready."

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
    deviceLanguages: List<String> = emptyList(),
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
    onStageChange: (String) -> Unit,
    onIntroSeen: () -> Unit,
    onRefreshSetup: () -> Unit,
    onWarmLocalModel: () -> Unit,
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
    if (!settings.onboardingIntroSeen) {
        OnboardingWordFlow(onContinue = onIntroSeen, modifier = modifier)
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
    val readyPresentation = readyPagePresentation(status, settings.localTranscriptionEnabled, localModels)
    val attention = attentionCopy(status.remainingSteps)

    // The saved page is read only once status has loaded (the guard above),
    // because settings arrive with it: reading the stage a frame early would
    // send every returning user back to the welcome.
    var stage by rememberSaveable {
        mutableStateOf(OnboardingStage.resume(OnboardingStage.persisted(settings.onboardingStage), status))
    }
    // rememberSaveable brings the page back verbatim after process death —
    // and granting a permission from Settings kills the process. Re-validate
    // once on first composition: a restored page whose requirement was met
    // while the app was away is walked past, exactly as a fresh launch would.
    // Idempotent on an ordinary first composition, since the initial value
    // already came through resume().
    LaunchedEffect(Unit) { stage = OnboardingStage.resume(stage, status) }
    val scrollState = rememberScrollState()
    LaunchedEffect(stage) {
        scrollState.scrollTo(0)
        // The confirmation is a moment, not a place: saving it would reopen
        // the app on a page that immediately leaves.
        if (stage != OnboardingStage.KEYBOARD_READY) onStageChange(stage.name)
    }
    // The keyboard landing gets its own moment. Detected from status, which
    // Android reads directly (DEFAULT_INPUT_METHOD) — no probe field needed.
    LaunchedEffect(status.keyboard) {
        if (status.keyboard && stage == OnboardingStage.KEYBOARD) stage = OnboardingStage.KEYBOARD_READY
    }
    LaunchedEffect(stage) {
        if (stage == OnboardingStage.KEYBOARD_READY) {
            kotlinx.coroutines.delay(KEYBOARD_READY_MILLIS)
            if (stage == OnboardingStage.KEYBOARD_READY) stage = OnboardingStage.READY
        }
    }
    fun advance() {
        stage = stage.advance(status, settings.localTranscriptionEnabled)
    }
    BackHandler(enabled = stage != OnboardingStage.WELCOME) { stage = stage.previous() }
    // Load the model while the user reads the Ready page, and again on every
    // return to it: leaving the app is when the system takes it back. Without
    // this the practice dictation carried the whole load. Only once the page
    // is truly ready: mid-download the stored id is still the old model (or
    // none), and warming that would compete with the adoption for memory.
    val resumed = LocalLifecycleOwner.current.lifecycle.currentStateAsState().value
        .isAtLeast(Lifecycle.State.RESUMED)
    val warmsModel = stage == OnboardingStage.READY &&
        readyPresentation == ReadyPagePresentation.READY &&
        settings.localTranscriptionEnabled && resumed
    LaunchedEffect(warmsModel, settings.localModelId) {
        if (warmsModel) onWarmLocalModel()
    }

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
                    if (stage != OnboardingStage.WELCOME) {
                        IconButton(onClick = { stage = stage.previous() }) {
                            Icon(
                                painter = painterResource(R.drawable.ic_arrow_back),
                                contentDescription = "Back",
                                tint = MaterialTheme.colorScheme.primary,
                            )
                        }
                    } else {
                        Spacer(Modifier)
                    }
                    if (stage == OnboardingStage.READY) {
                        Row(
                            horizontalArrangement = Arrangement.spacedBy(4.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            if (status.isReadyToDictate) {
                                Icon(
                                    painter = painterResource(R.drawable.ic_check),
                                    contentDescription = null,
                                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                                    modifier = Modifier.size(16.dp),
                                )
                            }
                            Text(
                                when {
                                    status.isReadyToDictate -> "Setup complete"
                                    status.remainingSteps.size == 1 -> "1 step left"
                                    else -> "${status.remainingSteps.size} steps left"
                                },
                                style = MaterialTheme.typography.bodyMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    } else {
                        Spacer(Modifier)
                    }
                    if (stage.allowsSkip) {
                        TextButton(onClick = { advance() }) {
                            Text("Skip")
                            Icon(
                                painter = painterResource(R.drawable.ic_chevron),
                                contentDescription = null,
                                modifier = Modifier.size(18.dp),
                            )
                        }
                    } else {
                        Spacer(Modifier)
                    }
                }
                // Page progress, not requirement progress: the bar answers "how
                // far through" and the footer below answers "what is still
                // needed", and they used to disagree.
                LinearProgressIndicator(
                    progress = { stage.progress },
                    modifier = Modifier.fillMaxWidth(),
                )
                if (stage != OnboardingStage.KEYBOARD_READY) {
                    Text(
                        when {
                            stage != OnboardingStage.READY -> stage.title
                            readyPresentation == ReadyPagePresentation.NEEDS_ATTENTION -> attention.title
                            readyPresentation == ReadyPagePresentation.WAITING_FOR_MODEL -> SetupCopy.WAITING_TITLE
                            else -> stage.title
                        },
                        style = MaterialTheme.typography.headlineLarge,
                        modifier = Modifier.semantics { heading() },
                    )
                    Text(
                        when {
                            stage != OnboardingStage.READY -> stage.detail
                            readyPresentation == ReadyPagePresentation.NEEDS_ATTENTION -> attention.detail
                            readyPresentation == ReadyPagePresentation.WAITING_FOR_MODEL -> SetupCopy.WAITING_DETAIL
                            else -> stage.detail
                        },
                        style = MaterialTheme.typography.bodyLarge,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }

            when (stage) {
                OnboardingStage.WELCOME -> {
                    WelcomeCard(
                        icon = R.drawable.ic_lock,
                        title = "Your voice stays on this phone",
                        body = "On-device by default. A gateway you run is a separate choice.",
                    )
                    WelcomeCard(
                        icon = R.drawable.ic_infinity,
                        title = "No subscriptions or limits",
                        body = "Dictate as much as you want, whenever you want.",
                    )
                    WelcomeCard(
                        icon = R.drawable.ic_keyboard,
                        title = "Works anywhere you can type",
                        body = "Use it in any app with a keyboard.",
                    )
                }
                OnboardingStage.SOURCE -> {
                    SpeechSourceCard(
                        settings = settings,
                        compact = true,
                        onOpenGateway = onOpenGateway,
                        onLocalTranscriptionEnabled = onLocalTranscriptionEnabled,
                    )
                }
                OnboardingStage.MODEL -> {
                    if (settings.localTranscriptionEnabled) {
                        LocalModelPicker(
                            state = localModels,
                            selectedModelId = settings.localModelId,
                            selectionFromRetiredModel = settings.selectionIsRetiredModelReplacement,
                            compact = true,
                            onSelect = onLocalModel,
                            onDownload = onDownloadLocalModel,
                            // "Download and continue" means both halves: the
                            // download runs in the background and the page moves
                            // on. The last page and the home screen carry its
                            // progress, and the keyboard says "downloading" until
                            // it lands — nobody waits here for 661 MB.
                            onDownloadAndUse = { model ->
                                onDownloadAndUseLocalModel(model)
                                advance()
                            },
                            onCancelDownload = onCancelLocalModelDownload,
                            guidanceLanguage = settings.language.wireValue,
                            languages = deviceLanguages,
                            onGuidanceLanguage = { onLanguage(TranscriptionLanguage.fromWire(it)) },
                        )
                    } else {
                        Notice { Text("Speech goes to your gateway. No model is needed on this phone.") }
                    }
                }
                OnboardingStage.KEYBOARD_READY -> {
                    KeyboardReadyMoment()
                }
                OnboardingStage.KEYBOARD -> {
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
                OnboardingStage.MICROPHONE, OnboardingStage.NOTIFICATIONS -> {
                    val step = if (stage == OnboardingStage.MICROPHONE) SetupStep.MICROPHONE else SetupStep.NOTIFICATIONS
                    SetupPermissionRow(
                        step = step,
                        permission = if (stage == OnboardingStage.MICROPHONE) Manifest.permission.RECORD_AUDIO
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
                            if (stage == OnboardingStage.MICROPHONE) "You choose when to record" else "Stay in control",
                            style = MaterialTheme.typography.titleMedium,
                        )
                        Text(
                            if (stage == OnboardingStage.MICROPHONE)
                                "Recording starts when you tap the microphone. You can finish or cancel from the keyboard."
                            else "The recording notification lets you see when the microphone is active and cancel recording outside the keyboard.",
                        )
                    }
                }
                OnboardingStage.READY -> {
                    // The model may still be on its way: setup no longer waits
                    // for it. The bar lives here so the last page answers "when
                    // can I dictate" rather than leaving it to the keyboard.
                    if (settings.localTranscriptionEnabled && localModels.downloading != null) {
                        ModelDownloadCard(state = localModels, onCancelDownload = onCancelLocalModelDownload)
                    }
                    // Nothing to try while the model is on its way: the
                    // keyboard would only say "downloading" back.
                    if (readyPresentation == ReadyPagePresentation.READY) {
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
                        // Recording does not wait for the load; the words are
                        // kept and transcribed once the model is in. So this
                        // says to start, not to wait.
                        localModels.preparing?.let { name ->
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                CircularProgressIndicator(
                                    modifier = Modifier.padding(end = 12.dp).size(18.dp),
                                    strokeWidth = 2.dp,
                                )
                                Text(
                                    SetupCopy.preparingModel(name),
                                    style = MaterialTheme.typography.bodyMedium,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
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
                    } else if (readyPresentation == ReadyPagePresentation.NEEDS_ATTENTION) {
                        val reason = localModels.message
                            ?.takeIf { settings.localTranscriptionEnabled && !status.gatewayConfigured }
                        if (reason != null) Notice { Text(reason) }
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
            if (stage != OnboardingStage.KEYBOARD_READY && (stage.isSatisfied(status) || stage == OnboardingStage.READY)) {
                PrimaryButton(
                    text = when (stage) {
                        OnboardingStage.WELCOME -> "Get started"
                        OnboardingStage.SOURCE -> "Next"
                        OnboardingStage.READY -> readyPageButtonLabel(
                            readyPresentation,
                            localModels.takeIf { it.downloading != null }?.let(::downloadProgressLine),
                            attention.button,
                        )
                        else -> "Continue"
                    },
                    // Greyed, not hidden: the label is where the progress
                    // reads, and a button that comes back on its own says
                    // "wait here" better than an empty bar would.
                    enabled = stage != OnboardingStage.READY || readyPresentation != ReadyPagePresentation.WAITING_FOR_MODEL,
                    onClick = {
                        if (stage != OnboardingStage.READY) advance()
                        else if (!status.isReadyToDictate) stage = OnboardingStage.firstUnmet(status)
                        else if (askUsageReporting) askingUsageReporting = true
                        else onFinish()
                    },
                    modifier = Modifier.fillMaxWidth(),
                )
            }
            Text(
                when (stage) {
                    OnboardingStage.READY -> "You can change your setup in Settings."
                    OnboardingStage.WELCOME -> "Next, choose how speech becomes text."
                    OnboardingStage.KEYBOARD_READY -> ""
                    else -> "${status.completedStepCount} of ${status.stepCount} requirements ready. Your progress is kept when you leave."
                },
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
                if (status.isReadyToDictate) onFinish() else stage = OnboardingStage.firstUnmet(status)
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

/** How long the keyboard confirmation stays before moving on by itself. */
private const val KEYBOARD_READY_MILLIS = 1_200L

@Composable
private fun WelcomeCard(icon: Int, title: String, body: String) {
    Notice {
        Icon(
            painter = painterResource(icon),
            contentDescription = null,
            tint = MaterialTheme.colorScheme.primary,
        )
        Text(title, style = MaterialTheme.typography.titleMedium)
        Text(body, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/**
 * A full check for the step people most often stall on. Satisfying a
 * requirement used to teleport straight to the next page, so the one moment
 * worth a pause was the one moment never shown.
 */
@Composable
private fun KeyboardReadyMoment() {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 64.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Icon(
            painter = painterResource(R.drawable.ic_step_done),
            contentDescription = null,
            tint = MaterialTheme.colorScheme.primary,
            modifier = Modifier.size(72.dp),
        )
        Text(OnboardingStage.KEYBOARD_READY.title, style = MaterialTheme.typography.headlineMedium)
    }
}
