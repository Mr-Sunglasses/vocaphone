package com.vocahq.vocaphone.ui

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.view.HapticFeedbackConstants
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.wrapContentWidth
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Checkbox
import androidx.compose.material3.FilledTonalIconButton
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.onLongClick
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import com.vocahq.vocaphone.R
import com.vocahq.vocaphone.core.TranscriptionLanguage
import com.vocahq.vocaphone.core.WritingStyle
import com.vocahq.vocaphone.data.DictationRecordEntity
import com.vocahq.vocaphone.data.RECORD_STATE_FAILED
import java.text.DateFormat
import java.util.Date

@Composable
fun HistoryScreen(
    records: List<DictationRecordEntity>,
    selectedIds: Set<String>,
    selecting: Boolean,
    onRetry: (String) -> Unit,
    onToggleSelect: (String) -> Unit,
    onEnterSelect: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val view = LocalView.current

    if (records.isEmpty()) {
        EmptyState(
            "Dictations you make will be listed here. Nothing is uploaded except " +
                "the audio your gateway transcribes.",
            modifier = modifier.fillMaxSize(),
        )
        return
    }

    LazyColumn(
        modifier = modifier
            .fillMaxSize()
            .wrapContentWidth(Alignment.CenterHorizontally)
            .widthIn(max = AppContentMaxWidth),
    ) {
        items(records, key = { it.sessionId }) { record ->
            HistoryRow(
                record = record,
                selected = record.sessionId in selectedIds,
                selecting = selecting,
                onRetry = { onRetry(record.sessionId) },
                onCopy = { text ->
                    view.performHapticFeedback(HapticFeedbackConstants.CONFIRM)
                    context.copyToClipboard(text)
                },
                onToggleSelect = { onToggleSelect(record.sessionId) },
                onEnterSelect = { onEnterSelect(record.sessionId) },
            )
        }
    }
}

/** Tap copies. Long-press or the app-bar Select action starts a selection. */
internal fun toggleHistorySelection(selected: Set<String>, id: String): Set<String> =
    if (id in selected) selected - id else selected + id

internal fun historySelectionTitle(count: Int): String = when (count) {
    0 -> "Select items"
    1 -> "1 selected"
    else -> "$count selected"
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun HistoryRow(
    record: DictationRecordEntity,
    selected: Boolean,
    selecting: Boolean,
    onRetry: () -> Unit,
    onCopy: (String) -> Unit,
    onToggleSelect: () -> Unit,
    onEnterSelect: () -> Unit,
) {
    val failed = record.state == RECORD_STATE_FAILED
    val timestamp = DateFormat.getDateTimeInstance(DateFormat.SHORT, DateFormat.SHORT)
        .format(Date(record.createdAt))
    val transcript = record.transcript?.takeIf { it.isNotEmpty() }
    val canRetry = !selecting && failed && record.recoverable && record.audioPath != null
    val meta = buildString {
        append(timestamp)
        append(" · ")
        append(TranscriptionLanguage.fromWire(record.language).displayName)
        append(" · ")
        append(WritingStyle.fromWire(record.style).displayName)
        if (record.insertedIntoField) append(" · inserted")
        if (record.audioPath != null) append(" · audio kept for retry")
    }

    ListItem(
        modifier = Modifier
            .fillMaxWidth()
            .semantics {
                this.selected = selected
                if (selecting) {
                    onClick(label = if (selected) "Deselect" else "Select") {
                        onToggleSelect()
                        true
                    }
                } else if (transcript != null) {
                    onClick(label = "Copy") {
                        onCopy(transcript)
                        true
                    }
                }
                onLongClick(label = "Select") {
                    if (selecting) onToggleSelect() else onEnterSelect()
                    true
                }
            }
            .combinedClickable(
                onClick = {
                    if (selecting) {
                        onToggleSelect()
                    } else if (transcript != null) {
                        onCopy(transcript)
                    }
                },
                onLongClick = {
                    if (selecting) onToggleSelect() else onEnterSelect()
                },
            ),
        headlineContent = {
            if (failed) {
                Text(
                    record.errorMessage ?: "This dictation failed.",
                    color = MaterialTheme.colorScheme.error,
                )
            } else if (transcript != null) {
                Text(transcript)
            }
        },
        supportingContent = {
            Text(meta)
        },
        leadingContent = if (selecting) {
            {
                // The row owns the click so the box cannot toggle twice.
                Checkbox(checked = selected, onCheckedChange = null)
            }
        } else {
            null
        },
        trailingContent = if (canRetry) {
            {
                FilledTonalIconButton(onClick = onRetry) {
                    Icon(
                        painter = painterResource(R.drawable.ic_retry),
                        contentDescription = "Retry",
                    )
                }
            }
        } else {
            null
        },
        colors = ListItemDefaults.colors(
            containerColor = if (selected) {
                MaterialTheme.colorScheme.secondaryContainer
            } else {
                Color.Transparent
            },
        ),
    )
}

private fun Context.copyToClipboard(text: String) {
    // Explicit only: VocaPhone never writes to the clipboard on its own.
    val clipboard = getSystemService(ClipboardManager::class.java) ?: return
    clipboard.setPrimaryClip(ClipData.newPlainText("VocaPhone transcript", text))
}
