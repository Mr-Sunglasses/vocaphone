package com.vocahq.vocaphone.grammar

import org.json.JSONObject

/**
 * The grammar tagger's tokenizer: GPT-2 style byte-level BPE, read from the
 * model's `tokenizer.json` (Hugging Face `tokenizers` format).
 *
 * Only what that file uses is implemented: the ByteLevel pre-tokenizer with
 * its regex, no normalizer, no added prefix space, merges applied by rank.
 * `assets/grammar/parity_fixtures.json` pins the ids this must produce, and
 * the Swift port is tested against the same file.
 */
class ByteLevelBpe(
    private val vocab: Map<String, Int>,
    merges: List<Pair<String, String>>,
    private val unknownId: Int,
) {
    private val ranks: Map<Pair<String, String>, Int> =
        merges.withIndex().associate { (rank, pair) -> pair to rank }
    private val cache = HashMap<String, IntArray>()

    fun encode(text: String): IntArray {
        val ids = ArrayList<Int>()
        PRE_TOKENIZER.findAll(text).forEach { match ->
            val piece = match.value
            val cached = cache[piece] ?: bpe(piece).also { if (cache.size < CACHE_LIMIT) cache[piece] = it }
            cached.forEach(ids::add)
        }
        return ids.toIntArray()
    }

    private fun bpe(piece: String): IntArray {
        var symbols: MutableList<String> = piece.toByteArray(Charsets.UTF_8)
            .map { BYTE_TO_CHAR[it.toInt() and 0xFF].toString() }
            .toMutableList()
        while (symbols.size > 1) {
            var best = -1
            var bestRank = Int.MAX_VALUE
            for (i in 0 until symbols.size - 1) {
                val rank = ranks[symbols[i] to symbols[i + 1]] ?: continue
                if (rank < bestRank) {
                    bestRank = rank
                    best = i
                }
            }
            if (best < 0) break
            val first = symbols[best]
            val second = symbols[best + 1]
            // Merge every occurrence of the winning pair, left to right.
            val merged = ArrayList<String>(symbols.size)
            var i = 0
            while (i < symbols.size) {
                if (i < symbols.size - 1 && symbols[i] == first && symbols[i + 1] == second) {
                    merged.add(first + second)
                    i += 2
                } else {
                    merged.add(symbols[i])
                    i += 1
                }
            }
            symbols = merged
        }
        return IntArray(symbols.size) { vocab[symbols[it]] ?: unknownId }
    }

    companion object {
        private const val CACHE_LIMIT = 4096

        /** GPT-2's pre-tokenizer pattern, which `tokenizers`' ByteLevel uses. */
        private val PRE_TOKENIZER = Regex(
            """'s|'t|'re|'ve|'m|'ll|'d| ?\p{L}+| ?\p{N}+| ?[^\s\p{L}\p{N}]+|\s+(?!\S)|\s+""",
        )

        /** GPT-2's `bytes_to_unicode`: every byte gets a printable character. */
        private val BYTE_TO_CHAR: CharArray = run {
            val printable = (('!'.code..'~'.code) + ('¡'.code..'¬'.code) + ('®'.code..'ÿ'.code)).toSet()
            var next = 256
            CharArray(256) { byte -> if (byte in printable) byte.toChar() else (next++).toChar() }
        }

        fun parse(json: String): ByteLevelBpe {
            val model = JSONObject(json).getJSONObject("model")
            val vocabJson = model.getJSONObject("vocab")
            val vocab = HashMap<String, Int>(vocabJson.length() * 2)
            vocabJson.keys().forEach { vocab[it] = vocabJson.getInt(it) }
            val mergesJson = model.getJSONArray("merges")
            val merges = (0 until mergesJson.length()).map { i ->
                when (val entry = mergesJson.get(i)) {
                    is String -> entry.substringBefore(' ') to entry.substringAfter(' ')
                    else -> mergesJson.getJSONArray(i).let { it.getString(0) to it.getString(1) }
                }
            }
            return ByteLevelBpe(vocab, merges, vocab[model.optString("unk_token", "[UNK]")] ?: 3)
        }
    }
}
