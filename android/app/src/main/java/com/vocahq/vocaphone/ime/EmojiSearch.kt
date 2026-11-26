package com.vocahq.vocaphone.ime

/**
 * Skin tones, from the catalog alone. `catalog.tsv` lists every toned form
 * inline after its base (👍 then 👍🏻…👍🏿), so the tone picker needs no new
 * data: toned entries are grouped under their base and kept out of the grid,
 * and a held emoji offers its five tones.
 *
 * Built once off the main thread with the catalog ([build]); lookups are map
 * reads. Multi-person emoji with two different tones (🧑🏻‍🤝‍🧑🏿) are not
 * offered: the picker is one tone per emoji, as Gboard's default is.
 */
internal class EmojiTones private constructor(
    /** Base glyph → its five uniform-tone forms, light to dark. */
    private val variants: Map<String, List<String>>,
    /** Glyphs carrying any tone modifier: left out of the grid and search. */
    private val toned: Set<String>,
) {
    fun variantsOf(glyph: String): List<String>? = variants[glyph]

    fun hasTones(glyph: String): Boolean = glyph in variants

    fun isToned(glyph: String): Boolean = glyph in toned

    /** [glyph] in [tone] (1-5), or [glyph] itself for 0 or an emoji without tones. */
    fun applied(glyph: String, tone: Int): String {
        if (tone !in 1..5) return glyph
        return variants[glyph]?.getOrNull(tone - 1) ?: glyph
    }

    companion object {
        val EMPTY = EmojiTones(emptyMap(), emptySet())

        /** U+1F3FB..U+1F3FF, light to dark. */
        private val MODIFIERS = (0x1F3FB..0x1F3FF).toList()
        private const val VARIATION_SELECTOR = 0xFE0F

        /** Which tone (1-5) a code point is, or 0. */
        fun toneOf(codePoint: Int): Int = MODIFIERS.indexOf(codePoint) + 1

        /** The glyph with its tones and variation selectors gone: what base and toned forms share. */
        fun key(glyph: String): String {
            val out = StringBuilder(glyph.length)
            var index = 0
            while (index < glyph.length) {
                val cp = glyph.codePointAt(index)
                if (toneOf(cp) == 0 && cp != VARIATION_SELECTOR) out.appendCodePoint(cp)
                index += Character.charCount(cp)
            }
            return out.toString()
        }

        private fun tones(glyph: String): Set<Int> {
            val found = HashSet<Int>()
            var index = 0
            while (index < glyph.length) {
                val cp = glyph.codePointAt(index)
                toneOf(cp).takeIf { it > 0 }?.let(found::add)
                index += Character.charCount(cp)
            }
            return found
        }

        fun build(entries: List<EmojiEntry>): EmojiTones {
            val baseByKey = HashMap<String, String>()
            val byKey = HashMap<String, Array<String?>>()
            val toned = HashSet<String>()
            for (entry in entries) {
                val glyph = entry.glyph
                val found = tones(glyph)
                if (found.isEmpty()) {
                    baseByKey.putIfAbsent(key(glyph), glyph)
                    continue
                }
                toned.add(glyph)
                if (found.size != 1) continue
                val slots = byKey.getOrPut(key(glyph)) { arrayOfNulls(5) }
                val tone = found.first()
                if (slots[tone - 1] == null) slots[tone - 1] = glyph
            }
            val variants = HashMap<String, List<String>>()
            for ((key, slots) in byKey) {
                val base = baseByKey[key] ?: continue
                if (slots.all { it != null }) variants[base] = slots.map { it!! }
            }
            return EmojiTones(variants, toned)
        }
    }
}

/**
 * Emoji search over the catalog's keywords (CLDR names and keywords, already
 * loaded with the catalog). Every word typed must start a keyword; an emoji
 * whose name starts with the query ranks first, then the catalog's own order.
 * Toned forms are left out, as in the grid; the tone comes from the default.
 */
internal object EmojiSearch {
    fun search(
        entries: List<EmojiEntry>,
        query: String,
        tones: EmojiTones = EmojiTones.EMPTY,
        limit: Int = 60,
        shouldAbort: () -> Boolean = { false },
    ): List<String> {
        val words = query.lowercase().split(' ', '\t').filter { it.isNotEmpty() }
        if (words.isEmpty()) return emptyList()
        val phrase = words.joinToString(" ")
        val strong = ArrayList<String>()
        val weak = ArrayList<String>()
        for ((index, entry) in entries.withIndex()) {
            if (index % 128 == 0 && shouldAbort()) return emptyList()
            if (tones.isToned(entry.glyph)) continue
            val keywords = entry.keywords
            if (!words.all { word -> startsAWord(keywords, word) }) continue
            if (keywords.startsWith(phrase)) strong.add(entry.glyph) else weak.add(entry.glyph)
            if (strong.size >= limit) break
        }
        return (strong + weak).distinct().take(limit)
    }

    /** [text] has a space-separated word starting with [prefix]. */
    private fun startsAWord(text: String, prefix: String): Boolean {
        var from = 0
        while (true) {
            val at = text.indexOf(prefix, from)
            if (at < 0) return false
            if (at == 0 || text[at - 1] == ' ') return true
            from = at + 1
        }
    }
}
