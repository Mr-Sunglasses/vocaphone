package com.vocahq.vocaphone.ui

import org.junit.Assert.assertTrue
import org.junit.Test

class ModelDeleteCopyTest {

    @Test
    fun deletingTheModelInUseSaysDictationStops() {
        assertTrue(modelDeleteConfirmation("142 MB", inUse = true).contains("stops working"))
    }

    @Test
    fun deletingAnotherModelOnlyMentionsTheSpace() {
        val text = modelDeleteConfirmation("142 MB", inUse = false)
        assertTrue(text.contains("142 MB"))
        assertTrue(!text.contains("stops"))
    }
}
