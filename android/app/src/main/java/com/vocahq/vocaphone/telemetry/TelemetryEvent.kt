package com.vocahq.vocaphone.telemetry

import com.vocahq.vocaphone.core.TranscriptionQuality
import com.vocahq.vocaphone.local.LocalModelCatalog
import com.vocahq.vocaphone.local.LocalModelDescriptor
import com.vocahq.vocaphone.settings.VocaPhoneSettings

/**
 * The complete telemetry vocabulary.
 *
 * Deliberately finite and content-free, for the same reason
 * [com.vocahq.vocaphone.data.DiagnosticLog] is: nothing here accepts a
 * transcript, typed text, audio path, gateway URL, model file path, or bearer
 * token, so private user content cannot reach the network by accident.
 *
 * The enforcement is structural rather than a matter of review discipline.
 * Every property value below is an enum, and [Telemetry] exposes one typed
 * function per event instead of a generic `track(name, properties)`. A call
 * site cannot pass a free string because no parameter accepts one, and
 * `TelemetryVocabularyTest` fails the build if that ever stops being true.
 *
 * The `wire` values are what land in ClickHouse, so treat them as a published
 * schema: add new ones, never rename an existing one. `TelemetryParityTest`
 * holds them identical to the Swift copy in
 * `ios/VocaPhoneApp/Telemetry/TelemetryEvent.swift` by parsing that file
 * directly; a drifted enum is a silently broken funnel rather than a build
 * failure, which is why it is checked at all.
 */
enum class TelemetryEvent(val wire: String) {
    /**
     * Fired once ever, on the first launch after install. The denominator for
     * every activation ratio, which is the only reason it exists: Aptabase
     * rotates its anonymous user hash daily (see [TelemetryConfig]), so
     * per-user funnels are impossible and counting one-shot milestones is what
     * replaces them.
     */
    APP_FIRST_OPEN("app_first_open"),

    /** Once per step, ever. The setup funnel is the ratio of these to [APP_FIRST_OPEN]. */
    SETUP_STEP_COMPLETED("setup_step_completed"),

    /** Once ever, when guided setup is finished rather than abandoned. */
    SETUP_FINISHED("setup_finished"),

    /** Which transcription route the user picked. Repeats: switching back is a signal. */
    SOURCE_SELECTED("source_selected"),

    /** Whether an on-device model download actually completed, and which one. */
    MODEL_DOWNLOAD_FINISHED("model_download_finished"),

    /**
     * Once ever. The single most valuable number in the whole feature: the
     * share of installs that reach a working transcript at all.
     */
    FIRST_DICTATION_EVER("first_dictation_ever"),

    DICTATION_SUCCEEDED("dictation_succeeded"),

    DICTATION_FAILED("dictation_failed"),

    /**
     * Sent once, as the last act before reporting is switched off, so the
     * opt-out rate is knowable. This is disclosed in the settings copy: a
     * "we log your opt-out" that a user discovers by packet capture is much
     * worse than not knowing the number.
     */
    TELEMETRY_DISABLED("telemetry_disabled"),
    ;

    companion object {
        /** Fired at most once per install. Guarded by a local flag, never sent twice. */
        val ONE_SHOT: Set<TelemetryEvent> = setOf(
            APP_FIRST_OPEN,
            SETUP_STEP_COMPLETED,
            SETUP_FINISHED,
            FIRST_DICTATION_EVER,
        )
    }
}

/**
 * The guided-setup steps, matching what `SetupStatus` already tracks.
 *
 * Deliberately not derived from `SetupStep` in the ui package: that enum is
 * free to be renamed or reordered as the setup screen changes, and this one
 * cannot be, because it is a wire format.
 */
enum class TelemetrySetupStep(val wire: String) {
    KEYBOARD("keyboard"),
    MICROPHONE("microphone"),
    NOTIFICATIONS("notifications"),
    SOURCE("source"),
}

/** Where transcription ran. The gateway's address is never part of this. */
enum class TelemetrySource(val wire: String) {
    ON_DEVICE("on_device"),
    GATEWAY("gateway"),
}

/**
 * Which route the current settings select, as the one fact about the user's
 * transcription setup that may be reported.
 *
 * An extension on the settings rather than a member of them, so the telemetry
 * vocabulary stays in the telemetry package and nothing in
 * `VocaPhoneSettings` has to know this feature exists.
 */
val VocaPhoneSettings.telemetrySource: TelemetrySource
    get() = if (localTranscriptionEnabled) TelemetrySource.ON_DEVICE else TelemetrySource.GATEWAY

/**
 * How much decoding work the on-device engines were allowed to spend.
 *
 * Its own enum rather than a reuse of [TranscriptionQuality] for the same reason
 * [TelemetryReason] is separate from the diagnostic categories: that type is a
 * user-facing setting and is free to grow a case or rename one, while this is a
 * wire format that cannot. It also needs a value the setting has no business
 * having — [NOT_APPLICABLE], for the gateway route, which decides its own
 * decoding and would be misdescribed by whatever happens to be selected locally.
 */
enum class TelemetryQuality(val wire: String) {
    FAST("fast"),
    BALANCED("balanced"),
    ACCURATE("accurate"),

    /**
     * Transcription did not run on this phone, so the local accuracy setting did
     * not apply to it.
     */
    NOT_APPLICABLE("not_applicable"),
    ;

    companion object {
        fun of(quality: TranscriptionQuality?, source: TelemetrySource): TelemetryQuality =
            if (source != TelemetrySource.ON_DEVICE || quality == null) {
                NOT_APPLICABLE
            } else {
                when (quality) {
                    TranscriptionQuality.FAST -> FAST
                    TranscriptionQuality.BALANCED -> BALANCED
                    TranscriptionQuality.ACCURATE -> ACCURATE
                }
            }
    }
}

/**
 * Which model a dictation actually ran on.
 *
 * `model_download_finished` already answers "which models get downloaded", which
 * is a different and much weaker question: a download is a one-time act of
 * optimism, and someone can fetch three models, use one, and go back to the
 * gateway. Only the dictation events can say whether a performance fix landed on
 * the model people are really dictating with.
 *
 * Not an enum, because the catalog is data rather than vocabulary and gains
 * entries every release. The safety comes from pinning instead: anything the
 * shipped [LocalModelCatalog] does not contain is reported as [UNKNOWN], so a
 * sideloaded directory name or a stale identifier cannot reach the network even
 * though the value begins life as a string.
 */
object TelemetryModelId {
    /**
     * Transcription ran on the user's own gateway, which never tells the app
     * which model it loaded — and must not be asked, since that answer describes
     * a machine rather than this install. A fixed value rather than an omitted
     * property, so the column stays groupable instead of ragged.
     */
    const val GATEWAY = "gateway"

    /**
     * A model the shipped catalog does not contain: a sideloaded directory, or
     * an entry withdrawn in a later release.
     */
    const val UNKNOWN = "unknown"

    /**
     * Pins a descriptor to the shipped catalog. Everything that reports a model
     * goes through here, so there is one place to audit rather than two.
     */
    fun pinned(model: LocalModelDescriptor?): String =
        model?.let { LocalModelCatalog.find(it.id)?.id } ?: UNKNOWN

    /**
     * What a dictation reports. Gateway sessions name the gateway rather than
     * whichever model happens to be selected on this phone: attributing a
     * session to a model that never touched it is worse than reporting nothing.
     */
    fun of(model: LocalModelDescriptor?, source: TelemetrySource): String =
        if (source == TelemetrySource.ON_DEVICE) pinned(model) else GATEWAY
}

/**
 * The model the current settings select, resolved against the shipped catalog.
 *
 * An extension for the same reason [telemetrySource] is one: the telemetry
 * vocabulary stays in this package, and `VocaPhoneSettings` does not have to
 * know this feature exists.
 */
val VocaPhoneSettings.telemetryModel: LocalModelDescriptor?
    get() = LocalModelCatalog.find(localModelId)

/**
 * How far a dictation got before it failed, drawn from the timing stages
 * `DiagnosticLog` already records. Knowing that a failure happened is nearly
 * useless; knowing it happened at upload rather than insertion is the whole
 * value of the event.
 */
enum class TelemetryStage(val wire: String) {
    CAPTURE("capture"),
    UPLOAD("upload"),
    TRANSCRIPTION("transcription"),
    INSERTION("insertion"),
}

/**
 * Why it failed. The vocabulary is `DiagnosticLog.ERROR_CATEGORIES` plus the
 * two insertion outcomes worth separating, kept as its own enum so the
 * diagnostic log can grow categories without silently widening what is sent
 * over the network.
 */
enum class TelemetryReason(val wire: String) {
    AUDIO("audio"),
    AUDIO_FOCUS_LOST("audio_focus_lost"),
    AUDIO_SILENCED("audio_silenced"),
    AUDIO_CAPTURE_LOST("audio_capture_lost"),
    GATEWAY_UNREACHABLE("gateway_unreachable"),
    GATEWAY_REJECTED("gateway_rejected"),
    ENGINE_NOT_READY("engine_not_ready"),
    MODEL_MISSING("model_missing"),
    TRANSCRIPT_EMPTY("transcript_empty"),
    TARGET_FIELD_CHANGED("target_field_changed"),
    INSERTION_REJECTED("insertion_rejected"),
    PERMISSION("permission"),
    UNKNOWN("unknown"),
}

/**
 * Recording length, bucketed.
 *
 * Never the exact duration and never a character count: both are content-length
 * side channels. Buckets answer the one question worth asking — whether the
 * 120-second cap in `AppConfiguration.maximumRecordingSeconds` is cutting real
 * dictations short — and nothing else.
 */
enum class TelemetryDurationBucket(val wire: String) {
    UNDER_10S("under_10s"),
    TEN_TO_30S("10_30s"),
    THIRTY_TO_60S("30_60s"),
    OVER_60S("over_60s"),
    ;

    companion object {
        fun of(seconds: Double): TelemetryDurationBucket = when {
            seconds < 10 -> UNDER_10S
            seconds < 30 -> TEN_TO_30S
            seconds < 60 -> THIRTY_TO_60S
            else -> OVER_60S
        }
    }
}

enum class TelemetryDownloadOutcome(val wire: String) {
    COMPLETED("completed"),
    FAILED("failed"),
    CANCELLED("cancelled"),
    /** The file downloaded but its SHA-256 did not match the pinned digest. */
    INTEGRITY_FAILED("integrity_failed"),
}
