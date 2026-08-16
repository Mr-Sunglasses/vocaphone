package com.vocahq.vocaphone.ime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class EmojiCommitTest {

    @Test
    fun tapReplacesTheTriggerWhileStillOnTheWord() {
        assertTrue(EmojiCommit.shouldReplaceTrigger("sad", ""))
        assertTrue(EmojiCommit.shouldReplaceTrigger("sad", "I am "))
        assertTrue(EmojiCommit.shouldReplaceTrigger("", "I am sad"))
        assertTrue(EmojiCommit.shouldReplaceTrigger("", "sad"))
    }

    @Test
    fun tapInsertsOnceAnythingFollowsTheTrigger() {
        assertFalse(EmojiCommit.shouldReplaceTrigger("", "sad "))
        assertFalse(EmojiCommit.shouldReplaceTrigger("", "sad."))
        assertFalse(EmojiCommit.shouldReplaceTrigger("", "sad!"))
        assertFalse(EmojiCommit.shouldReplaceTrigger("", "sad,"))
        assertFalse(EmojiCommit.shouldReplaceTrigger("", "I am sad "))
    }

    @Test
    fun aNonTriggerWordIsNeverReplaced() {
        assertFalse(EmojiCommit.shouldReplaceTrigger("the", ""))
        assertFalse(EmojiCommit.shouldReplaceTrigger("", "the"))
        assertFalse(EmojiCommit.shouldReplaceTrigger("hap", ""))
    }

    @Test
    fun insertKeepsASpaceAfterPunctuationAndNotAfterASpace() {
        assertEquals("😢", EmojiCommit.insertText("sad ", "😢"))
        assertEquals(" 😢", EmojiCommit.insertText("sad.", "😢"))
        assertEquals("😢", EmojiCommit.insertText("", "😢"))
    }
}
