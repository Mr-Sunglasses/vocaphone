package com.vocahq.vocaphone.ime

import java.io.File
import kotlin.system.measureNanoTime
import org.junit.Assert.assertEquals
import org.junit.Assume.assumeTrue
import org.junit.Test

/**
 * Holds the indexed lookups to the answers an unindexed scan would give.
 *
 * [SuggestionDictionary] used to walk all ten thousand words for every lookup.
 * It now rejects most candidates from a prefix bucket, a length and a bitmap of
 * the letters each word contains, and the whole point of those filters is that
 * they are conservative: a filter that drops a real match costs the user a
 * correction they should have been offered, silently, on the words least likely
 * to be reported — the rare ones.
 *
 * So the checks here are differential rather than absolute. They run the
 * original unfiltered algorithm against the shipped dictionary and require the
 * indexed one to agree exactly, which pins both the results and their order
 * without anybody having to hand-maintain a list of expected corrections.
 */
class SuggestionIndexTest {

    private val keyboardAssets: File?
        get() = generateSequence(File("").absoluteFile) { it.parentFile }
            .map { File(it, "assets/keyboard") }
            .firstOrNull { File(it, "en.txt").isFile }

    private fun shippedDictionary(): SuggestionDictionary? {
        val assets = keyboardAssets ?: return null
        return SuggestionDictionary(
            words = words(assets),
            bigrams = SuggestionDictionary.parseBigrams(
                File(assets, "en-bigrams.txt").readLines(),
            ),
        )
    }

    private fun words(assets: File): List<String> =
        File(assets, "en.txt").readLines().map { it.trim() }.filter { it.isNotEmpty() }

    /** [SuggestionDictionary.similar] as it read before any index existed. */
    private fun bruteForceSimilar(words: List<String>, typed: String, limit: Int = 3): List<String> {
        val lower = typed.lowercase()
        if (lower.length < 2) return emptyList()
        val neighbor = ArrayList<String>(limit)
        val distance1 = ArrayList<String>(limit)
        val distance2 = ArrayList<String>(limit)
        val minLen = (lower.length - 2).coerceAtLeast(1)
        val maxLen = lower.length + 2
        for (word in words) {
            if (word == lower || word.length !in minLen..maxLen) continue
            when (SuggestionEngine.editDistance(lower, word, max = 2)) {
                1 -> if (SuggestionEngine.isNeighborSubstitution(lower, word)) {
                    neighbor.add(word)
                } else {
                    distance1.add(word)
                }
                2 -> if (distance2.size < limit) distance2.add(word)
            }
            if (neighbor.size >= limit) break
        }
        return (neighbor + distance1 + distance2)
            .take(limit)
            .map { SuggestionEngine.matchCase(typed, it) }
    }

    /** [SuggestionDictionary.complete] as it read before any index existed. */
    private fun bruteForceComplete(words: List<String>, prefix: String, limit: Int = 3): List<String> {
        if (prefix.isEmpty()) return emptyList()
        val lower = prefix.lowercase()
        return words.asSequence()
            .filter { it.startsWith(lower) && it.length > lower.length }
            .take(limit)
            .map { SuggestionEngine.matchCase(prefix, it) }
            .toList()
    }

    /**
     * Every prefix of every hundredth word, which covers one and two letter
     * prefixes shorter than the bucket key as well as prefixes longer than it.
     */
    @Test
    fun `the prefix index answers exactly what a full scan would`() {
        val assets = keyboardAssets
        assumeTrue("assets/keyboard is only present in the repository", assets != null)
        val words = words(assets!!)
        val dictionary = shippedDictionary()!!

        val prefixes = buildList {
            words.filterIndexed { index, _ -> index % 100 == 0 }.forEach { word ->
                for (length in 1..word.length) add(word.substring(0, length))
            }
            addAll(listOf("q", "zz", "xyzzy", "th", "the", "them", "A", "Th", "THE"))
        }
        prefixes.forEach { prefix ->
            assertEquals(
                "complete(\"$prefix\")",
                bruteForceComplete(words, prefix),
                dictionary.complete(prefix),
            )
        }
    }

    /**
     * The letter bitmap is the filter that could silently lose a correction:
     * two words within edit distance two cannot differ by more than four
     * distinct letters, and if that bound were ever wrong the only symptom
     * would be a missing suggestion.
     */
    @Test
    fun `the letter filter never drops a correction a full scan would offer`() {
        val assets = keyboardAssets
        assumeTrue("assets/keyboard is only present in the repository", assets != null)
        val words = words(assets!!)
        val dictionary = shippedDictionary()!!

        val typed = buildList {
            // Real misspellings, the case corrections exist for.
            addAll(
                listOf(
                    "teh", "recieve", "seperate", "definately", "occurence", "wierd",
                    "beleive", "acheive", "adress", "arguement", "calender", "cemetary",
                    "concious", "embarass", "existance", "goverment", "harrass",
                    "independant", "occassion", "priviledge", "publically", "recomend",
                    "refered", "relevent", "supercede", "tommorow", "untill", "wich",
                ),
            )
            // Known words, which take the `similar` path rather than `correct`.
            addAll(words.filterIndexed { index, _ -> index % 250 == 0 })
            // Prefixes mid-word: what the strip actually asks on each keystroke.
            addAll(listOf("hel", "thi", "wor", "abou", "peopl", "somethin"))
        }
        typed.forEach { word ->
            assertEquals(
                "similar(\"$word\")",
                bruteForceSimilar(words, word),
                dictionary.similar(word),
            )
        }
    }

    /**
     * A wall-clock harness, not a check: JVM timings on a shared CI runner are
     * too noisy to gate on, and the guards above are what actually stop the
     * indexes from rotting. Run it when changing them:
     *
     * ./gradlew :app:testFullDebugUnitTest -i \
     *   --tests '*SuggestionIndexTest*' -Dvocaphone.benchmark=1
     *
     * Opted in by property rather than `@Ignore`, which nothing can switch back
     * on from the command line.
     */
    @Test
    fun `report suggestion latency on the shipped dictionary`() {
        assumeTrue(
            "Timing harness; pass -Dvocaphone.benchmark=1 to run it",
            System.getProperty("vocaphone.benchmark") != null,
        )
        val dictionary = shippedDictionary() ?: return
        fun bench(label: String, iterations: Int = 200, block: () -> Unit) {
            repeat(50) { block() }
            val nanos = LongArray(iterations) { measureNanoTime(block) }
            nanos.sort()
            println(
                "%-34s median %7.1f us   p95 %7.1f us".format(
                    label,
                    nanos[iterations / 2] / 1_000.0,
                    nanos[(iterations * 95) / 100] / 1_000.0,
                ),
            )
        }
        listOf("t", "th", "thi", "thin", "think", "hel", "teh", "recieve", "seperate")
            .forEach { composing ->
                bench("strip(\"$composing\")") {
                    dictionary.strip(composing, "I ", "", correctionsEnabled = true)
                }
            }
        listOf("tjhinl", "qwertyu", "hjelklo").forEach { path ->
            bench("swipe(\"$path\")", iterations = 50) { dictionary.swipe(path) }
        }
    }
}
