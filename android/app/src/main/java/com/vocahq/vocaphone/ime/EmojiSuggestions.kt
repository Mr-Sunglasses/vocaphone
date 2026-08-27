package com.vocahq.vocaphone.ime

import android.content.res.AssetManager
import java.io.File

/**
 * Emoji offered for a word as it is typed: "lol" offers 😂, "flamingo" 🦩.
 *
 * Not a lookup into [EmojiCatalog]. The catalog's keywords exist for a
 * deliberate search in the emoji panel. Matched against ordinary prose they
 * answer "the" with 🤣, "dog" with 💩, and "clock" with 🏫.
 *
 * The strip table is `assets/keyboard/emoji/suggestions.tsv`, generated
 * from Unicode names, CLDR spoken names, and a short curated override
 * list. Function words stay off it. Distinctive names cover most of the
 * catalog; `lol` and `dog` → 🐶 are overrides because Unicode does not
 * call them that.
 *
 * Exact whole words first. A unique, almost-finished prefix (`pizz` → pizza)
 * and a unique one-letter insert or delete (`piza` → pizza) are the only
 * fuzzy paths, and only when they collapse to a single glyph. Substitution
 * is out: `read` is one edit from `dead`, and offering 💀 for "read" is
 * the strip crying wolf.
 */
internal object EmojiSuggestions {
    const val MINIMUM_LENGTH = 2

    /** Prefix and insert/delete matching start here. Three letters are too ambiguous. */
    const val FUZZY_MIN_LENGTH = 4

    /**
     * How much of the trigger may still be untyped for a prefix to count.
     * `pizz` (one short of pizza) is a finish; `read` (three short of reading)
     * is just the word "read".
     */
    const val PREFIX_SLACK = 2

    fun glyph(word: String): String? = glyphs(word).firstOrNull()

    fun glyphs(word: String): List<String> {
        val key = word.lowercase()
        if (key.length < MINIMUM_LENGTH) return emptyList()
        val primary = resolvePrimary(key) ?: return emptyList()
        return (listOf(primary) + EXTRAS[primary].orEmpty()).distinct()
    }

    private fun resolvePrimary(key: String): String? {
        TRIGGERS[key]?.let { return it }
        if (key.length < FUZZY_MIN_LENGTH) return null

        val prefixGlyphs = LinkedHashSet<String>()
        for ((trigger, glyph) in TRIGGERS) {
            if (
                trigger.length > key.length &&
                trigger.startsWith(key) &&
                key.length >= trigger.length - PREFIX_SLACK
            ) {
                prefixGlyphs.add(glyph)
                if (prefixGlyphs.size > 1) return null
            }
        }
        if (prefixGlyphs.size == 1) return prefixGlyphs.first()
        if (prefixGlyphs.isNotEmpty()) return null

        val fuzzyGlyphs = LinkedHashSet<String>()
        val scratch = SuggestionEngine.EditDistanceScratch(key.length + 1)
        for ((trigger, glyph) in TRIGGERS) {
            if (kotlin.math.abs(trigger.length - key.length) != 1) continue
            // A leading extra letter is how "they" becomes "hey". Trailing or
            // mid-word inserts are typos of the trigger itself (`piza` / `pizza`).
            if (isLeadingExtraLetter(key, trigger)) continue
            if (SuggestionEngine.editDistance(key, trigger, max = 1, scratch = scratch) != 1) continue
            fuzzyGlyphs.add(glyph)
            if (fuzzyGlyphs.size > 1) return null
        }
        return fuzzyGlyphs.singleOrNull()
    }

    private fun isLeadingExtraLetter(left: String, right: String): Boolean {
        val (shorter, longer) = if (left.length < right.length) left to right else right to left
        return longer.length == shorter.length + 1 && longer.endsWith(shorter)
    }

    /**
     * Word → glyph. Production fills this from assets in [load]. JVM tests
     * that never call [load] pick up the same file by walking up to the
     * repository root on first read, so the object's init does no I/O.
     */
    @Volatile
    private var table: Map<String, String> = emptyMap()

    val TRIGGERS: Map<String, String>
        get() {
            val current = table
            if (current.isNotEmpty()) return current
            val discovered = discoverFromRepository()
            if (discovered.isNotEmpty()) table = discovered
            return table
        }

    fun parse(text: String): Map<String, String> {
        val parsed = LinkedHashMap<String, String>()
        for (line in text.lineSequence()) {
            if (line.isEmpty() || line.startsWith("#")) continue
            val tab = line.indexOf('\t')
            if (tab <= 0) continue
            val word = line.substring(0, tab).lowercase()
            val glyph = line.substring(tab + 1)
            if (word.isEmpty() || glyph.isEmpty()) continue
            parsed.putIfAbsent(word, glyph)
        }
        return parsed
    }

    fun load(assets: AssetManager) {
        table = assets.open("emoji/suggestions.tsv").bufferedReader().use { reader ->
            parse(reader.readText())
        }
    }

    private fun discoverFromRepository(): Map<String, String> {
        val file = generateSequence(File("").absoluteFile) { it.parentFile }
            .map { File(it, "assets/keyboard/emoji/suggestions.tsv") }
            .firstOrNull(File::isFile)
            ?: return emptyMap()
        return parse(file.readText())
    }

    // Related chips, keyed by the primary glyph so every alias shares them.
    private val EXTRAS: Map<String, List<String>> = mapOf(
        "😢" to listOf("😭", "😞"),
        "😊" to listOf("😄", "😁"),
        "😭" to listOf("😢"),
        "❤️" to listOf("💕", "😍"),
        "😠" to listOf("😡"),
        "😂" to listOf("🤣"),
        "💀" to listOf("☠️"),
    )
}

/** Replace the trigger while the cursor is still on it; insert once anything follows. */
internal object EmojiCommit {
    fun shouldReplaceTrigger(composing: String, before: CharSequence): Boolean {
        if (composing.isNotEmpty()) return EmojiSuggestions.glyph(composing) != null
        if (before.isEmpty() || !isWordChar(before.last())) return false
        return EmojiSuggestions.glyph(SuggestionEngine.lastWord(before).orEmpty()) != null
    }

    fun insertText(before: CharSequence, emoji: String): String {
        val prefix = if (before.isEmpty() || before.last().isWhitespace()) "" else " "
        return prefix + emoji
    }

    private fun isWordChar(character: Char): Boolean =
        character.isLetterOrDigit() || character == '\''
}
