package com.vocahq.vocaphone.ime

import android.os.SystemClock
import android.util.Log
import android.view.Choreographer
import androidx.activity.ComponentActivity
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.performTouchInput
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.vocahq.vocaphone.core.DictationState
import com.vocahq.vocaphone.settings.VocaPhoneSettings
import kotlin.system.measureNanoTime
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * On-device timing for the keyboard hot path, after the 120 Hz pass.
 *
 * An IME draws in its own window, so Activity-level frame metrics never see
 * a key press. This times the work a press actually does on the phone, plus
 * Choreographer gaps while Compose taps letter keys. Opt in:
 *
 *     ./gradlew :app:connectedFullDebugAndroidTest \
 *       -Pandroid.testInstrumentationRunnerArguments.keyboardBenchmark=true
 *
 * Numbers go to logcat tag `VocaPhoneBenchmark`. A 120 Hz panel has 8.3 ms
 * per frame; anything in p95 above that on the UI thread is a missed vsync.
 */
@RunWith(AndroidJUnit4::class)
class KeyboardHotPathBenchmark {

    @get:Rule
    val composeRule = createAndroidComposeRule<ComponentActivity>()

    private val target = InstrumentationRegistry.getInstrumentation().targetContext

    @Test
    fun dictionaryAndReducerStayInsideAFrame() {
        assumeEnabled()
        val dictionary = SuggestionDictionary.load(target.assets)
        val letter = KeyboardKey("character-h", "h", "h")

        fun bench(label: String, iterations: Int = 80, warmup: Int = 20, block: () -> Unit) {
            repeat(warmup) { block() }
            val nanos = LongArray(iterations) { measureNanoTime(block) }
            report(label, nanos)
        }

        log("120 Hz frame budget is 8333 us")
        listOf("hel", "think", "teh", "recieve").forEach { composing ->
            bench("strip(\"$composing\")") {
                dictionary.strip(composing, "I ", "", correctionsEnabled = true)
            }
        }
        listOf("tjhinl", "qwertyu").forEach { path ->
            bench("swipe(\"$path\")", iterations = 24, warmup = 4) { dictionary.swipe(path) }
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

    @Test
    fun composeLetterTapsReportFrameGaps() {
        assumeEnabled()
        composeRule.setContent {
            VocaPhoneKeyboard(
                dictationState = DictationState(),
                editor = KeyboardEditorConfig.empty(),
                settings = VocaPhoneSettings(swipeTypingEnabled = false),
                isPreferenceWritePending = false,
                clipboard = null,
                editorText = EditorTextWindow(),
                suggestions = null,
                emojiCatalog = emptyList(),
                onCommand = {},
                onMicTap = {},
                onMicLongPress = {},
                onOpenSettings = {},
                onLanguageSelected = {},
                onStyleSelected = {},
                onSuggestionPicked = { _, _ -> },
                onSaveToDictionary = {},
                onEmojiSuggestion = {},
                onPasteClipboard = {},
                onDismissClipboard = {},
                onRemoveClipboardHistory = {},
                onClearClipboardHistory = {},
                onEmojiUsed = {},
            )
        }
        composeRule.waitForIdle()

        val sampler = FrameSampler()
        composeRule.runOnUiThread { sampler.start() }
        val letters = listOf("h", "e", "l", "l", "o", "t", "h", "e", "r", "e")
        val tapNanos = LongArray(letters.size)
        letters.forEachIndexed { index, letter ->
            tapNanos[index] = measureNanoTime {
                composeRule.onNodeWithContentDescription(letter).performTouchInput {
                    down(center)
                    up()
                }
                composeRule.waitForIdle()
            }
        }
        // Let a couple of idle frames land so the last press is in the sample.
        composeRule.runOnIdle { SystemClock.sleep(80) }
        composeRule.runOnUiThread { sampler.stop() }

        report("compose tap down+up+waitForIdle", tapNanos)
        val frames = sampler.durationsNs
        assumeTrue("Choreographer recorded frames", frames.isNotEmpty())
        report("choreographer frame gap", frames.toLongArray())
        // 8.3 ms is one 120 Hz vsync; counting "over 8.3 ms" catches jitter of
        // a few tens of microseconds. A missed frame is two vsyncs, 16.7 ms.
        val missed = frames.count { it > 16_667_000L }
        log("frames=${frames.size} missed_vsync(>16.7ms)=$missed")
    }

    private fun assumeEnabled() {
        assumeTrue(
            "set -Pandroid.testInstrumentationRunnerArguments.keyboardBenchmark=true to run",
            InstrumentationRegistry.getArguments().getString("keyboardBenchmark") == "true",
        )
    }

    private class FrameSampler : Choreographer.FrameCallback {
        private var last = 0L
        val durationsNs = ArrayList<Long>(256)

        fun start() {
            last = 0L
            durationsNs.clear()
            Choreographer.getInstance().postFrameCallback(this)
        }

        fun stop() {
            Choreographer.getInstance().removeFrameCallback(this)
        }

        override fun doFrame(frameTimeNanos: Long) {
            if (last != 0L) durationsNs.add(frameTimeNanos - last)
            last = frameTimeNanos
            Choreographer.getInstance().postFrameCallback(this)
        }
    }

    private companion object {
        const val TAG = "VocaPhoneBenchmark"

        fun report(label: String, nanos: LongArray) {
            nanos.sort()
            val median = nanos[nanos.size / 2] / 1_000.0
            val p95 = nanos[(nanos.size * 95) / 100] / 1_000.0
            log("%-40s median %7.1f us   p95 %7.1f us".format(label, median, p95))
            log(
                "VocaPhoneBenchmark|metric|name=${label.replace('|', ' ')}" +
                    "|median_us=$median|p95_us=$p95",
            )
        }

        fun log(line: String) {
            println(line)
            Log.i(TAG, line)
        }
    }
}
