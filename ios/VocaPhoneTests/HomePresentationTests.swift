import Foundation
import Testing

struct HomePresentationTests {
    private static func card(
        _ state: SessionState,
        location: SessionProcessingLocation? = nil,
        transcript: String? = nil,
        errorMessage: String? = nil,
        canRetry: Bool = false,
        startedInApp: Bool = true,
        quickDictationReady: Bool = false,
        quickDictationDuration: QuickDictationDuration = .tenMinutes,
        sourceReady: Bool = true,
        showTranscriptOnSession: Bool = false
    ) -> HomeSessionCard {
        HomeSessionCard.make(
            HomeSessionCard.Context(
                state: state,
                isRecording: state == .recording,
                isQuickDictationReady: quickDictationReady,
                quickDictationExpiresAt: quickDictationReady
                    ? Date(timeIntervalSince1970: 1_700_000_000)
                    : nil,
                quickDictationDuration: quickDictationReady ? quickDictationDuration : nil,
                processingLocation: location,
                transcript: transcript,
                errorMessage: errorMessage,
                canRetry: canRetry,
                startedInApp: startedInApp,
                isSourceReady: sourceReady,
                showTranscriptOnSession: showTranscriptOnSession
            )
        )
    }

    /// The user has already tapped Dictate by this point, so "nothing
    /// recording" would be both wrong and discouraging.
    @Test func aHandoffInFlightIsNotDrawnAsIdle() {
        for state in [SessionState.launchingApp, .awaitingReturn] {
            let card = Self.card(state, startedInApp: false)
            #expect(card.status == .working)
            #expect(card.title == "Starting the microphone")
            #expect(card.secondary?.action == .cancel)
        }
    }

    @Test func everyStateProducesOneTitledCard() {
        for state in SessionState.allCases {
            let card = Self.card(state)
            #expect(!card.title.isEmpty)
            // At most one filled action per decision area.
            #expect(card.primary?.title.isEmpty != true)
        }
    }

    /// Live capture is the only thing that may be drawn as recording, and it is
    /// the only state that shows the meter.
    @Test func onlyRecordingIsDrawnAsRecording() {
        for state in SessionState.allCases {
            let card = Self.card(state)
            #expect((card.status == .recording) == (state == .recording))
            #expect(card.showsMeter == (state == .recording))
        }
    }

    /// Standby is not recording. It lights the same iOS microphone indicator, so
    /// the card has to say what it actually is.
    @Test func quickDictationStandbyNeverReadsAsRecording() {
        let standby = Self.card(.idle, quickDictationReady: true)

        #expect(standby.status == .ready)
        #expect(standby.status != .recording)
        #expect(standby.detail?.contains("standby") == true)
        #expect(standby.detail?.contains("Nothing is being recorded") == true)
        #expect(!standby.showsMeter)
    }

    /// A window that renews itself every couple of seconds has no clock time
    /// worth printing, so the card names the exit instead of a deadline that
    /// keeps moving.
    @Test func anUnlimitedStandbyNamesTheExitRatherThanAClockTime() {
        let rolling = Self.card(
            .idle,
            quickDictationReady: true,
            quickDictationDuration: .untilAppCloses
        )

        #expect(rolling.detail?.contains("until you close vocaphone") == true)
        #expect(rolling.detail?.contains("Nothing is being recorded") == true)

        let bounded = Self.card(.idle, quickDictationReady: true)
        #expect(bounded.detail?.contains("until you close vocaphone") == false)
        #expect(bounded.detail?.contains("standby until") == true)
    }

    /// The processing card names the place, or says nothing rather than
    /// guessing one.
    @Test func processingNamesTheRouteOrStaysNeutral() {
        #expect(Self.card(.transcribing, location: .onDevice).title == "Transcribing on this iPhone")
        #expect(Self.card(.transcribing, location: .gateway).title == "Transcribing on your gateway")
        #expect(Self.card(.transcribing, location: nil).title == "Transcribing")

        #expect(Self.card(.uploading, location: .gateway).title == "Sending to your gateway")
        #expect(Self.card(.uploading, location: .onDevice).title == "Preparing on this iPhone")
        #expect(Self.card(.finalizing, location: .gateway).title == "Finishing recording")
    }

    @Test func noProcessingCopyEverGuessesAMac() {
        for state in SessionState.allCases {
            for location in [SessionProcessingLocation.onDevice, .gateway, nil] {
                let card = Self.card(state, location: location)
                #expect(!card.title.localizedCaseInsensitiveContains("your Mac"))
                #expect((card.detail ?? "").localizedCaseInsensitiveContains("your Mac") == false)
            }
        }
    }

    /// Retry spends the preserved recording; a new recording throws it away. The
    /// prominent button has to be the first one.
    @Test func aRecoverableFailurePromotesRetry() {
        for state in [
            SessionState.serverUnavailable, .uploadFailedRecoverable,
            .transcriptionFailedRecoverable,
        ] {
            let card = Self.card(state, canRetry: true)
            #expect(card.primary?.action == .retry)
            #expect(card.secondary?.action == .cancel)
            #expect(card.status == .attention)
        }
    }

    @Test func anUnretryableFailureOffersAFreshRecordingInstead() {
        let card = Self.card(.serverUnavailable, canRetry: false)
        #expect(card.primary?.action == .startTest)
    }

    /// A keyboard dictation delivers its transcript into the host field, so the
    /// home card must not offer to copy something it does not own.
    @Test func aKeyboardResultIsNotCopiedOnHome() {
        let fromKeyboard = Self.card(.readyToInsert, transcript: "Ship it", startedInApp: false)
        #expect(!fromKeyboard.showsTranscript)
        #expect(fromKeyboard.primary == nil)
        #expect(fromKeyboard.detail?.contains("Return to the keyboard") == true)
    }

    @Test func anInAppResultDoesNotReplaceReadyToDictate() {
        let inApp = Self.card(.readyToInsert, transcript: "Ship it", startedInApp: true)
        #expect(inApp.title == "Ready to dictate")
        #expect(!inApp.showsTranscript)
        #expect(inApp.primary?.action == .startTest)
    }

    @Test func anIdleReadyCardLeadsWithWhatItCanDo() {
        let card = Self.card(.idle)
        #expect(card.title == "Ready to dictate")
        #expect(card.status == .ready)
        #expect(card.primary?.action == .startTest)
    }

    /// The attention card names the hole. Idle must not claim Ready, and must
    /// not become a second "not ready" headline. The test button stays.
    @Test func anUnreadyIdleSessionDoesNotClaimReadyToDictate() {
        let card = Self.card(.idle, sourceReady: false)
        #expect(card.title != "Ready to dictate")
        #expect(card.title != "Not ready to dictate")
        #expect(card.primary?.action == .startTest)
    }

    /// After dictation the session card is the session again, not a second
    /// transcript pane. The words belong on Latest transcript.
    @Test func aFinishedInAppSessionReturnsToReadyToDictate() {
        let card = Self.card(.completed, transcript: "Ship it friday")
        #expect(card.title == "Ready to dictate")
        #expect(!card.showsTranscript)
        #expect(card.primary?.action == .startTest)
    }

    @Test func pinningTheSessionOnATranscriptShowsTranscriptReady() {
        let card = Self.card(
            .idle,
            transcript: "Ship it friday",
            showTranscriptOnSession: true
        )
        #expect(card.title == "Transcript ready")
        #expect(card.showsTranscript)
        #expect(card.primary?.action == .copyTranscript)
    }

    /// A cancel that discards preserved audio is destructive and says so; the
    /// one that merely abandons a live capture does not need the same warning.
    @Test func discardingPreservedAudioIsNamedForWhatItDoes() {
        #expect(Self.card(.serverUnavailable, canRetry: true).secondary?.title
            == "Discard recording")
        #expect(Self.card(.recording).secondary?.title == "Cancel")
    }
}
