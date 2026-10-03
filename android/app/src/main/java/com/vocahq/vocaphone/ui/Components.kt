package com.vocahq.vocaphone.ui

import androidx.annotation.DrawableRes
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.calculateStartPadding
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuAnchorType
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.layout.Layout
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

/**
 * Width decisions use the space a composable actually receives, not the device
 * model or a global screen bucket. Dividing by font scale makes the same layout
 * fold earlier when accessibility text needs more room.
 */
internal object AdaptiveLayout {
    private fun effectiveWidth(widthDp: Float, fontScale: Float): Float =
        widthDp / fontScale.coerceAtLeast(1f)

    fun stackActions(widthDp: Float, fontScale: Float): Boolean =
        effectiveWidth(widthDp, fontScale) < 360f

    fun stackInfo(widthDp: Float, fontScale: Float): Boolean =
        effectiveWidth(widthDp, fontScale) < 320f

    fun modelGridColumns(widthDp: Float, fontScale: Float): Int =
        if (effectiveWidth(widthDp, fontScale) < 400f) 1 else 2
}

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
        modifier = modifier.heightIn(min = ButtonHeight),
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
        modifier = modifier.heightIn(min = ButtonHeight),
    ) {
        ButtonLabel(text, loading)
    }
}

@Composable
fun DestructiveButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
) {
    FilledTonalButton(
        onClick = onClick,
        enabled = enabled,
        modifier = modifier.heightIn(min = ButtonHeight),
        colors = ButtonDefaults.filledTonalButtonColors(
            containerColor = MaterialTheme.colorScheme.errorContainer,
            contentColor = MaterialTheme.colorScheme.onErrorContainer,
        ),
    ) {
        Text(text)
    }
}

@Composable
fun DestructiveTextButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
) {
    TextButton(
        onClick = onClick,
        enabled = enabled,
        modifier = modifier,
        colors = ButtonDefaults.textButtonColors(
            contentColor = MaterialTheme.colorScheme.error,
        ),
    ) {
        Text(text)
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

/** A label and its value, stacked when narrow or enlarged text needs the room. */
@Composable
fun InfoRow(label: String, value: String, modifier: Modifier = Modifier) {
    BoxWithConstraints(modifier.fillMaxWidth().padding(vertical = 2.dp)) {
        val stacked = AdaptiveLayout.stackInfo(maxWidth.value, LocalDensity.current.fontScale)
        if (stacked) {
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                InfoLabel(label)
                Text(value, style = MaterialTheme.typography.bodyMedium)
            }
        } else {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                InfoLabel(label)
                Text(
                    value,
                    style = MaterialTheme.typography.bodyMedium,
                    textAlign = TextAlign.End,
                    modifier = Modifier.weight(1f),
                )
            }
        }
    }
}

@Composable
private fun InfoLabel(label: String) {
    Text(
        label,
        style = MaterialTheme.typography.bodyMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
}

/** Two actions share a row until either the available width or text scale says otherwise. */
@Composable
fun ResponsiveActionRow(
    leading: @Composable (Modifier) -> Unit,
    trailing: @Composable (Modifier) -> Unit,
    modifier: Modifier = Modifier,
    leadingWeight: Float = 1f,
    trailingWeight: Float = 1f,
) {
    BoxWithConstraints(modifier.fillMaxWidth()) {
        val stacked = AdaptiveLayout.stackActions(maxWidth.value, LocalDensity.current.fontScale)
        if (stacked) {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                leading(Modifier.fillMaxWidth())
                trailing(Modifier.fillMaxWidth())
            }
        } else {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                leading(Modifier.weight(leadingWeight))
                trailing(Modifier.weight(trailingWeight))
            }
        }
    }
}

/** Keeps app pages readable on unfolded foldables and wide landscape phones. */
val AppContentMaxWidth = 720.dp

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
        // A card on the page, one step lighter than it, like a settings group.
        NoticeTone.Neutral -> MaterialTheme.colorScheme.surfaceContainerLow
        NoticeTone.Attention -> MaterialTheme.colorScheme.errorContainer
        NoticeTone.Warning -> MaterialTheme.colorScheme.tertiaryContainer
    }
    val onContainer = when (tone) {
        NoticeTone.Neutral -> MaterialTheme.colorScheme.onSurface
        NoticeTone.Attention -> MaterialTheme.colorScheme.onErrorContainer
        NoticeTone.Warning -> MaterialTheme.colorScheme.onTertiaryContainer
    }
    Surface(
        modifier = modifier.fillMaxWidth(),
        color = container,
        contentColor = onContainer,
        shape = MaterialTheme.shapes.medium,
    ) {
        Column(
            Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
            content = content,
        )
    }
}

enum class NoticeTone { Neutral, Attention, Warning }

/** One line of the setup checklist: state, explanation, and the way to fix it. */
@Composable
fun ChecklistRow(
    title: String,
    detail: String,
    satisfied: Boolean,
    actionLabel: String,
    onAction: () -> Unit,
    modifier: Modifier = Modifier,
    actionColor: Color = MaterialTheme.colorScheme.primary,
    /**
     * Compact rows keep title + check only. Used for satisfied steps and for
     * unfinished steps that are not the current spotlight target.
     */
    compact: Boolean = false,
) {
    // Beside the text when the action is short enough, under it when it is
    // not. This was a Row with the text on weight(1f), and Compose measures
    // the weighted child last: at a 1.5x font "Enable keyboard" took nearly
    // the whole width first and the explanation was set one letter per line.
    // Stacking every row under 400 dp looked broken on ordinary handsets, so
    // the switch is made on the action's own width, not the screen's.
    val showAction = !satisfied && !compact
    Layout(
        modifier = modifier.fillMaxWidth().padding(vertical = 6.dp),
        content = {
            ChecklistContent(
                title = title,
                detail = detail,
                satisfied = satisfied,
                compact = compact,
            )
            if (showAction) {
                TextButton(
                    onClick = onAction,
                    colors = ButtonDefaults.textButtonColors(contentColor = actionColor),
                ) { Text(actionLabel) }
            }
        },
    ) { measurables, constraints ->
        val width = constraints.maxWidth
        val loose = constraints.copy(minWidth = 0, minHeight = 0)
        val content = measurables[0]
        val action = measurables.getOrNull(1)
        if (action == null) {
            val placed = content.measure(loose.copy(minWidth = width))
            return@Layout layout(width, placed.height) { placed.placeRelative(0, 0) }
        }
        if (action.maxIntrinsicWidth(constraints.maxHeight) <= width * ChecklistActionShare) {
            val button = action.measure(loose)
            val text = content.measure(
                loose.copy(minWidth = width - button.width, maxWidth = width - button.width),
            )
            val height = maxOf(text.height, button.height)
            layout(width, height) {
                // placeRelative mirrors in RTL: action on the left, text on the right.
                text.placeRelative(0, (height - text.height) / 2)
                button.placeRelative(width - button.width, (height - button.height) / 2)
            }
        } else {
            // Under the title, its label lined up with the title's first letter.
            val textStart = (ChecklistIconSize + ChecklistIconGap).roundToPx()
            val buttonInset = ButtonDefaults.TextButtonContentPadding
                .calculateStartPadding(layoutDirection)
                .roundToPx()
            val buttonX = (textStart - buttonInset).coerceAtLeast(0)
            val text = content.measure(loose.copy(minWidth = width, maxWidth = width))
            val button = action.measure(loose.copy(maxWidth = width - buttonX))
            layout(width, text.height + button.height) {
                text.placeRelative(0, 0)
                button.placeRelative(buttonX, text.height)
            }
        }
    }
}

/** Widest the action may be and still sit beside the text. */
private const val ChecklistActionShare = 0.4f
private val ChecklistIconSize = 24.dp
private val ChecklistIconGap = 12.dp

@Composable
private fun ChecklistContent(
    title: String,
    detail: String,
    satisfied: Boolean,
    compact: Boolean,
    modifier: Modifier = Modifier,
) {
    Row(modifier = modifier, verticalAlignment = Alignment.CenterVertically) {
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
            modifier = Modifier.size(ChecklistIconSize),
        )
        Spacer(Modifier.width(ChecklistIconGap))
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.bodyLarge)
            if (!compact && detail.isNotEmpty()) {
                Text(
                    detail,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = if (satisfied) {
                        Modifier.semantics { liveRegion = LiveRegionMode.Polite }
                    } else {
                        Modifier
                    },
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
