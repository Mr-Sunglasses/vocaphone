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
        isTryFieldSession: Bool = false,
        isTryFieldFocused: Bool = false,
        quickDictationReady: Bool = false,
        quickDictationDuration: QuickDictationDuration = .tenMinutes,
        readyToDictate: Bool = true,
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
                isTryFieldSession: isTryFieldSession,
                isTryFieldFocused: isTryFieldFocused,
                isReadyToDictate: readyToDictate,
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

    @Test func anInAppResultReturnsToTryItHere() {
        let inApp = Self.card(.readyToInsert, transcript: "Ship it", startedInApp: true)
        #expect(inApp.title == "Try it here")
        #expect(!inApp.showsTranscript)
        #expect(inApp.showsTryField)
    }

    /// Removing the focused field dismisses the keyboard extension before it
    /// can insert a transcript into Home. Keep it in the view for every state
    /// between tapping Dictate and receiving the finished text.
    @Test func dictatingIntoHomeKeepsTheTryFieldMounted() {
        for state in [
            SessionState.launchingApp, .awaitingReturn, .recording,
            .finalizing, .uploading, .transcribing, .readyToInsert,
            .inserting, .inserted, .completed,
            .serverUnavailable, .uploadFailedRecoverable,
            .transcriptionFailedRecoverable, .permissionDenied,
            .transcriptionFailedPermanent,
        ] {
            #expect(Self.card(state, isTryFieldSession: true).showsTryField)
            if state != .completed {
                #expect(!Self.card(state, startedInApp: false).showsTryField)
            }
        }
    }

    @Test func readinessChangeCannotRemoveTheInsertionTarget() {
        for state in [
            SessionState.readyToInsert, .targetContextChanged,
            .inserting, .inserted,
        ] {
            let card = Self.card(
                state, isTryFieldSession: true, readyToDictate: false
            )
            #expect(!card.isHidden)
            #expect(card.showsTryField)
            #expect(card.status != .ready)
            #expect(card.quietAction == nil)
            if state == .targetContextChanged {
                #expect(card.title == "Waiting to insert")
                #expect(card.detail == "Return to the keyboard. Go back to the original field, or choose Insert here.")
            } else {
                #expect(card.title == "Finishing dictation")
                #expect(card.detail == "Keep the keyboard open while this dictation finishes.")
            }
        }
    }

    /// Done, Clear, Settings and scroll-to-dismiss read this. It holds from
    /// Dictate until the text lands, and lets go once it has, once it cannot
    /// (a failure), or while insertion is parked on a field change.
    @Test func theTryFieldIsLockedOnlyWhileTheKeyboardStillHasToInsert() {
        for state in [
            SessionState.launchingApp, .awaitingReturn, .recording,
            .finalizing, .uploading, .transcribing, .readyToInsert,
            .inserting, .inserted,
        ] {
            #expect(Self.card(state, isTryFieldSession: true).locksTryField)
            #expect(Self.card(
                state, isTryFieldSession: true, readyToDictate: false
            ).locksTryField)
            // A microphone test or another app's dictation has no field here.
            #expect(!Self.card(state).locksTryField)
            #expect(!Self.card(state, startedInApp: false).locksTryField)
        }
        for state in [
            SessionState.idle, .targetContextChanged, .completed, .canceled,
            .serverUnavailable, .transcriptionFailedRecoverable,
            .permissionDenied, .transcriptionFailedPermanent,
        ] {
            #expect(!Self.card(state, isTryFieldSession: true).locksTryField)
        }
    }

    /// With the keyboard already up, "tap the field" describes a step the
    /// user has taken, and a microphone test would drop the keyboard.
    @Test func aFocusedTryFieldTalksAboutTheKeyboardInFront() {
        let focused = Self.card(.idle, isTryFieldFocused: true)
        #expect(focused.showsTryField)
        #expect(focused.quietAction == nil)
        #expect(focused.detail?.hasPrefix("Tap Dictate on the vocaphone keyboard") == true)

        let unfocused = Self.card(.idle)
        #expect(unfocused.quietAction?.action == .startTest)
        #expect(unfocused.detail?.hasPrefix("Tap the field") == true)
    }

    @Test func recordingIntoTheTryFieldSaysWhereTheTextGoes() {
        let card = Self.card(.recording, isTryFieldSession: true, isTryFieldFocused: true)
        #expect(card.title == "Listening")
        #expect(card.detail == "Tap Finish here or on the keyboard. The text goes into the field.")
        #expect(Self.card(.recording).detail == "Tap Finish when you are done.")
    }

    /// After cancel or complete the coordinator still holds the try-field
    /// session, but the field is no longer needed for insertion. Unready setup
    /// then belongs to the checklist, not a leftover Try it card.
    @Test func aFinishedTryFieldSessionDoesNotOutliveSetupReadiness() {
        for state in [SessionState.completed, .idle, .canceled, .expired] {
            let card = Self.card(
                state, isTryFieldSession: true, readyToDictate: false
            )
            #expect(card.isHidden)
            #expect(!card.showsTryField)
        }
    }

    /// Ready leads with the real thing — a field to dictate into — and keeps
    /// the microphone-only test as a quiet link, not a second button.
    @Test func anIdleReadyCardLeadsWithAFieldToDictateInto() {
        let card = Self.card(.idle)
        #expect(card.title == "Try it here")
        #expect(card.status == .ready)
        #expect(card.showsTryField)
        #expect(card.primary == nil)
        #expect(card.quietAction?.action == .startTest)
        #expect(!card.isHidden)
    }

    /// The setup checklist names the hole. A disabled test button beside it
    /// was dead UI, so the idle card stands down entirely.
    @Test func anUnreadyIdleSessionStandsDown() {
        let card = Self.card(.idle, readyToDictate: false)
        #expect(card.isHidden)
        #expect(card.primary == nil)
        #expect(!card.showsTryField)
    }

    @Test func missingMicrophoneOrKeyboardDoesNotOfferDictation() {
        for status in [
            Self.status(microphone: .undetermined),
            Self.status(microphone: .denied),
            Self.status(keyboard: .notAdded),
            Self.status(keyboard: .addedButNeverRun),
        ] {
            #expect(status.source.isReady)
            #expect(!status.isReadyToDictate)
            let card = Self.card(.idle, readyToDictate: status.isReadyToDictate)
            #expect(card.isHidden)
            #expect(!card.showsTryField)
        }
    }

    /// After dictation the session card is the session again, not a second
    /// transcript pane. The words belong on Recent.
    @Test func aFinishedInAppSessionReturnsToTryItHere() {
        let card = Self.card(.completed, transcript: "Ship it friday")
        #expect(card.title == "Try it here")
        #expect(!card.showsTranscript)
        #expect(card.showsTryField)
    }

    // MARK: - Setup checklist

    private static func status(
        source: Bool = true,
        microphone: MicrophoneAccess = .granted,
        keyboard: KeyboardSetupState = .ready(lastSeenAt: Date())
    ) -> SetupStatus {
        SetupStatus(
            source: source
                ? TranscriptionSourceStatus(selected: .onDevice, onDeviceModelName: "Whisper Base", isOnDeviceReady: true)
                : TranscriptionSourceStatus(selected: .onDevice),
            microphone: microphone,
            keyboard: keyboard,
            hasDictatedOnce: false
        )
    }

    @Test func aReadyPhoneHasNoChecklist() {
        #expect(HomeSetupChecklist.make(Self.status(), isModelArriving: false) == nil)
    }

    /// Every combination of the three required steps: the count in the title
    /// matches the rows, and every row not done has its own button.
    @Test func everyMissingStepHasItsOwnAction() {
        for source in [true, false] {
            for microphone in [MicrophoneAccess.granted, .undetermined, .denied] {
                for keyboard in [KeyboardSetupState.ready(lastSeenAt: Date()), .notAdded, .addedButNeverRun] {
                    let status = Self.status(source: source, microphone: microphone, keyboard: keyboard)
                    let checklist = HomeSetupChecklist.make(status, isModelArriving: false)
                    let missing = status.blockingSteps.count
                    guard missing > 0 else {
                        #expect(checklist == nil)
                        continue
                    }
                    let rows = try! #require(checklist).rows
                    #expect(rows.map(\.step) == [.source, .microphone, .keyboard])
                    #expect(rows.filter { !$0.isDone }.count == missing)
                    for row in rows {
                        #expect(row.isDone == (row.action == nil))
                    }
                    #expect(checklist?.detail.contains(missing == 1 ? "One step" : "\(missing) steps") == true)
                }
            }
        }
    }

    @Test func anUndecidedMicrophoneIsAskedForInApp() {
        let rows = HomeSetupChecklist.make(Self.status(microphone: .undetermined), isModelArriving: false)?.rows
        #expect(rows?.first { $0.step == .microphone }?.action?.kind == .allowMicrophone)
        let denied = HomeSetupChecklist.make(Self.status(microphone: .denied), isModelArriving: false)?.rows
        #expect(denied?.first { $0.step == .microphone }?.action?.kind == .openSystemSettings)
    }

    /// A model on its way is the download card's to show.
    @Test func aDownloadingModelIsNotAChecklist() {
        #expect(HomeSetupChecklist.make(Self.status(source: false), isModelArriving: true) == nil)
        let both = HomeSetupChecklist.make(Self.status(source: false, microphone: .undetermined), isModelArriving: true)
        let source = both?.rows.first { $0.step == .source }
        #expect(source?.detail == "Downloading…")
        #expect(source?.action == nil)
        #expect(source?.isDone == false)
    }

    @Test func theStatsLineWaitsForAStat() {
        #expect(HomeStatsLine.make(UsageStats(), now: Date()) == nil)
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
