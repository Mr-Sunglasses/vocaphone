package com.vocahq.vocaphone.core

import android.content.res.AssetManager
import java.io.File

/**
 * Which characters Chinese dictation is written in.
 *
 * Every on-device model writes Mandarin in Simplified characters, and so do
 * most gateway models, whatever the speaker reads. Someone in Taiwan or Hong
 * Kong otherwise gets text in a script they do not write. Converting the
 * finished transcript is the only fix that covers every model, and it costs no
 * download: the tables are OpenCC's and ship with the app.
 *
 * A choice of writing system, not a correction, which is why it applies to
 * every writing style, [WritingStyle.RAW] included.
 */
enum class ChineseScript(val storedValue: String) {
    UNCHANGED("auto"),
    TAIWAN("zh-TW"),
    HONG_KONG("zh-HK"),
    ;

    val displayName: String
        get() = when (this) {
            UNCHANGED -> "Unchanged"
            TAIWAN -> "Traditional (Taiwan)"
            HONG_KONG -> "Traditional (Hong Kong)"
        }

    val detail: String
        get() = when (this) {
            UNCHANGED -> "Chinese comes out the way the model writes it, usually Simplified."
            TAIWAN -> "软件 becomes 軟體: Taiwan characters and vocabulary."
            HONG_KONG -> "软件 becomes 軟件: Hong Kong characters and vocabulary."
        }

    companion object {
        val DEFAULT = UNCHANGED

        fun fromStored(value: String?): ChineseScript =
            entries.firstOrNull { it.storedValue == value } ?: DEFAULT
    }
}

/**
 * Simplified → Traditional Chinese, using OpenCC's algorithm over OpenCC's own
 * tables.
 *
 * `assets/keyboard/chinese/s2hant.tsv` is generated from OpenCC by
 * `tools/generate-chinese-script.py`, which also checks a Python copy of the
 * steps below against OpenCC itself. The iOS port is `ChineseScript.swift`;
 * the three are kept step for step alike.
 */
object TraditionalChinese {
    @Volatile
    private var tables: Tables? = null

    @Volatile
    private var boundAssets: AssetManager? = null

    /** See [EmojiTable.discovered]: walk the filesystem once, not per call. */
    @Volatile
    private var discovered = false

    /**
     * The finished transcript in [script], or unchanged when it is not
     * Chinese.
     *
     * [language] is the language the text is written in. A language other
     * than Mandarin or Cantonese is never converted: Japanese is written with
     * the same characters, and 会社 is not a Chinese word to correct. Text
     * holding any kana or Hangul is left alone for the same reason, whatever
     * the language says — a model that detected Chinese in a mixed sentence
     * has not made the Japanese in it Chinese.
     *
     * Web addresses are skipped: a path in Chinese characters names one page,
     * and its Traditional spelling names another.
     */
    fun apply(text: String, script: ChineseScript, language: String): String {
        if (script == ChineseScript.UNCHANGED || !appliesTo(text, language)) return text
        val loaded = load() ?: return text
        val output = StringBuilder(text.length)
        var cursor = 0
        for (match in WEB_ADDRESS.findAll(text)) {
            output.append(loaded.convert(text.substring(cursor, match.range.first), script))
            output.append(match.value)
            cursor = match.range.last + 1
        }
        return output.append(loaded.convert(text.substring(cursor), script)).toString()
    }

    fun appliesTo(text: String, language: String): Boolean =
        language.lowercase().substringBefore('-') in CHINESE_CODES &&
            containsHan(text) && text.codePoints().noneMatch(::isKanaOrHangul)

    private val CHINESE_CODES = setOf("zh", "yue", "", "auto")

    /**
     * A scheme and everything up to the next space, as [ProtectedSpans] reads
     * an address. Bare domains need nothing: they are ASCII, which the tables
     * leave alone.
     */
    private val WEB_ADDRESS = Regex("(?i:https?)://\\S+")

    /**
     * Remember the process [AssetManager]. Nothing is read until someone who
     * has asked for Traditional finishes a transcript, or [warm] is called:
     * about a megabyte of tables nobody else should pay for.
     */
    fun bind(assets: AssetManager) {
        boundAssets = assets
    }

    /** Read the tables now, from a background thread, ahead of first use. */
    fun warm() {
        load()
    }

    private fun load(): Tables? {
        tables?.let { return it }
        synchronized(this) {
            tables?.let { return it }
            val assets = boundAssets
            val text = if (assets != null) {
                runCatching {
                    assets.open("chinese/s2hant.tsv").bufferedReader().use { it.readText() }
                }.getOrNull()
            } else if (!discovered) {
                discovered = true
                discoverFromRepository()
            } else {
                null
            }
            tables = text?.let(Tables::parse)
            return tables
        }
    }

    /** JVM tests bind no assets; the repository copy is the file the app ships. */
    private fun discoverFromRepository(): String? =
        generateSequence(File("").absoluteFile) { it.parentFile }
            .map { File(it, "assets/keyboard/chinese/s2hant.tsv") }
            .firstOrNull(File::isFile)
            ?.readText()

    private fun containsHan(text: String): Boolean = text.codePoints().anyMatch { codePoint ->
        codePoint in 0x3400..0x4DBF || codePoint in 0x4E00..0x9FFF ||
            codePoint in 0xF900..0xFAFF || codePoint in 0x20000..0x323AF
    }

    private fun isKanaOrHangul(codePoint: Int): Boolean =
        codePoint in 0x3040..0x30FF || codePoint in 0x31F0..0x31FF ||
            codePoint in 0xFF66..0xFF9F || codePoint in 0x1100..0x11FF ||
            codePoint in 0x3130..0x318F || codePoint in 0xAC00..0xD7AF

    internal class Tables(
        private val normalize: Table,
        private val phrases: Table,
        private val characters: Table,
        private val taiwan: List<Table>,
        private val hongKong: List<Table>,
    ) {
        fun convert(text: String, script: ChineseScript): String {
            val regional = if (script == ChineseScript.HONG_KONG) hongKong else taiwan
            val normalized = convertWith(text, listOf(normalize))
            // Segment, then convert each segment on its own. A matched phrase
            // is a segment; the characters between matches are joined into
            // one, which is how a word no phrase holds — 软件 — still reaches
            // the regional table whole.
            val output = StringBuilder(normalized.length)
            var runStart = -1
            var index = 0
            while (index < normalized.length) {
                val length = phrases.matchLength(normalized, index)
                if (length > 0) {
                    if (runStart >= 0) {
                        output.append(convertSegment(normalized.substring(runStart, index), regional))
                        runStart = -1
                    }
                    output.append(convertSegment(normalized.substring(index, index + length), regional))
                    index += length
                } else {
                    if (runStart < 0) runStart = index
                    index += Character.charCount(normalized.codePointAt(index))
                }
            }
            if (runStart >= 0) output.append(convertSegment(normalized.substring(runStart), regional))
            return output.toString()
        }

        private fun convertSegment(segment: String, regional: List<Table>): String =
            convertWith(convertWith(segment, listOf(phrases, characters)), regional)

        companion object {
            fun parse(text: String): Tables? {
                val sections = HashMap<String, HashMap<String, String>>()
                var current: HashMap<String, String>? = null
                for (line in text.lineSequence()) {
                    if (line.isEmpty() || line.startsWith("#")) continue
                    if (line.startsWith("@")) {
                        current = sections.getOrPut(line.substring(1)) { HashMap() }
                        continue
                    }
                    val tab = line.indexOf('\t')
                    if (tab <= 0 || current == null) continue
                    current[line.substring(0, tab)] = line.substring(tab + 1)
                }
                fun chain(prefix: String): List<Table> =
                    generateSequence(1) { it + 1 }
                        .map { sections["$prefix$it"] }
                        .takeWhile { it != null }
                        .map { Table(it!!) }
                        .toList()
                return Tables(
                    normalize = Table(sections["normalize"] ?: emptyMap()),
                    phrases = Table(sections["phrases"] ?: return null),
                    characters = Table(sections["characters"] ?: return null),
                    taiwan = chain("tw"),
                    hongKong = chain("hk"),
                )
            }

            /**
             * Longest match at each position. Several tables are OpenCC's
             * short-circuit group: the first table with any match wins, even
             * over a longer key in a later one.
             */
            private fun convertWith(text: String, tables: List<Table>): String {
                val output = StringBuilder(text.length)
                var index = 0
                outer@ while (index < text.length) {
                    for (table in tables) {
                        val length = table.matchLength(text, index)
                        if (length > 0) {
                            output.append(table.valueAt(text, index, length))
                            index += length
                            continue@outer
                        }
                    }
                    val step = Character.charCount(text.codePointAt(index))
                    output.append(text, index, index + step)
                    index += step
                }
                return output.toString()
            }
        }
    }

    /**
     * Lengths are UTF-16 units. A candidate that would split a surrogate pair
     * matches no key, since every key is whole characters, so the units never
     * cut a character in two.
     *
     * The longest key is fifteen characters, but most characters begin no key
     * at all and the rest rarely begin a long one. Bounding the search by the
     * longest key *starting with that character* turns most positions into a
     * single map miss rather than fifteen substrings.
     */
    internal class Table(private val entries: Map<String, String>) {
        private val longestFrom: Map<Int, Int> = entries.keys
            .filter { it.isNotEmpty() }
            .groupBy({ it.codePointAt(0) }, { it.length })
            .mapValues { (_, lengths) -> lengths.max() }

        fun matchLength(text: String, start: Int): Int {
            val longest = longestFrom[text.codePointAt(start)] ?: return 0
            var length = minOf(longest, text.length - start)
            while (length > 0) {
                if (entries.containsKey(text.substring(start, start + length))) return length
                length--
            }
            return 0
        }

        fun valueAt(text: String, start: Int, length: Int): String =
            entries.getValue(text.substring(start, start + length))
    }
}
