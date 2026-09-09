package com.vocahq.vocaphone.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.HorizontalDivider
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
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.vocahq.vocaphone.core.UsageStats

/**
 * Copy lives here so it can be asserted without a Compose test, matching how the
 * other screens in this package are checked.
 */
internal object StatsCopy {
    const val EMPTY =
        "Your dictation totals will appear here after your first dictation."

    const val RESET_TITLE = "Reset statistics?"
    const val RESET_BODY =
        "This permanently deletes your usage totals. Your transcripts are not affected."
    const val RESET_CONFIRM = "Reset"

    const val SPEED_CAPTION = "Speaking Speed"
    const val TOTALS_TITLE = "Lifetime totals"
    const val ACTIVITY_TITLE = "Recent activity"

    fun menuSupporting(stats: UsageStats, nowMillis: Long): String =
        if (!stats.hasAny) {
            "Words, speaking speed and streaks"
        } else {
            "${StatsFormat.count(stats.totalWords)} words · " +
                StatsFormat.streak(stats.currentStreakAt(nowMillis)) + " streak"
        }
}

@Composable
fun StatsPage(
    stats: UsageStats,
    nowMillis: Long,
    onReset: () -> Unit,
    modifier: Modifier = Modifier,
) {
    var confirmingReset by remember { mutableStateOf(false) }

    if (!stats.hasAny) {
        EmptyState(StatsCopy.EMPTY, modifier = modifier.fillMaxWidth())
        return
    }

    Column(
        modifier = modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(CardSpacing),
    ) {
        FeaturedCard {
            CardTitle(StatsCopy.TOTALS_TITLE)
            StatTileRow(
                tiles = listOf(
                    StatTile("Total words", StatsFormat.count(stats.totalWords)),
                    StatTile("Transcriptions", StatsFormat.count(stats.totalTranscriptions)),
                    StatTile("Total time", StatsFormat.duration(stats.totalAudioMillis)),
                ),
            )
        }

        StatPairRow(
            first = {
                CardTitle("Speed")
                BigNumber(
                    value = StatsFormat.wordsPerMinute(stats.averageWordsPerMinute),
                    unit = "WPM",
                    caption = StatsCopy.SPEED_CAPTION,
                )
            },
            second = {
                val streak = stats.currentStreakAt(nowMillis)
                CardTitle("Streak")
                BigNumber(
                    value = StatsFormat.count(streak.toLong()),
                    unit = if (streak == 1) "day" else "days",
                    caption = "Best: ${StatsFormat.streak(stats.bestStreak)}",
                )
            },
        )

        FeaturedCard {
            CardTitle(StatsCopy.ACTIVITY_TITLE)
            val days = StatsFormat.recentDays(stats)
            days.forEachIndexed { index, (key, words) ->
                InfoRow(
                    label = StatsFormat.dayLabel(key, nowMillis),
                    value = StatsFormat.words(words),
                )
                if (index != days.lastIndex) HorizontalDivider()
            }
        }

        DestructiveTextButton(
            text = "Reset statistics",
            onClick = { confirmingReset = true },
            modifier = Modifier.fillMaxWidth(),
        )
    }

    if (confirmingReset) {
        AlertDialog(
            onDismissRequest = { confirmingReset = false },
            title = { Text(StatsCopy.RESET_TITLE) },
            text = { Text(StatsCopy.RESET_BODY) },
            confirmButton = {
                DestructiveTextButton(
                    text = StatsCopy.RESET_CONFIRM,
                    onClick = {
                        onReset()
                        confirmingReset = false
                    },
                )
            },
            dismissButton = {
                TextButton(onClick = { confirmingReset = false }) { Text("Cancel") }
            },
        )
    }
}

internal data class StatTile(val label: String, val value: String)

private val CardSpacing = 16.dp

/**
 * Quieter than [Section]'s heading on purpose: the card's edge already does the
 * grouping a heading used to have to do alone, so the number can lead.
 */
@Composable
private fun CardTitle(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.labelLarge,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
}

/**
 * Two cards abreast, folding to a column when the text needs the width more
 * than the layout does.
 *
 * Uses the same rule as [StatTileRow] rather than a threshold of its own, so
 * the page has one folding behaviour and it is the one [AdaptiveLayout] already
 * has tests for.
 */
@Composable
private fun StatPairRow(
    first: @Composable ColumnScope.() -> Unit,
    second: @Composable ColumnScope.() -> Unit,
) {
    BoxWithConstraints(Modifier.fillMaxWidth()) {
        val stacked = AdaptiveLayout.stackActions(maxWidth.value, LocalDensity.current.fontScale)
        if (stacked) {
            Column(verticalArrangement = Arrangement.spacedBy(CardSpacing)) {
                FeaturedCard(content = first)
                FeaturedCard(content = second)
            }
        } else {
            Row(horizontalArrangement = Arrangement.spacedBy(CardSpacing)) {
                FeaturedCard(modifier = Modifier.weight(1f), content = first)
                FeaturedCard(modifier = Modifier.weight(1f), content = second)
            }
        }
    }
}

/**
 * Three across, folding to a column when the text needs the width more than the
 * layout does — the same rule the rest of the app uses rather than a new one.
 */
@Composable
private fun StatTileRow(tiles: List<StatTile>) {
    BoxWithConstraints(Modifier.fillMaxWidth()) {
        val stacked = AdaptiveLayout.stackActions(maxWidth.value, LocalDensity.current.fontScale)
        if (stacked) {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                tiles.forEach { tile ->
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clearAndSetSemantics {
                                contentDescription = "${tile.label}, ${tile.value}"
                            },
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(
                            tile.label,
                            style = MaterialTheme.typography.bodyLarge,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                        Text(tile.value, style = MaterialTheme.typography.headlineSmall)
                    }
                }
            }
        } else {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                tiles.forEach { tile ->
                    Column(
                        modifier = Modifier
                            .weight(1f)
                            .clearAndSetSemantics {
                                contentDescription = "${tile.label}, ${tile.value}"
                            },
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(4.dp),
                    ) {
                        Text(
                            tile.value,
                            style = MaterialTheme.typography.headlineSmall,
                            textAlign = TextAlign.Center,
                        )
                        Text(
                            tile.label,
                            style = MaterialTheme.typography.labelMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            textAlign = TextAlign.Center,
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun BigNumber(value: String, unit: String, caption: String) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 2.dp)
            .clearAndSetSemantics { contentDescription = "$value $unit. $caption" },
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Row(verticalAlignment = Alignment.Bottom) {
            Text(value, style = MaterialTheme.typography.headlineMedium)
            Text(
                " $unit",
                style = MaterialTheme.typography.titleSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(bottom = 4.dp),
            )
        }
        Text(
            caption,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}
