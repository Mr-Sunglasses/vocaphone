import Foundation
import Testing

@MainActor
struct OnboardingPresentationTests {
    private var readyGateway: TranscriptionSourceStatus {
        var source = TranscriptionSourceStatus()
        source.selected = .gateway
        source.gatewayAddress = "https://dictation.example.com"
        source.isGatewayReady = true
        return source
    }

    private var readyToDictate: SetupStatus {
        SetupStatus(
            source: readyGateway,
            microphone: .granted,
            keyboard: .ready(lastSeenAt: Date()),
            hasDictatedOnce: false
        )
    }

    @Test func aFreshInstallStartsWithTheProductExplanation() {
        #expect(
            OnboardingPresentation.initialStage(
                setupCompleted: false,
                persistedStage: nil,
                status: SetupStatus(),
                hasCompletedKeyboardPractice: false
            ) == .welcome
        )
    }

    @Test func relaunchKeepsAnUnfinishedTeachingPage() {
        #expect(
            OnboardingPresentation.initialStage(
                setupCompleted: false,
                persistedStage: .handoff,
                status: SetupStatus(),
                hasCompletedKeyboardPractice: false
            ) == .handoff
        )
    }

    @Test func relaunchAfterSettingsUsesLiveProofInsteadOfReplayingWelcome() {
        var keyboardMissing = readyToDictate
        keyboardMissing.keyboard = .addedButNeverRun

        #expect(
            OnboardingPresentation.initialStage(
                setupCompleted: false,
                persistedStage: .keyboard,
                status: keyboardMissing,
                hasCompletedKeyboardPractice: false
            ) == .keyboard
        )
        #expect(
            OnboardingPresentation.initialStage(
                setupCompleted: false,
                persistedStage: .keyboard,
                status: readyToDictate,
                hasCompletedKeyboardPractice: false
            ) == .practice
        )
    }

    @Test func keyboardEnableAndSwitchAreSeparateResumableSteps() {
        var keyboardMissing = readyToDictate
        keyboardMissing.keyboard = .addedButNeverRun

        #expect(OnboardingPresentation.nextStage(after: .keyboard) == .keyboardSwitch)
        #expect(OnboardingPresentation.previousStage(before: .practice) == .keyboardSwitch)
        #expect(
            OnboardingPresentation.initialStage(
                setupCompleted: false,
                persistedStage: .keyboardSwitch,
                status: keyboardMissing,
                hasCompletedKeyboardPractice: false
            ) == .keyboardSwitch
        )
        #expect(OnboardingStage.keyboard.requiredStepNumber == 3)
        #expect(OnboardingStage.keyboardSwitch.requiredStepNumber == 4)
        #expect(OnboardingStage.practice.requiredStepNumber == 5)
    }

    /// The reported bug: opening Settings, changing nothing, and swiping back
    /// used to be enough to walk past a button that claimed Full Access was on.
    @Test func returningFromSettingsWithoutAddingTheKeyboardCannotAdvance() {
        var notAdded = readyToDictate
        notAdded.keyboard = .notAdded
        notAdded.isKeyboardInstalled = false

        #expect(!OnboardingPresentation.canAdvanceFromKeyboardEnablement(
            status: notAdded,
            returnedFromSettings: false
        ))
        #expect(!OnboardingPresentation.canAdvanceFromKeyboardEnablement(
            status: notAdded,
            returnedFromSettings: true
        ))
    }

    @Test func aKeyboardInTheListAdvancesWithoutTheSettingsRoundTrip() {
        var added = readyToDictate
        added.keyboard = .addedButNeverRun
        added.isKeyboardInstalled = true

        #expect(OnboardingPresentation.canAdvanceFromKeyboardEnablement(
            status: added,
            returnedFromSettings: false
        ))
        #expect(OnboardingPresentation.canAdvanceFromKeyboardEnablement(
            status: readyToDictate,
            returnedFromSettings: false
        ))
    }

    /// iOS publishes the keyboard list under an undocumented key. If it ever
    /// stops, setup must not trap the user on this page — the switch page still
    /// refuses to move on without the extension's own proof.
    @Test func anUnreadableKeyboardListFallsBackToTheSettingsRoundTrip() {
        var unknown = readyToDictate
        unknown.keyboard = .notAdded
        unknown.isKeyboardInstalled = nil

        #expect(!OnboardingPresentation.canAdvanceFromKeyboardEnablement(
            status: unknown,
            returnedFromSettings: false
        ))
        #expect(OnboardingPresentation.canAdvanceFromKeyboardEnablement(
            status: unknown,
            returnedFromSettings: true
        ))
    }

    @Test func oldSetupLaterStateReentersMandatoryPractice() {
        #expect(OnboardingPresentation.requiresFirstRunCover(
            setupCompleted: true,
            hasCompletedKeyboardPractice: false
        ))
        #expect(
            OnboardingPresentation.initialStage(
                setupCompleted: true,
                persistedStage: .complete,
                status: readyToDictate,
                hasCompletedKeyboardPractice: false
            ) == .practice
        )
        #expect(!OnboardingPresentation.requiresFirstRunCover(
            setupCompleted: true,
            hasCompletedKeyboardPractice: true
        ))
    }

    @Test func aReturningUserResumesAtTheFirstMissingProof() {
        var missingKeyboard = readyToDictate
        missingKeyboard.keyboard = .addedButNeverRun

        #expect(
            OnboardingPresentation.resumeStage(
                status: missingKeyboard,
                hasCompletedKeyboardPractice: false
            ) == .keyboard
        )
        #expect(
            OnboardingPresentation.resumeStage(
                status: readyToDictate,
                hasCompletedKeyboardPractice: false
            ) == .practice
        )
    }

    @Test func completionRequiresTheKeyboardPracticeProof() {
        #expect(
            OnboardingPresentation.resumeStage(
                status: readyToDictate,
                hasCompletedKeyboardPractice: true
            ) == .complete
        )
        #expect(
            OnboardingPresentation.completedProofCount(
                status: readyToDictate,
                hasCompletedKeyboardPractice: false
            ) == 3
        )
        #expect(
            OnboardingPresentation.progress(
                status: readyToDictate,
                hasCompletedKeyboardPractice: true
            ) == 1
        )
    }

    @Test func educationalPagesDoNotPretendToBeSystemProofs() {
        #expect(!OnboardingStage.welcome.showsProofProgress)
        #expect(!OnboardingStage.handoff.showsProofProgress)
        #expect(OnboardingStage.source.showsProofProgress)
        #expect(!OnboardingStage.complete.showsProofProgress)
    }
}
