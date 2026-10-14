import Foundation
import Testing

@MainActor
struct KeyboardHandoffPresentationTests {
    private func record(
        state: SessionState,
        startedInContainingApp: Bool? = false,
        sourceDocumentID: String? = nil,
        processingLocation: SessionProcessingLocation? = .gateway,
        transcript: String? = nil
    ) -> SessionRecord {
        var record = SessionRecord(
            state: state,
            sourceDocumentID: sourceDocumentID
        )
        record.startedInContainingApp = startedInContainingApp
        record.processingLocation = processingLocation
        record.transcript = transcript
        return record
    }

    @Test func externalRecordingAsksForTheReturnGestureWithAQuietWayOut() {
        let presentation = KeyboardHandoffPresentation.make(record(state: .recording))

        #expect(presentation?.kind == .recording)
        #expect(presentation?.title == "Swipe back to your app")
        #expect(presentation?.detail == "Recording follows you there.")
        #expect(presentation?.primaryAction == KeyboardHandoffPresentation.PrimaryAction.none)
        #expect(presentation?.primaryTitle == nil)
        #expect(presentation?.showsCancel == true)
        #expect(presentation?.showsElapsedTime == true)
        // Nothing is recording yet while the app comes up, so no clock.
        #expect(KeyboardHandoffPresentation.make(record(state: .launchingApp))?.showsElapsedTime == false)
    }

    /// The app is opened by the keyboard, so the screen it opens on has to be
    /// the hand-off — not the home screen for the moment before the recorder
    /// catches up.
    @Test func theWaitForTheAppToOpenIsAlreadyTheHandoff() {
        for state in [SessionState.launchingApp, .awaitingReturn] {
            let pending = record(state: state)
            #expect(KeyboardHandoffPresentation.shouldPresent(pending))
            #expect(KeyboardHandoffPresentation.make(pending)?.kind == .recording)
        }
    }

    /// But not on an ordinary launch days later, with a hand-off nobody claimed
    /// still sitting in the store.
    @Test func anAbandonedHandoffDoesNotTakeOverAnOrdinaryLaunch() {
        var abandoned = record(state: .launchingApp)
        abandoned.updatedAt = Date(
            timeIntervalSinceNow: -SessionExpiryPolicy.handoffWindow - 1
        )

        #expect(!KeyboardHandoffPresentation.shouldPresent(abandoned))
    }

    @Test func processingKeepsTheHandoffStoryAndNamesTheConfirmedRoute() {
        let presentation = KeyboardHandoffPresentation.make(
            record(state: .transcribing, processingLocation: .onDevice)
        )

        #expect(presentation?.kind == .processing)
        #expect(presentation?.title == "Transcribing on this iPhone")
        #expect(presentation?.primaryAction == KeyboardHandoffPresentation.PrimaryAction.none)
    }

    @Test func aReadyTranscriptExplainsTheDifferentFieldChoice() {
        let presentation = KeyboardHandoffPresentation.make(
            record(
                state: .targetContextChanged,
                transcript: "A preserved transcript"
            )
        )

        #expect(presentation?.kind == .ready)
        #expect(presentation?.title == "Your text is ready")
        #expect(presentation?.detail.contains("original") == true)
        #expect(presentation?.detail.contains("Insert here") == true)
    }

    @Test func inAppPracticeNeverShowsTheExternalHandoff() {
        #expect(!KeyboardHandoffPresentation.shouldPresent(
            record(state: .recording, startedInContainingApp: true)
        ))
        #expect(!KeyboardHandoffPresentation.shouldPresent(
            record(state: .recording, sourceDocumentID: "in-app-test")
        ))
    }

    @Test func recoverableFailurePreservesTheRetryPath() {
        var failedRecord = record(state: .uploadFailedRecoverable)
        failedRecord.error = SessionFailure(
            code: "timeout",
            message: "The gateway did not answer in time.",
            recoverable: true
        )
        let presentation = KeyboardHandoffPresentation.make(failedRecord)

        #expect(presentation?.kind == .recoverableFailure)
        #expect(presentation?.primaryAction == .retry)
        #expect(presentation?.primaryTitle == "Retry transcript")
        #expect(presentation?.detail == "The gateway did not answer in time.")
    }

    /// A waiting transcript used to hold the whole app behind this screen with
    /// only Cancel dictation. Copy text and Not now are the ways past it that
    /// keep the words.
    @Test func aWaitingTranscriptCanBeCopiedOrLeftForLater() {
        for state in [SessionState.readyToInsert, .targetContextChanged] {
            let presentation = KeyboardHandoffPresentation.make(
                record(state: state, transcript: "Waiting words")
            )
            #expect(presentation?.primaryAction == .copyTranscript)
            #expect(presentation?.primaryTitle == "Copy text")
            #expect(presentation?.showsNotNow == true)
        }
        let empty = KeyboardHandoffPresentation.make(record(state: .readyToInsert))
        #expect(empty?.primaryAction == KeyboardHandoffPresentation.PrimaryAction.none)
        #expect(empty?.showsNotNow == true)
    }

    @Test func everyStatusScreenHasAWayHomeButRecordingDoesNot() {
        for state in [SessionState.finalizing, .uploading, .transcribing, .serverUnavailable,
                      .uploadFailedRecoverable, .transcriptionFailedRecoverable] {
            #expect(KeyboardHandoffPresentation.make(record(state: state))?.showsNotNow == true)
        }
        #expect(KeyboardHandoffPresentation.make(record(state: .recording))?.showsNotNow == false)
    }

    @Test func aRecordingStoppedByTheCapSaysSoHereToo() {
        var capped = record(state: .transcribing)
        capped.stoppedAtRecordingLimit = true
        #expect(KeyboardHandoffPresentation.make(capped)?.title == "Stopped at the 2-minute limit")
    }

    /// A Home-button iPhone has no bottom edge to swipe. Everyone gets the
    /// top-left button as well.
    @Test func swipeBackGuidanceFollowsThePhone() {
        let modern = SwipeBackGuidance.make(
            hasHomeIndicator: true,
            title: "Swipe back to your app",
            detail: "Recording follows you there."
        )
        #expect(modern.showsSwipe)
        #expect(modern.title == "Swipe back to your app")
        #expect(modern.alternative.contains("◀"))

        let homeButton = SwipeBackGuidance.make(
            hasHomeIndicator: false,
            title: "Swipe back to your app",
            detail: "Recording follows you there."
        )
        #expect(!homeButton.showsSwipe)
        #expect(homeButton.title == "Go back to your app")
        #expect(homeButton.alternative.contains("Home button"))
        #expect(!homeButton.title.contains("Swipe"))
    }
}
