package com.example.localflow.android.core

import android.text.InputType
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FieldClassifierTest {

    private fun signals(
        editable: Boolean = true,
        visible: Boolean = true,
        enabled: Boolean = true,
        password: Boolean = false,
        inputType: Int = InputType.TYPE_CLASS_TEXT,
        hint: String? = null,
        viewId: String? = null,
        packageName: String? = "com.example.notes",
    ) = FieldSignals(editable, visible, enabled, password, inputType, hint, viewId, packageName)

    @Test
    fun `an ordinary visible editable field is eligible`() {
        assertEquals(FieldEligibility.ELIGIBLE, FieldClassifier.classify(signals()))
    }

    @Test
    fun `a hidden disabled or non editable field is not a target`() {
        assertEquals(FieldEligibility.NOT_EDITABLE, FieldClassifier.classify(signals(editable = false)))
        assertEquals(FieldEligibility.NOT_EDITABLE, FieldClassifier.classify(signals(visible = false)))
        assertEquals(FieldEligibility.NOT_EDITABLE, FieldClassifier.classify(signals(enabled = false)))
    }

    @Test
    fun `password fields are suppressed however they are flagged`() {
        assertEquals(FieldEligibility.SUPPRESSED, FieldClassifier.classify(signals(password = true)))
        assertEquals(
            FieldEligibility.SUPPRESSED,
            FieldClassifier.classify(
                signals(inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD)
            ),
        )
        assertEquals(
            FieldEligibility.SUPPRESSED,
            FieldClassifier.classify(
                signals(
                    inputType = InputType.TYPE_CLASS_TEXT or
                        InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD
                )
            ),
        )
        assertEquals(
            FieldEligibility.SUPPRESSED,
            FieldClassifier.classify(
                signals(inputType = InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_VARIATION_PASSWORD)
            ),
        )
    }

    @Test
    fun `payment and credential field names are suppressed`() {
        assertEquals(
            FieldEligibility.SUPPRESSED,
            FieldClassifier.classify(signals(viewId = "com.shop:id/card_number")),
        )
        assertEquals(
            FieldEligibility.SUPPRESSED,
            FieldClassifier.classify(signals(hint = "Security code (CVV)")),
        )
        assertEquals(
            FieldEligibility.SUPPRESSED,
            FieldClassifier.classify(signals(hint = "One-time passcode")),
        )
    }

    @Test
    fun `system permission screens and excluded apps are suppressed`() {
        assertEquals(
            FieldEligibility.SUPPRESSED,
            FieldClassifier.classify(signals(packageName = "com.google.android.permissioncontroller")),
        )
        assertEquals(
            FieldEligibility.SUPPRESSED,
            FieldClassifier.classify(signals(packageName = "com.bank.app"), setOf("com.bank.app")),
        )
        assertEquals(
            FieldEligibility.ELIGIBLE,
            FieldClassifier.classify(signals(packageName = "com.bank.app"), setOf("com.other.app")),
        )
    }

    @Test
    fun `ordinary names are not mistaken for sensitive ones`() {
        assertFalse(FieldClassifier.isSensitive(signals(hint = "Message")))
        assertFalse(FieldClassifier.isSensitive(signals(viewId = "com.chat:id/compose_input")))
        assertTrue(FieldClassifier.isSensitive(signals(viewId = "com.chat:id/pin_entry")))
    }
}
