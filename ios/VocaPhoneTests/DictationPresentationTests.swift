import Testing
import UIKit

@MainActor
struct DictationPresentationTests {
    private static func model(
        _ state: SessionState,
        transcript: String? = nil,
        errorMessage: String? = nil,
        autoInsert: Bool = false,
        canRetry: Bool = false,
        canUndo: Bool = false,
        hasFullAccess: Bool = true,
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

    @Test func withoutFullAccessNothingIsActionable() {
        let model = Self.model(.idle, canUndo: true, hasFullAccess: false)
        #expect(model.accent == .locked)
        #expect(!model.primary.isEnabled)
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

    @Test func aStrandedTranscriptCanBeRedirectedToTheCurrentField() {
        let model = Self.model(.targetContextChanged, transcript: "Redirect me")
        #expect(model.primary.action == .insertHere)
        #expect(model.body == .message("“Redirect me”"))
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
        #expect(text.contains("Keyboard"))
        #expect(AppConfiguration.fullAccessSettingsPath.contains("Keyboards › vocaphone"))
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
}
