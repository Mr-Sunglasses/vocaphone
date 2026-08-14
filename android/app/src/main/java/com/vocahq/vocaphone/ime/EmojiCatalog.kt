package com.vocahq.vocaphone.ime

import android.content.res.AssetManager

internal enum class EmojiCategory(val id: String, val label: String, val icon: String) {
    RECENTS("recents", "Recents", "🕒"),
    SMILEYS("smileys", "Smileys", "😀"),
    PEOPLE("people", "People", "👋"),
    ANIMALS("animals", "Animals", "🐻"),
    FOOD("food", "Food", "🍔"),
    TRAVEL("travel", "Travel", "✈️"),
    ACTIVITIES("activities", "Activities", "⚽"),
    OBJECTS("objects", "Objects", "💡"),
    SYMBOLS("symbols", "Symbols", "🔣"),
    FLAGS("flags", "Flags", "🚩"),
    ;

    companion object {
        val browsable = entries.filter { it != RECENTS }
    }
}

internal data class EmojiEntry(
    val glyph: String,
    val category: String,
    val keywords: String,
)

internal object EmojiCatalog {
    fun parse(lines: Sequence<String>): List<EmojiEntry> = lines.mapNotNull { line ->
        val first = line.indexOf('\t')
        val second = if (first >= 0) line.indexOf('\t', first + 1) else -1
        if (first <= 0 || second <= first) return@mapNotNull null
        EmojiEntry(
            glyph = line.substring(0, first),
            category = line.substring(first + 1, second),
            keywords = line.substring(second + 1),
        )
    }.toList()

    fun load(assets: AssetManager): List<EmojiEntry> =
        assets.open("emoji/catalog.tsv").bufferedReader().use { reader ->
            parse(reader.lineSequence())
        }

    fun inCategory(entries: List<EmojiEntry>, category: EmojiCategory): List<EmojiEntry> {
        if (category == EmojiCategory.RECENTS) return emptyList()
        return entries.filter { it.category == category.id }
    }
}
