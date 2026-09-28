package com.vocahq.vocaphone.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class OnboardingStageTest {
    private val ready = SetupStatus(
        microphone = true, notifications = true, keyboard = true, gatewayConfigured = true,
    )

    // --- the rules the page used to be derived from, kept ------------------

    @Test
    fun `review finds the first real missing requirement in page order`() {
        assertEquals(OnboardingStage.MODEL, OnboardingStage.firstUnmet(SetupStatus()))
        assertEquals(OnboardingStage.MICROPHONE, OnboardingStage.firstUnmet(SetupStatus(gatewayConfigured = true)))
        assertEquals(OnboardingStage.NOTIFICATIONS, OnboardingStage.firstUnmet(ready.copy(notifications = false)))
        assertEquals(OnboardingStage.KEYBOARD, OnboardingStage.firstUnmet(ready.copy(keyboard = false)))
        assertEquals(OnboardingStage.READY, OnboardingStage.firstUnmet(ready))
    }

    @Test
    fun `enabled but unselected keyboard cannot advance`() {
        val status = ready.copy(keyboard = false, ime = ImeSetupStatus(enabled = true))
        assertFalse(OnboardingStage.KEYBOARD.isSatisfied(status))
        assertEquals(OnboardingStage.KEYBOARD, OnboardingStage.firstUnmet(status))
    }

    @Test
    fun `revoking any requirement blocks completion and offers the right recovery page`() {
        val revoked = listOf(
            ready.copy(keyboard = false) to OnboardingStage.KEYBOARD,
            ready.copy(microphone = false) to OnboardingStage.MICROPHONE,
            ready.copy(notifications = false) to OnboardingStage.NOTIFICATIONS,
            ready.copy(gatewayConfigured = false) to OnboardingStage.MODEL,
        )
        revoked.forEach { (status, recovery) ->
            assertFalse(OnboardingStage.READY.isSatisfied(status))
            assertEquals(recovery, OnboardingStage.firstUnmet(status))
        }
        assertTrue(OnboardingStage.READY.isSatisfied(ready))
    }

    @Test
    fun `back and forward preserve the ordered journey without granting readiness`() {
        assertEquals(OnboardingStage.WELCOME, OnboardingStage.WELCOME.previous())
        assertEquals(OnboardingStage.READY, OnboardingStage.READY.next())
        OnboardingStage.entries
            .filterNot { it == OnboardingStage.READY || it == OnboardingStage.KEYBOARD_READY || it == OnboardingStage.KEYBOARD }
            .forEach { page -> assertEquals(page, page.next().previous()) }
        // Pages that carry a requirement are not satisfied by an empty status.
        OnboardingStage.entries.filter { it.step != null }
            .forEach { assertFalse(it.name, it.isSatisfied(SetupStatus())) }
    }

    // --- Continue walks past requirements already met ---------------------

    @Test
    fun `after review the model page leads straight to the end`() {
        // The reported case: skip the model, meet everything else, come back
        // for the model — Continue must not replay three green pages.
        assertEquals(OnboardingStage.READY, OnboardingStage.MODEL.advance(ready, true))
    }

    @Test
    fun `continue stops at the next unmet requirement only`() {
        assertEquals(OnboardingStage.MICROPHONE, OnboardingStage.MODEL.advance(ready.copy(microphone = false), true))
        assertEquals(OnboardingStage.KEYBOARD, OnboardingStage.MODEL.advance(ready.copy(keyboard = false), true))
        assertEquals(OnboardingStage.NOTIFICATIONS, OnboardingStage.MICROPHONE.advance(ready.copy(notifications = false), true))
    }

    @Test
    fun `the source page always shows the model page to a local user`() {
        assertEquals(OnboardingStage.MODEL, OnboardingStage.SOURCE.advance(SetupStatus(), true))
        assertEquals(OnboardingStage.MODEL, OnboardingStage.SOURCE.advance(ready, true))
    }

    @Test
    fun `a gateway user skips the model page and any met requirement`() {
        assertEquals(OnboardingStage.MICROPHONE, OnboardingStage.SOURCE.advance(SetupStatus(gatewayConfigured = true), false))
        assertEquals(OnboardingStage.READY, OnboardingStage.SOURCE.advance(ready, false))
    }

    @Test
    fun `continue never lands on the confirmation`() {
        assertEquals(OnboardingStage.READY, OnboardingStage.KEYBOARD.advance(ready, true))
    }

    @Test
    fun `the welcome always leads to the source choice`() {
        assertEquals(OnboardingStage.SOURCE, OnboardingStage.WELCOME.advance(ready, true))
        assertEquals(OnboardingStage.SOURCE, OnboardingStage.WELCOME.advance(SetupStatus(), false))
    }

    // --- what the split adds ------------------------------------------------

    @Test
    fun `a fresh install starts at the welcome`() {
        assertEquals(OnboardingStage.WELCOME, OnboardingStage.resume(null, SetupStatus()))
        assertEquals(OnboardingStage.WELCOME, OnboardingStage.resume(null, ready))
    }

    @Test
    fun `a saved teaching or choice page is shown again as saved`() {
        assertEquals(OnboardingStage.WELCOME, OnboardingStage.resume(OnboardingStage.WELCOME, SetupStatus()))
        assertEquals(OnboardingStage.SOURCE, OnboardingStage.resume(OnboardingStage.SOURCE, SetupStatus()))
    }

    @Test
    fun `a saved page whose requirement was met while away is walked past`() {
        // Granted the microphone from Settings, then came back.
        val status = SetupStatus(gatewayConfigured = true, microphone = true)
        assertEquals(OnboardingStage.NOTIFICATIONS, OnboardingStage.resume(OnboardingStage.MICROPHONE, status))
        // Everything done while away lands on the end.
        assertEquals(OnboardingStage.READY, OnboardingStage.resume(OnboardingStage.MODEL, ready))
    }

    @Test
    fun `skipping the model leaves its requirement unmet so the end still asks`() {
        assertTrue(OnboardingStage.MODEL.allowsSkip)
        assertFalse(OnboardingStage.MICROPHONE.allowsSkip)
        val skipped = ready.copy(gatewayConfigured = false)
        assertFalse(OnboardingStage.READY.isSatisfied(skipped))
        assertEquals(OnboardingStage.MODEL, OnboardingStage.firstUnmet(skipped))
    }

    @Test
    fun `the confirmation is never a landing page and back steps over it`() {
        OnboardingStage.entries.forEach { saved ->
            assertFalse(OnboardingStage.resume(saved, SetupStatus()) == OnboardingStage.KEYBOARD_READY)
            assertFalse(OnboardingStage.resume(saved, ready) == OnboardingStage.KEYBOARD_READY)
        }
        assertEquals(OnboardingStage.KEYBOARD, OnboardingStage.READY.previous())
        assertEquals(OnboardingStage.KEYBOARD, OnboardingStage.KEYBOARD_READY.previous())
    }

    @Test
    fun `an unknown saved value starts over rather than crashing`() {
        assertNull(OnboardingStage.persisted(null))
        assertNull(OnboardingStage.persisted(""))
        assertNull(OnboardingStage.persisted("handoff"))
        assertEquals(OnboardingStage.MODEL, OnboardingStage.persisted("MODEL"))
        assertEquals(OnboardingStage.WELCOME, OnboardingStage.resume(OnboardingStage.persisted("retired-page"), ready))
    }

    @Test
    fun `progress only moves forward and the confirmation shares the keyboard stop`() {
        val walk = OnboardingStage.entries
        walk.zipWithNext().forEach { (a, b) -> assertTrue("${a.name} -> ${b.name}", a.progress <= b.progress) }
        assertEquals(OnboardingStage.KEYBOARD.progress, OnboardingStage.KEYBOARD_READY.progress)
        assertEquals(1f, OnboardingStage.READY.progress)
    }
}
