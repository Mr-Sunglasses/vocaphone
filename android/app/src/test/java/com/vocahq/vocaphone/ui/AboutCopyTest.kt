package com.vocahq.vocaphone.ui

import com.vocahq.vocaphone.R
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
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
    fun `family and contact links match the public sites`() {
        assertEquals("https://vocahq.com", FAMILY_SITE_URL)
        assertEquals("https://vocalinux.com", VOCALINUX_URL)
        assertEquals("https://vocamac.com", VOCAMAC_URL)
        assertEquals("https://vocagateway.vocahq.com", VOCAGATEWAY_SITE_URL)
        assertEquals("https://discord.gg/UMJduhcqn", DISCORD_URL)
        assertEquals("https://x.com/vocahq", X_URL)
        assertEquals("hello@vocahq.com", CONTACT_EMAIL)
        assertEquals("mailto:hello@vocahq.com", CONTACT_MAILTO)
        assertEquals(
            listOf(
                "vocahq.com",
                "vocalinux.com",
                "vocamac.com",
                "vocaphone.vocahq.com",
                "vocagateway.vocahq.com",
            ),
            ABOUT_FAMILY_LINKS.map { it.label },
        )
        assertEquals(
            listOf(FAMILY_SITE_URL, VOCALINUX_URL, VOCAMAC_URL, WEBSITE_URL, VOCAGATEWAY_SITE_URL),
            ABOUT_FAMILY_LINKS.map { it.url },
        )
        ABOUT_FAMILY_LINKS.forEach { assertNull(it.icon) }
        assertEquals(listOf("Discord", "X", "Email"), ABOUT_CONTACT_LINKS.map { it.label })
        assertEquals(
            listOf(DISCORD_URL, X_URL, CONTACT_MAILTO),
            ABOUT_CONTACT_LINKS.map { it.url },
        )
        assertEquals(
            listOf(
                R.drawable.ic_social_discord,
                R.drawable.ic_social_x,
                R.drawable.ic_social_mail,
            ),
            ABOUT_CONTACT_LINKS.map { it.icon },
        )
        ABOUT_CONTACT_LINKS.forEach { assertFalse(it.label.contains("Twitter", ignoreCase = true)) }
    }

    @Test
    fun `talk-to-us hrefs match the VocaDesign social README`() {
        val root = generateSequence(File("").absoluteFile) { it.parentFile }
            .firstOrNull { File(it, "android/brand/vocahq/social/README.md").isFile }
            ?: error("Could not locate android/brand/vocahq/social/README.md")
        val readme = File(root, "android/brand/vocahq/social/README.md").readText()
        assertTrue(readme.contains("https://discord.gg/UMJduhcqn"))
        assertTrue(readme.contains("https://x.com/vocahq"))
        assertTrue(readme.contains("hello@vocahq.com"))
        assertTrue(readme.contains("Label it X, not Twitter"))
        assertEquals("https://discord.gg/UMJduhcqn", DISCORD_URL)
        assertEquals("https://x.com/vocahq", X_URL)
        assertEquals("mailto:hello@vocahq.com", CONTACT_MAILTO)
        assertEquals("https://github.com/VocaHQ/vocaphone/issues/new/choose", NEW_ISSUE_URL)
        assertTrue(NEW_ISSUE_URL.startsWith("https://github.com/VocaHQ/vocaphone/issues"))
    }

    @Test
    fun `about copy names the family and stays honest about status`() {
        assertEquals("VocaPhone", ABOUT_WORDMARK)
        assertEquals("Report a bug or idea", ABOUT_REPORT_BUG)
        assertEquals("Voice-to-text for Android, kept on this phone.", ABOUT_TAGLINE)
        assertTrue(ABOUT_TAGLINE.contains("Android"))
        assertFalse(ABOUT_TAGLINE.contains("iPhone"))
        assertFalse(ABOUT_TAGLINE.contains("iOS"))
        assertTrue(ABOUT_STATUS.contains("Public beta"))
        assertTrue(ABOUT_STATUS.contains("Android 13"))
        assertFalse(ABOUT_STATUS.contains("Play Store", ignoreCase = true))
        assertFalse(ABOUT_STATUS.contains("production", ignoreCase = true))
        assertFalse(ABOUT_STATUS.contains("App Store"))
        assertTrue(ABOUT_ON_DEVICE.contains("on this phone first"))
        assertTrue(ABOUT_ON_DEVICE.contains("optional"))
        assertTrue(ABOUT_ON_DEVICE.contains("self-hosted"))
        assertTrue(ABOUT_ON_DEVICE.contains("never calls it"))
        assertTrue(ABOUT_FAMILY_NOTE.contains("VocaHQ"))
        assertTrue(ABOUT_FAMILY_NOTE.contains("VocaLinux"))
        assertTrue(ABOUT_FAMILY_NOTE.contains("available now"))
        assertTrue(ABOUT_FAMILY_NOTE.contains("VocaMac"))
        assertTrue(ABOUT_FAMILY_NOTE.contains("beta"))
        assertTrue(ABOUT_FAMILY_NOTE.contains("VocaWin"))
        assertTrue(ABOUT_FAMILY_NOTE.contains("developer alpha"))
        assertTrue(ABOUT_FAMILY_NOTE.contains("VocaGateway"))
        assertTrue(ABOUT_FAMILY_NOTE.contains("Early"))
        assertTrue(ABOUT_FAMILY_NOTE.contains("source build"))
        assertFalse(ABOUT_FAMILY_NOTE.contains("on the way", ignoreCase = true))
        assertFalse(ABOUT_FAMILY_NOTE.contains("coming", ignoreCase = true))
        assertTrue(ABOUT_FEEDBACK_NOTE.contains("GitHub issue"))
        assertTrue(ABOUT_PRIVACY_NOTE.contains("does not read the field"))
        assertTrue(ABOUT_PRIVACY_NOTE.contains("32 characters"))
        assertTrue(ABOUT_PRIVACY_NOTE.contains("gateway you set up"))
        assertTrue(ABOUT_PRIVACY_NOTE.contains("no cloud transcription"))
        assertTrue(ABOUT_PRIVACY_NOTE.contains("counters only"))
    }

    @Test
    fun `about copy skips em dashes`() {
        for (text in listOf(
            ABOUT_WORDMARK,
            ABOUT_REPORT_BUG,
            ABOUT_TAGLINE,
            ABOUT_STATUS,
            ABOUT_ON_DEVICE,
            ABOUT_FAMILY_NOTE,
            ABOUT_FEEDBACK_NOTE,
            ABOUT_PRIVACY_NOTE,
            ABOUT_DIAGNOSTICS_NOTE,
            ABOUT_COPY_DIAGNOSTICS,
            ABOUT_CLEAR_EVENT_LOG,
        ) + ABOUT_FAMILY_LINKS.map { it.label } + ABOUT_CONTACT_LINKS.map { it.label }) {
            assertFalse(text.contains("—"))
            assertFalse(text.contains("–"))
        }
    }

    @Test
    fun `talk-to-us marks keep the official VocaDesign paths`() {
        val root = generateSequence(File("").absoluteFile) { it.parentFile }
            .firstOrNull { File(it, "android/brand/vocahq/social/discord.svg").isFile }
            ?: error("Could not locate android/brand/vocahq/social from ${File("").absolutePath}")
        val brand = File(root, "android/brand/vocahq/social")
        val drawable = File(root, "android/app/src/main/res/drawable")
        listOf(
            "discord" to "ic_social_discord.xml",
            "x" to "ic_social_x.xml",
            "github" to "ic_social_github.xml",
            "mail" to "ic_social_mail.xml",
        ).forEach { (stem, xmlName) ->
            val svg = File(brand, "$stem.svg").readText()
            assertTrue("$stem.svg must be 24 viewBox", svg.contains("viewBox=\"0 0 24 24\""))
            assertTrue("$stem.svg must use currentColor", svg.contains("fill=\"currentColor\""))
            assertFalse("$stem.svg must not hard-code blurple", svg.contains("#5865F2", ignoreCase = true))
            assertFalse("$stem.svg must not hard-code X black as a brand fill", svg.contains("fill=\"#000\""))
            val path = Regex("""<path fill="currentColor" d="([^"]+)"""")
                .find(svg)
                ?.groupValues
                ?.get(1)
            assertNotNull("$stem.svg is missing a currentColor path", path)
            val xml = File(drawable, xmlName).readText()
            assertTrue("$xmlName must keep the official $stem path", xml.contains(path!!))
            assertTrue("$xmlName must stay 24 viewport", xml.contains("android:viewportWidth=\"24\""))
        }
    }
}
