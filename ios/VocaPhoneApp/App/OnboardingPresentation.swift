import Foundation

/// The focused moments in first-run setup. These are deliberately separate from
/// `SetupStep`: Welcome teaches the product but is not an operational requirement.
enum OnboardingStage: String, CaseIterable, Identifiable, Hashable, Sendable {
    case welcome
    case source
    /// On-device model download. Gateway users skip this page in `SetupView`.
    case model
    case microphone
    case keyboard
    case keyboardSwitch
    case practice
    /// Optional anonymous usage reporting. The last page, and only for someone
    /// who has not answered the question yet — here or in Settings › Privacy.
    case usageReporting
    /// Not a walkable page. Persistence token after first run ends, and the
    /// signal `SetupView` uses to leave — with the Ready-to-dictate cover
    /// only when a model is actually on disk.
    case complete

    var id: String { rawValue }

    /// Left-to-right order of the first-run pages.
    static let pageOrder: [OnboardingStage] = [
        .welcome, .source, .model, .microphone, .keyboard, .keyboardSwitch, .practice,
        .usageReporting, .complete,
    ]

    /// Decode a saved page. `handoff` was a teaching screen that no longer exists.
    static func persisted(from raw: String?) -> OnboardingStage {
        guard let raw, !raw.isEmpty else { return .welcome }
        if raw == "handoff" { return .source }
        return OnboardingStage(rawValue: raw) ?? .welcome
    }

    /// Thin top bar. Welcome is a sliver so the bar is already visible, then
    /// each operational page fills it. Keyboard and switch share a stop so the
    /// bar does not jump sideways for a page that is a state, not a new room.
    var chromeProgress: Double {
        switch self {
        case .welcome: 1.0 / 6.0
        case .source: 2.0 / 6.0
        case .model: 3.0 / 6.0
        case .microphone: 4.0 / 6.0
        case .keyboard, .keyboardSwitch: 5.0 / 6.0
        case .practice, .usageReporting, .complete: 1
        }
    }

    /// Skip is one page forward. Choose model: no download. Try dictating: no
    /// insert proof — so a missed keyboard ping is not a trap.
    var allowsSkip: Bool { self == .model || self == .practice }
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

    /// How long the page stays merely patient before offering a way out.
    ///
    /// Twelve seconds was not enough to read the page, find the globe, hold it
    /// and pick vocaphone — it interrupted people who were doing exactly the
    /// right thing.
    static let grace: TimeInterval = 20
}

/// Pure onboarding decisions. Keeping these outside SwiftUI makes it impossible
/// for one view branch to call setup complete while another still names a missing
/// permission as required.
enum OnboardingPresentation {
    /// The first missing proof, and where a resumed first run belongs.
    ///
    /// A successful transcript is not sufficient for `.complete`: the stronger
    /// keyboard-practice proof says the keyboard inserted it too. `.complete`
    /// is not shown — it means first run is over.
    ///
    /// `allowSkippedModel` is what a finished first-run still holds: Skip was
    /// a choice rather than an unfinished room. Everywhere else a skipped
    /// download still reopens Choose model.
    static func resumeStage(
        status: SetupStatus,
        hasCompletedKeyboardPractice: Bool,
        allowSkippedModel: Bool = false
    ) -> OnboardingStage {
        let skippedModel = practiceIsBlockedUntilModelDownload(status: status)
        if !status.isSatisfied(.source), !(allowSkippedModel && skippedModel) {
            // On-device still needs a model; sending them to source would
            // re-ask a choice they already made.
            return status.source.selected == .onDevice ? .model : .source
        }
        if !status.isSatisfied(.microphone) { return .microphone }
        if !status.isSatisfied(.keyboard) { return .keyboard }
        if skippedModel { return .complete }
        if !hasCompletedKeyboardPractice { return .practice }
        return .complete
    }

    /// Where a relaunched first run resumes. Only ever called while setup is
    /// unfinished — `ContentView` shows the flow instead of home precisely
    /// then — so there is no "already completed" case to answer here.
    static func initialStage(
        persistedStage: OnboardingStage?,
        status: SetupStatus,
        hasCompletedKeyboardPractice: Bool,
        modelIsArriving: Bool = false,
        hasAnsweredUsageReporting: Bool = true
    ) -> OnboardingStage {
        // The two teaching pages have no system proof to reconstruct, so keep
        // their exact position. From the first operational page onward, live
        // state is stronger than a stale saved page: Settings may have finished
        // one or more requirements while vocaphone was suspended.
        switch persistedStage ?? .welcome {
        case .welcome: return .welcome
        case .microphone:
            // Stay. Settings may have granted the mic; Continue is on the page.
            // A skipped model is not a reason to rewind here.
            return .microphone
        case .source:
            return resumeStage(
                status: status,
                hasCompletedKeyboardPractice: hasCompletedKeyboardPractice
            )
        case .complete:
            return resumeStage(
                status: status,
                hasCompletedKeyboardPractice: hasCompletedKeyboardPractice,
                allowSkippedModel: true
            )
        case .usageReporting:
            // The question is only worth staying for while everything before
            // it still holds. Otherwise resume where setup actually broke.
            let resume = resumeStage(
                status: status,
                hasCompletedKeyboardPractice: hasCompletedKeyboardPractice,
                allowSkippedModel: true
            )
            return resume == .complete && !hasAnsweredUsageReporting ? .usageReporting : resume
        case .model:
            // Stay. Skip is a choice. Later pages must not rewind here.
            return .model
        case .keyboard:
            if !status.isSatisfied(.microphone) { return .microphone }
            // Stay, whatever the stored status says. A `.ready` write proves
            // Full Access was on when it was written; the switch may have been
            // turned off since, and an extension without Full Access cannot
            // write to say so. The page asks the keyboard on arrival and moves
            // on only when this visit hears back.
            return .keyboard
        case .keyboardSwitch:
            if !status.isSatisfied(.microphone) { return .microphone }
            if status.isKeyboardInstalled == false { return .keyboard }
            return .keyboardSwitch
        case .practice:
            // A download that survived the relaunch is still a reason to be
            // here: the background session keeps going while the app is gone.
            if practiceIsBlockedUntilModelDownload(status: status),
               !modelIsArriving,
               status.isSatisfied(.microphone),
               status.isSatisfied(.keyboard) || status.isKeyboardInstalled == true
            {
                return .complete
            }
            return .practice
        }
    }

    /// First run owns the window until it is finished. Once `setupCompleted`
    /// is written the flow is over, including for someone who skipped the
    /// practice — Skip is an answer, and re-imposing the flow on them would
    /// make it a trap rather than a choice.
    static func requiresFirstRunCover(setupCompleted: Bool) -> Bool {
        !setupCompleted
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

    /// What Set up keyboard can say, and the one button that goes with it.
    enum SetupKeyboardVerdict: Equatable {
        /// Not in the keyboard list. Open Settings.
        case addKeyboard
        /// In the list, and Full Access is off. Turn on Full Access.
        case turnOnFullAccess
        /// In the list with Full Access. On to Enable keyboard.
        case ready
        /// Full Access changed while vocaphone was away. Only the keyboard can
        /// say which way, and it only speaks once it is running — which is
        /// what Enable keyboard is for.
        case verifyOnEnable
    }

    /// Set up keyboard's answer, without raising a keyboard to ask.
    ///
    /// The app cannot read Full Access; only the extension can, and only while
    /// it is the keyboard on screen — which on this page it never is, so a
    /// hidden field raised here brings up whatever keyboard was used last and
    /// hears nothing. That silence used to be read as "carry on", and waved
    /// people through with the switch still off.
    ///
    /// What the app *can* see is whether it survived the trip. iOS terminates
    /// an app when its privacy settings change, and Allow Full Access for its
    /// keyboard is one of them; adding the keyboard to the list is not. So a
    /// return the process lived through is proof the switch did not move, and
    /// the keyboard's last report still stands. A return it did not live
    /// through means the switch moved, and the answer has to come from the
    /// keyboard itself.
    ///
    /// - Parameter fullAccessMayHaveChanged: vocaphone did not survive a trip
    ///   to Settings started from this page.
    static func setupKeyboardVerdict(
        status: SetupStatus,
        fullAccessMayHaveChanged: Bool
    ) -> SetupKeyboardVerdict {
        if fullAccessMayHaveChanged { return .verifyOnEnable }
        switch status.keyboard {
        case .notAdded:
            return status.isKeyboardInstalled == true ? .turnOnFullAccess : .addKeyboard
        case .ready, .silent:
            // A keyboard that has been gone from the list since it last ran is
            // not ready, whatever it reported then.
            return status.isKeyboardInstalled == false ? .addKeyboard : .ready
        case .addedButNeverRun, .seenWithoutFullAccess:
            return status.isKeyboardInstalled == false ? .addKeyboard : .turnOnFullAccess
        }
    }

    /// The verification page's whole state, from evidence plus elapsed time.
    ///
    /// `waitedFor` only ever chooses between two ways of saying "nothing yet";
    /// it can never promote the page to verified, which is the property that
    /// keeps a slow keyboard from being mistaken for a granted one.
    ///
    /// The page asks the extension to republish while it waits (see
    /// ``VocaPhoneDarwinNotification/keyboardStatusRequested``), so a write at
    /// or after `pageOpenedAt` means vocaphone is on screen *now*. That
    /// includes a vocaphone that was already the keyboard when the page
    /// opened, which is the page's goal reached early rather than a false
    /// positive — the earlier version treated it as one and waited forever.
    static func keyboardVerification(
        status: SetupStatus,
        waitedFor: TimeInterval,
        pageOpenedAt: Date? = nil
    ) -> KeyboardVerification {
        if case .seenWithoutFullAccess(let at) = status.keyboard {
            // Only a report from *this* visit. Turning the switch off then
            // on again leaves the old Darwin ping in place; treating that as
            // current sealed Enable keyboard on "Turn on Full Access" with
            // no way to re-prove.
            if let gate = pageOpenedAt {
                if keyboardAppeared(lastSeenAt: at, after: gate) {
                    return .fullAccessOff
                }
            } else {
                return .fullAccessOff
            }
        }
        if status.isSatisfied(.keyboard) {
            // No clock yet: a leftover `.ready` from Settings or last week
            // must not count as switching vocaphone on this page.
            guard let gate = pageOpenedAt else {
                return waitedFor >= KeyboardVerification.grace ? .stalled : .waiting
            }
            if !keyboardAppeared(lastSeenAt: status.keyboard.lastSeenAt, after: gate) {
                return waitedFor >= KeyboardVerification.grace ? .stalled : .waiting
            }
            return .verified
        }
        return waitedFor >= KeyboardVerification.grace ? .stalled : .waiting
    }

    /// vocaphone ran at or after `gate`. A write from last week is earlier and
    /// does not count.
    ///
    /// ``KeyboardStatus`` floors `lastSeenAt` to the second, so the gate is
    /// floored too. Comparing a whole-second write against a fractional gate
    /// lost the same-second case (`11.0 < 11.4`) and left Enable keyboard up
    /// with nowhere to type.
    static func keyboardAppeared(lastSeenAt: Date?, after gate: Date) -> Bool {
        guard let lastSeenAt else { return false }
        return lastSeenAt >= Date(timeIntervalSince1970: gate.timeIntervalSince1970.rounded(.down))
    }

    static func previousStage(before stage: OnboardingStage) -> OnboardingStage? {
        switch stage {
        case .welcome: nil
        case .source: .welcome
        case .model: .source
        case .microphone: .model
        case .keyboard: .microphone
        case .keyboardSwitch: .keyboard
        case .practice: .keyboardSwitch
        case .usageReporting: .practice
        case .complete: .practice
        }
    }

    /// One page back, skipping rooms that would immediately bounce forward.
    /// Enable keyboard auto-advances once vocaphone is the IME, so Back from
    /// Try dictating must land on Set up keyboard instead of that waiting page.
    static func previousNavigableStage(
        before stage: OnboardingStage,
        localTranscriptionEnabled: Bool,
        isKeyboardReady: Bool,
        practiceBlockedUntilModel: Bool = false
    ) -> OnboardingStage? {
        guard var previous = previousStage(before: stage) else { return nil }
        // A gateway user has no Choose model page at all. An on-device user
        // without a model very much does — that is the room Back is for, and
        // skipping it because the download is missing sent them one page past
        // the only page that could fix it.
        if previous == .model, !localTranscriptionEnabled {
            previous = .source
        }
        // Enable keyboard auto-advances once vocaphone is the IME. Landing
        // there after a skipped model bounced straight back.
        if stage == .complete || stage == .usageReporting, practiceBlockedUntilModel {
            return .keyboard
        }
        if previous == .keyboardSwitch, isKeyboardReady || practiceBlockedUntilModel {
            previous = .keyboard
        }
        return previous
    }

    /// vocaphone is the IME. No on-device model means nothing to dictate, so
    /// Try dictating is skipped — unless one is on its way, which is the point
    /// of letting Choose model be left early: adding the keyboard takes about
    /// as long as the download, and the page waits out whatever is left.
    static func stageAfterKeyboardSwitch(
        status: SetupStatus,
        modelIsArriving: Bool = false
    ) -> OnboardingStage {
        if modelIsArriving { return .practice }
        return practiceIsBlockedUntilModelDownload(status: status) ? .complete : .practice
    }

    static func nextStage(after stage: OnboardingStage) -> OnboardingStage? {
        switch stage {
        case .welcome: .source
        case .source: .model
        case .model: .microphone
        case .microphone: .keyboard
        case .keyboard: .keyboardSwitch
        case .keyboardSwitch: .practice
        case .practice: .complete
        case .usageReporting: .complete
        case .complete: nil
        }
    }

    /// Practice is deliberately not required: it can be skipped when the
    /// insert ping never arrives. Mic and keyboard are what actually make
    /// dictation work.
    static func canFinishSetup(status: SetupStatus) -> Bool {
        let keyboardReady = status.isSatisfied(.keyboard) || status.isKeyboardInstalled == true
        guard status.isSatisfied(.microphone), keyboardReady else { return false }
        if practiceIsBlockedUntilModelDownload(status: status) { return true }
        return status.isReadyToDictate
    }

    /// The Ready-to-dictate cover is the same kind of confirmation as
    /// Microphone ready: only when the claim is true. A skipped download
    /// is not ready to dictate, so first run ends without it.
    static func showsSetupReadyFlash(status: SetupStatus) -> Bool {
        canFinishSetup(status: status)
            && !practiceIsBlockedUntilModelDownload(status: status)
    }

    /// First run ends by asking about usage reporting, once. Someone who
    /// already answered — on this page or with the switch in Settings — is not
    /// asked again, and nobody is asked before setup can actually finish.
    static func asksAboutUsageReporting(status: SetupStatus, hasBeenAsked: Bool) -> Bool {
        !hasBeenAsked && canFinishSetup(status: status)
    }

    /// Skip on Choose model is the "no download" answer. Once Get has started
    /// a transfer, that answer is gone — Continue (or waiting later) is.
    /// Try dictating still offers Skip: that one is about insert proof, not
    /// the download.
    static func showsSkip(stage: OnboardingStage, modelIsArriving: Bool) -> Bool {
        guard stage.allowsSkip else { return false }
        if stage == .model, modelIsArriving { return false }
        return true
    }

    /// Skip on Choose model is allowed. On-device dictation has nothing to
    /// run until a model is on disk, so Try dictating is omitted.
    static func practiceIsBlockedUntilModelDownload(status: SetupStatus) -> Bool {
        status.source.selected == .onDevice && !status.source.isOnDeviceReady
    }

    /// After Get finishes, skip rooms already proven. Walking Microphone and
    /// Set up keyboard again is what made "download a model, then try" a loop.
    /// A keyboard already in the list still needs Enable keyboard (the globe),
    /// not another Open Settings.
    static func stageAfterOnboardingModelDownload(
        status: SetupStatus,
        hasCompletedKeyboardPractice: Bool
    ) -> OnboardingStage {
        if !status.isSatisfied(.microphone) { return .microphone }
        if status.isSatisfied(.keyboard) {
            return hasCompletedKeyboardPractice ? .complete : .practice
        }
        let added = status.isKeyboardInstalled == true || status.keyboard != .notAdded
        return added ? .keyboardSwitch : .keyboard
    }

}
