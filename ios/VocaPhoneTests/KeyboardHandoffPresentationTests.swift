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

    @Test func externalRecordingShowsTheRealReturnGestureAndFinishAction() {
        let presentation = KeyboardHandoffPresentation.make(record(state: .recording))

        #expect(presentation?.kind == .recording)
        #expect(presentation?.title == "Recording")
        #expect(presentation?.primaryAction == .finish)
        #expect(presentation?.primaryTitle == "Finish & transcribe here")
        #expect(presentation?.detail.contains("Swipe back") == true)
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
        #expect(presentation?.detail.contains("Insert in this field") == true)
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
}
