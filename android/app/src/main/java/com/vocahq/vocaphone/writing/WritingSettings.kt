package com.vocahq.vocaphone.writing

import com.vocahq.vocaphone.settings.VocaPhoneSettings

/** The groups Writing check offers, from Settings. Correctness is always on. */
fun VocaPhoneSettings.writingCategories(): Set<WritingCategory> = buildSet {
    add(WritingCategory.CORRECTNESS)
    if (writingClarity) add(WritingCategory.CLARITY)
    if (writingEngagement) add(WritingCategory.ENGAGEMENT)
    if (writingDelivery) add(WritingCategory.DELIVERY)
}

/** The rules the user turned on that are off by default ([WritingCheck.Options.optIn]). */
fun VocaPhoneSettings.writingOptIn(): Set<String> = buildSet {
    if (writingSerialComma) add("serial_comma")
}
