package com.vocahq.vocaphone.ime

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.vocahq.vocaphone.settings.OneHandedMode

/**
 * Gboard's one-handed mode, decided apart from Compose so it can be tested.
 * Only a phone held upright gets it: on a tablet, a landscape phone or an
 * unfolded foldable the keys are already split or a thumb is not the limit.
 */
internal object OneHandedLayout {
    /** Share of the width the keys keep; the rest is the side strip. Gboard's is about this. */
    const val KEY_FRACTION = 0.82f

    /** sw600dp is where Android draws the line between phone and tablet. */
    const val MAX_PHONE_SMALLEST_WIDTH_DP = 600

    fun available(smallestWidthDp: Int, portrait: Boolean): Boolean =
        portrait && smallestWidthDp < MAX_PHONE_SMALLEST_WIDTH_DP

    fun active(mode: OneHandedMode, smallestWidthDp: Int, portrait: Boolean): Boolean =
        mode != OneHandedMode.OFF && available(smallestWidthDp, portrait)

    /** The menu tile: off goes to the right hand (the common one), either side goes off. */
    fun toggled(mode: OneHandedMode): OneHandedMode =
        if (mode == OneHandedMode.OFF) OneHandedMode.RIGHT else OneHandedMode.OFF

    fun otherSide(mode: OneHandedMode): OneHandedMode = when (mode) {
        OneHandedMode.LEFT -> OneHandedMode.RIGHT
        OneHandedMode.RIGHT -> OneHandedMode.LEFT
        OneHandedMode.OFF -> OneHandedMode.OFF
    }
}

/**
 * The key area pushed to one side, with the strip Gboard puts in the space
 * left over: move to the other side, and back to full width.
 */
@Composable
internal fun OneHandedFrame(
    mode: OneHandedMode,
    height: Dp,
    onSwitchSide: () -> Unit,
    onExpand: () -> Unit,
    content: @Composable () -> Unit,
) {
    if (mode == OneHandedMode.OFF) {
        content()
        return
    }
    Row(Modifier.fillMaxWidth().height(height), verticalAlignment = Alignment.CenterVertically) {
        if (mode == OneHandedMode.RIGHT) SideStrip(towardLeft = true, onSwitchSide, onExpand)
        Box(Modifier.weight(OneHandedLayout.KEY_FRACTION)) { content() }
        if (mode == OneHandedMode.LEFT) SideStrip(towardLeft = false, onSwitchSide, onExpand)
    }
}

@Composable
private fun androidx.compose.foundation.layout.RowScope.SideStrip(
    towardLeft: Boolean,
    onSwitchSide: () -> Unit,
    onExpand: () -> Unit,
) {
    Column(
        modifier = Modifier.weight(1f - OneHandedLayout.KEY_FRACTION),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(16.dp, Alignment.CenterVertically),
    ) {
        StripButton(description = "Full-width keyboard", onClick = onExpand) { tint ->
            // Two diagonal arrows apart: expand.
            Canvas(Modifier.size(20.dp)) {
                val w = size.width
                val stroke = 2.dp.toPx()
                drawLine(tint, Offset(w * 0.15f, w * 0.15f), Offset(w * 0.45f, w * 0.45f), stroke, StrokeCap.Round)
                drawLine(tint, Offset(w * 0.15f, w * 0.15f), Offset(w * 0.45f, w * 0.15f), stroke, StrokeCap.Round)
                drawLine(tint, Offset(w * 0.15f, w * 0.15f), Offset(w * 0.15f, w * 0.45f), stroke, StrokeCap.Round)
                drawLine(tint, Offset(w * 0.85f, w * 0.85f), Offset(w * 0.55f, w * 0.55f), stroke, StrokeCap.Round)
                drawLine(tint, Offset(w * 0.85f, w * 0.85f), Offset(w * 0.55f, w * 0.85f), stroke, StrokeCap.Round)
                drawLine(tint, Offset(w * 0.85f, w * 0.85f), Offset(w * 0.85f, w * 0.55f), stroke, StrokeCap.Round)
            }
        }
        StripButton(
            description = if (towardLeft) "Move keyboard left" else "Move keyboard right",
            onClick = onSwitchSide,
        ) { tint ->
            Canvas(Modifier.size(20.dp)) {
                val w = size.width
                val stroke = 2.dp.toPx()
                val tip = if (towardLeft) w * 0.3f else w * 0.7f
                val tail = if (towardLeft) w * 0.65f else w * 0.35f
                drawLine(tint, Offset(tail, w * 0.2f), Offset(tip, w * 0.5f), stroke, StrokeCap.Round)
                drawLine(tint, Offset(tip, w * 0.5f), Offset(tail, w * 0.8f), stroke, StrokeCap.Round)
            }
        }
    }
}

@Composable
private fun StripButton(description: String, onClick: () -> Unit, icon: @Composable (Color) -> Unit) {
    val tint = MaterialTheme.colorScheme.onSurfaceVariant
    Surface(
        modifier = Modifier
            .size(48.dp)
            .semantics {
                role = Role.Button
                contentDescription = description
            },
        shape = CircleShape,
        color = MaterialTheme.colorScheme.surfaceContainerHigh,
        onClick = onClick,
    ) {
        Box(contentAlignment = Alignment.Center) { icon(tint) }
    }
}
