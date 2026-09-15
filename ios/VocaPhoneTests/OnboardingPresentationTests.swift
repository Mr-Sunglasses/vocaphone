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
                persistedStage: nil,
                status: SetupStatus(),
                hasCompletedKeyboardPractice: false
            ) == .welcome
        )
    }

    @Test func relaunchKeepsAnUnfinishedTeachingPage() {
        #expect(
            OnboardingPresentation.initialStage(
                persistedStage: .welcome,
                status: SetupStatus(),
                hasCompletedKeyboardPractice: false
            ) == .welcome
        )
    }

    @Test func aSavedHandoffPageMovesOnToSource() {
        #expect(OnboardingStage.persisted(from: "handoff") == .source)
        #expect(OnboardingStage.persisted(from: nil) == .welcome)
        #expect(OnboardingStage.persisted(from: "model") == .model)
    }

    @Test func relaunchAfterSettingsUsesLiveProofInsteadOfReplayingWelcome() {
        var keyboardMissing = readyToDictate
        keyboardMissing.keyboard = .addedButNeverRun

        #expect(
            OnboardingPresentation.initialStage(
                persistedStage: .keyboard,
                status: keyboardMissing,
                hasCompletedKeyboardPractice: false
            ) == .keyboard
        )
        // A stored `.ready` is history too; Set up keyboard asks the keyboard
        // on arrival rather than trusting it.
        #expect(
            OnboardingPresentation.initialStage(
                persistedStage: .keyboard,
                status: readyToDictate,
                hasCompletedKeyboardPractice: false
            ) == .keyboard
        )
    }

    @Test func returningFromMicrophoneSettingsStaysOnTheMicrophonePage() {
        var micGranted = readyToDictate
        micGranted.keyboard = .notAdded
        #expect(
            OnboardingPresentation.initialStage(
                persistedStage: .microphone,
                status: micGranted,
                hasCompletedKeyboardPractice: false
            ) == .microphone
        )
    }

    @Test func keyboardEnableAndSwitchAreSeparateResumableSteps() {
        var keyboardMissing = readyToDictate
        keyboardMissing.keyboard = .addedButNeverRun

        #expect(OnboardingPresentation.nextStage(after: .keyboard) == .keyboardSwitch)
        #expect(OnboardingPresentation.previousStage(before: .practice) == .keyboardSwitch)
        #expect(
            OnboardingPresentation.initialStage(
                persistedStage: .keyboardSwitch,
                status: keyboardMissing,
                hasCompletedKeyboardPractice: false
            ) == .keyboardSwitch
        )
    }

    @Test func backFromPracticeSkipsTheAutoAdvancingSwitchPage() {
        #expect(
            OnboardingPresentation.previousNavigableStage(
                before: .practice,
                localTranscriptionEnabled: true,
                isKeyboardReady: true
            ) == .keyboard
        )
        #expect(
            OnboardingPresentation.previousNavigableStage(
                before: .practice,
                localTranscriptionEnabled: true,
                isKeyboardReady: false
            ) == .keyboardSwitch
        )
        #expect(
            OnboardingPresentation.previousNavigableStage(
                before: .microphone,
                localTranscriptionEnabled: false,
                isKeyboardReady: false
            ) == .source
        )
    }

    /// The bug: Back from Microphone skipped Choose model whenever no model was
    /// downloaded yet — which is every on-device user who is standing there.
    /// It landed them on Choose source, one page past the only page that could
    /// answer them.
    @Test func backFromMicrophoneReachesChooseModelWithoutADownload() {
        #expect(
            OnboardingPresentation.previousNavigableStage(
                before: .microphone,
                localTranscriptionEnabled: true,
                isKeyboardReady: false,
                practiceBlockedUntilModel: true
            ) == .model
        )
    }

    @Test func welcomeSkipsTheHandoffLesson() {
        #expect(OnboardingPresentation.nextStage(after: .welcome) == .source)
        #expect(OnboardingPresentation.previousStage(before: .source) == .welcome)
        #expect(OnboardingPresentation.nextStage(after: .source) == .model)
        #expect(OnboardingPresentation.nextStage(after: .model) == .microphone)
        #expect(!OnboardingStage.welcome.allowsSkip)
        #expect(!OnboardingStage.source.allowsSkip)
        #expect(OnboardingStage.model.allowsSkip)
        #expect(!OnboardingStage.microphone.allowsSkip)
        #expect(!OnboardingStage.keyboard.allowsSkip)
        #expect(OnboardingStage.practice.allowsSkip)
    }

    @Test func anUnfinishedOnDeviceModelResumesOnTheModelPage() {
        var local = SetupStatus()
        local.source.selected = .onDevice
        local.source.isOnDeviceReady = false
        #expect(
            OnboardingPresentation.resumeStage(
                status: local,
                hasCompletedKeyboardPractice: false
            ) == .model
        )
    }

    /// Opening Settings is not proof the keyboard was added. Stay on Setup
    /// keyboard until the list says so; Enable keyboard is the next room.
    @Test func returningFromSettingsWithoutAddingTheKeyboardStaysOnSetupKeyboard() {
        var missing = SetupStatus()
        missing.microphone = .granted
        missing.keyboard = .notAdded
        missing.isKeyboardInstalled = false
        #expect(
            OnboardingPresentation.initialStage(
                persistedStage: .keyboard,
                status: missing,
                hasCompletedKeyboardPractice: false
            ) == .keyboard
        )
    }

    @Test func returningFromSettingsWithTheKeyboardListedStillNeedsFullAccess() {
        var listed = SetupStatus()
        listed.microphone = .granted
        listed.keyboard = .addedButNeverRun
        listed.isKeyboardInstalled = true
        #expect(
            OnboardingPresentation.initialStage(
                persistedStage: .keyboard,
                status: listed,
                hasCompletedKeyboardPractice: false
            ) == .keyboard
        )
    }

    @Test func fullAccessOffKeepsSetupKeyboardUntilTheSwitchIsOn() {
        var off = SetupStatus()
        off.microphone = .granted
        off.keyboard = .seenWithoutFullAccess(lastSeenAt: Date())
        off.isKeyboardInstalled = true
        #expect(
            OnboardingPresentation.initialStage(
                persistedStage: .keyboard,
                status: off,
                hasCompletedKeyboardPractice: false
            ) == .keyboard
        )
        #expect(
            OnboardingPresentation.initialStage(
                persistedStage: .keyboardSwitch,
                status: off,
                hasCompletedKeyboardPractice: false
            ) == .keyboardSwitch
        )
    }

    /// The bug: a `.ready` status left over from an earlier session carried a
    /// relaunch straight past Set up keyboard, with Full Access since turned
    /// off. The stored status is history; the page stays and asks.
    @Test func aStoredReadyStatusDoesNotCarryARelaunchPastSetupKeyboard() {
        var ready = SetupStatus()
        ready.microphone = .granted
        ready.keyboard = .ready(lastSeenAt: Date())
        ready.isKeyboardInstalled = true
        #expect(
            OnboardingPresentation.initialStage(
                persistedStage: .keyboard,
                status: ready,
                hasCompletedKeyboardPractice: false
            ) == .keyboard
        )
    }

    /// The reported bug: keyboard added in Settings, Full Access left off,
    /// back to the app — and the page waited a moment and let them through.
    /// vocaphone survived that trip, and changing Full Access would have ended
    /// it, so the switch is still off. The page says so and stays.
    @Test func addingTheKeyboardWithoutFullAccessStaysAndSaysTurnItOn() {
        var added = SetupStatus()
        added.microphone = .granted
        added.keyboard = .addedButNeverRun
        added.isKeyboardInstalled = true
        #expect(
            OnboardingPresentation.setupKeyboardVerdict(
                status: added, fullAccessMayHaveChanged: false
            ) == .turnOnFullAccess
        )

        var reportedOff = added
        reportedOff.keyboard = .seenWithoutFullAccess(lastSeenAt: Date())
        #expect(
            OnboardingPresentation.setupKeyboardVerdict(
                status: reportedOff, fullAccessMayHaveChanged: false
            ) == .turnOnFullAccess
        )
    }

    /// The trip that turns Full Access on is the one vocaphone does not
    /// survive. Whatever the stored status says is from before the switch
    /// moved; only the keyboard can say where it ended up.
    @Test func aRelaunchAfterSettingsHandsTheQuestionToEnableKeyboard() {
        for keyboard: KeyboardSetupState in [
            .addedButNeverRun,
            .seenWithoutFullAccess(lastSeenAt: Date()),
            .ready(lastSeenAt: Date()),
        ] {
            var status = SetupStatus()
            status.keyboard = keyboard
            status.isKeyboardInstalled = true
            #expect(
                OnboardingPresentation.setupKeyboardVerdict(
                    status: status, fullAccessMayHaveChanged: true
                ) == .verifyOnEnable
            )
        }
    }

    @Test func aKeyboardThatIsNotInTheListAsksToBeAdded() {
        var missing = SetupStatus()
        missing.keyboard = .notAdded
        missing.isKeyboardInstalled = false
        #expect(
            OnboardingPresentation.setupKeyboardVerdict(
                status: missing, fullAccessMayHaveChanged: false
            ) == .addKeyboard
        )

        // Removed after a good run: the old `.ready` does not make it ready.
        var removed = missing
        removed.keyboard = .ready(lastSeenAt: Date())
        #expect(
            OnboardingPresentation.setupKeyboardVerdict(
                status: removed, fullAccessMayHaveChanged: false
            ) == .addKeyboard
        )
    }

    /// Full Access already on, nothing changed on the way: nothing to do here.
    @Test func anUnchangedKeyboardWithFullAccessIsReady() {
        var ready = SetupStatus()
        ready.keyboard = .ready(lastSeenAt: Date())
        ready.isKeyboardInstalled = true
        #expect(
            OnboardingPresentation.setupKeyboardVerdict(
                status: ready, fullAccessMayHaveChanged: false
            ) == .ready
        )
    }

    /// Turning vocaphone off after a good Full Access run must not skip
    /// Set up keyboard: the last write is still `.ready`, but the IME is gone.
    @Test func removingTheKeyboardAfterFullAccessKeepsSetupKeyboard() {
        var removed = SetupStatus()
        removed.microphone = .granted
        removed.keyboard = .ready(lastSeenAt: Date())
        removed.isKeyboardInstalled = false
        #expect(
            OnboardingPresentation.initialStage(
                persistedStage: .keyboard,
                status: removed,
                hasCompletedKeyboardPractice: false
            ) == .keyboard
        )
        #expect(
            OnboardingPresentation.initialStage(
                persistedStage: .keyboardSwitch,
                status: removed,
                hasCompletedKeyboardPractice: false
            ) == .keyboard
        )
    }

    /// Skip-without-practice must be able to leave. Once `setupCompleted` is
    /// written, first run is over — even for someone who never dictated.
    @Test func finishingSetupEndsFirstRunEvenWithoutThePracticeProof() {
        #expect(!OnboardingPresentation.requiresFirstRunCover(setupCompleted: true))
        #expect(OnboardingPresentation.requiresFirstRunCover(setupCompleted: false))
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

    // MARK: - The verification page

    /// Time alone must never promote the page. This is the property that keeps
    /// a slow keyboard from being mistaken for a granted one, which is the
    /// whole reason the page exists.
    @Test func waitingLongerNeverCountsAsVerified() {
        var waiting = readyToDictate
        waiting.keyboard = .addedButNeverRun

        #expect(
            OnboardingPresentation.keyboardVerification(status: waiting, waitedFor: 0)
                == .waiting
        )
        #expect(
            OnboardingPresentation.keyboardVerification(
                status: waiting,
                waitedFor: KeyboardVerification.grace
            ) == .stalled
        )
        #expect(
            OnboardingPresentation.keyboardVerification(
                status: waiting,
                waitedFor: 60 * 60
            ) == .stalled
        )
    }

    /// The keyboard's own report outranks the clock in both directions: it is
    /// named immediately, and it is not downgraded to a guess later.
    @Test func aReportedFullAccessProblemIsNamedAtOnce() {
        var reported = readyToDictate
        reported.keyboard = .seenWithoutFullAccess(lastSeenAt: Date())

        #expect(
            OnboardingPresentation.keyboardVerification(status: reported, waitedFor: 0)
                == .fullAccessOff
        )
        #expect(
            OnboardingPresentation.keyboardVerification(
                status: reported,
                waitedFor: 60 * 60
            ) == .fullAccessOff
        )
    }

    /// Turning Full Access off then on leaves the old Darwin ping in place.
    /// Enable keyboard must not treat that as the current switch.
    @Test func aStaleFullAccessOffReportDoesNotSealTheSwitchPage() {
        let opened = Date()
        var stale = readyToDictate
        stale.keyboard = .seenWithoutFullAccess(
            lastSeenAt: opened.addingTimeInterval(-2)
        )
        stale.isKeyboardInstalled = true
        #expect(
            OnboardingPresentation.keyboardVerification(
                status: stale,
                waitedFor: 0,
                pageOpenedAt: opened
            ) == .waiting
        )
    }

    @Test func aFreshFullAccessOffReportStillSealsTheSwitchPage() {
        let opened = Date().addingTimeInterval(-2)
        var fresh = readyToDictate
        fresh.keyboard = .seenWithoutFullAccess(lastSeenAt: Date())
        fresh.isKeyboardInstalled = true
        #expect(
            OnboardingPresentation.keyboardVerification(
                status: fresh,
                waitedFor: 0,
                pageOpenedAt: opened
            ) == .fullAccessOff
        )
    }

    @Test func aVerifiedKeyboardIsVerifiedImmediately() {
        let opened = Date().addingTimeInterval(-2)
        #expect(
            OnboardingPresentation.keyboardVerification(
                status: readyToDictate,
                waitedFor: 0,
                pageOpenedAt: opened
            ) == .verified
        )
    }

    @Test func aReadyKeyboardDoesNotCountUntilThisPageHasAClock() {
        #expect(
            OnboardingPresentation.keyboardVerification(
                status: readyToDictate,
                waitedFor: 0
            ) == .waiting
        )
    }

    @Test func aKeyboardWriteFromBeforeThePageOpenedDoesNotCount() {
        let opened = Date()
        var stale = readyToDictate
        // Status floors lastSeenAt to the second, and the gate does too, so a
        // write 0.2s earlier is the same second and counts. Two seconds back
        // is last week, as far as this page is concerned.
        stale.keyboard = .ready(lastSeenAt: opened.addingTimeInterval(-2))
        #expect(
            !OnboardingPresentation.keyboardAppeared(
                lastSeenAt: stale.keyboard.lastSeenAt,
                after: opened
            )
        )
        #expect(
            OnboardingPresentation.keyboardVerification(
                status: stale,
                waitedFor: 0,
                pageOpenedAt: opened
            ) == .waiting
        )
    }

    /// The bug this replaced: the page used to discard the first write it saw
    /// after raising the probe, on the theory that vocaphone coming up because
    /// it was *already* the keyboard did not count. It does count — that is the
    /// page's goal, reached early — and discarding it left Enable keyboard
    /// waiting forever with vocaphone visible on screen, telling the user that
    /// Full Access was probably off when it was not.
    @Test func aKeyboardThatWasAlreadyVocaphoneIsVerifiedRatherThanIgnored() {
        let opened = Date().addingTimeInterval(-3)
        var ready = readyToDictate
        // The reply to the page's ping, from an extension that never left.
        ready.keyboard = .ready(lastSeenAt: Date().addingTimeInterval(-0.1))
        #expect(
            OnboardingPresentation.keyboardVerification(
                status: ready,
                waitedFor: 0,
                pageOpenedAt: opened
            ) == .verified
        )
        // ...and it still refuses to count a write from before the page opened.
        var stale = readyToDictate
        stale.keyboard = .ready(lastSeenAt: opened.addingTimeInterval(-60))
        #expect(
            OnboardingPresentation.keyboardVerification(
                status: stale,
                waitedFor: 0,
                pageOpenedAt: opened
            ) == .waiting
        )
    }

    /// Continue used to appear because the keyboard had run last week. This
    /// page only counts vocaphone opening now.
    @Test func aStaleReadyKeyboardDoesNotCountAsSwitchedOnThisPage() {
        let opened = Date()
        var stale = readyToDictate
        stale.keyboard = .ready(lastSeenAt: opened.addingTimeInterval(-60))

        #expect(
            OnboardingPresentation.keyboardVerification(
                status: stale,
                waitedFor: 0,
                pageOpenedAt: opened
            ) == .waiting
        )
        #expect(
            OnboardingPresentation.keyboardVerification(
                status: stale,
                waitedFor: KeyboardVerification.grace,
                pageOpenedAt: opened
            ) == .stalled
        )
        #expect(
            !OnboardingPresentation.keyboardAppeared(
                lastSeenAt: stale.keyboard.lastSeenAt,
                after: opened
            )
        )
    }

    @Test func aKeyboardThatAppearsAfterOpeningTheSwitchPageIsVerified() {
        let opened = Date().addingTimeInterval(-2)
        var fresh = readyToDictate
        fresh.keyboard = .ready(lastSeenAt: Date())

        #expect(
            OnboardingPresentation.keyboardVerification(
                status: fresh,
                waitedFor: 0,
                pageOpenedAt: opened
            ) == .verified
        )
        #expect(
            OnboardingPresentation.keyboardAppeared(
                lastSeenAt: fresh.keyboard.lastSeenAt,
                after: opened
            )
        )
    }

    /// ``KeyboardStatus`` floors `lastSeenAt` to the second, so a switch that
    /// lands in the same second as a fractional gate used to lose (`11.0 <
    /// 11.5`) and leave Enable keyboard up with nowhere to type. The gate is
    /// floored to match.
    @Test func aWriteInTheSameSecondAsTheGateCounts() {
        let fractionalGate = Date(timeIntervalSince1970: 1_700_000_011.5)
        let sameSecond = Date(timeIntervalSince1970: 1_700_000_011)
        let secondBefore = Date(timeIntervalSince1970: 1_700_000_010)

        #expect(OnboardingPresentation.keyboardAppeared(
            lastSeenAt: sameSecond, after: fractionalGate
        ))
        #expect(!OnboardingPresentation.keyboardAppeared(
            lastSeenAt: secondBefore, after: fractionalGate
        ))
        #expect(!OnboardingPresentation.keyboardAppeared(
            lastSeenAt: nil, after: fractionalGate
        ))
    }

    @Test func relaunchOnEnableKeyboardStaysUntilVocaphoneOpens() {
        #expect(
            OnboardingPresentation.initialStage(
                persistedStage: .keyboardSwitch,
                status: readyToDictate,
                hasCompletedKeyboardPractice: false
            ) == .keyboardSwitch
        )
    }

    @Test func practiceIsBlockedWhenOnDeviceHasNoModel() {
        var missing = SetupStatus()
        missing.source.selected = .onDevice
        missing.source.isOnDeviceReady = false
        #expect(OnboardingPresentation.practiceIsBlockedUntilModelDownload(status: missing))
    }

    @Test func practiceIsNotBlockedWhenAModelIsReady() {
        var ready = SetupStatus()
        ready.source.selected = .onDevice
        ready.source.isOnDeviceReady = true
        #expect(!OnboardingPresentation.practiceIsBlockedUntilModelDownload(status: ready))
    }

    @Test func practiceIsNotBlockedOnAGateway() {
        var gateway = SetupStatus()
        gateway.source.selected = .gateway
        gateway.source.isOnDeviceReady = false
        gateway.source.isGatewayReady = true
        #expect(!OnboardingPresentation.practiceIsBlockedUntilModelDownload(status: gateway))
    }

    @Test func returningFromKeyboardSettingsWithoutAModelDoesNotRewindToChooseModel() {
        var missingModel = SetupStatus()
        missingModel.source.selected = .onDevice
        missingModel.source.isOnDeviceReady = false
        missingModel.microphone = .granted
        missingModel.keyboard = .addedButNeverRun
        missingModel.isKeyboardInstalled = true

        #expect(
            OnboardingPresentation.initialStage(
                persistedStage: .keyboard,
                status: missingModel,
                hasCompletedKeyboardPractice: false
            ) == .keyboard
        )
        #expect(
            OnboardingPresentation.initialStage(
                persistedStage: .keyboardSwitch,
                status: missingModel,
                hasCompletedKeyboardPractice: false
            ) == .keyboardSwitch
        )
        #expect(OnboardingPresentation.nextStage(after: .keyboard) == .keyboardSwitch)
        #expect(
            OnboardingPresentation.stageAfterKeyboardSwitch(status: missingModel)
                == .complete
        )
    }

    @Test func setupKeyboardWithoutAModelStaysUntilTheKeyboardIsAdded() {
        var missingModel = SetupStatus()
        missingModel.source.selected = .onDevice
        missingModel.source.isOnDeviceReady = false
        missingModel.microphone = .granted
        missingModel.keyboard = .notAdded
        missingModel.isKeyboardInstalled = false

        #expect(
            OnboardingPresentation.initialStage(
                persistedStage: .keyboard,
                status: missingModel,
                hasCompletedKeyboardPractice: false
            ) == .keyboard
        )
        #expect(
            OnboardingPresentation.previousNavigableStage(
                before: .practice,
                localTranscriptionEnabled: true,
                isKeyboardReady: false,
                practiceBlockedUntilModel: true
            ) == .keyboard
        )
    }

    @Test func downloadingAModelLaterSkipsRoomsAlreadyProven() {
        var ready = readyToDictate
        ready.source.selected = .onDevice
        ready.source.isOnDeviceReady = true
        #expect(
            OnboardingPresentation.stageAfterOnboardingModelDownload(
                status: ready,
                hasCompletedKeyboardPractice: false
            ) == .practice
        )

        var micMissing = ready
        micMissing.microphone = .undetermined
        #expect(
            OnboardingPresentation.stageAfterOnboardingModelDownload(
                status: micMissing,
                hasCompletedKeyboardPractice: false
            ) == .microphone
        )
    }

    @Test func downloadingAModelWhenTheKeyboardIsListedGoesToEnableNotSetup() {
        var listed = SetupStatus()
        listed.source.selected = .onDevice
        listed.source.isOnDeviceReady = true
        listed.microphone = .granted
        listed.keyboard = .addedButNeverRun
        listed.isKeyboardInstalled = true
        #expect(
            OnboardingPresentation.stageAfterOnboardingModelDownload(
                status: listed,
                hasCompletedKeyboardPractice: false
            ) == .keyboardSwitch
        )

        var missing = listed
        missing.keyboard = .notAdded
        missing.isKeyboardInstalled = false
        #expect(
            OnboardingPresentation.stageAfterOnboardingModelDownload(
                status: missing,
                hasCompletedKeyboardPractice: false
            ) == .keyboard
        )
    }

    @Test func skippingTheModelSkipsTryDictatingAndCanFinish() {
        var skipped = SetupStatus()
        skipped.source.selected = .onDevice
        skipped.source.isOnDeviceReady = false
        skipped.microphone = .granted
        skipped.keyboard = .ready(lastSeenAt: Date())
        skipped.isKeyboardInstalled = true

        #expect(OnboardingPresentation.practiceIsBlockedUntilModelDownload(status: skipped))
        #expect(
            OnboardingPresentation.stageAfterKeyboardSwitch(status: skipped) == .complete
        )
        #expect(
            OnboardingPresentation.canFinishSetup(status: skipped)
        )
        #expect(
            OnboardingPresentation.previousNavigableStage(
                before: .complete,
                localTranscriptionEnabled: true,
                isKeyboardReady: true,
                practiceBlockedUntilModel: true
            ) == .keyboard
        )
        #expect(
            OnboardingPresentation.previousNavigableStage(
                before: .microphone,
                localTranscriptionEnabled: true,
                isKeyboardReady: false,
                practiceBlockedUntilModel: true
            ) == .model
        )
        #expect(
            OnboardingPresentation.initialStage(
                persistedStage: .complete,
                status: skipped,
                hasCompletedKeyboardPractice: false
            ) == .complete
        )
        #expect(
            OnboardingPresentation.initialStage(
                persistedStage: .practice,
                status: skipped,
                hasCompletedKeyboardPractice: false
            ) == .complete
        )
        #expect(
            OnboardingPresentation.resumeStage(
                status: skipped,
                hasCompletedKeyboardPractice: false,
                allowSkippedModel: true
            ) == .complete
        )
        #expect(
            OnboardingPresentation.resumeStage(
                status: skipped,
                hasCompletedKeyboardPractice: false
            ) == .model
        )
    }

    @Test func reviewSetupAfterSkippingTheModelRepairsTheMicrophone() {
        var skipped = SetupStatus()
        skipped.source.selected = .onDevice
        skipped.source.isOnDeviceReady = false
        skipped.microphone = .denied
        skipped.keyboard = .ready(lastSeenAt: Date())
        skipped.isKeyboardInstalled = true

        #expect(
            OnboardingPresentation.resumeStage(
                status: skipped,
                hasCompletedKeyboardPractice: false,
                allowSkippedModel: true
            ) == .microphone
        )
        #expect(
            OnboardingPresentation.initialStage(
                persistedStage: .complete,
                status: skipped,
                hasCompletedKeyboardPractice: false
            ) == .microphone
        )
    }

    @Test func skipIsOnlyOnTheTwoPagesThatCanBeAnsweredLater() {
        for stage in OnboardingStage.allCases {
            if stage == .model || stage == .practice {
                #expect(stage.allowsSkip)
            } else {
                #expect(!stage.allowsSkip)
            }
        }
        // Practice is not a requirement: Skip on Try dictating is an answer.
        #expect(OnboardingPresentation.canFinishSetup(status: readyToDictate))
    }

    @Test func firstRunEndsOnTheLeaveTokenNotAReadyPage() {
        #expect(OnboardingPresentation.nextStage(after: .practice) == .complete)
        #expect(OnboardingPresentation.nextStage(after: .complete) == nil)
        var skipped = SetupStatus()
        skipped.source.selected = .onDevice
        skipped.source.isOnDeviceReady = false
        skipped.microphone = .granted
        skipped.keyboard = .ready(lastSeenAt: Date())
        skipped.isKeyboardInstalled = true
        #expect(OnboardingPresentation.canFinishSetup(status: skipped))
        #expect(
            OnboardingPresentation.stageAfterKeyboardSwitch(status: skipped) == .complete
        )
    }

    @Test func theReadyFlashIsOnlyWhenAModelCanActuallyDictate() {
        var skipped = SetupStatus()
        skipped.source.selected = .onDevice
        skipped.source.isOnDeviceReady = false
        skipped.microphone = .granted
        skipped.keyboard = .ready(lastSeenAt: Date())
        skipped.isKeyboardInstalled = true
        #expect(!OnboardingPresentation.showsSetupReadyFlash(status: skipped))

        var ready = skipped
        ready.source.isOnDeviceReady = true
        #expect(OnboardingPresentation.showsSetupReadyFlash(status: ready))

        var micMissing = ready
        micMissing.microphone = .denied
        #expect(!OnboardingPresentation.showsSetupReadyFlash(status: micMissing))
    }

    @Test func skipOnChooseModelGoesAwayOnceADownloadStarts() {
        #expect(OnboardingPresentation.showsSkip(stage: .model, modelIsArriving: false))
        #expect(!OnboardingPresentation.showsSkip(stage: .model, modelIsArriving: true))
        #expect(OnboardingPresentation.showsSkip(stage: .practice, modelIsArriving: true))
        #expect(!OnboardingPresentation.showsSkip(stage: .welcome, modelIsArriving: false))
    }

    @Test func usageReportingIsAskedOnceAndOnlyWhenSetupCanFinish() {
        var ready = SetupStatus()
        ready.source.selected = .onDevice
        ready.source.isOnDeviceReady = true
        ready.microphone = .granted
        ready.keyboard = .ready(lastSeenAt: Date())
        ready.isKeyboardInstalled = true
        #expect(OnboardingPresentation.asksAboutUsageReporting(status: ready, hasBeenAsked: false))
        #expect(!OnboardingPresentation.asksAboutUsageReporting(status: ready, hasBeenAsked: true))

        var micMissing = ready
        micMissing.microphone = .denied
        #expect(!OnboardingPresentation.asksAboutUsageReporting(status: micMissing, hasBeenAsked: false))
    }

    @Test func aRelaunchOnUsageReportingStaysOnlyWhileTheQuestionIsOpen() {
        var ready = SetupStatus()
        ready.source.selected = .onDevice
        ready.source.isOnDeviceReady = true
        ready.microphone = .granted
        ready.keyboard = .ready(lastSeenAt: Date())
        ready.isKeyboardInstalled = true
        #expect(
            OnboardingPresentation.initialStage(
                persistedStage: .usageReporting,
                status: ready,
                hasCompletedKeyboardPractice: true,
                hasAnsweredUsageReporting: false
            ) == .usageReporting
        )
        #expect(
            OnboardingPresentation.initialStage(
                persistedStage: .usageReporting,
                status: ready,
                hasCompletedKeyboardPractice: true,
                hasAnsweredUsageReporting: true
            ) == .complete
        )
        var micMissing = ready
        micMissing.microphone = .denied
        #expect(
            OnboardingPresentation.initialStage(
                persistedStage: .usageReporting,
                status: micMissing,
                hasCompletedKeyboardPractice: true,
                hasAnsweredUsageReporting: false
            ) == .microphone
        )
    }

    @Test func theChromeBarFillsWithoutJumpingSidewaysForAState() {
        #expect(OnboardingStage.welcome.chromeProgress < OnboardingStage.source.chromeProgress)
        #expect(OnboardingStage.keyboard.chromeProgress == OnboardingStage.keyboardSwitch.chromeProgress)
        #expect(OnboardingStage.practice.chromeProgress == 1)
    }
}
