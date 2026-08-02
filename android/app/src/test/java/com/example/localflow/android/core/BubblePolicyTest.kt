package com.example.localflow.android.core

import com.example.localflow.android.core.BubblePolicy.Decision
import org.junit.Assert.assertEquals
import org.junit.Test

class BubblePolicyTest {

    private fun decide(
        bubbleEnabled: Boolean = true,
        dictationBusy: Boolean = false,
        imeVisible: Boolean = true,
        fieldEligible: Boolean = true,
        snoozed: Boolean = false,
        dismissed: Boolean = false,
    ) = BubblePolicy.decide(bubbleEnabled, dictationBusy, imeVisible, fieldEligible, snoozed, dismissed)

    @Test
    fun `shows over an eligible field while the keyboard is open`() {
        assertEquals(Decision.SHOW, decide())
    }

    @Test
    fun `hides when the keyboard closes even though focus stays on the field`() {
        // Android keeps input focus on the EditText after the IME is dismissed;
        // the bubble must not linger there.
        assertEquals(Decision.HIDE, decide(imeVisible = false))
    }

    @Test
    fun `hides for an ineligible or missing field`() {
        assertEquals(Decision.HIDE, decide(fieldEligible = false))
    }

    @Test
    fun `a dismissal lasts for the typing session only`() {
        assertEquals(Decision.HIDE, decide(dismissed = true))
        // The service clears `dismissed` when the keyboard closes, so reopening
        // the keyboard evaluates with dismissed = false and shows again.
        assertEquals(Decision.SHOW, decide(dismissed = false))
    }

    @Test
    fun `snooze and the off setting always hide an idle bubble`() {
        assertEquals(Decision.HIDE, decide(snoozed = true))
        assertEquals(Decision.HIDE, decide(bubbleEnabled = false))
    }

    @Test
    fun `an active dictation keeps its bubble everywhere`() {
        // Finish and Cancel must stay reachable across app switches, keyboard
        // dismissals, and fields that stop being eligible mid-dictation.
        assertEquals(Decision.SHOW, decide(dictationBusy = true, imeVisible = false))
        assertEquals(Decision.SHOW, decide(dictationBusy = true, fieldEligible = false))
        assertEquals(Decision.SHOW, decide(dictationBusy = true, snoozed = true))
        assertEquals(Decision.SHOW, decide(dictationBusy = true, dismissed = true))
    }

    @Test
    fun `off wins even over an active dictation`() {
        assertEquals(Decision.HIDE, decide(bubbleEnabled = false, dictationBusy = true))
    }
}
