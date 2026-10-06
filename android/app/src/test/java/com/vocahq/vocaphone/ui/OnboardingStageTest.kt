package com.vocahq.vocaphone.ui

import com.vocahq.vocaphone.BuildConfig
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class OnboardingStageTest {
    private val floating = BuildConfig.FLOATING_INPUT

    /** A finished checklist for whichever input path this flavor ships. */
    private val ready = if (floating) {
        SetupStatus(
            microphone = true, notifications = true, disclosureAccepted = true,
            overlay = true, accessibility = true, gatewayConfigured = true,
        )
    } else {
        SetupStatus(
            microphone = true, notifications = true, keyboard = true, gatewayConfigured = true,
        )
    }

    /** The input page this flavor lands a person on. */
    private val inputStage =
        if (floating) OnboardingStage.FLOATING_MIC else OnboardingStage.KEYBOARD

    private val inputUnmet = if (floating) ready.copy(accessibility = false) else ready.copy(keyboard = false)

    // --- the rules the page used to be derived from, kept ------------------

    @Test
    fun `review finds the first real missing requirement in page order`() {
        assertEquals(OnboardingStage.MODEL, OnboardingStage.firstUnmet(SetupStatus()))
        assertEquals(OnboardingStage.MICROPHONE, OnboardingStage.firstUnmet(SetupStatus(gatewayConfigured = true)))
        assertEquals(OnboardingStage.NOTIFICATIONS, OnboardingStage.firstUnmet(ready.copy(notifications = false)))
        assertEquals(inputStage, OnboardingStage.firstUnmet(inputUnmet))
        assertEquals(OnboardingStage.READY, OnboardingStage.firstUnmet(ready))
    }

    @Test
    fun `enabled but unselected keyboard cannot advance`() {
        val status = ready.copy(keyboard = false, ime = ImeSetupStatus(enabled = true))
        if (floating) return // the X build has no keyboard to select
        assertFalse(OnboardingStage.KEYBOARD.isSatisfied(status))
        assertEquals(OnboardingStage.KEYBOARD, OnboardingStage.firstUnmet(status))
    }

    @Test
    fun `revoking any requirement blocks completion and offers the right recovery page`() {
        val revoked = listOf(
            inputUnmet to inputStage,
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
        OnboardingStage.active()
            .filterNot { it == OnboardingStage.READY || it == OnboardingStage.KEYBOARD_READY || it == OnboardingStage.KEYBOARD }
            .forEach { page -> assertEquals(page, page.next().previous()) }
        // Pages that carry a requirement are not satisfied by an empty status.
        OnboardingStage.active().filter { it.steps.isNotEmpty() }
            .forEach { assertFalse(it.name, it.isSatisfied(SetupStatus())) }
    }

    // --- Continue walks past requirements already met ---------------------

    @Test
    fun `after review the model page leads straight to the end`() {
        // The reported case: skip the model, meet everything else, come back
        // for the model — Continue must not replay three green pages.
        assertEquals(OnboardingStage.READY, OnboardingStage.MODEL.advance(ready))
    }

    @Test
    fun `continue stops at the next unmet requirement only`() {
        assertEquals(OnboardingStage.MICROPHONE, OnboardingStage.MODEL.advance(ready.copy(microphone = false)))
        assertEquals(inputStage, OnboardingStage.MODEL.advance(inputUnmet))
        assertEquals(OnboardingStage.NOTIFICATIONS, OnboardingStage.MICROPHONE.advance(ready.copy(notifications = false)))
    }

    @Test
    fun `a speech source already set up walks past the model page`() {
        assertEquals(OnboardingStage.MICROPHONE, OnboardingStage.WELCOME.advance(SetupStatus(gatewayConfigured = true)))
        assertEquals(OnboardingStage.READY, OnboardingStage.WELCOME.advance(ready))
    }

    @Test
    fun `continue never lands on the confirmation`() {
        assertEquals(OnboardingStage.READY, inputStage.advance(ready))
    }

    /** No source page: the welcome goes straight to Choose a model, where a gateway is offered too. */
    @Test
    fun `the welcome leads to the model page`() {
        assertEquals(OnboardingStage.MODEL, OnboardingStage.WELCOME.advance(SetupStatus()))
        assertEquals(OnboardingStage.MODEL, OnboardingStage.WELCOME.next())
        assertEquals(OnboardingStage.WELCOME, OnboardingStage.MODEL.previous())
    }

    @Test
    fun `a saved source page resumes on the model page`() {
        assertEquals(OnboardingStage.MODEL, OnboardingStage.persisted("SOURCE"))
        assertEquals(OnboardingStage.MODEL, OnboardingStage.resume(OnboardingStage.persisted("SOURCE"), SetupStatus()))
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
        OnboardingStage.active().forEach { saved ->
            assertFalse(OnboardingStage.resume(saved, SetupStatus()) == OnboardingStage.KEYBOARD_READY)
            assertFalse(OnboardingStage.resume(saved, ready) == OnboardingStage.KEYBOARD_READY)
        }
        assertEquals(inputStage, OnboardingStage.READY.previous())
        if (!floating) {
            assertEquals(OnboardingStage.KEYBOARD, OnboardingStage.KEYBOARD_READY.previous())
        }
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
