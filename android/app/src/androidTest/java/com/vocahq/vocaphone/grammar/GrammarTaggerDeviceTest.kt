package com.vocahq.vocaphone.grammar

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The tagger's word and sentence split, run on the phone's ICU regex engine.
 *
 * The unit suite compiles these patterns on the desktop JVM, which accepted an
 * inline `(?U)` that Android rejects: the class failed to initialize on every
 * phone while every unit test passed. This is the check that would have
 * caught it.
 *
 *     ./gradlew :app:connectedFullDebugAndroidTest \
 *       -Pandroid.testInstrumentationRunnerArguments.class=\
 *     com.vocahq.vocaphone.grammar.GrammarTaggerDeviceTest
 */
@RunWith(AndroidJUnit4::class)
class GrammarTaggerDeviceTest {
    @Test
    fun wordsSplitOnDevice() {
        assertEquals(
            listOf("He", "don’t", "know", ",", "café", "👍"),
            GrammarTagger.splitWords("He don’t know, café 👍").map { it.text },
        )
    }

    @Test
    fun sentencesSplitOnDevice() {
        assertEquals(
            listOf("" to "One.", "  " to "Two!", " " to "Three"),
            GrammarTagger.splitSentences("One.  Two! Three"),
        )
    }
}
