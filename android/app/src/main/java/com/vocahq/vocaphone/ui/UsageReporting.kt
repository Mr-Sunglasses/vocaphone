package com.vocahq.vocaphone.ui

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import com.vocahq.vocaphone.BuildConfig

/**
 * The words this feature is judged on.
 *
 * Written once and used in both places it appears — the onboarding step and the
 * settings screen — because a shorter paraphrase in one of them is how the two
 * end up promising different things. `UsageReportingCopyTest` pins the claims
 * that have to survive a copy edit.
 */
object UsageReportingCopy {

    const val TITLE = "Help fix what's broken?"

    const val SETTINGS_TITLE = "Usage reporting"

    const val WHAT_IS_SENT =
        "VocaPhone is in beta and most problems never get reported. With this on, " +
            "the app sends a short list of counters — which setup step you reached, " +
            "whether a dictation succeeded or failed and at which stage, which " +
            "on-device model you downloaded, which one transcribed your speech and at " +
            "what accuracy setting, and the app version — to a server VocaHQ runs."

    /**
     * The third sentence is the one worth keeping through every copy review. It
     * is literally true — Aptabase derives its anonymous user from a salt it
     * throws away every 24 hours, so nothing is stored on the phone to identify
     * anyone — it is unusual, and it is what a sceptical reader will actually
     * weigh.
     */
    const val WHAT_IS_NEVER_SENT =
        "It never sends what you say, what you type, your transcripts, your audio, " +
            "your gateway's address, or your device model. It stores nothing on your " +
            "phone to identify you, and nothing sent today can be linked to anything " +
            "sent tomorrow."

    const val OPT_OUT_IS_LOGGED =
        "Turning this off sends one last event recording that you turned it off, " +
            "then discards anything still waiting. That final event is how we know " +
            "how many people opt out."

    const val NO_IDENTIFIER =
        "There is no reporting ID to reset, because there is never one stored."

    const val TURN_ON = "Turn on"

    const val NOT_NOW = "Not now"

    const val SEE_WHAT_IS_SENT = "See exactly what's sent"

    const val CHANGE_LATER = "You can change this any time in Settings › Usage reporting."

    const val EMPTY_QUEUE =
        "Nothing is waiting to be sent. Events appear here as you use the app, and " +
            "this screen shows the exact JSON that would be posted — not a summary of it."
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
    onSeePayload: () -> Unit,
    modifier: Modifier = Modifier,
) {
    if (!BuildConfig.TELEMETRY) return

    Notice(modifier = modifier) {
        Text(UsageReportingCopy.TITLE, style = MaterialTheme.typography.titleSmall)
        Text(UsageReportingCopy.WHAT_IS_SENT, style = MaterialTheme.typography.bodyMedium)
        Text(UsageReportingCopy.WHAT_IS_NEVER_SENT, style = MaterialTheme.typography.bodyMedium)
        TextButton(onClick = onSeePayload, modifier = Modifier.fillMaxWidth()) {
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
}

/** The settings section: the same words, the switch, and the payload viewer. */
@Composable
fun UsageReportingSection(
    enabled: Boolean,
    onEnabled: (Boolean) -> Unit,
    payload: () -> String,
    pendingCount: () -> Int,
    deliveryStatus: () -> String,
    modifier: Modifier = Modifier,
) {
    if (!BuildConfig.TELEMETRY) return
    var showingPayload by remember { mutableStateOf(false) }

    Section(
        title = UsageReportingCopy.SETTINGS_TITLE,
        supporting = UsageReportingCopy.WHAT_IS_SENT,
        modifier = modifier,
    ) {
        SettingToggle(
            title = "Send anonymous usage data",
            detail = if (enabled) "On — reporting to VocaHQ" else "Off — nothing is sent",
            checked = enabled,
            onCheckedChange = onEnabled,
        )
        Text(
            UsageReportingCopy.WHAT_IS_NEVER_SENT,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Text(
            UsageReportingCopy.NO_IDENTIFIER + " " + UsageReportingCopy.OPT_OUT_IS_LOGGED,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        SecondaryButton(
            text = if (showingPayload) "Hide what's queued" else UsageReportingCopy.SEE_WHAT_IS_SENT,
            onClick = { showingPayload = !showingPayload },
            modifier = Modifier.fillMaxWidth(),
        )
        if (showingPayload) {
            PendingPayloadView(
                payload = payload(),
                pendingCount = pendingCount(),
                deliveryStatus = deliveryStatus(),
            )
        }
    }
}

/**
 * The literal JSON the next flush would POST.
 *
 * Rendered rather than summarised on purpose: this is the screen that makes the
 * privacy claim checkable by the person it is made to, and it is self-enforcing
 * — if someone later adds a field to the payload it appears here without anyone
 * remembering to update a description of it.
 */
@Composable
fun PendingPayloadView(
    payload: String,
    pendingCount: Int,
    deliveryStatus: String = "",
    modifier: Modifier = Modifier,
) {
    Column(modifier = modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        // Shown whether or not anything is queued: an empty queue is exactly the
        // case where "did it send, or was it never recorded?" needs answering.
        if (deliveryStatus.isNotEmpty()) {
            Text(
                deliveryStatus,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        if (payload.isEmpty()) {
            Text(
                UsageReportingCopy.EMPTY_QUEUE,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            return@Column
        }
        Text(
            "$pendingCount event${if (pendingCount == 1) "" else "s"} waiting · " +
                "POST ${BuildConfig.APTABASE_HOST}/api/v0/events",
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Surface(
            color = MaterialTheme.colorScheme.surfaceContainerHigh,
            shape = MaterialTheme.shapes.medium,
            modifier = Modifier.fillMaxWidth(),
        ) {
            Text(
                payload,
                // Monospaced and horizontally scrolled rather than wrapped:
                // wrapped JSON is unreadable, and this screen is worthless if
                // it cannot actually be read.
                style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
                modifier = Modifier
                    .padding(12.dp)
                    .horizontalScroll(rememberScrollState()),
            )
        }
    }
}
