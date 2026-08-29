package com.vocahq.vocaphone.core

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The same expansions as `SnippetExpanderTest`, run on the phone.
 *
 * The unit suite runs against the desktop JVM's own regex engine; Android
 * ships ICU instead, and the two disagree. `UNICODE_CHARACTER_CLASS` compiles
 * on the JVM and throws on Android, and `\b` reads ASCII-only `\w` on the JVM
 * but Unicode `\w` under ICU — so a snippet regex can be green in the unit
 * suite and still throw out of `deliver()` on a real dictation. This runs the
 * expander where it actually ships.
 *
 *     ./gradlew :app:connectedFullDebugAndroidTest \
 *       -Pandroid.testInstrumentationRunnerArguments.class=\
 *     com.vocahq.vocaphone.core.SnippetExpanderDeviceTest
 */
@RunWith(AndroidJUnit4::class)
class SnippetExpanderDeviceTest {

    @Test
    fun asciiTriggerExpandsOnDevice() {
        val snippets = listOf(Snippet("1", "brb", "be right back"))
        assertEquals(
            "be right back, getting coffee",
            SnippetExpander.expand("BRB, getting coffee", snippets),
        )
    }

    @Test
    fun nonAsciiTriggerExpandsOnDevice() {
        val snippets = listOf(Snippet("1", "büro", "the office"))
        assertEquals(
            "meet me at the office later",
            SnippetExpander.expand("meet me at büro later", snippets),
        )
    }

    @Test
    fun nonAsciiTriggerRespectsWordBoundariesOnDevice() {
        val snippets = listOf(Snippet("1", "büro", "the office"))
        assertEquals(
            "the bürogebäude is closed",
            SnippetExpander.expand("the bürogebäude is closed", snippets),
        )
    }

    @Test
    fun nonLatinScriptTriggerExpandsOnDevice() {
        val snippets = listOf(Snippet("1", "पता", "221B Baker Street"))
        assertEquals(
            "भेजें 221B Baker Street पर",
            SnippetExpander.expand("भेजें पता पर", snippets),
        )
    }

    @Test
    fun punctuationOnlyTriggerExpandsOnDevice() {
        val snippets = listOf(Snippet("1", "->", "results in"))
        assertEquals("a results in b", SnippetExpander.expand("a -> b", snippets))
    }

    @Test
    fun asciiWordBoundaryHoldsOnDevice() {
        val snippets = listOf(Snippet("1", "addr", "123 Main St"))
        assertEquals(
            "my address is unlisted",
            SnippetExpander.expand("my address is unlisted", snippets),
        )
    }
}
