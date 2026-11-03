package com.vocahq.vocaphone.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.vocahq.vocaphone.core.CorrectionSuggestion
import com.vocahq.vocaphone.settings.CorrectionLearningState

/** What the Suggested section can do; defaults do nothing, for previews. */
data class CorrectionLearningActions(
    val onEnabled: (Boolean) -> Unit = {},
    val onAdd: (key: String) -> Unit = {},
    val onDismiss: (key: String) -> Unit = {},
    val onClear: () -> Unit = {},
)

internal val learnedCorrectionsHelp = LearnMore(
    title = "Learning from your corrections",
    paragraphs = listOf(
        "When you fix a word in something you just dictated, using the VocaPhone " +
            "keyboard, the keyboard notices the new spelling and suggests it here: " +
            "\"Namratha\" fixed to \"Namrata\", \"git hub\" to \"GitHub\".",
        "To see what you changed, the keyboard reads the text around the dictation " +
            "as you edit it, for up to 20 seconds, until your next dictation, or until " +
            "the keyboard closes. That text stays in memory on this phone and is " +
            "never saved. Only the pair of words, what was heard and how you wrote " +
            "it, is kept here.",
        "Only spelling fixes count: a name spelled another way, different capitals, " +
            "or words joined into one. Rewording, and swapping one ordinary word for " +
            "another, are ignored. Nothing is read in password, PIN or card fields, " +
            "in fields that ask keyboards not to learn, such as incognito tabs, or in " +
            "text that is not in English.",
        "Add puts the word in your dictionary, so dictation spells it your way and " +
            "listens for it, and adds a replacement when dictation heard different " +
            "letters. A name or term you fix the same way twice is added for you; " +
            "remove it from the lists above if that was wrong.",
        "Turn learning off to stop all of this. Clear suggestions forgets every " +
            "suggestion and dismissal; words already added stay until you remove them.",
    ),
)

/**
 * Spellings the keyboard learned from the user's fixes to dictated text:
 * Add or Dismiss each, with the switch that turns learning off.
 */
@Composable
internal fun SuggestedCorrectionsSection(
    state: CorrectionLearningState,
    actions: CorrectionLearningActions,
) {
    var confirmClear by remember { mutableStateOf(false) }
    SettingsGroup(
        title = "Suggested",
        footer = if (state.enabled) {
            "Spellings you fixed after dictating with the VocaPhone keyboard."
        } else {
            "Off. The keyboard does not look at your fixes."
        },
        learnMore = learnedCorrectionsHelp,
    ) {
        SettingsSwitchRow(
            title = "Learn from my corrections",
            supporting = "Only the words you fixed are kept.",
            checked = state.enabled,
            onCheckedChange = actions.onEnabled,
        )
        state.suggestions.forEach { suggestion ->
            SettingsDivider()
            SuggestionRow(suggestion, onAdd = { actions.onAdd(suggestion.key) }, onDismiss = { actions.onDismiss(suggestion.key) })
        }
        if (state.suggestions.isNotEmpty() || state.dismissedCount > 0) {
            SettingsDivider()
            SettingsActionRow(
                title = "Clear suggestions",
                destructive = true,
                onClick = { confirmClear = true },
            )
        }
    }
    if (confirmClear) {
        AlertDialog(
            onDismissRequest = { confirmClear = false },
            title = { Text("Clear suggestions?") },
            text = {
                Text(
                    "Forgets every suggested and dismissed spelling. Words already in your " +
                        "dictionary stay.",
                )
            },
            confirmButton = {
                DestructiveTextButton(
                    text = "Clear",
                    onClick = {
                        confirmClear = false
                        actions.onClear()
                    },
                )
            },
            dismissButton = {
                TextButton(onClick = { confirmClear = false }) { Text("Cancel") }
            },
        )
    }
}

@Composable
private fun SuggestionRow(suggestion: CorrectionSuggestion, onAdd: () -> Unit, onDismiss: () -> Unit) {
    Row(
        modifier = Modifier.padding(start = 16.dp, end = 4.dp, top = 8.dp, bottom = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(suggestion.corrected, style = MaterialTheme.typography.bodyLarge)
            Text(
                text = "Heard \"${suggestion.heard}\"" +
                    if (suggestion.occurrences > 1) " · fixed ${suggestion.occurrences} times" else "",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
            )
        }
        TextButton(onClick = onDismiss) { Text("Dismiss") }
        TextButton(onClick = onAdd) { Text("Add") }
    }
}
