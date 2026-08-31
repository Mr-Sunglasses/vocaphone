import Foundation
import Testing

struct SetupStatusTests {
    private static let seenAt = Date(timeIntervalSince1970: 1_700_000_000)

    private static let readyGateway = TranscriptionSourceStatus(
        selected: .gateway,
        gatewayAddress: "http://homelabone:8765",
        isGatewayReady: true
    )

    private let complete = SetupStatus(
        source: readyGateway,
        microphone: .granted,
        keyboard: .ready(lastSeenAt: seenAt),
        hasDictatedOnce: true
    )

    @Test func everyStepSatisfiedIsComplete() {
        #expect(complete.isComplete)
        #expect(complete.isReadyToDictate)
        #expect(complete.remainingSteps.isEmpty)
        #expect(complete.completedStepCount == complete.stepCount)
        #expect(complete.attentionHeadline == nil)
    }

    @Test func freshInstallHasNothingDone() {
        let status = SetupStatus()

        #expect(status.completedStepCount == 0)
        #expect(status.remainingSteps == SetupStep.allCases)
        #expect(!status.isReadyToDictate)
        #expect(status.progress == 0)
    }

    @Test func remainingStepsAreListedInChecklistOrder() {
        var status = complete
        status.source.isGatewayReady = false
        status.keyboard = .notAdded

        #expect(status.remainingSteps == [.source, .keyboard])
        #expect(status.completedStepCount == status.stepCount - 2)
    }

    /// The trial run proves the chain works; it is not a prerequisite for it.
    @Test func theTrialRunIsOfferedNeverRequired() {
        var status = complete
        status.hasDictatedOnce = false

        #expect(!status.isComplete)
        #expect(status.isReadyToDictate)
        #expect(status.remainingSteps == [.firstDictation])
        #expect(status.blockingSteps.isEmpty)
        #expect(status.attentionHeadline == nil)
    }

    // MARK: - Keyboard state

    @Test func aKeyboardThatHasNeverRunIsNotSetUp() {
        #expect(KeyboardSetupState.resolve(nil) == .notAdded)
    }

    /// Without this, the checklist repeats "add the keyboard" at someone who
    /// has already added it and is only missing Full Access.
    @Test func anAddedKeyboardIsRecognisedBeforeItEverRuns() {
        let state = KeyboardSetupState.resolve(nil, isInstalled: true)

        #expect(state == .addedButNeverRun)
        #expect(!state.isReady)

        var status = complete
        status.keyboard = state
        #expect(status.attentionHeadline == "The keyboard needs Full Access")
    }

    /// The keyboard list is read from an undocumented preference, so it is only
    /// ever allowed to move the checklist forward. A stored status proves the
    /// extension ran with Full Access and must survive a list that says
    /// otherwise — the alternative is calling a working setup broken.
    @Test func theUndocumentedKeyboardListCannotOverrideProofTheKeyboardRan() {
        let status = KeyboardStatus(lastSeenAt: Self.seenAt, hasFullAccess: true)

        #expect(
            KeyboardSetupState.resolve(
                status,
                isInstalled: false,
                now: Self.seenAt
            ) == .ready(lastSeenAt: Self.seenAt)
        )
    }

    @Test func anUnreadableKeyboardListIsNotTreatedAsNotInstalled() {
        #expect(InstalledKeyboards.includesVocaPhone(nil) == nil)
        #expect(KeyboardSetupState.resolve(nil, isInstalled: nil) == .notAdded)
    }

    @Test func theKeyboardListMatchesEntriesCarryingLayoutOptions() {
        let entries = [
            "en_US@sw=QWERTY;hw=Automatic",
            "\(AppConfiguration.keyboardBundleIdentifier)@sw=QWERTY;hw=Automatic",
        ]

        #expect(InstalledKeyboards.includesVocaPhone(entries) == true)
        #expect(InstalledKeyboards.includesVocaPhone(["emoji@sw=Emoji"]) == false)
    }

    @Test func aRecentKeyboardWithFullAccessIsReady() {
        let status = KeyboardStatus(lastSeenAt: Self.seenAt, hasFullAccess: true)

        #expect(
            KeyboardSetupState.resolve(status, now: Self.seenAt.addingTimeInterval(3600))
                == .ready(lastSeenAt: Self.seenAt)
        )
    }

    /// A keyboard whose Full Access is revoked cannot report the loss — it
    /// simply stops being able to write — so a long silence has to demote the
    /// step rather than leaving a stale checkmark forever.
    @Test func aLongSilentKeyboardStopsCountingAsReady() {
        let status = KeyboardStatus(lastSeenAt: Self.seenAt, hasFullAccess: true)
        let laterOn = Self.seenAt.addingTimeInterval(
            KeyboardSetupState.silenceThreshold + 1
        )

        let state = KeyboardSetupState.resolve(status, now: laterOn)

        #expect(state == .silent(lastSeenAt: Self.seenAt))
        #expect(!state.isReady)

        var setup = complete
        setup.keyboard = state
        #expect(!setup.isReadyToDictate)
        #expect(setup.attentionHeadline == "Confirm the keyboard is still installed")
    }

    @Test func aKeyboardWithoutFullAccessIsNotReady() {
        let status = KeyboardStatus(lastSeenAt: Self.seenAt, hasFullAccess: false)

        #expect(
            KeyboardSetupState.resolve(status, now: Self.seenAt)
                == .seenWithoutFullAccess(lastSeenAt: Self.seenAt)
        )
    }

    /// The previous checklist reported "Keyboard last active …" from any stored
    /// status, which read as done beside an unchecked box.
    @Test func anIncompleteKeyboardNeverDescribesItselfAsActive() {
        for state: KeyboardSetupState in [
            .notAdded,
            .addedButNeverRun,
            .seenWithoutFullAccess(lastSeenAt: Self.seenAt),
            .silent(lastSeenAt: Self.seenAt),
        ] {
            var status = complete
            status.keyboard = state

            #expect(!status.isSatisfied(.keyboard))
            #expect(!status.detail(for: .keyboard).contains("Ready."))
        }
    }

    // MARK: - Main-screen prompt

    @Test func severalOutstandingStepsAreCountedRatherThanNamed() {
        var status = SetupStatus()
        status.microphone = .granted

        #expect(status.attentionHeadline == "vocaphone needs 2 more steps")
    }

    @Test func aConfiguredGatewayThatFailsIsDistinguishedFromNoGateway() {
        var missing = complete
        missing.source.isGatewayReady = false
        missing.source.gatewayAddress = ""

        var unreachable = complete
        unreachable.source.isGatewayReady = false

        #expect(missing.attentionHeadline == "No transcription gateway yet")
        #expect(unreachable.attentionHeadline == "Your gateway is not responding")
    }

    @Test func deniedMicrophoneAccessIsWordedAsSomethingToTurnBackOn() {
        var undetermined = complete
        undetermined.microphone = .undetermined

        var denied = complete
        denied.microphone = .denied

        #expect(undetermined.attentionHeadline == "Microphone access is needed")
        #expect(denied.attentionHeadline == "Microphone access is turned off")
        #expect(denied.detail(for: .microphone).contains("Settings"))
    }
}

/// The keyboard's identifier is derived from the running bundle, not written
/// down. A hardcoded one rots the moment anyone re-signs under their own
/// identifier for device testing — and because guided setup will not advance
/// past the keyboard step until it finds that identifier in the enabled list,
/// the rot is a deadlock rather than a cosmetic wrong answer.
struct KeyboardBundleIdentifierTests {
    @Test func theKeyboardIsTheAppsIdentifierPlusItsSuffix() {
        #expect(
            AppConfiguration.keyboardBundleIdentifier(forHostBundle: "com.vocahq.vocaphone")
                == "com.vocahq.vocaphone.keyboard"
        )
    }

    /// A locally re-signed build. This is the case that was broken: everything
    /// else was renamed and the identifier was not.
    @Test func aLocallyResignedAppFindsItsOwnKeyboard() {
        let host = "dev.kanishkpachauri.vocaphone"
        let keyboard = AppConfiguration.keyboardBundleIdentifier(forHostBundle: host)
        #expect(keyboard == "dev.kanishkpachauri.vocaphone.keyboard")
        // The enabled-keyboard list carries trailing layout options, which is
        // why the match is a substring.
        #expect(
            InstalledKeyboards.includesVocaPhone(
                ["\(keyboard)@sw=QWERTY;hw=Automatic"],
                keyboard: keyboard
            ) == true
        )
        // And the identifier it used to look for is no longer in the list,
        // which is exactly why guided setup could not find the keyboard.
        #expect(
            InstalledKeyboards.includesVocaPhone(
                ["\(keyboard)@sw=QWERTY;hw=Automatic"],
                keyboard: "com.vocahq.vocaphone.keyboard"
            ) == false
        )
    }

    /// Asked from inside the keyboard, the answer is already in hand.
    @Test func theKeyboardDoesNotAppendItsSuffixTwice() {
        #expect(
            AppConfiguration.keyboardBundleIdentifier(
                forHostBundle: "dev.kanishkpachauri.vocaphone.keyboard"
            ) == "dev.kanishkpachauri.vocaphone.keyboard"
        )
    }

    /// Asked from another extension, the sibling is derived from the app rather
    /// than from the asker.
    @Test func anotherExtensionDerivesTheSibling() {
        #expect(
            AppConfiguration.keyboardBundleIdentifier(
                forHostBundle: "dev.kanishkpachauri.vocaphone.liveactivity"
            ) == "dev.kanishkpachauri.vocaphone.keyboard"
        )
    }

    /// A bundle that will not name itself falls back to the shipping identifier
    /// rather than producing ".keyboard" on its own.
    @Test func anUnnamedBundleFallsBackToTheShippingIdentifier() {
        #expect(
            AppConfiguration.keyboardBundleIdentifier(forHostBundle: nil)
                == "com.vocahq.vocaphone.keyboard"
        )
    }
}
