import Foundation

/// A step guided setup walks through, in the order the checklist presents them.
enum SetupStep: String, CaseIterable, Identifiable, Sendable {
    case gateway
    case microphone
    case keyboard
    case firstDictation

    var id: String { rawValue }

    /// Short enough to read as a list inside a single sentence.
    var label: String {
        switch self {
        case .gateway: "Gateway"
        case .microphone: "Microphone"
        case .keyboard: "Keyboard"
        case .firstDictation: "Test dictation"
        }
    }

    var title: String {
        switch self {
        case .gateway: "Connect your transcription gateway"
        case .microphone: "Allow microphone access"
        case .keyboard: "Add the keyboard with Full Access"
        case .firstDictation: "Try one dictation"
        }
    }

    var symbolName: String {
        switch self {
        case .gateway: "server.rack"
        case .microphone: "mic"
        case .keyboard: "keyboard"
        case .firstDictation: "waveform"
        }
    }

    /// Dictation cannot work at all without the first three. The trial run only
    /// proves the chain end to end, so skipping it must not produce a warning
    /// on the main screen later.
    var isRequiredForDictation: Bool { self != .firstDictation }
}

/// iOS publishes the user's enabled keyboards under an undocumented key in the
/// global domain. There is no API for this, so the key may change or disappear
/// in a future release — `nil` therefore means "iOS did not say", never "not
/// installed", and the result is only ever used to move the checklist forward.
enum InstalledKeyboards {
    static let preferenceKey = "AppleKeyboards"

    static func includesVocaPhone() -> Bool? {
        includesVocaPhone(UserDefaults.standard.array(forKey: preferenceKey) as? [String])
    }

    /// Entries carry trailing layout options, so the bundle identifier is
    /// matched as a substring rather than compared whole.
    static func includesVocaPhone(_ identifiers: [String]?) -> Bool? {
        identifiers.map { entries in
            entries.contains { $0.contains(AppConfiguration.keyboardBundleIdentifier) }
        }
    }
}

/// What the app can observe about the keyboard extension.
///
/// iOS exposes no API for whether a keyboard holds Full Access, and a keyboard
/// without it cannot reach the shared container at all. So the extension's own
/// last write is the only proof of Full Access, and losing it looks like
/// silence rather than a reported loss.
enum KeyboardSetupState: Equatable, Sendable {
    case notAdded
    /// Listed among the user's keyboards but it has never reached the shared
    /// container — so either Full Access is still off, or it has not been
    /// switched to yet. The two are indistinguishable from here, and both are
    /// answered by the same instruction.
    case addedButNeverRun
    /// Defensive: the extension reports the state it sees, and a write that
    /// lands while it believes Full Access is off is worth saying plainly.
    case seenWithoutFullAccess(lastSeenAt: Date)
    case ready(lastSeenAt: Date)
    /// Full Access was granted once, but the keyboard has not run since. It may
    /// have been removed, or Full Access turned back off.
    case silent(lastSeenAt: Date)

    /// The keyboard rewrites its status every time it appears, so a long gap
    /// means it has not been used — not that it is idle between dictations.
    static let silenceThreshold: TimeInterval = 30 * 24 * 60 * 60

    var lastSeenAt: Date? {
        switch self {
        case .notAdded, .addedButNeverRun: nil
        case let .seenWithoutFullAccess(date), let .ready(date), let .silent(date): date
        }
    }

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    /// A stored status is hard evidence that the extension ran with Full
    /// Access, so `isInstalled` is never allowed to contradict it. If the
    /// undocumented keyboard list ever changes shape, the worst that happens is
    /// the checklist stops advancing early — not that a working setup is
    /// declared broken.
    static func resolve(
        _ status: KeyboardStatus?,
        isInstalled: Bool? = nil,
        now: Date = Date()
    ) -> KeyboardSetupState {
        guard let status else {
            return isInstalled == true ? .addedButNeverRun : .notAdded
        }
        guard status.hasFullAccess else {
            return .seenWithoutFullAccess(lastSeenAt: status.lastSeenAt)
        }
        return now.timeIntervalSince(status.lastSeenAt) > silenceThreshold
            ? .silent(lastSeenAt: status.lastSeenAt)
            : .ready(lastSeenAt: status.lastSeenAt)
    }
}

/// Mirrors the three states iOS reports for the microphone. Kept separate from
/// `AVAudioApplication` so the setup model stays free of audio machinery, and
/// because "denied" and "not asked yet" need different buttons: iOS only ever
/// shows the system prompt once.
enum MicrophoneAccess: Sendable {
    case undetermined
    case denied
    case granted
}

/// Everything guided setup checks, re-read whenever the app returns to the
/// foreground: every one of these can be undone from iOS Settings.
struct SetupStatus: Equatable, Sendable {
    var gatewayReady = false
    var gatewayAddress = ""
    var microphone: MicrophoneAccess = .undetermined
    var keyboard: KeyboardSetupState = .notAdded
    var hasDictatedOnce = false

    func isSatisfied(_ step: SetupStep) -> Bool {
        switch step {
        case .gateway: gatewayReady
        case .microphone: microphone == .granted
        case .keyboard: keyboard.isReady
        case .firstDictation: hasDictatedOnce
        }
    }

    /// What the checklist still wants, in checklist order.
    var remainingSteps: [SetupStep] {
        SetupStep.allCases.filter { !isSatisfied($0) }
    }

    /// The subset the main screen is allowed to warn about once setup has been
    /// left behind.
    var blockingSteps: [SetupStep] {
        remainingSteps.filter(\.isRequiredForDictation)
    }

    var stepCount: Int { SetupStep.allCases.count }

    var completedStepCount: Int { stepCount - remainingSteps.count }

    var progress: Double { Double(completedStepCount) / Double(stepCount) }

    /// Dictation works. The trial run may still be outstanding.
    var isReadyToDictate: Bool { blockingSteps.isEmpty }

    var isComplete: Bool { remainingSteps.isEmpty }

    /// A headline for the main screen naming the first thing that stops
    /// dictation working, or `nil` when nothing does. An outstanding trial run
    /// never produces one: it is a confidence check, not a fault.
    var attentionHeadline: String? {
        guard let first = blockingSteps.first else { return nil }
        guard blockingSteps.count == 1 else {
            return "vocaphone needs \(blockingSteps.count) more steps"
        }
        switch first {
        case .gateway:
            return gatewayAddress.isEmpty
                ? "No transcription gateway yet"
                : "Your gateway is not responding"
        case .microphone:
            return microphone == .denied
                ? "Microphone access is turned off"
                : "Microphone access is needed"
        case .keyboard:
            switch keyboard {
            case .silent: return "Confirm the keyboard is still installed"
            case .addedButNeverRun, .seenWithoutFullAccess:
                return "The keyboard needs Full Access"
            default: return "The keyboard is not ready yet"
            }
        case .firstDictation:
            return nil
        }
    }

    /// The supporting line for `attentionHeadline`.
    var attentionDetail: String? {
        blockingSteps.first.map(detail(for:))
    }

    /// Plain-English state for one step.
    ///
    /// This lives beside the model rather than in the view so that a step can
    /// never describe itself as done while its checkmark says otherwise — the
    /// keyboard row in particular used to report "last active …" for a keyboard
    /// that had never been granted Full Access.
    func detail(for step: SetupStep) -> String {
        switch step {
        case .gateway:
            if gatewayReady {
                return gatewayAddress.isEmpty
                    ? (LocalTranscriptionPreferences.enabled
                        ? "On-device speech-to-text model is ready."
                        : "Gateway, token, and model are ready.")
                    : "Ready at \(gatewayAddress)."
            }
            return "Connect a gateway, or choose and download an on-device model below."
        case .microphone:
            switch microphone {
            case .granted:
                return "vocaphone records on this iPhone; the keyboard only "
                    + "receives the finished transcript."
            case .undetermined:
                return "Recording happens in this app, never in the keyboard."
            case .denied:
                return "Microphone access was declined. Turn it back on for "
                    + "vocaphone in iOS Settings › Privacy & Security › Microphone."
            }
        case .keyboard:
            switch keyboard {
            case .notAdded:
                return "In iOS Settings, open General › Keyboard › Keyboards › "
                    + "Add New Keyboard and choose vocaphone, then tap it again "
                    + "and turn on Allow Full Access."
            case .addedButNeverRun:
                return "vocaphone is in your keyboard list. Turn on Allow Full "
                    + "Access for it, then switch to it in the field below — "
                    + "this ticks itself the moment it runs."
            case .seenWithoutFullAccess:
                return "vocaphone is added, but Full Access is off. Tap vocaphone "
                    + "Flow under Keyboards and turn on Allow Full Access."
            case let .ready(lastSeenAt):
                return "Ready. The keyboard last ran \(Self.format(lastSeenAt))."
            case let .silent(lastSeenAt):
                return "The keyboard has not run since \(Self.format(lastSeenAt)). "
                    + "Switch to it once in any app to confirm it is still "
                    + "installed with Full Access."
            }
        case .firstDictation:
            return hasDictatedOnce
                ? "A transcript has come back from your gateway."
                : "Record a few seconds here to prove the whole chain works "
                    + "before you rely on it in another app."
        }
    }

    private static func format(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}
