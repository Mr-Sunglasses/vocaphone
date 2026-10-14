package com.vocahq.vocaphone.core

import java.util.UUID

/** What the keyboard and the companion app are both driven by. */
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

    /**
     * The dictation no longer owns work that needs the foreground service.
     *
     * Derived from [isBusy] rather than listed again: spelled out separately,
     * the two enumerations cover the same phases and a phase added to one would
     * quietly go missing from the other, leaving the service either stopped
     * mid-transcription or never stopped at all.
     */
    val isTerminal: Boolean
        get() = !isBusy

    val holdsMicrophone: Boolean
        get() = this == LISTENING || this == FINALIZING
}

/** Permissions the user has to repair before dictation can run again. */
enum class MissingPermission {
    MICROPHONE,
    NOTIFICATIONS,
    /** X build only: the overlay permission that lets the bubble draw. */
    OVERLAY,
    /** X build only: the accessibility service that finds the field and inserts. */
    ACCESSIBILITY,
    GATEWAY_NOT_CONFIGURED,
    MODEL_DOWNLOADING,
    MODEL_PREPARING,

    /**
     * On-device transcription is on but the stored model cannot run: it is not
     * in the catalog (a selection this build no longer ships, or one the launch
     * migration has not reached yet), or its files are not on this phone and no
     * download of it is under way. Either way the local route cannot run, and saying so
     * before the microphone opens is the whole point of this state.
     */
    LOCAL_MODEL_UNAVAILABLE,
    ;

    val title: String
        get() = when (this) {
            MICROPHONE -> "Microphone access"
            NOTIFICATIONS -> "Notifications"
            OVERLAY -> "Display over other apps"
            ACCESSIBILITY -> "VocaPhone accessibility service"
            GATEWAY_NOT_CONFIGURED -> "Gateway address and token"
            MODEL_DOWNLOADING -> "Model download"
            MODEL_PREPARING -> "Model preparation"
            LOCAL_MODEL_UNAVAILABLE -> "Voice model"
        }
}

data class DictationFailure(
    val code: String,
    val message: String,
    /** Whether the recording was kept and Retry can re-send it. */
    val recoverable: Boolean,
    /**
     * A few words for a one-line status. [message] is a sentence, and the
     * keyboard's status line cut it off after "Could not reach your g…".
     */
    val title: String = failureTitle(code),
)

/**
 * The short form of a failure, keyed on its code (a closed set) rather than
 * its message. Anything unfamiliar is just "Dictation failed": the message
 * underneath still says what happened.
 */
fun failureTitle(code: String): String = when {
    code == "gateway_unreachable" || code == "unreachable" -> "Gateway unreachable"
    code in TOKEN_REJECTED_CODES -> "Gateway token rejected"
    code == "language_unsupported" -> "Language not supported"
    code == "empty_transcript" -> "Nothing was heard"
    code == "audio_expired" -> "Recording expired"
    code == "local_model_integrity" -> "Voice model damaged"
    code == "local_transcription_failed" -> "Transcription failed"
    code == "microphone_silenced" -> "Microphone in use"
    code == "microphone_service_refused" -> "Couldn't start the microphone"
    code.startsWith("microphone") || code.startsWith("audio") -> "Microphone interrupted"
    code == "engine_not_ready" || code == "engine_unavailable" -> "Gateway busy"
    code.startsWith("insert") -> "Couldn't insert"
    else -> "Dictation failed"
}

/** The codes a gateway answers a bad or missing bearer token with. */
val TOKEN_REJECTED_CODES = setOf("unauthorized", "forbidden", "http_401", "http_403")

/**
 * One dictation, from the tap that starts it to the transcript that leaves it.
 * [sessionId] is generated once and reused across streaming, batch fallback,
 * retries and process recreation so the gateway stays idempotent.
 */
data class DictationState(
    val sessionId: UUID? = null,
    val phase: DictationPhase = DictationPhase.IDLE,
    val modelDownloadProgress: Int? = null,
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
    /**
     * A more specific line than the phase alone can give. Currently only the
     * on-device model being loaded, which is the one wait long enough that
     * "Transcribing" reads as the app having hung.
     */
    val statusDetail: String? = null,
) {
    val isRecording: Boolean get() = phase.holdsMicrophone
    val canRetry: Boolean get() = phase == DictationPhase.FAILED && failure?.recoverable == true

    /** The user-visible status line in the keyboard and companion app. */
    val statusText: String
        get() = when (phase) {
            DictationPhase.IDLE -> "Tap to dictate"
            DictationPhase.LISTENING -> "Listening"
            DictationPhase.FINALIZING -> "Finishing"
            DictationPhase.UPLOADING -> "Sending to your gateway"
            DictationPhase.TRANSCRIBING -> statusDetail ?: "Transcribing"
            DictationPhase.READY_TO_INSERT -> "Ready to insert"
            DictationPhase.INSERTING -> "Inserting"
            DictationPhase.INSERTED -> "Inserted"
            DictationPhase.FAILED -> failure?.message ?: "Dictation failed"
            DictationPhase.PERMISSION_REPAIR -> repairTitle
        }

    /**
     * Whether the only thing missing is a voice model on this phone. The
     * keyboard says so and opens the Models page rather than "Permission
     * needed", which sent people looking for a permission that was never off.
     */
    val needsVoiceModel: Boolean
        get() = phase == DictationPhase.PERMISSION_REPAIR &&
            missingPermissions == setOf(MissingPermission.LOCAL_MODEL_UNAVAILABLE)

    /**
     * Named after what is actually missing. Every repair used to be
     * "Permission needed", which read as a permission prompt for a model
     * still downloading or a gateway nobody had set up yet.
     */
    val repairTitle: String
        get() = when {
            MissingPermission.MICROPHONE in missingPermissions -> "Microphone permission needed"
            MissingPermission.NOTIFICATIONS in missingPermissions -> "Notification permission needed"
            MissingPermission.OVERLAY in missingPermissions ||
                MissingPermission.ACCESSIBILITY in missingPermissions -> "Permission needed"
            MissingPermission.GATEWAY_NOT_CONFIGURED in missingPermissions -> "Gateway not set up"
            MissingPermission.MODEL_PREPARING in missingPermissions -> "Preparing model"
            MissingPermission.MODEL_DOWNLOADING in missingPermissions -> "Model downloading"
            MissingPermission.LOCAL_MODEL_UNAVAILABLE in missingPermissions -> "Voice model needed"
            else -> "Setup needed"
        }

    /**
     * Where the companion app should open for this repair: the page that has
     * the fix, not Settings home. Permissions are granted from the Dictate
     * screen's repair list; a gateway is set up from Speech; anything about
     * the model is on Models. Keys are the ones `SettingsPage.fromExtra`
     * reads, plus "dictate" for the Dictate screen.
     */
    val repairPage: String?
        get() = when {
            phase != DictationPhase.PERMISSION_REPAIR -> null
            missingPermissions.any { it in PERMISSION_REPAIRS } -> REPAIR_PAGE_DICTATE
            MissingPermission.GATEWAY_NOT_CONFIGURED in missingPermissions -> "connection"
            missingPermissions.any { it in MODEL_REPAIRS } -> "models"
            else -> null
        }

    companion object {
        /** [repairPage] for the Dictate screen, where the permission rows are. */
        const val REPAIR_PAGE_DICTATE = "dictate"

        private val PERMISSION_REPAIRS = setOf(
            MissingPermission.MICROPHONE,
            MissingPermission.NOTIFICATIONS,
            MissingPermission.OVERLAY,
            MissingPermission.ACCESSIBILITY,
        )

        private val MODEL_REPAIRS = setOf(
            MissingPermission.MODEL_DOWNLOADING,
            MissingPermission.MODEL_PREPARING,
            MissingPermission.LOCAL_MODEL_UNAVAILABLE,
        )

        /** Active dictation follows focus across apps, but never past this. */
        const val MAXIMUM_RECORDING_MILLIS = 5 * 60 * 1000L

        /** A one-minute warning before the cap stops the recording for them. */
        const val RECORDING_WARNING_MILLIS = 4 * 60 * 1000L
    }

    /**
     * The keyboard's second line under [repairTitle]: what a tap on the mic
     * does about it, since the title already says what is wrong.
     */
    val repairAction: String
        get() = when {
            MissingPermission.MODEL_PREPARING in missingPermissions -> "Almost ready"
            MissingPermission.MODEL_DOWNLOADING in missingPermissions ->
                modelDownloadProgress?.let { "$it% · Tap to see the download" } ?: "Tap to see the download"
            repairPage == REPAIR_PAGE_DICTATE -> "Tap to check again or open VocaPhone"
            MissingPermission.GATEWAY_NOT_CONFIGURED in missingPermissions -> "Tap to set up your gateway"
            MissingPermission.LOCAL_MODEL_UNAVAILABLE in missingPermissions -> "Tap to download one"
            else -> repairHint
        }

    val repairHint: String
        get() = when {
            MissingPermission.MODEL_PREPARING in missingPermissions -> "Preparing model…"
            MissingPermission.MODEL_DOWNLOADING in missingPermissions ->
                modelDownloadProgress?.let { "Model downloading · $it%" } ?: "Model downloading"
            MissingPermission.LOCAL_MODEL_UNAVAILABLE in missingPermissions -> "Open VocaPhone to download a voice model"
            else -> "Open VocaPhone to finish setup"
        }
}
