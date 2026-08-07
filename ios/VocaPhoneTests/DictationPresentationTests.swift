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
        hasFullAccess: Bool = true
    ) -> DictationBarModel {
        DictationBarModel.make(
            DictationContext(
                state: state,
                hasFullAccess: hasFullAccess,
                transcript: transcript,
                errorMessage: errorMessage,
                autoInsertsTranscripts: autoInsert,
                canRetry: canRetry,
                canUndo: canUndo
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
