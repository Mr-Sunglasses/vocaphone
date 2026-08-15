package com.vocahq.vocaphone.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AboutCopyTest {

    @Test
    fun `source links point at the org, the repo, and a new issue`() {
        assertEquals("https://github.com/VocaHQ", ORG_URL)
        assertEquals("https://github.com/VocaHQ/vocaphone", PROJECT_URL)
        assertEquals("https://vocaphone.vocahq.com", WEBSITE_URL)
        assertEquals("https://github.com/VocaHQ/vocaphone/issues/new/choose", NEW_ISSUE_URL)
    }

    @Test
    fun `about copy names the family and the other platforms`() {
        assertTrue(ABOUT_TAGLINE.contains("Android"))
        assertTrue(ABOUT_TAGLINE.contains("iPhone"))
        assertTrue(ABOUT_FAMILY_NOTE.contains("VocaHQ"))
        assertTrue(ABOUT_FAMILY_NOTE.contains("VocaLinux"))
        assertTrue(ABOUT_FAMILY_NOTE.contains("VocaMac"))
        assertTrue(ABOUT_FAMILY_NOTE.contains("Windows"))
        assertTrue(ABOUT_FAMILY_NOTE.contains("iPhone"))
        assertTrue(ABOUT_FEEDBACK_NOTE.contains("GitHub issue"))
    }

    @Test
    fun `about copy skips em dashes`() {
        for (text in listOf(ABOUT_TAGLINE, ABOUT_FAMILY_NOTE, ABOUT_FEEDBACK_NOTE)) {
            assertFalse(text.contains("—"))
            assertFalse(text.contains("–"))
        }
    }
}
