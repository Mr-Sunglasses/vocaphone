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

    @Test func keyboardEnablementCannotAdvanceBeforeTheSettingsRoundTrip() {
        var keyboardMissing = readyToDictate
        keyboardMissing.keyboard = .addedButNeverRun

        #expect(!OnboardingPresentation.canAdvanceFromKeyboardEnablement(
            status: keyboardMissing,
            returnedFromSettings: false
        ))
        #expect(OnboardingPresentation.canAdvanceFromKeyboardEnablement(
            status: keyboardMissing,
            returnedFromSettings: true
        ))
        #expect(OnboardingPresentation.canAdvanceFromKeyboardEnablement(
            status: readyToDictate,
            returnedFromSettings: false
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
