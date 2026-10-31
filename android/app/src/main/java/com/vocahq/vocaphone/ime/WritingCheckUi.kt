package com.vocahq.vocaphone.ime

import android.view.HapticFeedbackConstants
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.vocahq.vocaphone.writing.WritingCategory
import com.vocahq.vocaphone.writing.WritingSuggestion
import kotlinx.coroutines.launch

/** What the strip and the panel draw for Writing check. */
internal data class WritingStripState(
    val report: WritingCheckSession.Report?,
    val checking: Boolean,
    /** "teh → the" after an automatic typo fix, offered with Undo until the next edit. */
    val autoFixed: String? = null,
) {
    val count: Int get() = report?.count ?: 0
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

    /** The colour of a fix: what the words become, and the Accept button. */
    @Composable
    fun fix(): Color = if (isSystemInDarkTheme()) Color(0xFF1FB89A) else Color(0xFF0B7A64)

    /** Text on [fix]: near-black on the bright dark-mode teal, white on the deep light one. */
    @Composable
    fun onFix(): Color = if (isSystemInDarkTheme()) Color(0xFF00201A) else Color.White

    /** The struck-through words. */
    @Composable
    fun removed(): Color = if (isSystemInDarkTheme()) Color(0xFFFF8A80) else Color(0xFFC5221F)

    /** The button's badge: the correctness red, solid in both themes so white reads on it. */
    @Composable
    fun badge(): Color = if (isSystemInDarkTheme()) Color(0xFFE5483D) else Color(0xFFD93025)

    fun name(category: WritingCategory): String = when (category) {
        WritingCategory.CORRECTNESS -> "Correctness"
        WritingCategory.CLARITY -> "Clarity"
        WritingCategory.ENGAGEMENT -> "Engagement"
        WritingCategory.DELIVERY -> "Delivery"
    }
}

/**
 * The Writing check button at the start of the strip, in every field it can
 * check: a ring to tap when nothing has been checked, a spinner while it
 * checks, the count in red when there is something to fix, a green tick when
 * there is not. Tapping it checks now and opens the panel.
 */
@Composable
internal fun WritingBadge(state: WritingStripState, onClick: () -> Unit) {
    val view = LocalView.current
    val accent = WritingColors.fix()
    val clean = state.report != null && state.count == 0
    Box(
        modifier = Modifier
            .size(44.dp)
            .semantics {
                role = Role.Button
                contentDescription = when {
                    state.checking -> "Writing check, checking"
                    state.count == 1 -> "Writing check, 1 suggestion"
                    state.count > 1 -> "Writing check, ${state.count} suggestions"
                    clean -> "Writing check, no suggestions"
                    else -> "Check writing"
                }
            }
            .clickable {
                view.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
                onClick()
            },
        contentAlignment = Alignment.Center,
    ) {
        AnimatedContent(
            targetState = when {
                state.count > 0 -> BadgeLook.COUNT
                state.checking -> BadgeLook.CHECKING
                clean -> BadgeLook.CLEAN
                else -> BadgeLook.IDLE
            },
            transitionSpec = { fadeIn(tween(160)) togetherWith fadeOut(tween(120)) },
            label = "writingBadge",
        ) { look ->
            when (look) {
                BadgeLook.COUNT -> Box(
                    modifier = Modifier
                        .size(30.dp)
                        .clip(CircleShape)
                        .background(WritingColors.badge()),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        text = if (state.count > 99) "99+" else "${state.count}",
                        color = Color.White,
                        fontSize = if (state.count > 9) 12.sp else 14.sp,
                        fontWeight = FontWeight.Bold,
                    )
                }
                BadgeLook.CHECKING -> CircularProgressIndicator(
                    modifier = Modifier.size(26.dp),
                    strokeWidth = 2.5.dp,
                    color = accent,
                    trackColor = accent.copy(alpha = 0.18f),
                )
                BadgeLook.CLEAN -> Canvas(Modifier.size(30.dp)) {
                    drawCircle(accent)
                    drawTick(Color.White, stroke = 2.4.dp.toPx(), inset = size.minDimension * 0.28f)
                }
                BadgeLook.IDLE -> Canvas(Modifier.size(30.dp)) {
                    val stroke = 2.dp.toPx()
                    drawCircle(accent, radius = (size.minDimension - stroke) / 2, style = Stroke(stroke))
                    drawTick(accent, stroke = 2.2.dp.toPx(), inset = size.minDimension * 0.3f)
                }
            }
        }
    }
}

private enum class BadgeLook { IDLE, CHECKING, COUNT, CLEAN }

/** A check mark inside the square, [inset] from each side. */
private fun DrawScope.drawTick(color: Color, stroke: Float, inset: Float) {
    val w = size.width - inset * 2
    val h = size.height - inset * 2
    val path = Path().apply {
        moveTo(inset + w * 0.05f, inset + h * 0.55f)
        lineTo(inset + w * 0.38f, inset + h * 0.85f)
        lineTo(inset + w * 0.95f, inset + h * 0.18f)
    }
    drawPath(path, color, style = Stroke(stroke, cap = StrokeCap.Round, join = StrokeJoin.Round))
}

/**
 * The nearest fix, as a two-line chip beside the words: what kind of fix
 * above, what the words become below. Tapping it applies it.
 */
@Composable
internal fun WritingFixChip(suggestion: WritingSuggestion, onApply: (WritingSuggestion) -> Unit) {
    val view = LocalView.current
    val replacement = suggestion.shownReplacement
    val main = when {
        replacement == null -> suggestion.title
        replacement.isEmpty() -> "Remove “${suggestion.shownOriginal}”"
        else -> replacement
    }
    Surface(
        modifier = Modifier
            .widthIn(min = 64.dp, max = 128.dp)
            .height(42.dp)
            .semantics {
                role = Role.Button
                contentDescription = "${suggestion.title}: ${suggestion.label}"
            },
        shape = RoundedCornerShape(12.dp),
        color = MaterialTheme.colorScheme.surfaceContainerHigh,
        onClick = {
            view.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
            onApply(suggestion)
        },
    ) {
        Column(
            modifier = Modifier.padding(horizontal = 10.dp),
            verticalArrangement = Arrangement.Center,
        ) {
            Text(
                text = suggestion.title,
                fontSize = 11.sp,
                lineHeight = 13.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                text = main,
                fontSize = 15.sp,
                lineHeight = 18.sp,
                fontWeight = FontWeight.SemiBold,
                color = WritingColors.fix(),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
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

/** The words around a suggestion, within its sentence, for the card. */
internal data class WritingContext(val before: String, val after: String)

/**
 * The rest of the sentence on each side of [s] in [text], at most [maxSide]
 * characters each, with "…" where it was cut. Line breaks end a sentence too.
 */
internal fun writingContext(text: String, s: WritingSuggestion, maxSide: Int = 60): WritingContext {
    val start = s.start.coerceIn(0, text.length)
    val end = s.end.coerceIn(start, text.length)
    var from = start
    while (from > 0) {
        val c = text[from - 1]
        if (c == '\n') break
        if (c in ".!?" && from < start && text[from].isWhitespace()) break
        from--
    }
    while (from < start && text[from].isWhitespace()) from++
    var to = end
    while (to < text.length) {
        val c = text[to]
        if (c == '\n') break
        to++
        if (c in ".!?" && (to == text.length || text[to].isWhitespace())) break
    }
    // The words' own surrounding spaces belong to the context: the card
    // shows the words trimmed.
    var before = text.substring(from, start) + s.original.takeWhile(Char::isWhitespace)
    var after = (s.original.takeLastWhile(Char::isWhitespace) + text.substring(end, to)).trimEnd()
    if (before.isBlank()) before = ""
    if (before.length > maxSide) {
        val cut = before.takeLast(maxSide)
        val space = cut.indexOf(' ')
        before = "…" + if (space in 0 until cut.length - 1) cut.substring(space + 1) else cut
    }
    if (after.length > maxSide) {
        val cut = after.take(maxSide)
        val space = cut.lastIndexOf(' ')
        after = (if (space > 0) cut.substring(0, space) else cut) + "…"
    }
    return WritingContext(before, after)
}

/**
 * Writing check in place of the keys, one suggestion at a time: what kind of
 * fix, the sentence with the words struck through and their replacement, why,
 * and Accept / Dismiss. Swipe or the arrows for the next; "⋯" for the rest.
 */
@Composable
internal fun WritingCheckPanel(
    state: WritingStripState,
    height: Dp,
    onApply: (WritingSuggestion) -> Unit,
    onDismiss: (WritingSuggestion) -> Unit,
    onAddWord: (WritingSuggestion) -> Unit,
    onAcceptAll: () -> Unit,
    onRecheck: () -> Unit,
    onOpenApp: () -> Unit,
) {
    val report = state.report
    val suggestions = report?.suggestions.orEmpty()
    val pager = rememberPagerState { suggestions.size }
    val scope = rememberCoroutineScope()
    var more by remember { mutableStateOf(false) }
    val current = suggestions.getOrNull(pager.currentPage.coerceAtMost(suggestions.lastIndex))
    LaunchedEffect(current?.key) { more = false }
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .height(height)
            .padding(horizontal = 10.dp, vertical = 4.dp),
    ) {
        Surface(
            modifier = Modifier
                .fillMaxWidth()
                .weight(1f),
            shape = RoundedCornerShape(18.dp),
            color = MaterialTheme.colorScheme.surfaceContainer,
        ) {
            when {
                suggestions.isNotEmpty() && report != null -> Column(Modifier.fillMaxSize()) {
                    HorizontalPager(
                        state = pager,
                        modifier = Modifier
                            .fillMaxWidth()
                            .weight(1f),
                        key = { suggestions.getOrNull(it)?.let { s -> "${s.kind}:${s.start}:${s.end}:${s.replacement}" } ?: it },
                    ) { page ->
                        suggestions.getOrNull(page)?.let { WritingCard(it, report.field.text) }
                    }
                    if (suggestions.size > 1) {
                        PagerControls(
                            page = pager.currentPage,
                            count = suggestions.size,
                            onPrevious = { scope.launch { pager.animateScrollToPage(pager.currentPage - 1) } },
                            onNext = { scope.launch { pager.animateScrollToPage(pager.currentPage + 1) } },
                        )
                    }
                }
                state.checking -> CheckingView()
                report != null -> CleanView(report)
                else -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Text(
                        "Type something to check it.",
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        fontSize = 14.sp,
                    )
                }
            }
        }
        Spacer(Modifier.height(8.dp))
        val acceptAll = suggestions.count { it.isActionable && it.mechanical }
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .height(44.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (more) {
                Row(
                    modifier = Modifier
                        .weight(1f)
                        .horizontalScroll(rememberScrollState()),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    if (current != null && current.kind == "spelling" && current.shownOriginal.none(Char::isWhitespace)) {
                        PillButton("Add to dictionary", filled = false) { onAddWord(current) }
                    }
                    if (acceptAll >= 2) PillButton("Accept all $acceptAll", filled = false) { onAcceptAll() }
                    PillButton("Check again", filled = false) {
                        more = false
                        onRecheck()
                    }
                    PillButton("Open in app", filled = false) { onOpenApp() }
                }
            } else {
                val enabled = current != null
                PillButton(
                    "Accept",
                    filled = true,
                    enabled = enabled && current?.isActionable == true,
                ) { current?.let(onApply) }
                Spacer(Modifier.width(8.dp))
                PillButton("Dismiss", filled = false, enabled = enabled) { current?.let(onDismiss) }
                Spacer(Modifier.weight(1f))
            }
            Spacer(Modifier.width(8.dp))
            MoreButton(open = more) { more = !more }
        }
    }
}

@Composable
private fun WritingCard(s: WritingSuggestion, text: String) {
    val color = WritingColors.of(s.category)
    val context = writingContext(text, s)
    val replacement = s.shownReplacement
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(horizontal = 16.dp, vertical = 12.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(
                modifier = Modifier
                    .size(18.dp)
                    .clip(CircleShape)
                    .background(color.copy(alpha = 0.2f)),
                contentAlignment = Alignment.Center,
            ) {
                Box(
                    Modifier
                        .size(8.dp)
                        .clip(CircleShape)
                        .background(color),
                )
            }
            Spacer(Modifier.width(8.dp))
            Text(
                text = s.title,
                fontSize = 13.sp,
                fontWeight = FontWeight.Medium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.semantics { contentDescription = "${WritingColors.name(s.category)}: ${s.title}" },
            )
        }
        Spacer(Modifier.height(8.dp))
        val removed = WritingColors.removed()
        val fix = WritingColors.fix()
        val muted = MaterialTheme.colorScheme.onSurfaceVariant
        Text(
            text = buildAnnotatedString {
                append(context.before)
                val first = s.shownOriginal.ifEmpty { replacement.orEmpty() }.firstOrNull()
                if (context.before.isNotEmpty() && !context.before.last().isWhitespace() && first?.isLetterOrDigit() == true) {
                    append(" ")
                }
                if (s.shownOriginal.isNotEmpty()) {
                    withStyle(
                        SpanStyle(
                            textDecoration = TextDecoration.LineThrough,
                            color = if (replacement == null) muted else removed,
                            fontWeight = FontWeight.SemiBold,
                        ),
                    ) { append(s.shownOriginal) }
                }
                if (!replacement.isNullOrEmpty()) {
                    if (s.shownOriginal.isNotEmpty()) append(" ")
                    withStyle(SpanStyle(color = fix, fontWeight = FontWeight.Bold)) { append(replacement) }
                }
                if (context.after.isNotEmpty() && !context.after.first().isWhitespace() &&
                    context.after.first().isLetterOrDigit()
                ) {
                    append(" ")
                }
                append(context.after)
            },
            fontSize = 18.sp,
            lineHeight = 24.sp,
            maxLines = 3,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.semantics {
                contentDescription = when {
                    replacement == null -> s.shownOriginal
                    replacement.isEmpty() -> "Remove ${s.shownOriginal}"
                    s.shownOriginal.isEmpty() -> "Add $replacement"
                    else -> "${s.shownOriginal} becomes $replacement"
                }
            },
        )
        Spacer(Modifier.height(6.dp))
        Text(
            text = s.message,
            fontSize = 14.sp,
            lineHeight = 19.sp,
            color = muted,
            maxLines = 3,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun PagerControls(page: Int, count: Int, onPrevious: () -> Unit, onNext: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 8.dp, vertical = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.End,
    ) {
        ArrowButton(left = true, enabled = page > 0, onClick = onPrevious)
        Text(
            text = "${page + 1} of $count",
            fontSize = 12.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(horizontal = 4.dp),
        )
        ArrowButton(left = false, enabled = page < count - 1, onClick = onNext)
    }
}

@Composable
private fun ArrowButton(left: Boolean, enabled: Boolean, onClick: () -> Unit) {
    val color = MaterialTheme.colorScheme.onSurfaceVariant
    Box(
        modifier = Modifier
            .size(36.dp)
            .clip(CircleShape)
            .semantics {
                role = Role.Button
                contentDescription = if (left) "Previous suggestion" else "Next suggestion"
            }
            .clickable(enabled = enabled, onClick = onClick)
            .alpha(if (enabled) 1f else 0.3f),
        contentAlignment = Alignment.Center,
    ) {
        Canvas(Modifier.size(12.dp)) {
            val x0 = if (left) size.width * 0.7f else size.width * 0.3f
            val x1 = if (left) size.width * 0.3f else size.width * 0.7f
            val path = Path().apply {
                moveTo(x0, 0f)
                lineTo(x1, size.height / 2)
                lineTo(x0, size.height)
            }
            drawPath(path, color, style = Stroke(2.dp.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round))
        }
    }
}

@Composable
private fun PillButton(label: String, filled: Boolean, enabled: Boolean = true, onClick: () -> Unit) {
    val view = LocalView.current
    Surface(
        modifier = Modifier
            .height(40.dp)
            .alpha(if (enabled) 1f else 0.4f),
        shape = RoundedCornerShape(percent = 50),
        color = if (filled) WritingColors.fix() else MaterialTheme.colorScheme.surfaceContainerHighest,
        contentColor = if (filled) WritingColors.onFix() else MaterialTheme.colorScheme.onSurface,
        enabled = enabled,
        onClick = {
            view.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
            onClick()
        },
    ) {
        Box(Modifier.padding(horizontal = 20.dp), contentAlignment = Alignment.Center) {
            Text(label, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, maxLines = 1)
        }
    }
}

@Composable
private fun MoreButton(open: Boolean, onClick: () -> Unit) {
    val color = MaterialTheme.colorScheme.onSurface
    Surface(
        modifier = Modifier
            .size(40.dp)
            .semantics { contentDescription = if (open) "Fewer actions" else "More actions" },
        shape = CircleShape,
        color = MaterialTheme.colorScheme.surfaceContainerHighest,
        onClick = onClick,
    ) {
        Canvas(Modifier.fillMaxSize()) {
            if (open) {
                val a = size.minDimension * 0.36f
                val b = size.minDimension * 0.64f
                drawLine(color, Offset(a, a), Offset(b, b), 2.dp.toPx(), StrokeCap.Round)
                drawLine(color, Offset(a, b), Offset(b, a), 2.dp.toPx(), StrokeCap.Round)
            } else {
                val r = 2.dp.toPx()
                val gap = 6.dp.toPx()
                for (i in -1..1) drawCircle(color, r, Offset(center.x + i * gap, center.y))
            }
        }
    }
}

/** Three dots rising in turn while the check runs. */
@Composable
private fun CheckingView() {
    val transition = rememberInfiniteTransition(label = "checking")
    val phase by transition.animateFloat(
        initialValue = 0f,
        targetValue = 3f,
        animationSpec = infiniteRepeatable(tween(1_200, easing = LinearEasing), RepeatMode.Restart),
        label = "phase",
    )
    val accent = WritingColors.fix()
    Column(
        modifier = Modifier.fillMaxSize(),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Canvas(Modifier.size(width = 56.dp, height = 24.dp)) {
            val r = 5.dp.toPx()
            for (i in 0..2) {
                val t = ((phase - i + 3f) % 3f).let { if (it < 1f) it else 0f }
                val lift = kotlin.math.sin(t * Math.PI).toFloat()
                drawCircle(
                    color = accent.copy(alpha = 0.45f + 0.55f * lift),
                    radius = r,
                    center = Offset(size.width / 2 + (i - 1) * 3.6f * r, size.height / 2 - lift * 5.dp.toPx()),
                )
            }
        }
        Spacer(Modifier.height(10.dp))
        Text("Checking your writing…", fontSize = 15.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/** Nothing left to fix: a tick among sparkles, and the tone if there is one. */
@Composable
private fun CleanView(report: WritingCheckSession.Report) {
    val accent = WritingColors.fix()
    val sparkle = MaterialTheme.colorScheme.onSurfaceVariant
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(horizontal = 16.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Canvas(Modifier.size(width = 96.dp, height = 64.dp)) {
            val c = Offset(size.width / 2, size.height / 2)
            val r = size.height * 0.36f
            drawCircle(accent.copy(alpha = 0.16f), radius = r * 1.35f, center = c)
            drawCircle(accent, radius = r, center = c)
            val tick = Path().apply {
                moveTo(c.x - r * 0.45f, c.y + r * 0.02f)
                lineTo(c.x - r * 0.1f, c.y + r * 0.36f)
                lineTo(c.x + r * 0.5f, c.y - r * 0.32f)
            }
            drawPath(tick, Color.White, style = Stroke(r * 0.18f, cap = StrokeCap.Round, join = StrokeJoin.Round))
            drawSparkle(Offset(size.width * 0.12f, size.height * 0.22f), 6.dp.toPx(), sparkle)
            drawSparkle(Offset(size.width * 0.88f, size.height * 0.3f), 5.dp.toPx(), accent)
            drawSparkle(Offset(size.width * 0.82f, size.height * 0.85f), 4.dp.toPx(), sparkle)
            drawSparkle(Offset(size.width * 0.2f, size.height * 0.82f), 3.5.dp.toPx(), accent)
        }
        Spacer(Modifier.height(10.dp))
        Text("Looking good!", fontSize = 17.sp, fontWeight = FontWeight.Bold)
        Text(
            "No more suggestions.",
            fontSize = 14.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        val tones = report.tones
        if (tones.isNotEmpty()) {
            Text(
                text = "Sounds " + tones.joinToString(" · ") { "${it.emoji} ${it.label}" },
                fontSize = 13.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.padding(top = 6.dp),
            )
        }
        Text(
            "Checked on this phone. Nothing you type is sent anywhere.",
            fontSize = 11.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f),
            textAlign = TextAlign.Center,
            modifier = Modifier.padding(top = 8.dp),
        )
    }
}

/** A four-pointed star centred on [c]. */
private fun DrawScope.drawSparkle(c: Offset, r: Float, color: Color) {
    val k = r * 0.28f
    val path = Path().apply {
        moveTo(c.x, c.y - r)
        quadraticTo(c.x + k * 0.3f, c.y - k * 0.3f, c.x + r, c.y)
        quadraticTo(c.x + k * 0.3f, c.y + k * 0.3f, c.x, c.y + r)
        quadraticTo(c.x - k * 0.3f, c.y + k * 0.3f, c.x - r, c.y)
        quadraticTo(c.x - k * 0.3f, c.y - k * 0.3f, c.x, c.y - r)
        close()
    }
    drawPath(path, color)
}
