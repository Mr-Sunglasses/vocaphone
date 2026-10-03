package com.vocahq.vocaphone.ui

import androidx.annotation.DrawableRes
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.RadioButton
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
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.vocahq.vocaphone.R

/**
 * The one way a settings page is built: named groups of rows in a rounded
 * container, a one-line footer under each, and nothing laid loose on the page.
 *
 * Settings used to mix four layouts — grouped rows on the home page, headings
 * and switches straight on the page below it, cards on Stats, a bare list in
 * History — and five ways to pick a value. Every page now draws from this file,
 * which is what Android's own Settings and the iOS app's inset grouped lists
 * have in common.
 */

/** The gap between groups on a page. */
val GroupSpacing = 24.dp

/** Row text starts here inside a group; headers and footers line up with it. */
private val RowInset = 16.dp

/**
 * A titled group. [footer] is one sentence; anything longer goes behind
 * [learnMore], which adds a "Learn more" link to the end of the footer.
 */
@Composable
fun SettingsGroup(
    modifier: Modifier = Modifier,
    title: String? = null,
    footer: String? = null,
    learnMore: LearnMore? = null,
    content: @Composable ColumnScope.() -> Unit,
) {
    var showingLearnMore by remember { mutableStateOf(false) }
    Column(modifier = modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (title != null) SettingsGroupHeader(title)
        Surface(
            modifier = Modifier.fillMaxWidth(),
            color = MaterialTheme.colorScheme.surfaceContainerLow,
            shape = MaterialTheme.shapes.large,
        ) {
            Column(content = content)
        }
        if (footer != null || learnMore != null) {
            SettingsFooter(
                text = footer,
                onLearnMore = learnMore?.let { { showingLearnMore = true } },
            )
        }
    }
    if (showingLearnMore && learnMore != null) {
        LearnMoreDialog(learnMore, onDismiss = { showingLearnMore = false })
    }
}

/** The one heading style on every settings page. */
@Composable
fun SettingsGroupHeader(title: String, modifier: Modifier = Modifier) {
    Text(
        title,
        style = MaterialTheme.typography.labelLarge,
        color = MaterialTheme.colorScheme.primary,
        modifier = modifier.padding(horizontal = RowInset),
    )
}

@Composable
private fun SettingsFooter(text: String?, onLearnMore: (() -> Unit)?) {
    Column(
        modifier = Modifier.fillMaxWidth().padding(horizontal = RowInset),
        verticalArrangement = Arrangement.spacedBy(0.dp),
    ) {
        if (text != null) {
            Text(
                text,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        if (onLearnMore != null) {
            Text(
                "Learn more",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.primary,
                modifier = Modifier
                    .clickable(role = Role.Button, onClick = onLearnMore)
                    .padding(vertical = 6.dp),
            )
        }
    }
}

@Composable
internal fun LearnMoreDialog(learnMore: LearnMore, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(learnMore.title) },
        text = {
            Column(
                modifier = Modifier.verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                learnMore.paragraphs.forEach { Text(it, style = MaterialTheme.typography.bodyMedium) }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("Done") } },
    )
}

/**
 * Hairline between rows of a group. [inset] lines it up with the row text:
 * past the icon when the rows have one.
 */
@Composable
fun SettingsDivider(inset: Boolean = false) {
    HorizontalDivider(
        modifier = Modifier.padding(start = if (inset) 56.dp else RowInset),
        color = MaterialTheme.colorScheme.outlineVariant,
    )
}

/** The shared row frame: optional icon, title, optional supporting line, trailing slot. */
@Composable
private fun SettingsRowFrame(
    title: String,
    modifier: Modifier = Modifier,
    supporting: String? = null,
    @DrawableRes icon: Int? = null,
    enabled: Boolean = true,
    titleColor: Color = MaterialTheme.colorScheme.onSurface,
    supportingMaxLines: Int = Int.MAX_VALUE,
    trailing: (@Composable () -> Unit)? = null,
) {
    val alpha = if (enabled) 1f else 0.38f
    Row(
        modifier = modifier
            .fillMaxWidth()
            .heightIn(min = 56.dp)
            .padding(horizontal = RowInset, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        if (icon != null) {
            Icon(
                painter = painterResource(icon),
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = alpha),
                modifier = Modifier.size(24.dp),
            )
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(
                title,
                style = MaterialTheme.typography.bodyLarge,
                color = titleColor.copy(alpha = alpha),
            )
            if (!supporting.isNullOrEmpty()) {
                Text(
                    supporting,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = alpha),
                    maxLines = supportingMaxLines,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        trailing?.invoke()
    }
}

/** Opens another page or sheet. `null` [onClick] makes a row that only states something. */
@Composable
fun SettingsNavRow(
    title: String,
    onClick: (() -> Unit)?,
    modifier: Modifier = Modifier,
    supporting: String? = null,
    @DrawableRes icon: Int? = null,
) {
    SettingsRowFrame(
        title = title,
        supporting = supporting,
        icon = icon,
        modifier = modifier.then(
            if (onClick != null) Modifier.clickable(role = Role.Button, onClick = onClick) else Modifier,
        ),
        trailing = if (onClick != null) {
            {
                Icon(
                    painter = painterResource(R.drawable.ic_chevron),
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(24.dp),
                )
            }
        } else {
            null
        },
    )
}

/** An on/off setting. The whole row toggles, not just the switch. */
@Composable
fun SettingsSwitchRow(
    title: String,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
    modifier: Modifier = Modifier,
    supporting: String? = null,
    @DrawableRes icon: Int? = null,
    enabled: Boolean = true,
) {
    SettingsRowFrame(
        title = title,
        supporting = supporting,
        icon = icon,
        enabled = enabled,
        modifier = modifier.toggleable(
            value = checked,
            enabled = enabled,
            role = Role.Switch,
            onValueChange = onCheckedChange,
        ),
        trailing = { Switch(checked = checked, onCheckedChange = null, enabled = enabled) },
    )
}

/**
 * A setting with one of several values. The row names the setting and shows
 * the current value; a tap opens a single-choice dialog. This replaces the
 * unlabelled dropdowns and chip rows the pages used to mix.
 */
@Composable
fun <T> SettingsChoiceRow(
    title: String,
    options: List<T>,
    selected: T,
    label: (T) -> String,
    onSelect: (T) -> Unit,
    modifier: Modifier = Modifier,
    /** Under the current value in the row. Defaults to the value itself. */
    supporting: String? = null,
    detail: (T) -> String = { "" },
    @DrawableRes icon: Int? = null,
    enabled: Boolean = true,
    optionEnabled: (T) -> Boolean = { true },
    /** A small action that belongs to the value, like Preview for a sound. */
    trailing: (@Composable () -> Unit)? = null,
) {
    var choosing by remember { mutableStateOf(false) }
    SettingsRowFrame(
        title = title,
        supporting = supporting ?: label(selected),
        icon = icon,
        enabled = enabled,
        modifier = modifier.clickable(
            enabled = enabled,
            role = Role.Button,
            onClick = { choosing = true },
        ),
        trailing = trailing,
    )
    if (choosing) {
        SettingsChoiceDialog(
            title = title,
            options = options,
            selected = selected,
            label = label,
            detail = detail,
            optionEnabled = optionEnabled,
            onSelect = {
                onSelect(it)
                choosing = false
            },
            onDismiss = { choosing = false },
        )
    }
}

@Composable
private fun <T> SettingsChoiceDialog(
    title: String,
    options: List<T>,
    selected: T,
    label: (T) -> String,
    detail: (T) -> String,
    optionEnabled: (T) -> Boolean,
    onSelect: (T) -> Unit,
    onDismiss: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = {
            Column(
                modifier = Modifier
                    .selectableGroup()
                    .verticalScroll(rememberScrollState()),
            ) {
                options.forEach { option ->
                    val enabled = optionEnabled(option)
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .heightIn(min = 48.dp)
                            .selectable(
                                selected = option == selected,
                                enabled = enabled,
                                role = Role.RadioButton,
                                onClick = { onSelect(option) },
                            )
                            .padding(vertical = 6.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        RadioButton(selected = option == selected, onClick = null, enabled = enabled)
                        Column(Modifier.weight(1f)) {
                            val alpha = if (enabled) 1f else 0.38f
                            Text(
                                label(option),
                                style = MaterialTheme.typography.bodyLarge,
                                color = MaterialTheme.colorScheme.onSurface.copy(alpha = alpha),
                            )
                            val explanation = detail(option)
                            if (explanation.isNotBlank()) {
                                Text(
                                    explanation,
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = alpha),
                                )
                            }
                        }
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

/** A command in a group: "Add snippet", "Copy diagnostics", "Delete all history". */
@Composable
fun SettingsActionRow(
    title: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    supporting: String? = null,
    @DrawableRes icon: Int? = null,
    destructive: Boolean = false,
    enabled: Boolean = true,
    /** Opens outside the app: marked so the tap is not a surprise. */
    external: Boolean = false,
) {
    SettingsRowFrame(
        title = title,
        supporting = supporting,
        icon = icon,
        enabled = enabled,
        titleColor = if (destructive) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.primary,
        modifier = modifier.clickable(enabled = enabled, role = Role.Button, onClick = onClick),
        trailing = if (external) {
            {
                Icon(
                    painter = painterResource(R.drawable.ic_open_external),
                    contentDescription = "Opens outside the app",
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(20.dp),
                )
            }
        } else {
            null
        },
    )
}

/** A label and a value, for read-only facts like the device table. */
@Composable
fun SettingsInfoRow(label: String, value: String, modifier: Modifier = Modifier) {
    InfoRow(
        label = label,
        value = value,
        modifier = modifier.padding(horizontal = RowInset, vertical = 8.dp),
    )
}

/** Free content inside a group, padded like a row: a text field, a sample, a meter. */
@Composable
fun SettingsGroupContent(
    modifier: Modifier = Modifier,
    content: @Composable ColumnScope.() -> Unit,
) {
    Column(
        modifier = modifier.fillMaxWidth().padding(RowInset),
        verticalArrangement = Arrangement.spacedBy(12.dp),
        content = content,
    )
}


/** A tappable row with no chevron: a list item that opens an editor. */
@Composable
fun SettingsTapRow(
    title: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    supporting: String? = null,
) {
    SettingsRowFrame(
        title = title,
        supporting = supporting,
        supportingMaxLines = 2,
        modifier = modifier.clickable(role = Role.Button, onClick = onClick),
    )
}
