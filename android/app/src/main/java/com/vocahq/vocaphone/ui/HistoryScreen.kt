package com.vocahq.vocaphone.ui

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.view.HapticFeedbackConstants
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.wrapContentWidth
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CornerSize
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Checkbox
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalIconButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.onLongClick
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.vocahq.vocaphone.R
import com.vocahq.vocaphone.core.TranscriptionLanguage
import com.vocahq.vocaphone.core.WritingStyle
import com.vocahq.vocaphone.data.DictationRecordEntity
import com.vocahq.vocaphone.data.RECORD_STATE_FAILED
import java.text.DateFormat
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Date
import java.util.Locale

/** Past this many dictations a search field earns its place at the top. */
internal const val HISTORY_SEARCH_THRESHOLD = 20

/**
 * Dictations by day, newest first. Each row is the start of the transcript and
 * its time; anything else is shown only when it is not the usual case (a
 * failure, a language other than Automatic, audio kept for Retry). A tap opens
 * the whole dictation with Copy, Share and Delete. Long-press, or Select in the
 * app bar, starts a multi-selection.
 */
@Composable
fun HistoryScreen(
    records: List<DictationRecordEntity>,
    selectedIds: Set<String>,
    selecting: Boolean,
    onRetry: (String) -> Unit,
    onDelete: (String) -> Unit,
    onToggleSelect: (String) -> Unit,
    onEnterSelect: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    var query by remember { mutableStateOf("") }
    var opened by remember { mutableStateOf<String?>(null) }

    if (records.isEmpty()) {
        EmptyState("Your dictations will show up here.", modifier = modifier.fillMaxSize())
        return
    }

    val zone = remember { ZoneId.systemDefault() }
    val today = LocalDate.now(zone)
    val visible = remember(records, query) { filterHistory(records, query) }
    val days = remember(visible, zone) {
        visible.groupBy { historyDay(it.createdAt, zone) }.toList()
    }
    val timeFormat = remember { DateFormat.getTimeInstance(DateFormat.SHORT) }

    LazyColumn(
        modifier = modifier
            .fillMaxSize()
            .wrapContentWidth(Alignment.CenterHorizontally)
            .widthIn(max = AppContentMaxWidth),
        contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 24.dp),
    ) {
        // Stays while a query is set, even if deleting a match takes the list
        // under the threshold: otherwise the filter would outlive its field.
        if (showHistorySearch(records.size, query)) {
            item(key = "search") {
                OutlinedTextField(
                    value = query,
                    onValueChange = { query = it },
                    singleLine = true,
                    placeholder = { Text("Search dictations") },
                    leadingIcon = { Icon(painterResource(R.drawable.ic_search), contentDescription = null) },
                    trailingIcon = if (query.isNotEmpty()) {
                        {
                            IconButton(onClick = { query = "" }) {
                                Icon(painterResource(R.drawable.ic_cancel), contentDescription = "Clear search")
                            }
                        }
                    } else {
                        null
                    },
                    modifier = Modifier.fillMaxWidth().padding(bottom = GroupSpacing),
                )
            }
        }
        if (days.isEmpty()) {
            item(key = "none") { EmptyState("No dictations match “$query”.") }
        }
        // One lazy item per row, not per day: a day can hold many of the
        // records History loads, and a whole day built at once stalls the
        // scroll. Each row draws its own slice of the day's rounded card.
        days.forEachIndexed { dayIndex, (day, dayRecords) ->
            item(key = "day-${day.toEpochDay()}") {
                SettingsGroupHeader(
                    historyDayLabel(day, today),
                    modifier = Modifier.padding(
                        top = if (dayIndex == 0) 0.dp else GroupSpacing,
                        bottom = 8.dp,
                    ),
                )
            }
            itemsIndexed(dayRecords, key = { _, record -> record.sessionId }) { index, record ->
                Surface(
                    color = MaterialTheme.colorScheme.surfaceContainerLow,
                    shape = groupSliceShape(first = index == 0, last = index == dayRecords.lastIndex),
                ) {
                    Column {
                        if (index > 0) SettingsDivider()
                        HistoryRow(
                            record = record,
                            time = timeFormat.format(Date(record.createdAt)),
                            selected = record.sessionId in selectedIds,
                            selecting = selecting,
                            onRetry = { onRetry(record.sessionId) },
                            onOpen = { opened = record.sessionId },
                            onToggleSelect = { onToggleSelect(record.sessionId) },
                            onEnterSelect = { onEnterSelect(record.sessionId) },
                        )
                    }
                }
            }
        }
    }

    records.firstOrNull { it.sessionId == opened }?.let { record ->
        HistoryDetailSheet(
            record = record,
            onRetry = {
                onRetry(record.sessionId)
                opened = null
            },
            onDelete = {
                onDelete(record.sessionId)
                opened = null
            },
            onDismiss = { opened = null },
        )
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

internal fun showHistorySearch(recordCount: Int, query: String): Boolean =
    recordCount >= HISTORY_SEARCH_THRESHOLD || query.isNotEmpty()

/** The corners one row of a day's card needs: rounded only at its ends. */
@Composable
private fun groupSliceShape(first: Boolean, last: Boolean): Shape {
    val corner = MaterialTheme.shapes.large.topStart
    val none = CornerSize(0.dp)
    return RoundedCornerShape(
        topStart = if (first) corner else none,
        topEnd = if (first) corner else none,
        bottomStart = if (last) corner else none,
        bottomEnd = if (last) corner else none,
    )
}

internal fun historyDay(createdAt: Long, zone: ZoneId): LocalDate =
    Instant.ofEpochMilli(createdAt).atZone(zone).toLocalDate()

/** "Today", "Yesterday", "Mon 28 Sep", or "28 Sep 2025" for another year. */
internal fun historyDayLabel(day: LocalDate, today: LocalDate, locale: Locale = Locale.getDefault()): String =
    when {
        day == today -> "Today"
        day == today.minusDays(1) -> "Yesterday"
        day.year == today.year -> day.format(DateTimeFormatter.ofPattern("EEE d MMM", locale))
        else -> day.format(DateTimeFormatter.ofPattern("d MMM yyyy", locale))
    }

/** The row's second line: the time, plus only what is out of the ordinary. */
internal fun historyRowMeta(time: String, record: DictationRecordEntity): String = buildList {
    add(time)
    val language = TranscriptionLanguage.fromWire(record.language)
    if (language != TranscriptionLanguage.AUTOMATIC) add(language.displayName)
    if (record.audioPath != null) add("audio kept for Retry")
}.joinToString(" · ")

internal fun filterHistory(records: List<DictationRecordEntity>, query: String): List<DictationRecordEntity> {
    val needle = query.trim()
    if (needle.isEmpty()) return records
    return records.filter { record ->
        record.transcript?.contains(needle, ignoreCase = true) == true ||
            record.errorMessage?.contains(needle, ignoreCase = true) == true
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun HistoryRow(
    record: DictationRecordEntity,
    time: String,
    selected: Boolean,
    selecting: Boolean,
    onRetry: () -> Unit,
    onOpen: () -> Unit,
    onToggleSelect: () -> Unit,
    onEnterSelect: () -> Unit,
) {
    val view = LocalView.current
    val failed = record.state == RECORD_STATE_FAILED
    val transcript = record.transcript?.takeIf { it.isNotEmpty() }
    val canRetry = !selecting && failed && record.recoverable && record.audioPath != null

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 56.dp)
            .semantics {
                this.selected = selected
                onClick(label = if (selecting) (if (selected) "Deselect" else "Select") else "Open") {
                    if (selecting) onToggleSelect() else onOpen()
                    true
                }
                onLongClick(label = "Select") {
                    if (selecting) onToggleSelect() else onEnterSelect()
                    true
                }
            }
            .combinedClickable(
                onClick = { if (selecting) onToggleSelect() else onOpen() },
                onLongClick = {
                    view.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
                    if (selecting) onToggleSelect() else onEnterSelect()
                },
            )
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        if (selecting) Checkbox(checked = selected, onCheckedChange = null)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(
                text = when {
                    failed -> record.errorMessage ?: "This dictation failed."
                    else -> transcript.orEmpty()
                },
                style = MaterialTheme.typography.bodyLarge,
                color = if (failed) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurface,
                maxLines = 3,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                historyRowMeta(time, record),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        if (canRetry) {
            FilledTonalIconButton(onClick = onRetry) {
                Icon(painter = painterResource(R.drawable.ic_retry), contentDescription = "Retry")
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun HistoryDetailSheet(
    record: DictationRecordEntity,
    onRetry: () -> Unit,
    onDelete: () -> Unit,
    onDismiss: () -> Unit,
) {
    val context = LocalContext.current
    val view = LocalView.current
    var confirmingDelete by remember { mutableStateOf(false) }
    val failed = record.state == RECORD_STATE_FAILED
    val transcript = record.transcript?.takeIf { it.isNotEmpty() }
    val canRetry = failed && record.recoverable && record.audioPath != null
    val stamp = remember(record.createdAt) {
        DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date(record.createdAt))
    }
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp)
                .padding(bottom = 28.dp),
            verticalArrangement = Arrangement.spacedBy(GroupSpacing),
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(stamp, style = MaterialTheme.typography.titleMedium)
                Text(
                    listOf(
                        TranscriptionLanguage.fromWire(record.language).displayName,
                        WritingStyle.fromWire(record.style).displayName,
                    ).joinToString(" · ") + if (record.insertedIntoField) " · typed into an app" else "",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            SettingsGroup {
                SettingsGroupContent {
                    SelectionContainer {
                        Text(
                            if (failed) record.errorMessage ?: "This dictation failed." else transcript.orEmpty(),
                            style = MaterialTheme.typography.bodyLarge,
                            color = if (failed) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurface,
                        )
                    }
                }
            }
            SettingsGroup {
                if (transcript != null) {
                    SettingsActionRow(
                        title = "Copy",
                        icon = R.drawable.ic_copy,
                        onClick = {
                            view.performHapticFeedback(HapticFeedbackConstants.CONFIRM)
                            context.copyToClipboard(transcript)
                        },
                    )
                    SettingsDivider(inset = true)
                    SettingsActionRow(
                        title = "Share",
                        icon = R.drawable.ic_share,
                        onClick = { context.shareText(transcript) },
                    )
                    SettingsDivider(inset = true)
                }
                if (canRetry) {
                    SettingsActionRow(
                        title = "Retry",
                        icon = R.drawable.ic_retry,
                        onClick = onRetry,
                    )
                    SettingsDivider(inset = true)
                }
                SettingsActionRow(
                    title = "Delete",
                    icon = R.drawable.ic_delete,
                    destructive = true,
                    onClick = { confirmingDelete = true },
                )
            }
        }
    }
    if (confirmingDelete) {
        AlertDialog(
            onDismissRequest = { confirmingDelete = false },
            title = { Text("Delete this dictation?") },
            text = { Text("This removes it from this phone.") },
            confirmButton = {
                DestructiveTextButton(
                    text = "Delete",
                    onClick = {
                        confirmingDelete = false
                        onDelete()
                    },
                )
            },
            dismissButton = {
                TextButton(onClick = { confirmingDelete = false }) { Text("Cancel") }
            },
        )
    }
}

private fun Context.copyToClipboard(text: String) {
    val clipboard = getSystemService(ClipboardManager::class.java) ?: return
    clipboard.setPrimaryClip(ClipData.newPlainText("VocaPhone transcript", text))
}

private fun Context.shareText(text: String) {
    val send = Intent(Intent.ACTION_SEND).apply {
        type = "text/plain"
        putExtra(Intent.EXTRA_TEXT, text)
    }
    runCatching { startActivity(Intent.createChooser(send, null)) }
}
