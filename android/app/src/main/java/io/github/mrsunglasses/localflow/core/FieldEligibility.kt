package io.github.mrsunglasses.localflow.core

import android.text.InputType

/**
 * Everything the bubble needs to know about a focused node, lifted out of
 * `AccessibilityNodeInfo` so the policy below stays testable. Field *contents*
 * are deliberately absent: eligibility never depends on what the user has typed.
 */
data class FieldSignals(
    val editable: Boolean,
    val visibleToUser: Boolean,
    val enabled: Boolean,
    val password: Boolean,
    val inputType: Int,
    val hintText: String?,
    val viewIdResourceName: String?,
    val packageName: String?,
)

enum class FieldEligibility {
    /** A normal editable field: show the bubble. */
    ELIGIBLE,

    /** Editable, but sensitive or in an excluded app: stay hidden and silent. */
    SUPPRESSED,

    /** Nothing to dictate into. */
    NOT_EDITABLE,
    ;

    val allowsDictation: Boolean get() = this == ELIGIBLE
}

object FieldClassifier {

    /**
     * Apps whose text fields are never a dictation target: the system UI and the
     * permission flows the user might be granting Local Flow's own access in.
     */
    val ALWAYS_EXCLUDED_PACKAGES: Set<String> = setOf(
        "com.android.systemui",
        "com.android.permissioncontroller",
        "com.google.android.permissioncontroller",
        "com.android.packageinstaller",
        "com.google.android.packageinstaller",
    )

    /**
     * Matched against a field's resource id and hint. These names accompany
     * credentials and payment details often enough that the cost of a missed
     * bubble is far below the cost of overlaying a card number field.
     */
    private val SENSITIVE_KEYWORDS = listOf(
        "password", "passwd", "passcode", "pin", "otp", "2fa", "mfa",
        "cvv", "cvc", "cardnumber", "card_number", "creditcard", "credit_card",
        "debitcard", "debit_card", "securitycode", "security_code", "expiry",
        "expiration", "iban", "sortcode", "sort_code", "routing", "ssn",
        "socialsecurity", "social_security", "taxid", "seedphrase", "seed_phrase",
        "mnemonic", "recoveryphrase", "recovery_phrase",
    )

    fun classify(
        signals: FieldSignals,
        excludedPackages: Set<String> = emptySet(),
    ): FieldEligibility {
        if (!signals.editable || !signals.enabled || !signals.visibleToUser) {
            return FieldEligibility.NOT_EDITABLE
        }
        val packageName = signals.packageName
        if (packageName != null &&
            (packageName in ALWAYS_EXCLUDED_PACKAGES || packageName in excludedPackages)
        ) {
            return FieldEligibility.SUPPRESSED
        }
        if (isSensitive(signals)) return FieldEligibility.SUPPRESSED
        return FieldEligibility.ELIGIBLE
    }

    fun isSensitive(signals: FieldSignals): Boolean {
        if (signals.password) return true
        if (isSensitiveInputType(signals.inputType)) return true
        return matchesSensitiveName(signals.viewIdResourceName) || matchesSensitiveName(signals.hintText)
    }

    fun isSensitiveInputType(inputType: Int): Boolean {
        val klass = inputType and InputType.TYPE_MASK_CLASS
        val variation = inputType and InputType.TYPE_MASK_VARIATION
        return when (klass) {
            InputType.TYPE_CLASS_TEXT -> variation == InputType.TYPE_TEXT_VARIATION_PASSWORD ||
                variation == InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD ||
                variation == InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD

            InputType.TYPE_CLASS_NUMBER -> variation == InputType.TYPE_NUMBER_VARIATION_PASSWORD
            // A phone-number pad is never worth dictating into and is a common
            // disguise for payment entry.
            InputType.TYPE_CLASS_PHONE -> true
            else -> false
        }
    }

    private fun matchesSensitiveName(value: String?): Boolean {
        if (value.isNullOrBlank()) return false
        val normalized = value.lowercase().filter { it.isLetterOrDigit() || it == '_' }
        return SENSITIVE_KEYWORDS.any { normalized.contains(it) }
    }
}
