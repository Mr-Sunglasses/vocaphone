import Foundation

/// The focused moments in first-run setup. These are deliberately separate from
/// `SetupStep`: Welcome and the handoff explanation teach the product but do not
/// pretend to be operational requirements.
enum OnboardingStage: String, CaseIterable, Identifiable, Sendable {
    case welcome
    case handoff
    case source
    case microphone
    case keyboard
    case keyboardSwitch
    case practice
    case complete

    var id: String { rawValue }

    var showsProofProgress: Bool {
        switch self {
        case .welcome, .handoff, .complete: false
        default: true
        }
    }

    var requiredStepNumber: Int? {
        switch self {
        case .source: 1
        case .microphone: 2
        case .keyboard: 3
        case .keyboardSwitch: 4
        case .practice: 5
        case .welcome, .handoff, .complete: nil
        }
    }

    static let requiredStepCount = 5
}

/// Pure onboarding decisions. Keeping these outside SwiftUI makes it impossible
/// for one view branch to call setup complete while another still names a missing
/// permission as required.
enum OnboardingPresentation {
    /// The first useful place to resume after the educational pages have been
    /// seen. A successful transcript is not sufficient for `.complete`: the
    /// stronger keyboard-practice proof says the keyboard inserted it too.
    static func resumeStage(
        status: SetupStatus,
        hasCompletedKeyboardPractice: Bool
    ) -> OnboardingStage {
        if !status.isSatisfied(.source) { return .source }
        if !status.isSatisfied(.microphone) { return .microphone }
        if !status.isSatisfied(.keyboard) { return .keyboard }
        if !hasCompletedKeyboardPractice { return .practice }
        return .complete
    }

    static func initialStage(
        setupCompleted: Bool,
        persistedStage: OnboardingStage?,
        status: SetupStatus,
        hasCompletedKeyboardPractice: Bool
    ) -> OnboardingStage {
        if setupCompleted {
            // Older builds set this flag when setup was merely dismissed. Use
            // the absence of keyboard-practice proof to identify that state
            // and migrate it to the first real missing requirement.
            return hasCompletedKeyboardPractice
                ? .complete
                : resumeStage(
                    status: status,
                    hasCompletedKeyboardPractice: false
                )
        }

        // The two teaching pages have no system proof to reconstruct, so keep
        // their exact position. From the first operational page onward, live
        // state is stronger than a stale saved page: Settings may have finished
        // one or more requirements while vocaphone was suspended.
        switch persistedStage ?? .welcome {
        case .welcome: return .welcome
        case .handoff: return .handoff
        case .source, .microphone, .keyboard, .practice, .complete:
            return resumeStage(
                status: status,
                hasCompletedKeyboardPractice: hasCompletedKeyboardPractice
            )
        case .keyboardSwitch:
            if !status.isSatisfied(.source) || !status.isSatisfied(.microphone) {
                return resumeStage(
                    status: status,
                    hasCompletedKeyboardPractice: hasCompletedKeyboardPractice
                )
            }
            return status.isSatisfied(.keyboard) ? .practice : .keyboardSwitch
        }
    }

    /// Existing builds used `setupCompleted` as “the intro was dismissed.” A
    /// user who chose that escape hatch without proving keyboard insertion must
    /// re-enter the now-mandatory flow once; completed users stay undisturbed.
    static func requiresFirstRunCover(
        setupCompleted: Bool,
        hasCompletedKeyboardPractice: Bool
    ) -> Bool {
        !setupCompleted || !hasCompletedKeyboardPractice
    }

    /// Four proof-oriented units, preserving the original progress contract
    /// while making the final unit the actual keyboard exercise.
    static func completedProofCount(
        status: SetupStatus,
        hasCompletedKeyboardPractice: Bool
    ) -> Int {
        [
            status.isSatisfied(.source),
            status.isSatisfied(.microphone),
            status.isSatisfied(.keyboard),
            hasCompletedKeyboardPractice,
        ].filter { $0 }.count
    }

    static func progress(
        status: SetupStatus,
        hasCompletedKeyboardPractice: Bool
    ) -> Double {
        Double(completedProofCount(
            status: status,
            hasCompletedKeyboardPractice: hasCompletedKeyboardPractice
        )) / Double(SetupStep.allCases.count)
    }

    /// The containing app cannot query the Full Access switch. It may advance
    /// only after an already-ready keyboard proves access, or after the user
    /// returns from the Settings trip and explicitly confirms the switch is on.
    /// The keyboard-switch page then performs the real extension-side proof.
    static func canAdvanceFromKeyboardEnablement(
        status: SetupStatus,
        returnedFromSettings: Bool
    ) -> Bool {
        status.isSatisfied(.keyboard) || returnedFromSettings
    }

    static func previousStage(before stage: OnboardingStage) -> OnboardingStage? {
        switch stage {
        case .welcome: nil
        case .handoff: .welcome
        case .source: .handoff
        case .microphone: .source
        case .keyboard: .microphone
        case .keyboardSwitch: .keyboard
        case .practice: .keyboardSwitch
        case .complete: .practice
        }
    }

    static func nextStage(after stage: OnboardingStage) -> OnboardingStage? {
        switch stage {
        case .welcome: .handoff
        case .handoff: .source
        case .source: .microphone
        case .microphone: .keyboard
        case .keyboard: .keyboardSwitch
        case .keyboardSwitch: .practice
        case .practice: .complete
        case .complete: nil
        }
    }
}
