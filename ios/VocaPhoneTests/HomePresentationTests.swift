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
        sourceReady: Bool = true
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
                isSourceReady: sourceReady
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
    @Test func onlyAnInAppResultIsShownOnTheCard() {
        let inApp = Self.card(.readyToInsert, transcript: "Ship it", startedInApp: true)
        let fromKeyboard = Self.card(.readyToInsert, transcript: "Ship it", startedInApp: false)

        #expect(inApp.showsTranscript)
        #expect(inApp.primary?.action == .copyTranscript)
        #expect(!fromKeyboard.showsTranscript)
        #expect(fromKeyboard.primary == nil)
        #expect(fromKeyboard.detail?.contains("Return to the keyboard") == true)
    }

    /// A card that cannot do its job says so on the card, instead of leaving the
    /// user to discover it after speaking.
    @Test func anUnreadySourceIsExplainedBeforeTheTapNotAfter() {
        let card = Self.card(.idle, sourceReady: false)
        #expect(card.title == "Not ready to dictate")
        #expect(card.status == .inactive)
        #expect(card.detail?.contains("where speech becomes text") == true)
        #expect(card.primary?.action == .startTest)
    }

    /// And a card that can do its job leads with that, rather than with what is
    /// not currently happening.
    @Test func anIdleReadyCardLeadsWithWhatItCanDo() {
        let card = Self.card(.idle, sourceReady: true)
        #expect(card.title == "Ready to dictate")
        #expect(card.status == .ready)
    }

    /// A cancel that discards preserved audio is destructive and says so; the
    /// one that merely abandons a live capture does not need the same warning.
    @Test func discardingPreservedAudioIsNamedForWhatItDoes() {
        #expect(Self.card(.serverUnavailable, canRetry: true).secondary?.title
            == "Discard recording")
        #expect(Self.card(.recording).secondary?.title == "Cancel")
    }
}
