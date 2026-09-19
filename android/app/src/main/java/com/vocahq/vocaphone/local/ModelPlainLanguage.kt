package com.vocahq.vocaphone.local

/**
 * What a model is for, in words someone with no idea what a speech model is can
 * choose between.
 *
 * The catalog's names are the upstream ones -- "Parakeet TDT 0.6B", "Canary
 * 180M Flash" -- and they are right to keep for anyone who looks the model up,
 * but on their own they say nothing about which one to download. The picker
 * leads with [title] and [summary] and keeps the upstream name as the small
 * print underneath.
 *
 * The ratings are relative to the rest of this catalog, not measurements:
 * accuracy follows the published numbers quoted beside each catalog entry,
 * speed the arm64 timings recorded there. Nothing here was benchmarked on a
 * phone. Mirrors `ModelPlainLanguage.swift`.
 */
data class ModelPlainLanguage(
    /** A few words naming the job, such as "Most accurate English". */
    val title: String,
    /** One sentence on what the model is good at and what it costs. */
    val summary: String,
    /** 1 to [MAXIMUM_RATING], how often it gets the words right here. */
    val accuracy: Int,
    /** 1 to [MAXIMUM_RATING], how quickly text appears after speaking here. */
    val speed: Int,
) {
    /** "Accuracy 4 of 4, speed 3 of 4", for TalkBack. */
    val accessibilityRatings: String
        get() = "Accuracy $accuracy of $MAXIMUM_RATING, speed $speed of $MAXIMUM_RATING"

    companion object {
        const val MAXIMUM_RATING = 4

        /**
         * Every catalog id. `ModelPlainLanguageTest` fails when a model is added
         * without an entry, so a new row cannot reach the picker unexplained.
         */
        val byId: Map<String, ModelPlainLanguage> = mapOf(
            "tiny-q8_0" to ModelPlainLanguage(
                "Tiny · most languages",
                "The smallest download that works with almost any language. Makes the most mistakes.",
                accuracy = 1, speed = 4,
            ),
            "base-q8_0" to ModelPlainLanguage(
                "Basic · most languages",
                "Small and works with almost any language, but makes more mistakes.",
                accuracy = 1, speed = 3,
            ),
            "small-q8_0" to ModelPlainLanguage(
                "Good · most languages",
                "Works with almost any language. Fewer mistakes than Basic, a little slower.",
                accuracy = 2, speed = 2,
            ),
            "large-v3-turbo-q5_0" to ModelPlainLanguage(
                "Best · most languages (compact)",
                "The most accurate choice for a language with no model of its own here, " +
                    "in a build that fits phones with less memory. Slow.",
                accuracy = 4, speed = 1,
            ),
            "large-v3-turbo-q8_0" to ModelPlainLanguage(
                "Best · most languages",
                "The most accurate choice for a language with no model of its own here. " +
                    "Slow, and a large download.",
                accuracy = 4, speed = 1,
            ),
            "omnilingual-300m-ctc" to ModelPlainLanguage(
                "Hundreds of languages",
                "Understands far more languages than anything else here, including rare ones. " +
                    "Less accurate in common languages.",
                accuracy = 2, speed = 2,
            ),
            "parakeet-tdt-ctc-110m-en" to ModelPlainLanguage(
                "Small English",
                "Accurate, fast English with punctuation, in a small download.",
                accuracy = 3, speed = 4,
            ),
            "parakeet-tdt-0.6b-v2-en" to ModelPlainLanguage(
                "Most accurate English",
                "The most accurate English model here. A large download.",
                accuracy = 4, speed = 3,
            ),
            "parakeet-tdt-0.6b-v3" to ModelPlainLanguage(
                "European languages",
                "Very accurate in 25 European languages, English included, " +
                    "and tells them apart by itself.",
                accuracy = 4, speed = 3,
            ),
            "sense-voice" to ModelPlainLanguage(
                "Chinese, Japanese and Korean",
                "Mandarin, Cantonese, Japanese, Korean and English in one fast model.",
                accuracy = 3, speed = 4,
            ),
            "dolphin-small-ctc" to ModelPlainLanguage(
                "Asian languages",
                "Hindi, Bengali, Tamil, Thai, Indonesian and many more, " +
                    "and tells them apart by itself.",
                accuracy = 2, speed = 3,
            ),
            "canary-180m-flash" to ModelPlainLanguage(
                "English, German, Spanish, French",
                "Accurate in four languages, and can translate between them.",
                accuracy = 3, speed = 3,
            ),
            "giga-am-v3-ru" to ModelPlainLanguage(
                "Russian",
                "Made for Russian, with punctuation. Far more accurate than the general models.",
                accuracy = 4, speed = 3,
            ),
            "parakeet-tdt-ctc-ja" to ModelPlainLanguage(
                "Most accurate Japanese",
                "Made for Japanese. A large download.",
                accuracy = 4, speed = 3,
            ),
            "paraformer-zh-small" to ModelPlainLanguage(
                "Small Chinese",
                "A small Mandarin model that is quick to download.",
                accuracy = 2, speed = 4,
            ),
            "zipformer-ko" to ModelPlainLanguage(
                "Small Korean",
                "Made for Korean, in a small download.",
                accuracy = 3, speed = 4,
            ),
            "zipformer-vi" to ModelPlainLanguage(
                "Vietnamese",
                "Made for Vietnamese: very accurate, in a small download.",
                accuracy = 4, speed = 4,
            ),
        )

        /** Falls back to the upstream facts, so a row can never render blank. */
        fun of(model: LocalModelDescriptor): ModelPlainLanguage =
            byId[model.id] ?: ModelPlainLanguage(
                title = model.displayName,
                summary = model.languages,
                accuracy = 2,
                speed = 2,
            )
    }
}

val LocalModelDescriptor.plain: ModelPlainLanguage get() = ModelPlainLanguage.of(this)
