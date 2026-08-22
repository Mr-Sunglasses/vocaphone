package com.vocahq.vocaphone.ime

import java.io.File
import kotlin.system.measureNanoTime
import org.junit.Assume.assumeTrue
import org.junit.Test

/**
 * Wall-clock harness for the IME hot path on the host JVM.
 *
 * Frame timing has to be measured on a phone (see
 * [com.vocahq.vocaphone.ime.KeyboardHotPathBenchmark]); this is the same
 * dictionary and reducer work, so a change that blows the 8.3 ms 120 Hz budget
 * here will show up before anyone flashes an APK. Opt in:
 *
 *     ./gradlew :app:testFullDebugUnitTest -i \
 *       --tests '*KeyboardHotPathTest' -Dvocaphone.benchmark=1
 */
class KeyboardHotPathTest {

    private val keyboardAssets: File?
        get() = generateSequence(File("").absoluteFile) { it.parentFile }
            .map { File(it, "assets/keyboard") }
            .firstOrNull { File(it, "en.txt").isFile }

    @Test
    fun `report keystroke and swipe latency on the shipped dictionary`() {
        assumeTrue(
            "Timing harness; pass -Dvocaphone.benchmark=1 to run it",
            System.getProperty("vocaphone.benchmark") != null,
        )
        val assets = keyboardAssets
        assumeTrue("assets/keyboard is only present in the repository", assets != null)
        val dictionary = SuggestionDictionary(
            words = File(assets, "en.txt").readLines().map { it.trim() }.filter { it.isNotEmpty() },
            bigrams = SuggestionDictionary.parseBigrams(
                File(assets, "en-bigrams.txt").readLines(),
            ),
        )
        val letter = KeyboardKey("character-h", "h", "h")

        fun bench(label: String, iterations: Int = 200, block: () -> Unit) {
            repeat(40) { block() }
            val nanos = LongArray(iterations) { measureNanoTime(block) }
            nanos.sort()
            println(
                "%-40s median %7.1f us   p95 %7.1f us".format(
                    label,
                    nanos[iterations / 2] / 1_000.0,
                    nanos[(iterations * 95) / 100] / 1_000.0,
                ),
            )
        }

        println("120 Hz frame budget is 8333 us")
        listOf("t", "th", "hel", "think", "teh", "recieve").forEach { composing ->
            bench("strip(\"$composing\")") {
                dictionary.strip(composing, "I ", "", correctionsEnabled = true)
            }
        }
        listOf("tjhinl", "qwertyu", "hjelklo").forEach { path ->
            bench("swipe(\"$path\")", iterations = 40) { dictionary.swipe(path) }
        }
        bench("reducer.press letter (compose)") {
            KeyboardReducer.press(
                KeyboardState(KeyboardLayer.LETTERS, ShiftState.OFF, composing = "hel"),
                letter,
                nowMillis = 1_000L,
                composeWords = true,
            )
        }
        bench("reducer.undoLastCharacter") {
            KeyboardReducer.undoLastCharacter(
                KeyboardState(KeyboardLayer.LETTERS, ShiftState.OFF, composing = "hell"),
                composeWords = true,
                restoreShift = ShiftState.ONCE,
            )
        }
    }
}
