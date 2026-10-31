package com.vocahq.vocaphone.writing

import com.vocahq.vocaphone.settings.VocaPhoneSettings

/** The groups Writing check offers, from Settings. Correctness is always on. */
fun VocaPhoneSettings.writingCategories(): Set<WritingCategory> = buildSet {
    add(WritingCategory.CORRECTNESS)
    if (writingClarity) add(WritingCategory.CLARITY)
    if (writingEngagement) add(WritingCategory.ENGAGEMENT)
    if (writingDelivery) add(WritingCategory.DELIVERY)
}
