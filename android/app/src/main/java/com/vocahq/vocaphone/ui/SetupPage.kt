package com.vocahq.vocaphone.ui

/** Page position never grants a requirement; live system state gates every action. */
internal enum class SetupPage(val title: String, val detail: String, private val step: SetupStep?) {
    KEYBOARD("Make room for your voice", "Start by enabling VocaPhone and choosing it as your keyboard.", SetupStep.KEYBOARD),
    MICROPHONE("Let your voice do the typing", "Allow microphone access so VocaPhone can hear your dictation.", SetupStep.MICROPHONE),
    NOTIFICATIONS("Know when you're recording", "Allow notifications to keep recording controls within reach.", SetupStep.NOTIFICATIONS),
    SOURCE("Choose where speech becomes text", "Download a model to dictate on this phone, or connect a gateway you run.", SetupStep.GATEWAY),
    READY("You're ready to dictate", "Your keyboard, permissions, and speech-to-text source are ready.", null);

    fun isSatisfied(status: SetupStatus): Boolean = step?.let(status::isSatisfied) ?: status.isReadyToDictate
    fun previous(): SetupPage = entries[(ordinal - 1).coerceAtLeast(0)]
    fun next(): SetupPage = entries[(ordinal + 1).coerceAtMost(entries.lastIndex)]

    companion object {
        fun resume(status: SetupStatus): SetupPage = entries.firstOrNull { !it.isSatisfied(status) } ?: READY
    }
}
