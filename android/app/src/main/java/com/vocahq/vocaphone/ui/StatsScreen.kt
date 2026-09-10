package com.vocahq.vocaphone.ui

import android.widget.Toast
import androidx.annotation.DrawableRes
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.vocahq.vocaphone.R
import com.vocahq.vocaphone.core.UsageStats

internal object StatsCopy {
    const val EMPTY = "Your dictation totals will appear here after your first dictation."
    const val RESET_TITLE = "Reset statistics?"
    const val RESET_BODY = "This permanently deletes your usage totals. Your transcripts are not affected."
    const val RESET_CONFIRM = "Reset"
    const val SPEED_CAPTION = "Speaking Speed"
    const val TOTALS_TITLE = "Your voice, at a glance"
    const val ACTIVITY_TITLE = "Recent activity"

    fun menuSupporting(stats: UsageStats, nowMillis: Long): String = if (!stats.hasAny) {
        "Words, speaking speed and streaks"
    } else {
        "${StatsFormat.count(stats.totalWords)} words · ${StatsFormat.streak(stats.currentStreakAt(nowMillis))} streak"
    }
}

@Composable
fun StatsPage(stats: UsageStats, nowMillis: Long, onReset: () -> Unit, modifier: Modifier = Modifier) {
    var confirmingReset by remember { mutableStateOf(false) }
    val context = LocalContext.current
    if (!stats.hasAny) {
        EmptyState(StatsCopy.EMPTY, modifier = modifier.fillMaxWidth())
        return
    }
    Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(20.dp)) {
        StatsHero(stats, nowMillis)
        MetricGrid(stats, nowMillis)
        ActivityCard(stats, nowMillis)
        ShareCard(
            onCopy = {
                val copied = StatsShareExporter.copyCard(context, stats, nowMillis)
                Toast.makeText(context, if (copied) "Stats card copied — paste it anywhere" else "Couldn’t copy stats card", Toast.LENGTH_SHORT).show()
            },
            onShare = { destination ->
                val result = StatsShareExporter.share(context, stats, nowMillis, destination)
                val message = when {
                    result.opened && result.cardCopied -> "Card copied — paste it into your ${destination.label} post"
                    result.opened -> "${destination.label} opened (card copy unavailable)"
                    result.cardCopied -> "Card copied, but ${destination.label} could not be opened"
                    else -> "Couldn’t open ${destination.label}"
                }
                Toast.makeText(context, message, Toast.LENGTH_SHORT).show()
            },
        )
        TextButton(
            onClick = { confirmingReset = true },
            modifier = Modifier.align(Alignment.CenterHorizontally),
            colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.error),
        ) { Text("Reset statistics") }
    }
    if (confirmingReset) {
        AlertDialog(
            onDismissRequest = { confirmingReset = false },
            title = { Text(StatsCopy.RESET_TITLE) },
            text = { Text(StatsCopy.RESET_BODY) },
            confirmButton = { TextButton(onClick = { onReset(); confirmingReset = false }) { Text(StatsCopy.RESET_CONFIRM) } },
            dismissButton = { TextButton(onClick = { confirmingReset = false }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun MetricGrid(stats: UsageStats, nowMillis: Long) {
    val cards = listOf(
        Metric(R.drawable.ic_snippets, "Words", StatsFormat.count(stats.totalWords), "lifetime", Color(0xFF79D8BF)),
        Metric(R.drawable.ic_dictation, "Sessions", StatsFormat.count(stats.totalTranscriptions), "dictations", Color(0xFF79D8BF)),
        Metric(R.drawable.ic_history, "Time", StatsFormat.duration(stats.totalAudioMillis), "recorded", Color(0xFFFFAC5C)),
        Metric(R.drawable.ic_stat_streak, "Streak", "${stats.currentStreakAt(nowMillis)}", "days · best ${stats.bestStreak}", Color(0xFFFFAC5C)),
    )
    BoxWithConstraints(Modifier.fillMaxWidth()) {
        val stacked = AdaptiveLayout.stackInfo(maxWidth.value, LocalDensity.current.fontScale)
        if (stacked) {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                cards.forEach { metric -> MetricCard(metric, Modifier.fillMaxWidth()) }
            }
        } else {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                cards.chunked(2).forEach { row ->
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        row.forEach { metric -> MetricCard(metric, Modifier.weight(1f)) }
                    }
                }
            }
        }
    }
}

private data class Metric(
    @param:DrawableRes val icon: Int,
    val label: String,
    val value: String,
    val caption: String,
    val accent: Color,
)

@Composable
private fun StatsHero(stats: UsageStats, nowMillis: Long) {
    val streak = stats.currentStreakAt(nowMillis)
    FeaturedCard {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            MetricIcon(R.drawable.ic_stats, MaterialTheme.colorScheme.primary)
            Text("DICTATION STATS", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.primary, fontWeight = FontWeight.Bold)
        }
        Text("Your voice, at a glance", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
        Text("${StatsFormat.count(stats.totalWords)} words captured", style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(StatsFormat.wordsPerMinute(stats.averageWordsPerMinute), style = MaterialTheme.typography.displaySmall, fontWeight = FontWeight.Bold)
            Text("WPM", modifier = Modifier.padding(bottom = 8.dp), color = MaterialTheme.colorScheme.onSurfaceVariant)
            Text("·", modifier = Modifier.padding(bottom = 8.dp), color = MaterialTheme.colorScheme.primary)
            Text("$streak-day streak", modifier = Modifier.padding(bottom = 8.dp), color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Text(StatsCopy.SPEED_CAPTION, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun MetricCard(metric: Metric, modifier: Modifier) {
    FeaturedCard(
        modifier.clearAndSetSemantics {
            contentDescription = "${metric.label}, ${metric.value}, ${metric.caption}"
        },
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            MetricIcon(metric.icon, metric.accent)
            Text(metric.label, style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Text(metric.value, style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis)
        Text(metric.caption, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun MetricIcon(@DrawableRes icon: Int, accent: Color) {
    Box(
        Modifier
            .size(34.dp)
            .background(accent.copy(alpha = 0.15f), RoundedCornerShape(11.dp)),
        contentAlignment = Alignment.Center,
    ) {
        Icon(painterResource(icon), contentDescription = null, tint = accent, modifier = Modifier.size(19.dp))
    }
}

@Composable
private fun ActivityCard(stats: UsageStats, nowMillis: Long) {
    FeaturedCard {
        Text(StatsCopy.ACTIVITY_TITLE, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
        val days = StatsFormat.recentDays(stats)
        val maxWords = days.maxOfOrNull { it.second }?.coerceAtLeast(1) ?: 1
        days.forEachIndexed { index, (key, words) ->
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Row(horizontalArrangement = Arrangement.SpaceBetween, modifier = Modifier.fillMaxWidth()) {
                    Text(StatsFormat.dayLabel(key, nowMillis), style = MaterialTheme.typography.bodyMedium)
                    Text(StatsFormat.words(words), style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.SemiBold)
                }
                Box(Modifier.fillMaxWidth().size(6.dp).background(MaterialTheme.colorScheme.surfaceVariant, RoundedCornerShape(4.dp))) {
                    Box(Modifier.fillMaxWidth(words.toFloat() / maxWords).size(6.dp).background(MaterialTheme.colorScheme.primary, RoundedCornerShape(4.dp)))
                }
            }
            if (index != days.lastIndex) HorizontalDivider(modifier = Modifier.padding(vertical = 4.dp))
        }
    }
}

@Composable
private fun ShareCard(onCopy: () -> Unit, onShare: (StatsShareDestination) -> Unit) {
    FeaturedCard {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            MetricIcon(R.drawable.ic_clipboard, MaterialTheme.colorScheme.primary)
            Column {
                Text("Share your progress", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
                Text("A polished card, ready to post", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        BoxWithConstraints(Modifier.fillMaxWidth()) {
            val stacked = AdaptiveLayout.stackInfo(maxWidth.value, LocalDensity.current.fontScale)
            val actions = listOf<@Composable (Modifier) -> Unit>(
                { actionModifier -> ShareAction(R.drawable.ic_clipboard, "Copy", MaterialTheme.colorScheme.primary, onCopy, actionModifier) },
                { actionModifier -> ShareAction(R.drawable.ic_social_x, "X", MaterialTheme.colorScheme.onSurface, { onShare(StatsShareDestination.X) }, actionModifier) },
                { actionModifier -> ShareAction(R.drawable.ic_social_linkedin, "LinkedIn", Color(0xFF4D9BE8), { onShare(StatsShareDestination.LINKEDIN) }, actionModifier) },
            )
            if (stacked) {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    actions.forEach { action -> action(Modifier.fillMaxWidth()) }
                }
            } else {
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    actions.forEach { action -> action(Modifier.weight(1f)) }
                }
            }
        }
        Text("Social shares attach the card when the app is installed; otherwise it is copied for the web composer.", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun ShareAction(
    @DrawableRes icon: Int,
    label: String,
    accent: Color,
    onClick: () -> Unit,
    modifier: Modifier,
) {
    Surface(
        onClick = onClick,
        modifier = modifier,
        shape = MaterialTheme.shapes.medium,
        color = accent.copy(alpha = 0.10f),
        contentColor = accent,
        border = BorderStroke(1.dp, accent.copy(alpha = 0.28f)),
    ) {
        Column(
            modifier = Modifier.padding(horizontal = 6.dp, vertical = 12.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Icon(painterResource(icon), contentDescription = null, modifier = Modifier.size(22.dp))
            Text(label, style = MaterialTheme.typography.labelMedium, maxLines = 1)
        }
    }
}
