package com.vocahq.vocaphone.core

import android.view.inputmethod.EditorInfo

/**
 * Whether the keyboard may read a dictation back from this field to learn
 * the spellings the user fixes in it ([CorrectionWatch]).
 *
 * Only where dictation itself is offered — never a password or PIN field —
 * and never in a field that asked keyboards not to learn from it
 * ([EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING], set by incognito tabs and
 * private messaging), nor in one whose hint or id names a secret
 * ([FieldClassifier]'s list: one-time codes, card numbers, recovery phrases).
 */
object CorrectionLearningPolicy {
    fun allowsLearning(inputType: Int, imeOptions: Int, hintText: CharSequence?, fieldName: String?): Boolean {
        if (!ImeInputPolicy.acceptsDictation(inputType)) return false
        if (imeOptions and EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING != 0) return false
        return !FieldClassifier.matchesSensitiveName(hintText?.toString()) &&
            !FieldClassifier.matchesSensitiveName(fieldName)
    }
}
