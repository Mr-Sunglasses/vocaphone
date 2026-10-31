package com.vocahq.vocaphone.ime

import android.view.HapticFeedbackConstants
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.vocahq.vocaphone.writing.WritingCategory
import com.vocahq.vocaphone.writing.WritingSuggestion

/** What the strip and the panel draw for Writing check. */
internal data class WritingStripState(
    val report: WritingCheckSession.Report?,
    val checking: Boolean,
    /** "teh → the" after an automatic typo fix, offered with Undo until the next edit. */
    val autoFixed: String? = null,
) {
    val count: Int get() = report?.count ?: 0
    val showsBadge: Boolean get() = count > 0 || checking || autoFixed != null
}

/** Grammarly's four colours: red, blue, green, purple, lightened for dark mode. */
internal object WritingColors {
    @Composable
    fun of(category: WritingCategory): Color {
        val dark = isSystemInDarkTheme()
        return when (category) {
            WritingCategory.CORRECTNESS -> if (dark) Color(0xFFFF8A80) else Color(0xFFD93025)
            WritingCategory.CLARITY -> if (dark) Color(0xFF8AB4F8) else Color(0xFF1A73E8)
            WritingCategory.ENGAGEMENT -> if (dark) Color(0xFF81C995) else Color(0xFF188038)
            WritingCategory.DELIVERY -> if (dark) Color(0xFFD7AEFB) else Color(0xFF8E24AA)
        }
    }

    fun name(category: WritingCategory): String = when (category) {
        WritingCategory.CORRECTNESS -> "Correctness"
        WritingCategory.CLARITY -> "Clarity"
        WritingCategory.ENGAGEMENT -> "Engagement"
        WritingCategory.DELIVERY -> "Delivery"
    }
}

/**
 * The count at the start of the strip, Grammarly's "G": how many suggestions
 * the field has, in the colour of the most serious one, or a spinner while
 * it checks. Tapping it opens the panel.
 */
@Composable
internal fun WritingBadge(state: WritingStripState, onClick: () -> Unit) {
    val view = LocalView.current
    val top = state.report?.suggestions?.minByOrNull { it.category.ordinal }?.category
    val color = top?.let { WritingColors.of(it) } ?: MaterialTheme.colorScheme.primary
    Box(
        modifier = Modifier
            .size(48.dp)
            .semantics {
                role = Role.Button
                contentDescription = when {
                    state.checking -> "Writing check, checking"
                    state.count == 1 -> "Writing check, 1 suggestion"
                    else -> "Writing check, ${state.count} suggestions"
                }
            }
            .clickable {
                view.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
                onClick()
            },
        contentAlignment = Alignment.Center,
    ) {
        Box(
            modifier = Modifier
                .size(30.dp)
                .clip(CircleShape)
                .background(if (state.count > 0) color else MaterialTheme.colorScheme.surfaceContainerHigh),
            contentAlignment = Alignment.Center,
        ) {
            when {
                state.checking && state.count == 0 -> CircularProgressIndicator(
                    modifier = Modifier.size(16.dp),
                    strokeWidth = 2.dp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                state.count > 0 -> Text(
                    text = if (state.count > 99) "99+" else "${state.count}",
                    color = Color.White,
                    fontSize = 13.sp,
                    fontWeight = FontWeight.Bold,
                )
                else -> Text("✓", color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 15.sp)
            }
        }
    }
}

/** Up to three fixes as chips: the words as typed, what they become, the group's colour. */
@Composable
internal fun RowScope.WritingChips(
    chips: List<WritingSuggestion>,
    onApply: (WritingSuggestion) -> Unit,
    onOpen: () -> Unit,
) {
    val view = LocalView.current
    Row(
        modifier = Modifier.weight(1f),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        chips.forEach { s ->
            Surface(
                modifier = Modifier
                    .weight(1f, fill = false)
                    .widthIn(max = 220.dp)
                    .height(32.dp)
                    .semantics {
                        role = Role.Button
                        contentDescription = "${s.title}: ${s.label}"
                    },
                shape = RoundedCornerShape(percent = 50),
                color = MaterialTheme.colorScheme.surfaceContainerHigh,
                onClick = {
                    view.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
                    onApply(s)
                },
            ) {
                Row(
                    modifier = Modifier.padding(horizontal = 10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    Box(
                        Modifier
                            .size(8.dp)
                            .clip(CircleShape)
                            .background(WritingColors.of(s.category)),
                    )
                    Text(
                        text = s.label,
                        fontSize = 14.sp,
                        fontWeight = FontWeight.Medium,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
        }
        if (chips.isEmpty()) {
            TextButton(onClick = onOpen) { Text("Review suggestions", maxLines = 1) }
        }
    }
}

/** "Fixed: teh → the", with Undo, after an automatic typo fix. */
@Composable
internal fun RowScope.AutoFixNotice(label: String, onUndo: () -> Unit) {
    Row(
        modifier = Modifier.weight(1f),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = "Fixed: $label",
            modifier = Modifier
                .weight(1f)
                .padding(start = 8.dp),
            fontSize = 14.sp,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        TextButton(onClick = onUndo) { Text("Undo") }
    }
}

/**
 * Grammarly's revision view: the keys give way to cards, each with its group,
 * the change (struck through, then the replacement), why, and Accept /
 * Ignore / Add to dictionary. The tone line and "Open in VocaPhone" close it.
 */
@Composable
internal fun WritingCheckPanel(
    state: WritingStripState,
    height: Dp,
    onApply: (WritingSuggestion) -> Unit,
    onDismiss: (WritingSuggestion) -> Unit,
    onAddWord: (WritingSuggestion) -> Unit,
    onRecheck: () -> Unit,
    onOpenApp: () -> Unit,
) {
    val report = state.report
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .height(height)
            .padding(horizontal = 8.dp, vertical = 4.dp),
    ) {
        val suggestions = report?.suggestions.orEmpty()
        if (suggestions.isEmpty()) {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .weight(1f),
                contentAlignment = Alignment.Center,
            ) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Text(
                        text = when {
                            state.checking -> "Checking…"
                            report == null -> "Nothing to check yet"
                            else -> "No issues found"
                        },
                        style = MaterialTheme.typography.titleSmall,
                    )
                    Text(
                        text = "Checked on this phone. Nothing you type is sent anywhere.",
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        fontSize = 12.sp,
                    )
                }
            }
        } else {
            LazyColumn(
                modifier = Modifier
                    .fillMaxWidth()
                    .weight(1f),
                contentPadding = PaddingValues(vertical = 2.dp),
                verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                items(suggestions, key = { "${it.kind}:${it.start}:${it.end}:${it.replacement}" }) { s ->
                    WritingCard(s, onApply, onDismiss, onAddWord)
                }
            }
        }
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = 40.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            val tones = report?.tones.orEmpty()
            Text(
                text = if (tones.isEmpty()) "" else "Sounds " + tones.joinToString(" · ") { "${it.emoji} ${it.label}" },
                modifier = Modifier.weight(1f),
                fontSize = 13.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            TextButton(onClick = onRecheck) { Text("Check again") }
            TextButton(onClick = onOpenApp) { Text("Open in app") }
        }
    }
}

@Composable
private fun WritingCard(
    s: WritingSuggestion,
    onApply: (WritingSuggestion) -> Unit,
    onDismiss: (WritingSuggestion) -> Unit,
    onAddWord: (WritingSuggestion) -> Unit,
) {
    val color = WritingColors.of(s.category)
    Surface(
        shape = RoundedCornerShape(12.dp),
        color = MaterialTheme.colorScheme.surfaceContainerHigh,
    ) {
        Column(Modifier.padding(start = 12.dp, end = 4.dp, top = 8.dp, bottom = 2.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(
                    Modifier
                        .size(8.dp)
                        .clip(CircleShape)
                        .background(color),
                )
                Spacer(Modifier.width(6.dp))
                Text(
                    text = "${WritingColors.name(s.category)} · ${s.title}",
                    fontSize = 12.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            val replacement = s.shownReplacement
            if (replacement != null) {
                Text(
                    text = buildAnnotatedString {
                        if (s.shownOriginal.isNotEmpty()) {
                            withStyle(SpanStyle(textDecoration = TextDecoration.LineThrough, color = MaterialTheme.colorScheme.onSurfaceVariant)) {
                                append(s.shownOriginal)
                            }
                            if (replacement.isNotEmpty()) append("  ")
                        }
                        if (replacement.isNotEmpty()) {
                            withStyle(SpanStyle(fontWeight = FontWeight.SemiBold, color = color)) { append(replacement) }
                        }
                    },
                    modifier = Modifier.padding(top = 4.dp),
                    fontSize = 16.sp,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            Text(
                text = s.message,
                modifier = Modifier.padding(top = 2.dp, end = 8.dp),
                fontSize = 13.sp,
                lineHeight = 17.sp,
            )
            Row(horizontalArrangement = Arrangement.spacedBy(0.dp)) {
                if (s.isActionable) TextButton(onClick = { onApply(s) }) { Text("Accept") }
                TextButton(onClick = { onDismiss(s) }) { Text("Ignore") }
                if (s.kind == "spelling" && s.shownOriginal.none(Char::isWhitespace)) {
                    TextButton(onClick = { onAddWord(s) }) { Text("Add to dictionary") }
                }
            }
        }
    }
}
