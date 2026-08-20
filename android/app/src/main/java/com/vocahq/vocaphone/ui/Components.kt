package com.vocahq.vocaphone.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ExposedDropdownMenuAnchorType
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.annotation.DrawableRes
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.vocahq.vocaphone.R

/**
 * The app's two button weights, so every screen agrees on height.
 *
 * The shape is Material's own. A bespoke 16.dp corner was applied here, to the
 * chips, and to every card, which is how a screen ends up with one radius on
 * everything and no hierarchy at all — and it was a worse fit than the shape the
 * platform already draws on every other button the user meets.
 *
 * Outlined buttons are deliberately absent: with dynamic dark colour their
 * border all but vanished, which left secondary actions looking like bare
 * floating text. The palette is fixed now, but a filled-tonal secondary is still
 * the clearer of the two, so this stays.
 */
private val ButtonHeight = 48.dp

@Composable
fun PrimaryButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    loading: Boolean = false,
) {
    Button(
        onClick = onClick,
        enabled = enabled && !loading,
        modifier = modifier.height(ButtonHeight),
    ) {
        ButtonLabel(text, loading)
    }
}

@Composable
fun SecondaryButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    loading: Boolean = false,
) {
    FilledTonalButton(
        onClick = onClick,
        enabled = enabled && !loading,
        modifier = modifier.height(ButtonHeight),
    ) {
        ButtonLabel(text, loading)
    }
}

@Composable
private fun ButtonLabel(text: String, loading: Boolean) {
    if (loading) {
        CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
    } else {
        Text(text)
    }
}

/** A label and its value on one line, for the About section. */
@Composable
fun InfoRow(label: String, value: String, modifier: Modifier = Modifier) {
    Row(
        modifier = modifier.fillMaxWidth().padding(vertical = 2.dp),
        horizontalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text(
            label,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Text(
            value,
            style = MaterialTheme.typography.bodyMedium,
            textAlign = TextAlign.End,
            modifier = Modifier.weight(1f),
        )
    }
}

/**
 * One titled group of settings or state, laid on the page.
 *
 * This used to be a filled `Card`, and every screen was a vertical stack of
 * them: Settings alone drew fourteen identical rounded slabs, so nothing on it
 * could be more or less important than anything else, and a third of the width
 * went to card padding. A heading and its content, separated from the next group
 * by space, is what Android's own Settings does and it lets the type carry the
 * grouping instead of a container.
 *
 * Screens space these with `Arrangement.spacedBy(SectionSpacing)`, which is
 * wider than the old inter-card gap because the gap is now the only separator.
 */
@Composable
fun Section(
    title: String,
    modifier: Modifier = Modifier,
    supporting: String? = null,
    content: @Composable () -> Unit,
) {
    Column(
        modifier = modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Text(title, style = MaterialTheme.typography.titleSmall)
        if (supporting != null) {
            Text(
                supporting,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        content()
    }
}

/** The gap between [Section]s. */
val SectionSpacing = 28.dp

/** The gap between page-level [SettingsCategory] blocks. */
val CategorySpacing = 36.dp

/**
 * A page-level heading. Settings used to be a flat stack of identically
 * weighted [Section]s, so Speech, Keyboard and About all looked like peers of
 * a single switch. The category is the thing you scan for; sections sit inside.
 */
@Composable
fun SettingsCategory(
    title: String,
    modifier: Modifier = Modifier,
    supporting: String? = null,
    content: @Composable ColumnScope.() -> Unit,
) {
    Column(
        modifier = modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(16.dp),
        content = {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(title, style = MaterialTheme.typography.headlineSmall)
                if (supporting != null) {
                    Text(
                        supporting,
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
            content()
        },
    )
}

/**
 * A quiet grouping surface for a hero or a short cluster of related controls.
 *
 * [Section] stays on the page; this is for the one or two blocks that should
 * read as a unit (current speech source, recommended model).
 */
@Composable
fun FeaturedCard(
    modifier: Modifier = Modifier,
    content: @Composable ColumnScope.() -> Unit,
) {
    Surface(
        modifier = modifier.fillMaxWidth(),
        color = MaterialTheme.colorScheme.surfaceContainerLow,
        shape = MaterialTheme.shapes.large,
    ) {
        Column(
            Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
            content = content,
        )
    }
}

/** A tappable row that opens a settings sub-screen. */
@Composable
fun SettingsMenuRow(
    title: String,
    supporting: String,
    onClick: () -> Unit,
    @DrawableRes icon: Int,
    modifier: Modifier = Modifier,
) {
    Surface(
        modifier = modifier.fillMaxWidth(),
        color = MaterialTheme.colorScheme.surfaceContainerLow,
        shape = MaterialTheme.shapes.large,
        onClick = onClick,
    ) {
        Row(
            modifier = Modifier.padding(16.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Icon(
                painter = painterResource(icon),
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(24.dp),
            )
            Column(Modifier.weight(1f)) {
                Text(title, style = MaterialTheme.typography.titleMedium)
                Text(
                    supporting,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            Icon(
                painter = painterResource(R.drawable.ic_chevron),
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(24.dp),
            )
        }
    }
}

/** Title, detail and a switch, used for every boolean setting. */
@Composable
fun SettingToggle(
    title: String,
    detail: String,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .padding(vertical = 8.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(modifier = Modifier.weight(1f).padding(end = 12.dp)) {
            Text(title)
            Text(
                detail,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Switch(checked = checked, onCheckedChange = onCheckedChange)
    }
}

/**
 * An interruption: something the user has to read or act on before the screen
 * behaves normally — a blocked setting, a broken
 * step. These keep a container precisely because [Section] gave its up, so the
 * few things that genuinely need to stand out now can.
 */
@Composable
fun Notice(
    modifier: Modifier = Modifier,
    tone: NoticeTone = NoticeTone.Neutral,
    content: @Composable ColumnScope.() -> Unit,
) {
    val container = when (tone) {
        NoticeTone.Neutral -> MaterialTheme.colorScheme.surfaceContainerHigh
        NoticeTone.Attention -> MaterialTheme.colorScheme.errorContainer
    }
    Surface(
        modifier = modifier.fillMaxWidth(),
        color = container,
        shape = MaterialTheme.shapes.medium,
    ) {
        Column(
            Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
            content = content,
        )
    }
}

enum class NoticeTone { Neutral, Attention }

/** One line of the setup checklist: state, explanation, and the way to fix it. */
@Composable
fun ChecklistRow(
    title: String,
    detail: String,
    satisfied: Boolean,
    actionLabel: String,
    onAction: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier.fillMaxWidth().padding(vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            painter = painterResource(
                if (satisfied) R.drawable.ic_step_done else R.drawable.ic_step_pending
            ),
            contentDescription = if (satisfied) "Done" else "Not done yet",
            tint = if (satisfied) {
                MaterialTheme.colorScheme.primary
            } else {
                MaterialTheme.colorScheme.outline
            },
            modifier = Modifier.size(24.dp),
        )
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.bodyLarge)
            Text(
                detail,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        if (!satisfied) {
            TextButton(onClick = onAction) { Text(actionLabel) }
        }
    }
}

/**
 * A single-choice chip row, used for every enumerated setting.
 *
 * The chips carry their own fill rather than relying on an outline: the default
 * chip border was invisible in the dynamic dark scheme this app used to inherit,
 * which made unselected options read as loose words rather than something you
 * could tap. The palette is fixed now, so the fill is no longer load-bearing —
 * but it still tells a row of options apart from a row of labels at a glance,
 * and it is what the selected state contrasts against.
 *
 * [enabled] greys an option out rather than hiding it, so a choice that depends
 * on hardware — a microphone that is not plugged in — reads as "not right now"
 * instead of leaving the user hunting for a setting that appears to be missing.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun <T> SettingDropdown(
    options: List<T>,
    selected: T,
    label: (T) -> String,
    detail: (T) -> String,
    onSelect: (T) -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    optionEnabled: (T) -> Boolean = { true },
) {
    var expanded by remember { mutableStateOf(false) }
    ExposedDropdownMenuBox(
        expanded = expanded && enabled,
        onExpandedChange = { if (enabled) expanded = it },
        modifier = modifier.fillMaxWidth(),
    ) {
        OutlinedTextField(
            value = label(selected),
            onValueChange = {},
            readOnly = true,
            enabled = enabled,
            modifier = Modifier
                .fillMaxWidth()
                .menuAnchor(ExposedDropdownMenuAnchorType.PrimaryNotEditable, enabled),
            trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded && enabled) },
        )
        ExposedDropdownMenu(
            expanded = expanded && enabled,
            onDismissRequest = { expanded = false },
        ) {
            options.forEach { option ->
                DropdownMenuItem(
                    text = {
                        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                            Text(label(option))
                            val explanation = detail(option)
                            if (explanation.isNotBlank()) {
                                Text(
                                    explanation,
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                        }
                    },
                    onClick = {
                        onSelect(option)
                        expanded = false
                    },
                    enabled = optionEnabled(option),
                )
            }
        }
    }
}

/**
 * A compact filter. The chip shows the default label until a value is picked,
 * then the value. The menu is how M3 keeps a filter row from overflowing.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun <T> FilterChipMenu(
    unselectedLabel: String,
    options: List<T>,
    selected: T,
    label: (T) -> String,
    isDefault: (T) -> Boolean,
    onSelect: (T) -> Unit,
    modifier: Modifier = Modifier,
) {
    var expanded by remember { mutableStateOf(false) }
    Box(modifier) {
        FilterChip(
            selected = !isDefault(selected),
            onClick = { expanded = true },
            label = {
                // A chip that cannot fit its label should lose the end of it,
                // not set it one character per line and stretch the row.
                Text(
                    text = if (isDefault(selected)) unselectedLabel else label(selected),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            },
            trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded) },
            border = null,
            colors = FilterChipDefaults.filterChipColors(
                containerColor = MaterialTheme.colorScheme.surfaceVariant,
                labelColor = MaterialTheme.colorScheme.onSurface,
                selectedContainerColor = MaterialTheme.colorScheme.primary,
                selectedLabelColor = MaterialTheme.colorScheme.onPrimary,
                selectedTrailingIconColor = MaterialTheme.colorScheme.onPrimary,
            ),
        )
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            options.forEach { option ->
                DropdownMenuItem(
                    text = { Text(label(option)) },
                    onClick = {
                        onSelect(option)
                        expanded = false
                    },
                )
            }
        }
    }
}

@Composable
fun <T> ChipChoiceRow(
    options: List<T>,
    selected: T,
    label: (T) -> String,
    onSelect: (T) -> Unit,
    modifier: Modifier = Modifier,
    enabled: (T) -> Boolean = { true },
) {
    FlowRow(
        modifier = modifier.fillMaxWidth().selectableGroup(),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        options.forEach { option ->
            FilterChip(
                selected = option == selected,
                enabled = enabled(option),
                onClick = { onSelect(option) },
                label = { Text(label(option)) },
                border = null,
                // `surfaceVariant`, not `surface`: these used to sit inside a
                // `surfaceVariant` card, where a `surface` fill was the contrast.
                // Now they sit on the page, which *is* `surface`, so the fill has
                // to go the other way or the chips vanish.
                colors = FilterChipDefaults.filterChipColors(
                    containerColor = MaterialTheme.colorScheme.surfaceVariant,
                    labelColor = MaterialTheme.colorScheme.onSurface,
                    selectedContainerColor = MaterialTheme.colorScheme.primary,
                    selectedLabelColor = MaterialTheme.colorScheme.onPrimary,
                    // A disabled chip defaults to no fill at all, which drops it
                    // back to the loose-words problem the container solves. Keep
                    // the shape and dim only the label.
                    disabledContainerColor = MaterialTheme.colorScheme.surfaceVariant,
                    disabledLabelColor = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.38f),
                ),
            )
        }
    }
}

@Composable
fun EmptyState(message: String, modifier: Modifier = Modifier) {
    Column(
        modifier = modifier.fillMaxWidth().padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(
            message,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
        )
    }
}
