package io.github.mrsunglasses.localflow.ui

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import io.github.mrsunglasses.localflow.core.TranscriptionLanguage
import io.github.mrsunglasses.localflow.core.WritingStyle
import io.github.mrsunglasses.localflow.data.DictationRecordEntity
import io.github.mrsunglasses.localflow.data.RECORD_STATE_FAILED
import java.text.DateFormat
import java.util.Date

@Composable
fun HistoryScreen(
    records: List<DictationRecordEntity>,
    onRetry: (String) -> Unit,
    onDelete: (String) -> Unit,
    onDeleteAll: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current

    if (records.isEmpty()) {
        EmptyState(
            "Dictations you make will be listed here. Nothing is uploaded except " +
                "the audio your gateway transcribes.",
            modifier = modifier.fillMaxSize(),
        )
        return
    }

    LazyColumn(
        modifier = modifier.fillMaxSize().padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        items(records, key = { it.sessionId }) { record ->
            HistoryRow(
                record = record,
                onRetry = { onRetry(record.sessionId) },
                onDelete = { onDelete(record.sessionId) },
                onCopy = { context.copyToClipboard(it) },
            )
        }
        item {
            TextButton(onClick = onDeleteAll, modifier = Modifier.fillMaxWidth()) {
                Text("Delete all history")
            }
        }
    }
}

@Composable
private fun HistoryRow(
    record: DictationRecordEntity,
    onRetry: () -> Unit,
    onDelete: () -> Unit,
    onCopy: (String) -> Unit,
) {
    val failed = record.state == RECORD_STATE_FAILED
    val timestamp = DateFormat.getDateTimeInstance(DateFormat.SHORT, DateFormat.SHORT)
        .format(Date(record.createdAt))

    SectionCard(
        title = timestamp,
        supporting = buildString {
            append(TranscriptionLanguage.fromWire(record.language).displayName)
            append(" · ")
            append(WritingStyle.fromWire(record.style).displayName)
            if (record.insertedIntoField) append(" · inserted")
            if (record.audioPath != null) append(" · audio kept for retry")
        },
    ) {
        if (failed) {
            Text(
                record.errorMessage ?: "This dictation failed.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.error,
            )
        } else {
            Text(record.transcript.orEmpty(), style = MaterialTheme.typography.bodyMedium)
        }

        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            if (failed && record.recoverable && record.audioPath != null) {
                PrimaryButton("Retry", onClick = onRetry, modifier = Modifier.weight(1f))
            }
            record.transcript?.takeIf { it.isNotEmpty() }?.let { transcript ->
                // Explicit only: Local Flow never writes to the clipboard on its own.
                SecondaryButton(
                    text = "Copy",
                    onClick = { onCopy(transcript) },
                    modifier = Modifier.weight(1f),
                )
            }
            TextButton(onClick = onDelete, modifier = Modifier.weight(1f)) { Text("Delete") }
        }
    }
}

private fun Context.copyToClipboard(text: String) {
    val clipboard = getSystemService(ClipboardManager::class.java) ?: return
    clipboard.setPrimaryClip(ClipData.newPlainText("Local Flow transcript", text))
}
