package com.vocahq.vocaphone.writing

import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Writing check's part-of-speech tagger: a greedy averaged perceptron over
 * Penn Treebank tags, trained by `tools/writing-tagger/train.py` on the
 * Universal Dependencies English Web Treebank and shipped as
 * `assets/keyboard/en-pos.bin`. The agreement checks ([WritingAgreement]) read
 * its tags to find a verb's subject.
 *
 * A port of `tools/writing-tagger/postag.py`, which says how it works; this,
 * `PosTagger.swift` and the reference tag every sentence of
 * `assets/grammar/pos_fixtures.json` identically. All of it is integer
 * arithmetic: hashed features, int16 weights, ties to the lower tag.
 *
 * Words are [WritingText] tokens. A token the treebank splits carries its
 * pieces' tags joined with "+": "don't" is VBP+RB, "John's" NNP+POS.
 */
class PosTagger private constructor(
    val tags: List<String>,
    private val tableKeys: LongArray,
    private val tableTags: ByteArray,
    private val hashes: LongArray,
    private val offsets: IntArray,
    private val entryTags: ByteArray,
    private val entryWeights: ShortArray,
) {
    /** The tag of each of [words], in order. */
    fun tag(words: List<String>): List<String> {
        val context = ArrayList<String>(words.size + 4)
        context.add(START1)
        context.add(START2)
        for (w in words) context.add(normalize(w))
        context.add(END1)
        context.add(END2)
        val shapes = words.map(::shape)
        val out = ArrayList<String>(words.size)
        val scores = IntArray(tags.size)
        var p1 = START1
        var p2 = START2
        for (i in words.indices) {
            val word = context[i + 2]
            val fixed = find(tableKeys, fnv("w $word"))
            val best = if (fixed >= 0) {
                tableTags[fixed].toInt() and 0xFF
            } else {
                scores.fill(0)
                for (feature in features(i, context, shapes, p1, p2)) {
                    val f = find(hashes, fnv(feature))
                    if (f < 0) continue
                    for (e in offsets[f] until offsets[f + 1]) scores[entryTags[e].toInt() and 0xFF] += entryWeights[e]
                }
                var b = 0
                for (t in 1 until scores.size) if (scores[t] > scores[b]) b = t
                b
            }
            val tag = tags[best]
            out.add(tag)
            p2 = p1
            p1 = tag
        }
        return out
    }

    companion object {
        private const val START1 = "-START-"
        private const val START2 = "-START2-"
        private const val END1 = "-END-"
        private const val END2 = "-END2-"

        /** Reads `en-pos.bin`; throws on a file that is not one. */
        fun parse(bytes: ByteArray): PosTagger {
            val b = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
            val magic = ByteArray(4).also { b.get(it) }
            require(String(magic, Charsets.US_ASCII) == "VPOS") { "not a VPOS file" }
            require(b.int == 1) { "unknown VPOS version" }
            val tags = List(b.short.toInt() and 0xFFFF) {
                val n = b.get().toInt() and 0xFF
                String(ByteArray(n).also { a -> b.get(a) }, Charsets.UTF_8)
            }
            val tableCount = b.int
            val tableKeys = LongArray(tableCount) { b.long }
            val tableTags = ByteArray(tableCount).also { b.get(it) }
            val count = b.int
            val hashes = LongArray(count) { b.long }
            val offsets = IntArray(count + 1) { b.int }
            val entries = offsets[count]
            val entryTags = ByteArray(entries)
            val entryWeights = ShortArray(entries)
            for (e in 0 until entries) {
                entryTags[e] = b.get()
                entryWeights[e] = b.short
            }
            require(!b.hasRemaining()) { "trailing bytes in VPOS file" }
            return PosTagger(tags, tableKeys, tableTags, hashes, offsets, entryTags, entryWeights)
        }

        /** 64-bit FNV-1a over the UTF-8 bytes of [text]. */
        fun fnv(text: String): Long {
            var h = -0x340d631b7bdddcdbL // 0xcbf29ce484222325
            for (byte in text.toByteArray(Charsets.UTF_8)) {
                h = h xor (byte.toLong() and 0xFF)
                h *= 0x100000001b3L
            }
            return h
        }

        /** The index of [key] in [sorted] (ordered as unsigned 64-bit numbers), or -1. */
        private fun find(sorted: LongArray, key: Long): Int {
            var lo = 0
            var hi = sorted.size - 1
            while (lo <= hi) {
                val mid = (lo + hi) ushr 1
                val c = java.lang.Long.compareUnsigned(sorted[mid], key)
                when {
                    c < 0 -> lo = mid + 1
                    c > 0 -> hi = mid - 1
                    else -> return mid
                }
            }
            return -1
        }

        /** What the features see of a word: lower-case ASCII, numbers and foreign words collapsed. */
        fun normalize(word: String): String {
            val w = word.replace('’', '\'')
            if (w.any { it.code > 127 }) return "!FOREIGN"
            if (w.isNotEmpty() && w.all { it in '0'..'9' }) return if (w.length == 4) "!YEAR" else "!DIGITS"
            if (w.isNotEmpty() && w[0] in '0'..'9') return "!DIGITS"
            return buildString(w.length) { for (c in w) append(if (c in 'A'..'Z') c + 32 else c) }
        }

        /** Capitalisation, which the lower-cased features lose: X (all caps), Xx, x, d, p, f. */
        fun shape(word: String): String {
            if (word.any { it.code > 127 }) return "f"
            val first = word[0]
            return when (first) {
                in '0'..'9' -> "d"
                in 'A'..'Z' -> {
                    val letters = word.filter { it in 'A'..'Z' || it in 'a'..'z' }
                    if (letters.length > 1 && letters.all { it in 'A'..'Z' }) "X" else "Xx"
                }
                in 'a'..'z' -> "x"
                else -> "p"
            }
        }

        private fun suffix(w: String) = if (w.length <= 3) w else w.substring(w.length - 3)

        /** The feature strings for token [i]; [context] is the normalised words padded by two on each side. */
        internal fun features(i: Int, context: List<String>, shapes: List<String>, p1: String, p2: String): List<String> {
            val w = context[i + 2]
            return listOf(
                "b",
                "s " + suffix(w),
                "p " + w[0],
                "t1 $p1",
                "t2 $p2",
                "t12 $p1 $p2",
                "w $w",
                "t1w $p1 $w",
                "w-1 " + context[i + 1],
                "s-1 " + suffix(context[i + 1]),
                "w-2 " + context[i],
                "w+1 " + context[i + 3],
                "s+1 " + suffix(context[i + 3]),
                "w+2 " + context[i + 4],
                "sh " + shapes[i],
            )
        }
    }
}
