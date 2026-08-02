package com.example.localflow.android.core

import java.util.UUID

/** What the bubble and the companion app are both driven by. */
enum class DictationPhase {
    IDLE,
    LISTENING,
    FINALIZING,
    UPLOADING,
    TRANSCRIBING,
    READY_TO_INSERT,
    INSERTING,
    INSERTED,
    FAILED,
    PERMISSION_REPAIR,
    ;

    val isBusy: Boolean
        get() = this == LISTENING || this == FINALIZING || this == UPLOADING ||
            this == TRANSCRIBING || this == INSERTING

    val holdsMicrophone: Boolean
        get() = this == LISTENING || this == FINALIZING
}

/** Permissions the user has to repair before dictation can run again. */
enum class MissingPermission {
    MICROPHONE,
    NOTIFICATIONS,
    OVERLAY,
    ACCESSIBILITY,
    GATEWAY_NOT_CONFIGURED,
    ;

    val title: String
        get() = when (this) {
            MICROPHONE -> "Microphone access"
            NOTIFICATIONS -> "Notifications"
            OVERLAY -> "Display over other apps"
            ACCESSIBILITY -> "Local Flow accessibility service"
            GATEWAY_NOT_CONFIGURED -> "Gateway address and token"
        }
}

data class DictationFailure(
    val code: String,
    val message: String,
    val recoverable: Boolean,
)

/**
 * One dictation, from the tap that starts it to the transcript that leaves it.
 * [sessionId] is generated once and reused across streaming, batch fallback,
 * retries and process recreation so the gateway stays idempotent.
 */
data class DictationState(
    val sessionId: UUID? = null,
    val phase: DictationPhase = DictationPhase.IDLE,
    val language: TranscriptionLanguage = TranscriptionLanguage.DEFAULT,
    val style: WritingStyle = WritingStyle.DEFAULT,
    val startedAtElapsedMillis: Long = 0L,
    val recordedMillis: Long = 0L,
    val level: Float = 0f,
    val partialTranscript: String = "",
    /** True once the recording is within a minute of the five-minute cap. */
    val approachingLimit: Boolean = false,
    val transcript: String? = null,
    val streaming: Boolean = false,
    val failure: DictationFailure? = null,
    val missingPermissions: Set<MissingPermission> = emptySet(),
    val inputRouteLabel: String? = null,
) {
    val isRecording: Boolean get() = phase.holdsMicrophone
    val canRetry: Boolean get() = phase == DictationPhase.FAILED && failure?.recoverable == true

    /** The user-visible line under the bubble and in the companion app. */
    val statusText: String
        get() = when (phase) {
            DictationPhase.IDLE -> "Tap to dictate"
            DictationPhase.LISTENING -> "Listening"
            DictationPhase.FINALIZING -> "Finishing"
            DictationPhase.UPLOADING -> "Sending to your gateway"
            DictationPhase.TRANSCRIBING -> "Transcribing"
            DictationPhase.READY_TO_INSERT -> "Ready to insert"
            DictationPhase.INSERTING -> "Inserting"
            DictationPhase.INSERTED -> "Inserted"
            DictationPhase.FAILED -> failure?.message ?: "Dictation failed"
            DictationPhase.PERMISSION_REPAIR -> "Permission needed"
        }

    companion object {
        /** Active dictation follows focus across apps, but never past this. */
        const val MAXIMUM_RECORDING_MILLIS = 5 * 60 * 1000L

        /** A one-minute warning before the cap stops the recording for them. */
        const val RECORDING_WARNING_MILLIS = 4 * 60 * 1000L
    }
}
