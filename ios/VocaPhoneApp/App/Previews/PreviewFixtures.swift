#if DEBUG
import Foundation
import SwiftUI

/// Canned state for every screen, so a `#Preview` can show a state instead of
/// waiting for one.
///
/// The app's models are already pure and already tested — `HomeSessionCard`,
/// `SetupStatus`, `TranscriptionSourceStatus`, `TranscriptHistoryModel`. What
/// was missing was values to put in them. Before this file, checking what
/// "gateway reachable but token rejected" looks like meant building, booting a
/// simulator, and breaking a gateway on purpose; states that expensive to reach
/// are states nobody looks at twice.
///
/// The whole file is `#if DEBUG`. Nothing here may be referenced from code that
/// ships — see `tools/check-preview-isolation.sh`, which fails the build if it
/// is.
enum PreviewFixtures {

    // MARK: - Transcripts

    /// One sentence — the common case, and the one that must not look padded.
    static let shortTranscript = "Let's move the review to Thursday afternoon."

    /// Long enough to wrap several times in a card, so clipping and truncation
    /// show up in the canvas rather than on someone's phone.
    static let longTranscript = """
        I've been thinking about the gateway setup and I don't think we should \
        ask people to run anything before their first dictation. Let them pick \
        the on-device model, get a transcript back within a minute of \
        installing, and only mention the gateway when they want a bigger model \
        than the phone can hold. The current order gets it exactly backwards.
        """

    /// The pathological case for every fixed-width row and every `HStack` that
    /// assumes small text: one unbroken run plus a lot of words.
    static let verboseTranscript = """
        Reconfirming the Wednesday retrospective, the incident review, and the \
        quarterly infrastructure-consolidation-and-migration planning session, \
        all of which are now scheduled against the same afternoon, which means \
        somebody has to move at least two of them before Friday.
        """

    // MARK: - Sessions

    /// A session in whatever state is being previewed.
    ///
    /// `SessionRecord.transition(to:)` enforces the real state machine, which is
    /// exactly what a fixture must not have to satisfy: previews need the
    /// *destination* states, not the paths to them. So the state is assigned.
    static func record(
        state: SessionState,
        transcript: String? = nil,
        error: SessionFailure? = nil,
        processingLocation: SessionProcessingLocation? = .gateway,
        startedInApp: Bool = true,
        minutesAgo: Double = 0,
        style: WritingStyle = .casual
    ) -> SessionRecord {
        var record = SessionRecord(
            sessionID: UUID(),
            state: .idle,
            sourceDocumentID: startedInApp ? "in-app-test" : "host-field-1",
            style: style.rawValue,
            now: Date(timeIntervalSinceNow: -minutesAgo * 60)
        )
        record.state = state
        record.transcript = transcript
        record.error = error
        record.processingLocation = processingLocation
        record.startedInContainingApp = startedInApp ? true : nil
        return record
    }

    static let gatewayFailure = SessionFailure(
        code: "gateway_unreachable",
        message: "homelabone:8765 did not answer. Your recording is preserved.",
        recoverable: true
    )

    static let permanentFailure = SessionFailure(
        code: "transcription_failed",
        message: "The gateway returned no text for this recording.",
        recoverable: false
    )

    // MARK: - History

    /// Enough transcripts to cross three of `TranscriptHistoryModel`'s four
    /// heading kinds — Today, Yesterday, a weekday, and a date — because the
    /// grouping is the part of that screen with arithmetic in it.
    static var history: [SessionRecord] {
        [
            record(state: .completed, transcript: shortTranscript, minutesAgo: 12),
            record(
                state: .completed,
                transcript: longTranscript,
                processingLocation: .onDevice,
                minutesAgo: 95,
                style: .formal
            ),
            record(
                state: .completed,
                transcript: "Pick up the parcel before six.",
                minutesAgo: 60 * 26,
                style: .veryCasual
            ),
            record(
                state: .completed,
                transcript: verboseTranscript,
                processingLocation: .onDevice,
                minutesAgo: 60 * 30
            ),
            record(
                state: .completed,
                transcript: "Ship the beta on Friday.",
                processingLocation: nil,
                minutesAgo: 60 * 24 * 4,
                style: .excited
            ),
            record(
                state: .completed,
                transcript: shortTranscript,
                minutesAgo: 60 * 24 * 20,
                style: .raw
            ),
        ]
    }

    // MARK: - Transcription sources

    static let gatewayReady = TranscriptionSourceStatus(
        selected: .gateway,
        gatewayAddress: "http://homelabone:8765",
        isGatewayReady: true,
        gatewayMessage: "Gateway, token, and model are ready."
    )

    static let gatewayUnconfigured = TranscriptionSourceStatus(selected: .gateway)

    static let gatewayTokenRejected = TranscriptionSourceStatus(
        selected: .gateway,
        gatewayAddress: "https://dictation.example.com",
        isGatewayReady: false,
        gatewayMessage: "Gateway reachable, but the pairing token was rejected."
    )

    static let gatewayModelNotReady = TranscriptionSourceStatus(
        selected: .gateway,
        gatewayAddress: "http://homelabone:8765",
        isGatewayReady: false,
        gatewayMessage: "Gateway reachable; model is not ready."
    )

    static let onDeviceReady = TranscriptionSourceStatus(
        selected: .onDevice,
        onDeviceModelName: "Whisper Base",
        isOnDeviceReady: true
    )

    static let onDeviceMissing = TranscriptionSourceStatus(selected: .onDevice)

    // MARK: - Guided setup

    /// Nothing done yet: the state a first launch actually opens in.
    static let setupFresh = SetupStatus(
        source: gatewayUnconfigured,
        microphone: .undetermined,
        keyboard: .notAdded,
        hasDictatedOnce: false
    )

    static let setupMicrophoneDenied = SetupStatus(
        source: gatewayReady,
        microphone: .denied,
        keyboard: .notAdded,
        hasDictatedOnce: false
    )

    /// The keyboard is listed but has never reached the shared container, which
    /// is the single most common stuck point in this product.
    static let setupKeyboardNeedsFullAccess = SetupStatus(
        source: onDeviceReady,
        microphone: .granted,
        keyboard: .addedButNeverRun,
        hasDictatedOnce: false
    )

    static let setupKeyboardSilent = SetupStatus(
        source: gatewayReady,
        microphone: .granted,
        keyboard: .silent(lastSeenAt: Date(timeIntervalSinceNow: -60 * 60 * 24 * 45)),
        hasDictatedOnce: true
    )

    /// Dictation works; only the optional trial run is outstanding. This one
    /// must never produce an attention headline.
    static let setupReadyToDictate = SetupStatus(
        source: gatewayReady,
        microphone: .granted,
        keyboard: .ready(lastSeenAt: Date(timeIntervalSinceNow: -60 * 8)),
        hasDictatedOnce: false
    )

    static let setupComplete = SetupStatus(
        source: gatewayReady,
        microphone: .granted,
        keyboard: .ready(lastSeenAt: Date(timeIntervalSinceNow: -60 * 3)),
        hasDictatedOnce: true
    )

    /// Two steps outstanding, so the plural attention headline is reachable.
    static let setupTwoStepsLeft = SetupStatus(
        source: gatewayUnconfigured,
        microphone: .granted,
        keyboard: .notAdded,
        hasDictatedOnce: false
    )

    // MARK: - On-device models

    static var modelIDs: [String] { LocalModelCatalog.usableOnDevice.map(\.id) }

    /// The first model this iPhone can run, used wherever a preview needs "some
    /// model" rather than a particular one.
    static var firstModelID: String { modelIDs.first ?? LocalModelCatalog.recommended.id }

    static var secondModelID: String { modelIDs.dropFirst().first ?? firstModelID }

    // MARK: - Stored preferences

    /// A defaults suite that exists only for the life of the preview process.
    ///
    /// Preview code writes nothing: every value below goes into the
    /// *registration* domain, which `UserDefaults` keeps in memory and never
    /// persists. Without that, opening a canvas would rewrite the settings of
    /// the app installed on the same simulator — and a preview that changes the
    /// product is not a preview.
    nonisolated(unsafe) static let defaults = store(
        "ready",
        [
            "gatewayURL": "http://homelabone:8765",
            GatewayStatusPreferences.healthMessageKey: "Gateway, token, and model are ready.",
            GatewayStatusPreferences.engineKey: "faster-whisper · base",
            GatewayStatusPreferences.engineReadyKey: true,
        ]
    )

    /// A named store, so two previews of the same screen can disagree about
    /// what is in it. `@AppStorage` that names no store reads whichever one
    /// `PreviewHost` puts in the environment.
    nonisolated static func store(_ name: String, _ values: [String: Any]) -> UserDefaults {
        let suite = UserDefaults(suiteName: "com.vocahq.vocaphone.previews.\(name)")
            ?? .standard
        suite.register(defaults: values)
        return suite
    }

    /// No gateway paired yet — the state the scanner leads in.
    nonisolated(unsafe) static let gatewayUnpairedStore = store(
        "unpaired",
        [
            "gatewayURL": "",
            GatewayStatusPreferences.healthMessageKey: "Not tested",
            GatewayStatusPreferences.engineKey: "",
            GatewayStatusPreferences.engineReadyKey: false,
        ]
    )

    /// Reachable, but the token was refused. Tedious to reach by hand and the
    /// one gateway failure a user is most likely to hit.
    nonisolated(unsafe) static let gatewayTokenRejectedStore = store(
        "token-rejected",
        [
            "gatewayURL": "https://dictation.example.com",
            GatewayStatusPreferences.healthMessageKey:
                "Gateway reachable, but the pairing token was rejected.",
            GatewayStatusPreferences.engineKey: "",
            GatewayStatusPreferences.engineReadyKey: false,
        ]
    )

    /// Answering and authenticated, with no speech-to-text model loaded.
    nonisolated(unsafe) static let gatewayModelNotReadyStore = store(
        "model-not-ready",
        [
            "gatewayURL": "http://homelabone:8765",
            GatewayStatusPreferences.healthMessageKey: "Gateway reachable; model is not ready.",
            GatewayStatusPreferences.engineKey: "",
            GatewayStatusPreferences.engineReadyKey: false,
        ]
    )

    /// HTTP against a public-looking host, which is the one case the address
    /// field warns about.
    nonisolated(unsafe) static let gatewayUnencryptedStore = store(
        "unencrypted",
        [
            "gatewayURL": "http://dictation.example.com",
            GatewayStatusPreferences.healthMessageKey: "Not tested",
            GatewayStatusPreferences.engineKey: "",
            GatewayStatusPreferences.engineReadyKey: false,
        ]
    )

    /// The App Group values that `@AppStorage(store:)` and
    /// `KeyboardPreferences` read directly, so they cannot be redirected with
    /// `defaultAppStorage`. Registered, never set, for the same reason.
    static func registerAppGroupDefaults(hasDictatedOnce: Bool = true) {
        KeyboardPreferences.defaults?.register(defaults: [
            KeyboardPreferences.setupCompletedKey: true,
            KeyboardPreferences.firstDictationKey: hasDictatedOnce,
            KeyboardPreferences.keyboardHeightKey: KeyboardHeightPreference.standard.rawValue,
            KeyboardPreferences.writingStyleKey: WritingStyle.casual.rawValue,
            KeyboardPreferences.transcriptionLanguageKey: TranscriptionLanguage.automatic.rawValue,
            KeyboardPreferences.typingSuggestionsKey: true,
            KeyboardPreferences.quickDictationKey: false,
        ])
    }
}

// MARK: - Coordinators

extension RecordingCoordinator {
    /// The home screen resting on a working setup, with nothing recorded yet.
    static func previewIdle(
        setupStatus: SetupStatus = PreviewFixtures.setupComplete
    ) -> RecordingCoordinator {
        RecordingCoordinator(
            preview: nil,
            setupStatus: setupStatus,
            transcripts: PreviewFixtures.history
        )
    }

    /// A coordinator sitting in one session state, with the setup that state
    /// implies.
    static func preview(
        _ state: SessionState,
        transcript: String? = nil,
        error: SessionFailure? = nil,
        processingLocation: SessionProcessingLocation? = .gateway,
        startedInApp: Bool = true,
        setupStatus: SetupStatus = PreviewFixtures.setupComplete,
        message: String? = nil,
        meterLevel: Float = 0,
        isRecording: Bool = false
    ) -> RecordingCoordinator {
        RecordingCoordinator(
            preview: PreviewFixtures.record(
                state: state,
                transcript: transcript,
                error: error,
                processingLocation: processingLocation,
                startedInApp: startedInApp
            ),
            setupStatus: setupStatus,
            message: message,
            meterLevel: meterLevel,
            isRecording: isRecording,
            transcripts: PreviewFixtures.history
        )
    }

    /// Quick Dictation armed but not recording — the state whose whole job is to
    /// not look like recording.
    static func previewStandby() -> RecordingCoordinator {
        RecordingCoordinator(
            preview: nil,
            setupStatus: PreviewFixtures.setupComplete,
            quickDictationExpiresAt: Date(timeIntervalSinceNow: 60 * 12),
            transcripts: PreviewFixtures.history
        )
    }
}
#endif
