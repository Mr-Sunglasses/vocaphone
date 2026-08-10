package com.vocahq.vocaphone.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.layout.size
import com.vocahq.vocaphone.R
import com.vocahq.vocaphone.core.ModelLanguageSupport
import com.vocahq.vocaphone.core.TranscriptionLanguage

/**
 * The full language list, opened from one row in Settings.
 *
 * Twenty-seven chips in a wrapping row pushed every setting below Language off
 * the screen, so the list lives behind a sheet with search. The languages the
 * gateway's model cannot honour are grouped at the bottom and greyed rather than
 * hidden: a language that simply disappears reads as unsupported by the app, when
 * the fix is to change the model on the gateway.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LanguagePickerSheet(
    selected: TranscriptionLanguage,
    modelLanguages: Set<String>,
    detectsLanguageAutomatically: Boolean,
    onDevice: Boolean = false,
    onSelect: (TranscriptionLanguage) -> Unit,
    onDismiss: () -> Unit,
) {
    var query by remember { mutableStateOf("") }
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)

    fun matches(language: TranscriptionLanguage) =
        query.isBlank() ||
            language.displayName.contains(query, ignoreCase = true) ||
            language.wireValue.contains(query, ignoreCase = true)

    fun selectable(language: TranscriptionLanguage) =
        ModelLanguageSupport.isSelectable(language, modelLanguages, detectsLanguageAutomatically)

    val available = TranscriptionLanguage.entries.filter { matches(it) && selectable(it) }
    val unavailable = TranscriptionLanguage.entries.filter { matches(it) && !selectable(it) }
    val restriction =
        ModelLanguageSupport.restriction(
            modelLanguages,
            detectsLanguageAutomatically,
            onDevice = onDevice,
        )

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text("Transcription language", style = MaterialTheme.typography.titleMedium)
            OutlinedTextField(
                value = query,
                onValueChange = { query = it },
                label = { Text("Search languages") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            if (restriction != null) {
                Text(
                    restriction,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
        LazyColumn(
            modifier = Modifier.fillMaxWidth().heightIn(max = 420.dp).padding(top = 8.dp),
        ) {
            items(available, key = { it.wireValue }) { language ->
                LanguageRow(language, selected == language, enabled = true) {
                    onSelect(language)
                    onDismiss()
                }
            }
            if (unavailable.isNotEmpty()) {
                item {
                    Text(
                        "Needs a different model",
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp),
                    )
                }
                items(unavailable, key = { it.wireValue }) { language ->
                    LanguageRow(language, selected == language, enabled = false) {}
                }
            }
            if (available.isEmpty() && unavailable.isEmpty()) {
                item {
                    Text(
                        "No language matches \"$query\".",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        textAlign = TextAlign.Center,
                        modifier = Modifier.fillMaxWidth().padding(24.dp),
                    )
                }
            }
        }
    }
}

@Composable
private fun LanguageRow(
    language: TranscriptionLanguage,
    isSelected: Boolean,
    enabled: Boolean,
    onClick: () -> Unit,
) {
    val colour = if (enabled) {
        MaterialTheme.colorScheme.onSurface
    } else {
        MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f)
    }
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .let { if (enabled) it.clickable(onClick = onClick) else it }
            .padding(horizontal = 16.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(
            language.displayName,
            style = MaterialTheme.typography.bodyLarge,
            color = colour,
            modifier = Modifier.weight(1f),
        )
        if (isSelected) {
            Icon(
                painter = painterResource(R.drawable.ic_step_done),
                contentDescription = "Selected",
                tint = MaterialTheme.colorScheme.primary,
                modifier = Modifier.size(20.dp),
            )
        }
    }
}
