import Testing
import UIKit

@MainActor
struct DictationPresentationTests {
    /// The keyboard says one short line about a failure; the app's paragraph
    /// about it stays in the app. Concatenating the two put three sentences
    /// over somebody else's text field.
    @Test func failuresShowAShortLineNotTheAppsParagraph() {
        let appDetail = "Select and load a speech-to-text model in the gateway, then retry."
        for state in [SessionState.serverUnavailable, .uploadFailedRecoverable,
                      .transcriptionFailedRecoverable, .transcriptionFailedPermanent] {
            let model = Self.model(state, errorMessage: appDetail, canRetry: true)
            let message = model.surfaceMessage(for: state)
            #expect(message != nil)
            #expect(message?.contains(appDetail) == false)
            #expect((message?.count ?? 0) < 60)
            #expect(model.primary.isEnabled)
        }
        let permission = Self.model(.permissionDenied)
        #expect(permission.surfaceMessage(for: .permissionDenied)?.contains("allow the microphone") == true)
    }

    @Test func preparationDoesNotClaimTranscriptionHasStarted() {
        for location in [SessionProcessingLocation.gateway, .onDevice] {
            let uploading = Self.model(.uploading, location: location)
            #expect(uploading.surfaceMessage(for: .uploading) == uploading.title)
            #expect(uploading.surfaceMessage(for: .uploading)?.contains("Transcribing") == false)
        }
        #expect(Self.model(.finalizing).surfaceMessage(for: .finalizing) == "Finishing recording")
    }

    @Test func readySurfaceRetainsTranscriptAndCancel() {
        let ready = Self.model(.readyToInsert, transcript: "A preview to check.")
        let message = ready.surfaceMessage(for: .readyToInsert)
        #expect(message?.contains("A preview to check.") == true)
        #expect(ready.secondaries.contains { $0.action == .cancel })
        #expect(ready.primary.action == .insert)
        #expect(ready.primary.isEnabled)
        let empty = Self.model(.readyToInsert)
        #expect(empty.surfaceMessage(for: .readyToInsert) != nil)
    }

    /// A keyboard that ended mid-insertion may have left the text in the
    /// field. The transcript comes back behind Insert and Cancel with that said
    /// plainly, and auto-insert does not change the copy into a promise.
    @Test func anInterruptedInsertionOffersInsertAndCancelWithItsReason() {
        for autoInsert in [false, true] {
            let model = DictationBarModel.make(
                DictationContext(
                    state: .readyToInsert,
                    transcript: "Meet at noon.",
                    autoInsertsTranscripts: autoInsert,
                    insertionWasInterrupted: true
                )
            )
            let message = model.surfaceMessage(for: .readyToInsert)
            #expect(message?.contains("may have been interrupted") == true)
            #expect(message?.contains("Meet at noon.") == true)
            #expect(model.primary.action == .insert)
            #expect(model.primary.isEnabled)
            #expect(model.secondaries.contains { $0.action == .cancel })
        }
        let untold = DictationBarModel.make(
            DictationContext(state: .readyToInsert, insertionWasInterrupted: true)
        )
        #expect(untold.surfaceMessage(for: .readyToInsert)?.contains("interrupted") == true)
    }

    /// A transcript parked in another field — by an earlier build, or by a
    /// cursor move this keyboard watched — still carries the warning, and its
    /// Insert goes through the explicit path a parked transcript needs.
    @Test func aParkedInterruptedInsertionKeepsItsWarning() {
        let model = DictationBarModel.make(
            DictationContext(
                state: .targetContextChanged,
                transcript: "Meet at noon.",
                insertionWasInterrupted: true
            )
        )
        let message = model.surfaceMessage(for: .targetContextChanged)
        #expect(message?.contains("may have been interrupted") == true)
        #expect(message?.contains("Meet at noon.") == true)
        #expect(model.primary.action == .insertHere)
        #expect(model.primary.hint?.contains("already there") == true)
        #expect(model.announcement?.contains("interrupted") == true)
        #expect(model.secondaries.contains { $0.action == .cancel })
    }

    @Test func changedFieldSurfaceRetainsTranscriptAndGuidance() {
        let ready = Self.model(.targetContextChanged, transcript: "Waiting text.")
        let message = ready.surfaceMessage(for: .targetContextChanged)
        #expect(message?.contains("Waiting text.") == true)
        #expect(message?.contains("different text field") == true)
        #expect(ready.primary.action == .insertHere)
    }

    @Test func handoffRecoveryRemainsEnabledWhileProcessingIsDisabled() {
        for state in [SessionState.launchingApp, .awaitingReturn] {
            let presentation = Self.model(state)
            #expect(presentation.primary.isEnabled)
            #expect(presentation.primary.action == .openApp)
            #expect(presentation.primary.title == "Open app")
        }
        for state in [SessionState.finalizing, .uploading, .transcribing] {
            #expect(!Self.model(state).primary.isEnabled)
        }
    }

    private static func model(
        _ state: SessionState,
        transcript: String? = nil,
        errorMessage: String? = nil,
        autoInsert: Bool = false,
        canRetry: Bool = false,
        canUndo: Bool = false,
        hasFullAccess: Bool = true,
        prefersQuickDictation: Bool = false,
        location: SessionProcessingLocation? = nil
    ) -> DictationBarModel {
        DictationBarModel.make(
            DictationContext(
                state: state,
                hasFullAccess: hasFullAccess,
                transcript: transcript,
                errorMessage: errorMessage,
                autoInsertsTranscripts: autoInsert,
                canRetry: canRetry,
                canUndo: canUndo,
                prefersQuickDictation: prefersQuickDictation,
                processingLocation: location
            )
        )
    }

    @Test func everyStateOffersALabelledPrimaryButton() {
        for state in SessionState.allCases {
            let model = Self.model(state)
            #expect(!model.title.isEmpty)
            #expect(!model.primary.title.isEmpty)
            #expect(!model.primary.symbol.isEmpty)
        }
    }

    /// The prominent button in the recoverable-failure states used to start a
    /// fresh session, and starting one cancels the parked record — so the tap
    /// most people reached for threw away the recording the state had just
    /// promised to preserve.
    @Test func recoverableFailuresPromoteRetryOverANewRecording() {
        let states: [SessionState] = [
            .serverUnavailable, .uploadFailedRecoverable, .transcriptionFailedRecoverable,
        ]
        for state in states {
            let model = Self.model(state, canRetry: true)
            #expect(model.primary.action == .retry)
            #expect(model.secondaries.contains { $0.action == .cancel })
        }
    }

    @Test func anUnretryableFailureFallsBackToStartingOver() {
        let model = Self.model(.serverUnavailable, canRetry: false)
        #expect(model.primary.action == .start)
    }

    @Test func aReadyTranscriptIsShownBeforeItIsInserted() {
        let model = Self.model(.readyToInsert, transcript: "Ship the beta on Friday")
        #expect(model.body == .message("“Ship the beta on Friday”"))
        #expect(model.primary.action == .insert)
    }

    @Test func anEmptyTranscriptFallsBackToGuidance() {
        let model = Self.model(.readyToInsert, transcript: "   \n ")
        #expect(model.body == .message("Tap Insert to place the text."))
    }

    @Test func autoInsertionSaysSoWhenThereIsNoTranscriptYet() {
        let model = Self.model(.readyToInsert, autoInsert: true)
        #expect(model.body == .message("Inserting automatically…"))
    }

    @Test func aPreviewCollapsesWhitespaceAndTruncates() {
        let long = String(repeating: "word ", count: 60)
        let preview = DictationBarModel.quoted("  hello\n\n  there  ")
        #expect(preview == "“hello there”")
        #expect(DictationBarModel.quoted(long)?.hasSuffix("…”") == true)
        #expect(DictationBarModel.quoted(long)!.count <= 100)
        #expect(DictationBarModel.quoted(nil) == nil)
        #expect(DictationBarModel.quoted(" \t ") == nil)
    }

    @Test func withoutFullAccessTheLockOpensSettings() {
        let model = Self.model(.idle, canUndo: true, hasFullAccess: false)
        #expect(model.accent == .locked)
        #expect(model.primary.isEnabled)
        #expect(model.primary.action == .openFullAccessSettings)
        #expect(model.primary.title == "Turn on Full Access")
        #expect(model.secondaries.isEmpty)
    }

    /// States that own no work and have nothing to explain. A terminal failure
    /// is not one of them: it still has to say what went wrong.
    private static let resting: Set<SessionState> = [.idle, .completed, .canceled, .expired]

    /// The pickers change what the *next* dictation does, so they are offered
    /// exactly when no session owns the bar.
    @Test func thePickersAppearOnlyBetweenSessions() {
        for state in SessionState.allCases {
            #expect((Self.model(state).body == .controls) == Self.resting.contains(state))
        }
    }

    @Test func undoIsOfferedOnlyOnceTheSessionIsOver() {
        #expect(Self.model(.completed, canUndo: true).secondaries.contains { $0.action == .undo })
        #expect(Self.model(.completed, canUndo: false).secondaries.isEmpty)
        #expect(!Self.model(.recording, canUndo: true).secondaries.contains { $0.action == .undo })
    }

    /// Height is given back to the keys the moment nothing needs the space —
    /// which includes a finished insertion, but not a failure the user has yet
    /// to read.
    @Test func theBarCollapsesOnlyWhenItHasNothingToSay() {
        for state in SessionState.allCases {
            #expect(Self.model(state).isExpanded == !Self.resting.contains(state))
        }
        #expect(Self.model(.permissionDenied).isExpanded)
        #expect(Self.model(.transcriptionFailedPermanent).isExpanded)
    }

    /// A wait must never be drawn as though it were recorded audio.
    @Test func theMeterIsLiveOnlyWhileRecording() {
        #expect(Self.model(.recording).body == .waveform(.live))
        #expect(Self.model(.recording).showsElapsedTime)
        for state in [SessionState.finalizing, .uploading, .transcribing] {
            #expect(Self.model(state).body == .waveform(.indeterminate))
            #expect(!Self.model(state).showsElapsedTime)
        }
    }

    @Test func everyLiveStateCanBeAbandoned() {
        let live: [SessionState] = [
            .launchingApp, .awaitingReturn, .recording, .finalizing, .uploading,
            .transcribing, .readyToInsert, .targetContextChanged,
        ]
        for state in live {
            #expect(Self.model(state).secondaries.contains { $0.action == .cancel })
        }
    }

    @Test func quickDictationExplainsThatItStaysInTheCurrentApp() {
        let model = Self.model(.launchingApp, prefersQuickDictation: true)

        #expect(model.title == "Starting dictation")
        #expect(model.body == .message("Quick Dictation keeps you in this app."))
        #expect(model.primary.action == .openApp)
        #expect(model.primary.hint?.contains("if starting here does not complete") == true)
    }

    @Test func normalAndFallbackHandoffsStillExplainThatVocaphoneOpens() {
        for state in [SessionState.launchingApp, .awaitingReturn] {
            let model = Self.model(state)
            #expect(model.title == "Opening vocaphone")
        }
    }

    @Test func aStrandedTranscriptCanBeRedirectedToTheCurrentField() {
        let model = Self.model(.targetContextChanged, transcript: "Redirect me")
        #expect(model.title == "Your text is ready")
        #expect(model.primary.action == .insertHere)
        #expect(model.primary.title == "Insert here")
        #expect(model.body == .message(
            "“Redirect me” This is a different text field from the one where you started."
        ))
        #expect(
            model.announcement
                == "Text ready in a different field. Return to the original field or insert in this field."
        )
    }

    @Test func elapsedTimeReadsAsMinutesAndSeconds() {
        #expect(DictationBarModel.elapsedText(0) == "0:00")
        #expect(DictationBarModel.elapsedText(7.9) == "0:07")
        #expect(DictationBarModel.elapsedText(65) == "1:05")
        #expect(DictationBarModel.elapsedText(600) == "10:00")
        #expect(DictationBarModel.elapsedText(-4) == "0:00")
    }

    // MARK: - Processing location

    /// Where the work is happening, in the bar's own words. The keyboard is
    /// frequently the only surface the user is looking at while this runs.
    @Test func theBarNamesWhereTranscriptionIsHappening() {
        #expect(Self.model(.transcribing, location: .onDevice).title
            == "Transcribing on this iPhone")
        #expect(Self.model(.transcribing, location: .gateway).title
            == "Transcribing on your gateway")
        #expect(Self.model(.uploading, location: .gateway).title == "Sending to your gateway")
        #expect(Self.model(.uploading, location: .onDevice).title == "Preparing on this iPhone")
        #expect(Self.model(.finalizing, location: .onDevice).title == "Finishing recording")
    }

    /// A record written before the field existed, or a session interrupted
    /// before the app claimed it, has no route to name. Neutral wording is the
    /// answer; a guess would be a claim about where the user's audio went.
    @Test func anUnknownRouteStaysNeutralRatherThanGuessing() {
        let model = Self.model(.transcribing, location: nil)
        #expect(model.title == "Transcribing")
        #expect(!model.title.contains("iPhone"))
        #expect(!model.title.contains("gateway"))
    }

    @Test func noStateEverClaimsAMac() {
        for state in SessionState.allCases {
            for location in [SessionProcessingLocation.onDevice, .gateway, nil] {
                let model = Self.model(state, errorMessage: nil, location: location)
                #expect(!model.title.localizedCaseInsensitiveContains("your Mac"))
                if case let .message(text) = model.body {
                    #expect(!text.localizedCaseInsensitiveContains("your Mac"))
                }
            }
        }
    }

    // MARK: - Semantics

    /// One role per meaning. Recording red belongs to capture alone, and the
    /// hand-off is an ordinary expected step rather than a fourth colour.
    @Test func eachStateTakesItsOwnSemanticRole() {
        #expect(Self.model(.recording).accent == .recording)
        for state in [SessionState.finalizing, .uploading, .transcribing, .targetContextChanged] {
            #expect(Self.model(state).accent == .working)
        }
        for state in [
            SessionState.serverUnavailable, .transcriptionFailedPermanent, .permissionDenied,
        ] {
            #expect(Self.model(state).accent == .error)
        }
        for state in [SessionState.launchingApp, .awaitingReturn] {
            #expect(Self.model(state).accent == .brand)
        }
        #expect(Self.model(.idle, hasFullAccess: false).accent == .locked)
        // Only capture is ever recording-red.
        for state in SessionState.allCases where state != .recording {
            #expect(Self.model(state).accent != .recording)
        }
    }

    /// iOS offers no link to the Full Access switch, so the exact path is the
    /// only thing that gets the user there.
    @Test func theLockedBarGivesTheExactSettingsPath() {
        let model = Self.model(.idle, hasFullAccess: false)
        guard case let .message(text) = model.body else {
            Issue.record("the locked bar should explain itself")
            return
        }
        // The switch to turn on leads, so a narrow bar truncates the tail of
        // the path rather than the instruction. The containing app spells the
        // path out in full — see `AppConfiguration.fullAccessSettingsPath`.
        #expect(text.hasPrefix("Turn on Allow Full Access"))
        #expect(text.contains("Settings"))
        #expect(text.contains("Keyboards"))
        // The route the button takes: vocaphone opens its own Settings page.
        #expect(AppConfiguration.fullAccessSettingsPath.contains("vocaphone › Keyboards"))
        #expect(text.contains(AppConfiguration.fullAccessSettingsPage))
    }

    // MARK: - Announcements

    /// Milestones announce; polling does not. The bar re-renders up to four
    /// times a second, and announcing every render would make VoiceOver unusable
    /// during a dictation.
    @Test func onlyMeaningfulTransitionsAnnounceThemselves() {
        #expect(Self.model(.recording).announcement == "Recording started")
        #expect(Self.model(.readyToInsert).announcement == "Transcript ready")
        #expect(Self.model(.completed).announcement == "Text inserted")
        #expect(Self.model(.transcriptionFailedPermanent).announcement != nil)

        // Nothing to interrupt for: the user asked for these, or they are
        // intermediate steps toward one that does announce.
        #expect(Self.model(.idle).announcement == nil)
        #expect(Self.model(.launchingApp).announcement == nil)
        #expect(Self.model(.transcribing).announcement == nil)
        #expect(Self.model(.inserting).announcement == nil)
    }

    @Test func barHeightsLeaveMoreRoomForKeysThanTheCardAndToolbarDid() {
        let portrait = DictationBarMetrics.resolved(
            for: UITraitCollection { $0.verticalSizeClass = .regular }
        )
        // The card, the toolbar and the gap between them came to 117pt in every
        // state, including the idle one.
        #expect(portrait.collapsedHeight < 117)
        #expect(portrait.expandedHeight < 117)
        #expect(portrait.collapsedHeight < portrait.expandedHeight)

        let landscape = DictationBarMetrics.resolved(
            for: UITraitCollection { $0.verticalSizeClass = .compact }
        )
        #expect(landscape.expandedHeight < portrait.collapsedHeight)
        #expect(landscape.messageLineLimit == 1)
    }

    // MARK: - Who owns the keyboard

    /// Only capture and the wait for its transcript take the keys away. A
    /// waiting transcript or a failure is adopted by every field in every app
    /// for up to an hour, so those sit above the keys instead.
    @Test func onlyRecordingAndProcessingTakeTheKeysAway() {
        let owning: Set<SessionState> = [
            .launchingApp, .awaitingReturn, .recording, .finalizing, .uploading, .transcribing,
        ]
        for state in SessionState.allCases {
            #expect(
                DictationBarModel.surfaceOwnsKeyboard(state, hasFullAccess: true)
                    == owning.contains(state),
                "\(state.rawValue)"
            )
            #expect(!DictationBarModel.surfaceOwnsKeyboard(state, hasFullAccess: false))
        }
        // And what is not owned is drawn as the status bar, with its action.
        for state in [SessionState.readyToInsert, .targetContextChanged, .serverUnavailable,
                      .transcriptionFailedPermanent, .permissionDenied] {
            #expect(Self.model(state).layout == .status)
        }
    }

    /// × on a waiting transcript puts it away rather than deleting it, and
    /// says where it went.
    @Test func dismissingAWaitingTranscriptSaysItIsKept() {
        for state in [SessionState.readyToInsert, .targetContextChanged] {
            let model = Self.model(state, transcript: "Kept words")
            #expect(model.secondaries == [.dismissTranscript])
            #expect(DictationButton.dismissTranscript.hint?.contains("Transcripts") == true)
        }
    }

    /// Every failure that ended its session can be put away without starting
    /// another one.
    @Test func endedFailuresCanBeDismissed() {
        for state in [SessionState.transcriptionFailedPermanent, .permissionDenied] {
            #expect(Self.model(state).secondaries.contains { $0.action == .dismiss })
        }
    }

    /// Retry resends kept audio; a new recording starts over. They must not
    /// look alike.
    @Test func aNewRecordingNeverWearsRetrysArrow() {
        let retry = Self.model(.serverUnavailable, canRetry: true).primary
        #expect(retry.symbol == "arrow.clockwise")
        for model in [
            Self.model(.serverUnavailable, canRetry: false),
            Self.model(.transcriptionFailedPermanent),
            DictationBarModel.notice(.recordingDidNotStart),
        ] {
            #expect(model.primary.action == .start)
            #expect(model.primary.symbol != retry.symbol)
        }
    }

    // MARK: - Failures that are not the model's fault

    @Test func aRecordingWithNoSpeechAsksForANewOneNotARetry() {
        let model = DictationBarModel.make(
            DictationContext(
                state: .transcriptionFailedPermanent,
                errorMessage: DictationFailure.noSpeechMessage,
                errorCode: DictationFailure.noSpeechCode
            )
        )
        #expect(model.title == "Didn't catch any speech")
        #expect(model.primary.action == .start)
        #expect(!model.title.localizedCaseInsensitiveContains("gateway"))
        #expect(!model.title.localizedCaseInsensitiveContains("failed"))
    }

    @Test func aMissingVoiceModelOffersTheAppNotAnotherDictation() {
        let failed = DictationBarModel.make(
            DictationContext(
                state: .transcriptionFailedPermanent,
                errorCode: DictationFailure.voiceModelMissingCode
            )
        )
        #expect(failed.title == "Voice model needed")
        #expect(failed.primary.action == .openVoiceModelSetup)

        let checkedFirst = DictationBarModel.make(
            DictationContext(state: .idle, notice: .voiceModelNeeded)
        )
        #expect(checkedFirst.title == "Voice model needed")
        #expect(checkedFirst.primary.action == .openVoiceModelSetup)
        #expect(checkedFirst.secondaries.contains { $0.action == .dismiss })
        #expect(checkedFirst.layout == .status)
    }

    @Test func gatewayAnswersForSilenceAreNoSpeech() {
        #expect(DictationFailure.gatewayFoundNoSpeech(code: "empty_transcript"))
        #expect(DictationFailure.gatewayFoundNoSpeech(code: "silent_audio"))
        #expect(!DictationFailure.gatewayFoundNoSpeech(code: "engine_unavailable"))
        #expect(DictationFailure(code: "no_speech") == .noSpeech)
        #expect(DictationFailure(code: nil) == .other)
        for failure in [DictationFailure.noSpeech, .voiceModelMissing, .microphoneSilenced,
                        .languageUnsupported, .other] {
            #expect(failure.keyboardLine.count < 60)
        }
    }

    @Test func aFailedLiveActivityNamesTheProblem() {
        #expect(DictationFailure.liveActivityStatus(state: .serverUnavailable, code: nil)
            .contains("Gateway unreachable"))
        #expect(DictationFailure.liveActivityStatus(
            state: .transcriptionFailedPermanent, code: "no_speech"
        ) == "Didn't catch any speech")
        for state in [SessionState.serverUnavailable, .uploadFailedRecoverable,
                      .transcriptionFailedRecoverable, .transcriptionFailedPermanent] {
            let status = DictationFailure.liveActivityStatus(state: state, code: nil)
            #expect(status != "Needs attention")
            #expect(status.count <= 40)
        }
    }

    // MARK: - Sessions that ended without being asked to

    private static func ended(
        _ state: SessionState,
        error: SessionFailure? = nil,
        audio: String? = nil,
        transcript: String? = nil,
        age: TimeInterval = 5,
        source: String? = "doc"
    ) -> SessionRecord {
        var record = SessionRecord(state: state, sourceDocumentID: source)
        record.error = error
        record.localAudioReference = audio
        record.transcript = transcript
        record.updatedAt = Date(timeIntervalSinceNow: -age)
        return record
    }

    @Test func aMicrophoneThatWouldNotStartIsReportedOnce() {
        let failure = SessionFailure(code: "recording_start_failed", message: "x", recoverable: false)
        #expect(DictationNotice.forEndedSession(Self.ended(.canceled, error: failure))
            == .recordingDidNotStart)
        let model = DictationBarModel.make(
            DictationContext(state: .canceled, notice: .recordingDidNotStart)
        )
        #expect(model.title == "Recording didn't start")
        #expect(model.primary.action == .start)
    }

    @Test func aPlainCancelSaysNothing() {
        #expect(DictationNotice.forEndedSession(Self.ended(.canceled)) == nil)
        #expect(DictationNotice.forEndedSession(Self.ended(.completed)) == nil)
    }

    /// Discarding a failed dictation cancels it with the failure's error still
    /// attached. The recording worked; blaming the microphone would be wrong.
    @Test func discardingAFailureDoesNotBlameTheMicrophone() {
        let gateway = SessionFailure(code: "gateway_unreachable", message: "x", recoverable: true)
        #expect(DictationNotice.forEndedSession(Self.ended(.canceled, error: gateway)) == nil)
    }

    @Test func expiryIsToldApartByWhatWasLost() {
        #expect(DictationNotice.forEndedSession(Self.ended(.expired)) == .handoffTimedOut)
        #expect(DictationNotice.forEndedSession(Self.ended(.expired, audio: "a.wav"))
            == .dictationTimedOut)
        #expect(DictationNotice.forEndedSession(Self.ended(.expired, transcript: "words"))
            == .transcriptExpired)
        #expect(DictationNotice.forExpiry(of: Self.ended(.awaitingReturn, age: 125))
            == .handoffTimedOut)
        #expect(DictationNotice.forExpiry(of: Self.ended(.readyToInsert, transcript: "w", age: 3_700))
            == .transcriptExpired)
    }

    /// Yesterday's failure is not news, and nor is a microphone test.
    @Test func oldOrInAppSessionsAreNotReported() {
        let failure = SessionFailure(code: "recording_start_failed", message: "x", recoverable: false)
        #expect(DictationNotice.forEndedSession(
            Self.ended(.canceled, error: failure, age: 86_400)
        ) == nil)
        #expect(DictationNotice.forEndedSession(
            Self.ended(.canceled, error: failure, source: SessionOrigin.microphoneTest)
        ) == nil)
        #expect(DictationNotice.forExpiry(of: Self.ended(.launchingApp, age: 86_400)) == nil)
        #expect(!DictationNotice.showsEndedFailure(Self.ended(.transcriptionFailedPermanent, age: 86_400)))
        #expect(DictationNotice.showsEndedFailure(Self.ended(.transcriptionFailedPermanent)))
        #expect(!DictationNotice.showsEndedFailure(Self.ended(.completed)))
    }

    /// A notice only stands in for the resting bar. A live session always wins.
    @Test func aNoticeNeverCoversALiveSession() {
        let live = DictationBarModel.make(
            DictationContext(state: .recording, notice: .voiceModelNeeded)
        )
        #expect(live.title == "Listening")
    }
}
