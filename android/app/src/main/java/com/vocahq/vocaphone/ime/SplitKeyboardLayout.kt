package com.vocahq.vocaphone.ime

import com.vocahq.vocaphone.settings.SplitKeyboard

/**
 * Split layout for a too-wide IME window: keep key order, drop a dead spacer
 * near mid-row, and turn the spacebar into two space keys so each thumb can
 * reach one.
 *
 * The spacer fraction is HeliBoard's auto formula, `(widthDp - 600) / 600 + 0.15`
 * clamped to 15-35% of the keyboard width. Auto itself turns on at 600 dp
 * (sw600dp / a typical unfolded fold inner). One-handed mode is a different
 * feature and is not handled here.
 */
internal object SplitKeyboardLayout {
    const val AUTO_MIN_WIDTH_DP = 600
    const val MIN_SPACER_FRACTION = 0.15f
    const val MAX_SPACER_FRACTION = 0.35f

    fun shouldSplit(mode: SplitKeyboard, widthDp: Int): Boolean = when (mode) {
        SplitKeyboard.ALWAYS -> true
        SplitKeyboard.NEVER -> false
        SplitKeyboard.AUTO -> widthDp >= AUTO_MIN_WIDTH_DP
    }

    fun spacerFraction(widthDp: Int): Float =
        ((widthDp - AUTO_MIN_WIDTH_DP) / AUTO_MIN_WIDTH_DP.toFloat() + MIN_SPACER_FRACTION)
            .coerceIn(MIN_SPACER_FRACTION, MAX_SPACER_FRACTION)

    /** Weight that makes [fraction] of the finished row, given the key weights. */
    fun spacerWeight(keyWeightSum: Float, fraction: Float): Float {
        val clamped = fraction.coerceIn(MIN_SPACER_FRACTION, MAX_SPACER_FRACTION)
        return clamped / (1f - clamped) * keyWeightSum
    }

    /**
     * Index of the first key that starts at or past the row's midpoint, so the
     * spacer sits near the center without reordering keys.
     */
    fun insertIndex(weights: List<Float>): Int {
        if (weights.size <= 1) return weights.size
        val half = weights.sum() / 2f
        var before = 0f
        for (index in weights.indices) {
            if (before >= half) return index
            before += weights[index]
        }
        return weights.size / 2
    }

    fun splitRow(row: KeyboardRow, spacerFraction: Float): SplitRow {
        val spaceIndex = row.keys.indexOfFirst { it.type == KeyboardKeyType.SPACE }
        val items = if (spaceIndex >= 0) {
            splitSpaceRow(row.keys, spaceIndex, spacerFraction)
        } else {
            splitLetterRow(row.keys, spacerFraction)
        }
        return SplitRow(items, row.leadingSpace, row.trailingSpace)
    }

    private fun splitLetterRow(keys: List<KeyboardKey>, spacerFraction: Float): List<SplitItem> {
        val insertAt = insertIndex(keys.map { it.weight })
        val gap = spacerWeight(keys.sumOf { it.weight.toDouble() }.toFloat(), spacerFraction)
        return buildList {
            keys.take(insertAt).forEach { add(SplitItem.Key(it)) }
            add(SplitItem.Gap(gap))
            keys.drop(insertAt).forEach { add(SplitItem.Key(it)) }
        }
    }

    private fun splitSpaceRow(
        keys: List<KeyboardKey>,
        spaceIndex: Int,
        spacerFraction: Float,
    ): List<SplitItem> {
        val space = keys[spaceIndex]
        val half = (space.weight / 2f).coerceAtLeast(0.7f)
        val left = keys.take(spaceIndex)
        val right = keys.drop(spaceIndex + 1)
        val keyWeightSum = left.sumOf { it.weight.toDouble() }.toFloat() +
            half * 2f +
            right.sumOf { it.weight.toDouble() }.toFloat()
        return buildList {
            left.forEach { add(SplitItem.Key(it)) }
            add(SplitItem.Key(space.copy(id = "${space.id}$LEFT_SUFFIX", weight = half)))
            add(SplitItem.Gap(spacerWeight(keyWeightSum, spacerFraction)))
            add(SplitItem.Key(space.copy(id = "${space.id}$RIGHT_SUFFIX", weight = half)))
            right.forEach { add(SplitItem.Key(it)) }
        }
    }

    /** Half of a split spacebar. The wordmark stays off these so it is not painted twice. */
    fun isSplitSpace(key: KeyboardKey): Boolean =
        key.type == KeyboardKeyType.SPACE &&
            (key.id.endsWith(LEFT_SUFFIX) || key.id.endsWith(RIGHT_SUFFIX))

    private const val LEFT_SUFFIX = "-left"
    private const val RIGHT_SUFFIX = "-right"
}

internal data class SplitRow(
    val items: List<SplitItem>,
    val leadingSpace: Float,
    val trailingSpace: Float,
)

internal sealed class SplitItem {
    data class Key(val key: KeyboardKey) : SplitItem()
    data class Gap(val weight: Float) : SplitItem()
}
