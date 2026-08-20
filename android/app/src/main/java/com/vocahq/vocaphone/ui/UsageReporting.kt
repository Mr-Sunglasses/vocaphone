package com.vocahq.vocaphone.ui

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import com.vocahq.vocaphone.BuildConfig
import com.vocahq.vocaphone.telemetry.TelemetryInspectPayload

/**
 * The words this feature is judged on.
 *
 * Written once and used in both places it appears, the onboarding step and the
 * settings screen, because a shorter paraphrase in one of them is how the two
 * end up promising different things. `UsageReportingCopyTest` pins the claims
 * that have to survive a copy edit.
 */
object UsageReportingCopy {

    const val TITLE = "Help fix what's broken?"

    const val SETTINGS_TITLE = "Usage reporting"

    const val SETTINGS_SUMMARY = "Counters only. No transcripts or audio."

    const val SHEET_TITLE = "What's sent"

    const val WHAT_IS_SENT =
        "With this on, the app sends counters to a server VocaHQ runs: which " +
            "setup step you reached, whether a dictation succeeded or failed, which " +
            "model you used, and the app version."

    /**
     * The third sentence is the one worth keeping through every copy review. It
     * is literally true: Aptabase derives its anonymous user from a salt it
     * throws away every 24 hours, so nothing is stored on the phone to identify
     * anyone. It is unusual, and it is what a sceptical reader will actually
     * weigh.
     */
    const val WHAT_IS_NEVER_SENT =
        "It never sends what you say, what you type, your transcripts, your audio, " +
            "your gateway's address, or your device model. It stores nothing on your " +
            "phone to identify you, and nothing sent today can be linked to anything " +
            "sent tomorrow."

    const val OPT_OUT_IS_LOGGED =
        "Turning this off sends one last event, then discards anything still " +
            "waiting. That is how we know how many people opt out."

    const val NO_IDENTIFIER =
        "There is no reporting ID to reset, because there is never one stored."

    const val TURN_ON = "Turn on"

    const val NOT_NOW = "Not now"

    const val SEE_WHAT_IS_SENT = "See exactly what's sent"

    const val CHANGE_LATER = "You can change this any time in Settings, Usage reporting."

    const val SAMPLE_LABEL =
        "Nothing has been sent yet. This is the shape of a typical event, not a real one."

    const val REAL_LABEL = "Last event queued or sent."

    const val COPY_JSON = "Copy JSON"
}

/**
 * The onboarding step that asks.
 *
 * Deliberately placed at the end of guided setup, after the user has a working
 * transcript rather than while they are still deciding whether the app is worth
 * their time. Both buttons carry the same weight: no greyed-out decline, and
 * nothing that makes saying no look like a mistake. The switch is on this
 * screen rather than behind a link, because a notice whose control lives
 * somewhere else is not a choice.
 */
@Composable
fun UsageReportingSetupCard(
    onDecision: (Boolean) -> Unit,
    inspect: () -> TelemetryInspectPayload,
    pendingCount: () -> Int = { 0 },
    deliveryStatus: () -> String = { "" },
    modifier: Modifier = Modifier,
) {
    if (!BuildConfig.TELEMETRY) return
    var showingPayload by remember { mutableStateOf(false) }

    Notice(modifier = modifier) {
        Text(UsageReportingCopy.TITLE, style = MaterialTheme.typography.titleSmall)
        Text(UsageReportingCopy.WHAT_IS_SENT, style = MaterialTheme.typography.bodyMedium)
        Text(UsageReportingCopy.WHAT_IS_NEVER_SENT, style = MaterialTheme.typography.bodyMedium)
        TextButton(onClick = { showingPayload = true }, modifier = Modifier.fillMaxWidth()) {
            Text(UsageReportingCopy.SEE_WHAT_IS_SENT)
        }
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.fillMaxWidth()) {
            SecondaryButton(
                text = UsageReportingCopy.NOT_NOW,
                onClick = { onDecision(false) },
                modifier = Modifier.weight(1f),
            )
            SecondaryButton(
                text = UsageReportingCopy.TURN_ON,
                onClick = { onDecision(true) },
                modifier = Modifier.weight(1f),
            )
        }
        Text(
            UsageReportingCopy.CHANGE_LATER,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
    if (showingPayload) {
        UsagePayloadSheet(
            inspect = inspect(),
            pendingCount = pendingCount(),
            deliveryStatus = deliveryStatus(),
            onDismiss = { showingPayload = false },
        )
    }
}

/** The settings section: the same words, the switch, and the payload viewer. */
@Composable
fun UsageReportingSection(
    enabled: Boolean,
    onEnabled: (Boolean) -> Unit,
    inspect: () -> TelemetryInspectPayload,
    pendingCount: () -> Int,
    deliveryStatus: () -> String,
    modifier: Modifier = Modifier,
) {
    if (!BuildConfig.TELEMETRY) return
    var showingPayload by remember { mutableStateOf(false) }

    Section(
        title = UsageReportingCopy.SETTINGS_TITLE,
        supporting = UsageReportingCopy.SETTINGS_SUMMARY,
        modifier = modifier,
    ) {
        SettingToggle(
            title = "Send anonymous usage data",
            detail = if (enabled) "On. Reporting to VocaHQ." else "Off. Nothing is sent.",
            checked = enabled,
            onCheckedChange = onEnabled,
        )
        TextButton(onClick = { showingPayload = true }) {
            Text(UsageReportingCopy.SEE_WHAT_IS_SENT)
        }
    }
    if (showingPayload) {
        UsagePayloadSheet(
            inspect = inspect(),
            pendingCount = pendingCount(),
            deliveryStatus = deliveryStatus(),
            onDismiss = { showingPayload = false },
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun UsagePayloadSheet(
    inspect: TelemetryInspectPayload,
    pendingCount: Int,
    deliveryStatus: String,
    onDismiss: () -> Unit,
) {
    val context = LocalContext.current
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp)
                .padding(bottom = 28.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(UsageReportingCopy.SHEET_TITLE, style = MaterialTheme.typography.titleMedium)
            Text(
                if (inspect.isSample) UsageReportingCopy.SAMPLE_LABEL else UsageReportingCopy.REAL_LABEL,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Text(UsageReportingCopy.WHAT_IS_SENT, style = MaterialTheme.typography.bodySmall)
            Text(UsageReportingCopy.WHAT_IS_NEVER_SENT, style = MaterialTheme.typography.bodySmall)
            Text(
                UsageReportingCopy.NO_IDENTIFIER + " " + UsageReportingCopy.OPT_OUT_IS_LOGGED,
                style = MaterialTheme.typography.bodySmall,
            )
            PendingPayloadView(
                payload = inspect.json,
                pendingCount = pendingCount,
                deliveryStatus = deliveryStatus,
                isSample = inspect.isSample,
            )
            SecondaryButton(
                text = UsageReportingCopy.COPY_JSON,
                onClick = { context.copyPlainText("VocaPhone usage JSON", inspect.json) },
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}

/**
 * The literal JSON the next flush would POST, or a sample of that shape.
 *
 * Rendered rather than summarised on purpose: this is the screen that makes the
 * privacy claim checkable by the person it is made to, and it is self-enforcing
 * if someone later adds a field to the payload it appears here without anyone
 * remembering to update a description of it.
 */
@Composable
fun PendingPayloadView(
    payload: String,
    pendingCount: Int,
    deliveryStatus: String = "",
    isSample: Boolean = false,
    modifier: Modifier = Modifier,
) {
    Column(modifier = modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (deliveryStatus.isNotEmpty() && !isSample) {
            Text(
                deliveryStatus,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        if (!isSample && pendingCount > 0) {
            Text(
                "$pendingCount event${if (pendingCount == 1) "" else "s"} waiting. " +
                    "POST ${BuildConfig.APTABASE_HOST}/api/v0/events",
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Surface(
            color = MaterialTheme.colorScheme.surfaceContainerHigh,
            shape = MaterialTheme.shapes.medium,
            modifier = Modifier.fillMaxWidth(),
        ) {
            Text(
                payload,
                style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
                modifier = Modifier
                    .padding(12.dp)
                    .heightIn(max = 280.dp)
                    .verticalScroll(rememberScrollState())
                    .horizontalScroll(rememberScrollState()),
            )
        }
    }
}

private fun Context.copyPlainText(label: String, text: String) {
    val clipboard = getSystemService(ClipboardManager::class.java) ?: return
    clipboard.setPrimaryClip(ClipData.newPlainText(label, text))
}
