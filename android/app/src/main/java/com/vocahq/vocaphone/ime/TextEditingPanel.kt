package com.vocahq.vocaphone.ime

import android.view.HapticFeedbackConstants
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.waitForUpOrCancellation
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * Gboard's text-editing panel, in the key area's place: arrows with Select
 * in the middle, Home/End, undo/redo, and select all / cut / copy / paste
 * down the side. It replaces the keys rather than adding a row, so it costs
 * no height; ABC goes back to the keys.
 *
 * Arrows repeat while held at the delete key's rhythm ([DeleteHold]).
 */
@Composable
internal fun TextEditingPanel(
    height: Dp,
    hapticsOn: () -> Boolean,
    onEdit: (TextEditAction, Boolean) -> Unit,
    onDelete: () -> Unit,
    onClose: () -> Unit,
) {
    var selecting by remember { mutableStateOf(false) }
    val currentSelecting = rememberUpdatedState(selecting)
    val send: (TextEditAction) -> Unit = { action ->
        onEdit(action, currentSelecting.value)
        // A clipboard or history action ends a selection, as in Gboard.
        if (TextEditing.contextMenuId(action) != null && action != TextEditAction.SELECT_ALL) selecting = false
    }
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .height(height)
            .padding(horizontal = 4.dp, vertical = 2.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        EditRow {
            EditButton("Undo", "Undo", hapticsOn, onPress = { send(TextEditAction.UNDO) })
            EditButton("↑", "Up", hapticsOn, repeat = true, onPress = { send(TextEditAction.UP) })
            EditButton("Redo", "Redo", hapticsOn, onPress = { send(TextEditAction.REDO) })
            EditButton("Select all", "Select all", hapticsOn, onPress = { send(TextEditAction.SELECT_ALL) })
        }
        EditRow {
            EditButton("←", "Left", hapticsOn, repeat = true, onPress = { send(TextEditAction.LEFT) })
            EditButton(
                "Select",
                if (selecting) "Stop selecting" else "Select",
                hapticsOn,
                active = selecting,
                onPress = { selecting = !selecting },
            )
            EditButton("→", "Right", hapticsOn, repeat = true, onPress = { send(TextEditAction.RIGHT) })
            EditButton("Cut", "Cut", hapticsOn, onPress = { send(TextEditAction.CUT) })
        }
        EditRow {
            EditButton("⇤", "Start of line", hapticsOn, onPress = { send(TextEditAction.HOME) })
            EditButton("↓", "Down", hapticsOn, repeat = true, onPress = { send(TextEditAction.DOWN) })
            EditButton("⇥", "End of line", hapticsOn, onPress = { send(TextEditAction.END) })
            EditButton("Copy", "Copy", hapticsOn, onPress = { send(TextEditAction.COPY) })
        }
        EditRow {
            EditButton("ABC", "Back to the keys", hapticsOn, onPress = onClose)
            EditButton("⌫", "Delete", hapticsOn, weight = 2f, repeat = true, onPress = onDelete)
            EditButton("Paste", "Paste", hapticsOn, onPress = { send(TextEditAction.PASTE) })
        }
    }
}

@Composable
private fun androidx.compose.foundation.layout.ColumnScope.EditRow(content: @Composable RowScope.() -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .weight(1f),
        horizontalArrangement = Arrangement.spacedBy(4.dp),
        content = content,
    )
}

@Composable
private fun RowScope.EditButton(
    label: String,
    description: String,
    hapticsOn: () -> Boolean,
    weight: Float = 1f,
    repeat: Boolean = false,
    active: Boolean = false,
    onPress: () -> Unit,
) {
    val view = LocalView.current
    val currentOnPress = rememberUpdatedState(onPress)
    var pressed by remember { mutableStateOf(false) }
    val base = if (active) MaterialTheme.colorScheme.primaryContainer else MaterialTheme.colorScheme.surfaceContainerHigh
    Surface(
        modifier = Modifier
            .weight(weight)
            .fillMaxHeight()
            .semantics {
                role = Role.Button
                contentDescription = description
                if (active) selected = true
                onClick {
                    currentOnPress.value()
                    true
                }
            }
            .pointerInput(repeat) {
                coroutineScope {
                    awaitEachGesture {
                        val down = awaitFirstDown()
                        down.consume()
                        pressed = true
                        if (hapticsOn()) view.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
                        currentOnPress.value()
                        val repeater = if (repeat) {
                            launch {
                                delay(DeleteHold.REPEAT_DELAY_MS)
                                while (isActive) {
                                    currentOnPress.value()
                                    delay(DeleteHold.CHAR_INTERVAL_MS)
                                }
                            }
                        } else {
                            null
                        }
                        try {
                            waitForUpOrCancellation()
                        } finally {
                            repeater?.cancel()
                            pressed = false
                        }
                    }
                }
            },
        shape = RoundedCornerShape(8.dp),
        color = if (pressed) base.copy(alpha = 0.72f) else base,
        contentColor = if (active) MaterialTheme.colorScheme.onPrimaryContainer else MaterialTheme.colorScheme.onSurface,
    ) {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Text(
                text = label,
                fontSize = if (label.length <= 2) 20.sp else 14.sp,
                fontWeight = FontWeight.Medium,
                textAlign = TextAlign.Center,
                maxLines = 1,
            )
        }
    }
}
