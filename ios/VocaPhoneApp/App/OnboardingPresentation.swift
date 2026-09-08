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

    var progressTitle: String {
        switch self {
        case .welcome, .handoff: "Getting started"
        case .source: "Speech to text"
        case .microphone: "Microphone"
        case .keyboard: "Add your keyboard"
        case .keyboardSwitch: "Verify your keyboard"
        case .practice: "Try it out"
        case .complete: "Ready to dictate"
        }
    }

    static let requiredStepCount = 5
}

/// What the verification page knows about the keyboard right now.
///
/// The page it drives used to have exactly two states — a spinner and a
/// checkmark — which meant the most common failure, Full Access left off,
/// looked identical to having done nothing at all. Waiting is not a diagnosis,
/// and a page whose only content is a spinner cannot be walked past *or*
/// fixed.
enum KeyboardVerification: Equatable, Sendable {
    /// Nothing reported yet, and not enough time has passed to read anything
    /// into that. The user has probably not switched keyboards yet.
    case waiting
    /// Still nothing, long enough that saying so is more useful than waiting
    /// quietly. Offered as the likely cause, never asserted: an unswitched
    /// keyboard looks the same from here.
    case stalled
    /// The keyboard ran and told us Full Access is off. This is a fact, not an
    /// inference, so the page may say it plainly and act on it.
    case fullAccessOff
    case verified

    /// How long the page waits before it stops being merely patient.
    static let grace: TimeInterval = 12

    var title: String {
        switch self {
        case .waiting: "Waiting for vocaphone to open"
        case .stalled: "Still waiting for vocaphone"
        case .fullAccessOff: "Full Access is off"
        case .verified: "vocaphone opened with Full Access"
        }
    }

    /// One short line, or none. The page's heading already says what to do, and
    /// a paragraph under a status line is how the last version of this screen
    /// became something to read rather than something to act on.
    var detail: String? {
        switch self {
        // Nothing has gone wrong yet, so there is nothing to add.
        case .waiting: nil
        case .stalled: "If vocaphone is already open below, Full Access is probably still off."
        case .fullAccessOff: "It opened, but it cannot reach vocaphone until you turn the switch on."
        case .verified: nil
        }
    }

    var symbolName: String {
        switch self {
        case .waiting: "circle.dotted"
        case .stalled: "clock.badge.questionmark"
        case .fullAccessOff: "exclamationmark.triangle.fill"
        case .verified: "checkmark.circle.fill"
        }
    }

    /// Whether the page should send the user to iOS Settings rather than back
    /// to the text field. Only a proven report earns that.
    var needsSettings: Bool { self == .fullAccessOff }
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

    /// The containing app cannot query the Full Access switch: only the
    /// extension's own write proves it, and the extension cannot write until it
    /// has run. So this page advances on the strongest thing iOS does expose —
    /// whether vocaphone is in the user's keyboard list — and the keyboard
    /// switch page that follows performs the real Full Access proof.
    ///
    /// It deliberately no longer advances on the user's say-so after a trip to
    /// Settings. Returning from Settings says nothing about what was changed
    /// there, and offering a button that asserted Full Access was on let someone
    /// who had granted nothing walk past it.
    static func canAdvanceFromKeyboardEnablement(
        status: SetupStatus,
        returnedFromSettings: Bool
    ) -> Bool {
        if status.isSatisfied(.keyboard) { return true }
        guard let isInstalled = status.isKeyboardInstalled else {
            // iOS did not publish the keyboard list. Trapping the user on this
            // page would be worse than letting them through to the page that
            // does hold out for proof.
            return returnedFromSettings
        }
        return isInstalled
    }

    /// The verification page's whole state, from evidence plus elapsed time.
    ///
    /// `waitedFor` only ever chooses between two ways of saying "nothing yet";
    /// it can never promote the page to verified, which is the property that
    /// keeps a slow keyboard from being mistaken for a granted one.
    static func keyboardVerification(
        status: SetupStatus,
        waitedFor: TimeInterval
    ) -> KeyboardVerification {
        if status.isSatisfied(.keyboard) { return .verified }
        if case .seenWithoutFullAccess = status.keyboard { return .fullAccessOff }
        return waitedFor >= KeyboardVerification.grace ? .stalled : .waiting
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
