import SwiftUI
import UIKit

/// The full-screen confirmations first run is allowed to show.
///
/// Each one fires at the moment the app can actually see the thing happen.
/// Microphone: the permission grant. Keyboard: vocaphone is the IME after
/// the globe — not the keyboard list, which says nothing about Full Access.
/// Setup: mic, keyboard, and a model on disk. A skipped download is not
/// that, so it does not get a checkmark.
private enum OnboardingReadyFlash: Equatable {
    case none
    case microphone
    case keyboard
    case setup

    var title: String {
        switch self {
        case .none: ""
        case .microphone: "Microphone ready"
        case .keyboard: "Keyboard ready"
        case .setup: "Ready to dictate"
        }
    }
}

/// First-run setup. Each page owns one action and reconciles against the real
/// state from `SetupStatus`; no Continue button can manufacture a permission,
/// model, keyboard, or transcript that has not actually worked.
struct SetupView: View {
    @Environment(RecordingCoordinator.self) private var coordinator
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @AppStorage(
        KeyboardPreferences.setupCompletedKey,
        store: KeyboardPreferences.defaults
    ) private var setupCompleted = false
    @AppStorage(
        KeyboardPreferences.onboardingStageKey,
        store: KeyboardPreferences.defaults
    ) private var persistedStageRaw = OnboardingStage.welcome.rawValue
    @AppStorage(
        KeyboardPreferences.onboardingMotionIntroSeenKey,
        store: KeyboardPreferences.defaults
    ) private var motionIntroSeen = false
    @AppStorage(
        KeyboardPreferences.keyboardPracticeKey,
        store: KeyboardPreferences.defaults
    ) private var hasCompletedKeyboardPractice = false
    @AppStorage(
        LocalTranscriptionPreferences.enabledKey,
        store: KeyboardPreferences.defaults
    ) private var localTranscriptionEnabled = false

    @State private var stage: OnboardingStage
    @State private var hasInitialized = false
    @State private var darwinObservations: [VocaPhoneDarwinObservation] = []
    @State private var keyboardProbeFocused = false
    /// False while Settings (or any background) can unload the IME. Creating
    /// or focusing a field against a keyboard that just vanished is the crash
    /// after turning vocaphone off in Keyboards.
    @State private var keyboardProbeAllowed = true
    /// Ready-to-dictate is an in-app overlay; the keyboard sits above it.
    /// While this is true, nothing may raise the keys — not the practice
    /// field's on-appear, not the probe-focus task, not a foreground return.
    @State private var holdingKeyboardOff = false
    /// Set up keyboard is asking the extension, this visit, whether Full
    /// Access is on. Not a permanent field — it covers the video if left up.
    /// Counts trips to iOS Settings.
    ///
    /// A return's handler ends by clearing the notes that said a trip was under
    /// way — after waiting on the network for gateway health. Someone quick
    /// enough to go back to Settings in that window had those notes written for
    /// the *new* trip and then wiped by the old one's tail; the relaunch that
    /// follows turning Full Access on came up not knowing it had been to
    /// Settings at all, and offered to turn on a switch that was already on.
    @State private var settingsTrip = 0
    /// Enable Keyboard only counts a vocaphone appearance after this moment.
    /// The page pings the extension while it waits, so a write at or after
    /// this is vocaphone on screen now rather than a leftover from last week.
    @State private var keyboardSwitchOpenedAt: Date?
    @State private var practiceText = ""
    /// UIKit first-responder flag. `@FocusState` without `.focused()` was
    /// reset by SwiftUI every frame, so Try dictating never kept a caret.
    @State private var practiceFocused = false
    /// How long the verification page has been waiting without any report from
    /// the keyboard. Only ever chooses the wording of "nothing yet" — see
    /// `OnboardingPresentation.keyboardVerification`.
    @State private var keyboardWaitSeconds: TimeInterval = 0
    @AppStorage(
        KeyboardPreferences.keyboardSettingsRoundTripKey,
        store: KeyboardPreferences.defaults
    ) private var keyboardSettingsRoundTripStarted = false
    @State private var isShowingGatewaySetup = false
    /// Answered here or with the switch in Settings › Privacy.
    @State private var hasAskedAboutReporting = UserDefaultsTelemetryPreferences().hasBeenAsked
    @State private var isShowingReportingPayload = false
    /// Between the tap and the choice being stored. Holds the two buttons.
    @State private var isAnsweringReporting = false
    @State private var isShowingReportingDetails = false
    /// Height of the docked button, so scrolling pages can end above it
    /// instead of sliding their last card underneath.
    @State private var dockedActionHeight: CGFloat = 0
    /// Back from Settings on Set up keyboard with vocaphone still not in the
    /// list. iOS Settings can show a stale page without Keyboards on it.
    @State private var keyboardMissingAfterSettings = false
    /// Tallest welcome card's content, which every welcome card takes.
    @State private var welcomeCardHeights: [Int: CGFloat] = [:]
    /// Full-screen "Microphone ready" or "Ready to dictate".
    @State private var readyFlash: OnboardingReadyFlash = .none
    /// Title frozen while `readyFlash` fades out so the stack does not collapse.
    @State private var readyCoverCopy: OnboardingReadyFlash = .none
    /// Drives the confirmation's entrance. Flipped one frame after the cover
    /// is up so the spring has somewhere to travel from.
    @State private var readyCoverAppeared = false
    /// Drives the cover's exit. The entrance is keyed on `readyCoverAppeared`,
    /// and reusing it here would play the arrival backwards — including the
    /// label's delay, which reads as the words leaving after the symbol.
    @State private var readyCoverLeaving = false

    /// Roughly how long iOS takes to slide the keyboard away.
    static let keyboardDismissal = 320
    /// Open Settings was tapped on this page. Returning must only move this
    /// page, and only if its requirement is now met — never a chain of hops.
    @State private var awaitingSettingsReturn = false
    @State private var movesBackward = false
    /// When the app last came back to the foreground from iOS Settings.
    ///
    /// For a moment afterwards iOS is still reloading the keyboard list, and
    /// Enable keyboard is the one page that touches exactly what is being
    /// reloaded: it builds a `UITextField` to raise the keyboard, and it reads
    /// the keyboard list several times a second. Either one, too early, blocks
    /// the main thread long enough for the watchdog to kill the app.
    ///
    /// The "Keyboard ready" cover used to hold all of this off as a side
    /// effect — the page simply did not change until its animation had run.
    /// Deleting the cover deleted the wait with it. The checkmark was the
    /// half that lied; this is the half that was load bearing, so it is
    /// spelled out here instead of riding on an animation.
    @State private var returnedFromSettingsAt: Date?

    /// Long enough to outlast the keyboard-list reload. Restores what the
    /// cover's 950ms plus the probe's own delay used to add up to.
    private static let settingsSettle: TimeInterval = 2.5
    /// Enable keyboard's push. The probe waits this out so first responder
    /// does not land mid-transition. Same duration as the snappy on
    /// `moveToStage`. The globe sits in the top band, so waiting past the
    /// push only delayed the keyboard.
    private static let keyboardSwitchPageSettle: TimeInterval = 0.32

    init() {
        // Seed the persisted page before `.task` runs so a relaunch cannot
        // flash Welcome for a frame. Live keyboard/mic proof is applied in
        // `initializeIfNeeded` once `SetupStatus` exists.
        _stage = State(
            initialValue: OnboardingStage.persisted(
                from: KeyboardPreferences.defaults?.string(
                    forKey: KeyboardPreferences.onboardingStageKey
                )
            )
        )
    }

    private var status: SetupStatus { coordinator.setupStatus }

    /// The three onboarding cards, the same list `LocalModelPicker` draws.
    private var onboardingModelPicks: [LocalModelDescriptor] {
        let languages = LocalModelPicker.recommendationLanguages(
            preferred: KeyboardPreferences.transcriptionLanguage.rawValue
        )
        return LocalModelCatalog.onboardingRecommendations(
            deviceMemoryGB: LocalModelCatalog.deviceMemoryGB,
            languages: languages
        )
        .map(\.model)
    }

    /// Continue is available once a model is on disk *or* on its way.
    ///
    /// Waiting here is dead time: adding the keyboard is a minute of real work
    /// and the transfer keeps running through all of it. The only thing
    /// Continue must not do is leave with nothing coming at all — that is what
    /// Skip is for, and Skip says so by dropping Try dictating.
    private var isOnboardingModelActionDisabled: Bool {
        onboardingReadyModels.isEmpty && !modelIsArriving
    }

    /// Every verified model on disk, not only the three cards: More models
    /// can download anything this iPhone runs.
    private var onboardingReadyModels: [LocalModelDescriptor] {
        let models = coordinator.localModels
        return LocalModelCatalog.usableOnDevice.filter {
            models.isDownloaded($0.id) && !models.failedIntegrityModelIDs.contains($0.id)
        }
    }

    /// No model on disk yet, but one is coming. Try dictating waits for it
    /// instead of being skipped.
    private var modelIsArriving: Bool {
        guard OnboardingPresentation.practiceIsBlockedUntilModelDownload(status: status) else {
            return false
        }
        let models = coordinator.localModels
        // Queued counts, in flight counts. Anything else is not a transfer,
        // and a progress bar with no name behind it is worse than no bar.
        guard models.downloadingModelID != nil || !models.queuedModelIDs.isEmpty else {
            return false
        }
        return true
    }

    /// The chosen model, while it is being loaded into memory.
    private var practiceModelLoading: LocalModelDescriptor? {
        guard let model = selectedOnDeviceModel,
              coordinator.localModels.loadingModelID == model.id
        else { return nil }
        return model
    }

    /// The transfer Try dictating is waiting on, for the progress it shows.
    private var arrivingModel: LocalModelDescriptor? {
        coordinator.localModels.downloadingModelID.flatMap(LocalModelCatalog.descriptor(for:))
    }

    var body: some View {
        setupLifecycle
    }

    private var setupChrome: some View {
        Group {
            if !setupCompleted && !motionIntroSeen
                && persistedStageRaw == OnboardingStage.welcome.rawValue {
                OnboardingMotionIntroView {
                    motionIntroSeen = true
                }
            } else {
                onboardingBody
            }
        }
            .background(Color.vocaCanvas.ignoresSafeArea())
            .sheet(isPresented: $isShowingGatewaySetup, onDismiss: {
                coordinator.refreshSetupStatus()
            }) {
                NavigationStack {
                    GatewaySetupView()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { isShowingGatewaySetup = false }
                            }
                        }
                }
            }
    }

    private var setupLifecycle: some View {
        setupObservers
            .task {
                coordinator.refreshSetupStatus()
                initializeIfNeeded()
                observeKeyboardPracticeProof()
                guard readyFlash == .none else { return }
                await coordinator.refreshGatewayHealth()
            }
            .task(id: keyboardWatchID) {
                guard readyFlash == .none else { return }
                await watchForTheKeyboard()
            }
            // The model is loaded while the user works through the pages
            // before Try dictating, and again whenever they come back to one:
            // a trip to Settings is exactly when iOS reclaims it.
            .task(id: onboardingWarmKey) {
                await warmSelectedModel()
            }
            // Try dictating is the one page that waits on something no view
            // touches: a download finishing somewhere else entirely. The
            // picker used to re-read the status when its own download landed,
            // but a download resumed after a relaunch has no picker behind it,
            // and `SetupStatus` is a stored snapshot — so the page sat on a
            // model it already had.
            .task(id: "practice-model-\(stage.rawValue)-\(practiceNeedsModel)") {
                guard stage == .practice, practiceNeedsModel else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(600))
                    guard !Task.isCancelled else { return }
                    coordinator.refreshSetupStatus()
                    if !practiceNeedsModel { return }
                }
            }
            .task(id: "practice-proof-\(stage.rawValue)") {
                guard stage == .practice else { return }
                while !Task.isCancelled {
                    rereadKeyboardPracticeProof()
                    if hasCompletedKeyboardPractice { return }
                    try? await Task.sleep(for: .milliseconds(400))
                }
            }
            .task(id: keyboardProbeFocusToken) {
                if holdingKeyboardOff || readyFlash != .none {
                    practiceFocused = false
                    keyboardProbeFocused = false
                    return
                }
                if stage == .practice {
                    // Cover still up: do not raise the field under Keyboard
                    // ready. The token includes the flash, so this re-runs
                    // when it leaves.
                    if practiceNeedsModel {
                        practiceFocused = false
                        keyboardProbeFocused = false
                    } else {
                        practiceFocused = true
                    }
                } else {
                    await focusKeyboardProbeIfNeeded()
                }
            }
    }

    private var setupObservers: some View {
        setupChrome
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIApplication.willResignActiveNotification
                )
            ) { _ in
                // Resign before Keyboards can unload the extension under a
                // live first responder. scenePhase lags this notification.
                resignOnScreenKeyboard()
                coordinator.noteKeyboardListMayReload()
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UITextInputMode.currentInputModeDidChangeNotification
                )
            ) { _ in
                guard readyFlash == .none else { return }
                guard scenePhase == .active else { return }
                guard !coordinator.isKeyboardListReadUnsafe else { return }
                // The keyboard changed under us. If the new one is vocaphone,
                // this is the moment Enable keyboard is waiting for.
                if stage == .keyboardSwitch { pingTheKeyboard() }
                coordinator.refreshSetupStatus()
            }
            .onReceive(
                NotificationCenter.default.publisher(for: .vocaKeyboardPracticeCompleted)
            ) { _ in
                rereadKeyboardPracticeProof()
            }
            .onChange(of: scenePhase) { previousPhase, currentPhase in
                if currentPhase != .active {
                    resignOnScreenKeyboard()
                    return
                }
                guard previousPhase != .active else { return }
                Task { await refreshAfterForegroundReturn() }
            }
            .onChange(of: localTranscriptionEnabled) { _, _ in
                coordinator.refreshSetupStatus()
            }
            // A download landing is the one event that can make the whole
            // page wrong, and the snapshot it reads is only rewritten on
            // demand. Waiting for the next poll left a window where the model
            // was on disk and the page still drew a progress bar for it —
            // nameless, because nothing was in flight any more.
            .onChange(of: coordinator.localModels.downloadedModelIDs) { _, _ in
                coordinator.refreshSetupStatus()
            }
            .onChange(of: hasCompletedKeyboardPractice) { _, complete in
                guard complete, stage == .practice else { return }
                UIAccessibility.post(
                    notification: .announcement,
                    argument: "Your words were inserted through the vocaphone keyboard."
                )
            }
            .onChange(of: keyboardProofToken) { _, _ in
                if status.isKeyboardInstalled == false {
                    resignOnScreenKeyboard()
                    dropBackToSetupKeyboardIfRemoved()
                }
            }
            .onChange(of: keyboardVerification) { _, verification in
#if DEBUG
                if stage == .keyboardSwitch {
                    ModelDownloadTrace.record(
                        "kb.switch",
                        "\(verification) stored=\(status.keyboard)"
                            + " installed=\(String(describing: status.isKeyboardInstalled))"
                    )
                }
#endif
                guard stage == .keyboardSwitch, readyFlash == .none else { return }
                // Full Access off deliberately keeps the keyboard up. Dropping
                // it to make the repair copy readable is what sealed this page:
                // turning the switch on changes nothing the app can observe
                // until the extension runs again, and nothing else here raises
                // it. The page scrolls instead.
                guard verification == .verified else { return }
                Task { await advanceToPracticeAfterVocaphoneAppeared() }
            }
            .onChange(of: stage) { _, newStage in
                persistVisibleStage(newStage)
                skipPracticeIfNothingToDictate()
            }
            // A model that arrives late is good news, not a reason to reopen
            // a page the user has already finished: Get then Skip used to
            // pull them backwards when the download landed.
            .onChange(of: practiceNeedsModel) { _, blocked in
                if blocked {
                    skipPracticeIfNothingToDictate()
                    return
                }
                guard stage == .practice else { return }
                Task { await raisePracticeFieldAfterModelArrived() }
            }
    }

    // MARK: - First-run flow

    /// One page at a time. A paging strip of every stage reset its offset
    /// after Settings and flashed a previous page, then jumped forward.
    private var onboardingBody: some View {
        VStack(spacing: 0) {
            onboardingChrome
            onboardingPage(for: stage)
                .id(stage)
                .transition(pageTransition)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(readyFlash == .none && !holdingKeyboardOff)
        }
        .animation(
            reduceMotion
                || readyFlash != .none
                || stage == .practice
                || stage == .keyboardSwitch
                ? nil
                : .snappy(duration: 0.32),
            value: stage
        )
        .background(Color.vocaCanvas.ignoresSafeArea())
        .overlay(alignment: .topLeading) {
            // Lives outside `.id(stage)`. Destroying it with the Enable
            // Keyboard page resigned first responder and dropped the keyboard
            // before Try dictating could take over. Must not exist during
            // Keyboard ready: creating a UITextField right after Settings
            // hangs the main thread and iOS kills the process.
            if showsKeyboardProbe {
                KeyboardSwitchProbeField(
                    isFocused: Binding(
                        get: { keyboardProbeFocused && stage == .keyboardSwitch },
                        set: { keyboardProbeFocused = $0 }
                    ),
                    resignsWhenUnfocused: stage != .practice || !keyboardProbeFocused
                )
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .overlay(alignment: .leading) {
            edgeBackStrip
        }
        .overlay(alignment: .bottom) {
            // Overlay, not inset: an inset painted a cream slab over the
            // video. The button sits on the content; the page keeps its height.
            onboardingCTA(for: stage)
        }
        .ignoresSafeArea(.keyboard, edges: keepsKeyboardSafeArea ? [] : .bottom)
        .overlay {
            readyCover
                .opacity(readyFlash == .none ? 0 : 1)
                .allowsHitTesting(readyFlash != .none)
        }
        .onChange(of: status.microphone) { previous, now in
            guard stage == .microphone, now == .granted, previous != .granted else { return }
            guard !awaitingSettingsReturn else { return }
            presentReadyFlash(.microphone, then: .keyboard)
        }
    }

    /// Which pages let the keyboard resize them.
    ///
    /// Only two need to: Try dictating puts its field above the keyboard, and
    /// the Full Access repair page has to keep its button reachable. Everywhere
    /// else the keyboard is scenery — Enable keyboard raises it deliberately,
    /// to show the globe — and letting it push the whole page up on arrival,
    /// then drop it again on the way to Ready, was the lurch at both ends.
    private var keepsKeyboardSafeArea: Bool {
        switch stage {
        // Both halves of Try dictating, not just the live one. Switching this
        // on at the exact moment the keyboard rises made the page start
        // respecting an inset and the keyboard slide in on the same frame —
        // two large motions on top of each other. While the model is still
        // coming there is no keyboard, so it costs nothing to be ready.
        case .practice: true
        case .keyboardSwitch: keyboardVerification == .fullAccessOff
        default: false
        }
    }

    private var pageTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .push(from: movesBackward ? .leading : .trailing)
    }

    /// Thin leading strip so Back has an edge-swipe without eating the
    /// page's own scrolling.
    private var edgeBackStrip: some View {
        Color.clear
            .frame(width: 20)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 16)
                    .onEnded { value in
                        guard value.translation.width > 60,
                              abs(value.translation.height) < 80
                        else { return }
                        goBack()
                    }
            )
            .allowsHitTesting(
                showsChromeControls
                    && !holdingKeyboardOff
                    && readyFlash == .none
                    && OnboardingPresentation.previousStage(before: stage) != nil
            )
    }

    @ViewBuilder
    private func onboardingPage(for page: OnboardingStage) -> some View {
        // Waiting for the model is still Try dictating: same page, same
        // proportions, so nothing relayouts when the field goes live.
        let expands = page == .practice && !dynamicTypeSize.isAccessibilitySize
        let welcomeLike = page == .welcome
        let fitsWithoutScroll = welcomeLike
        VStack(alignment: .leading, spacing: VocaMetrics.grouping) {
            onboardingHeaderBlock(for: page)
            Group {
                if expands {
                    practiceStage
                } else if page == .keyboardSwitch, keyboardVerification != .fullAccessOff {
                    // Not a ScrollView: destroying one on the way to Try
                    // dictating dropped the keyboard inset and the bottom jumped.
                    // The repair page never makes that trip, and it has enough
                    // copy to need scrolling once the keyboard is up.
                    stageBody(for: page)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    onboardingScrollingBody(for: page, onlyIfNeeded: fitsWithoutScroll)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, VocaMetrics.padding)
        // Welcome sits tight under the bar. Other pages keep 20pt under chrome.
        .padding(.top, welcomeLike ? VocaMetrics.padding : 20)
        .padding(.bottom, VocaMetrics.grouping)
        // The model landing rewrites the heading and swaps the card's contents
        // at once. Scoped to that one value, so a page change still pushes.
        .animation(chromeFade, value: practiceNeedsModel)
        .frame(maxWidth: 620)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.vocaCanvas)
    }

    /// Welcome fits without a scroll on a default iPhone. Accessibility sizes
    /// and small phones still get a scroll so the three cards are not clipped.
    @ViewBuilder
    private func onboardingScrollingBody(
        for page: OnboardingStage,
        onlyIfNeeded: Bool
    ) -> some View {
        let column = stageBody(for: page)
            .frame(maxWidth: .infinity, alignment: .leading)
        let reserve = dockedActionReserve(for: page)
        if onlyIfNeeded {
            // The reserve is part of what has to fit. Without it the last card
            // "fit" by ending underneath the docked button.
            ViewThatFits(in: .vertical) {
                column
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, reserve)
                ScrollView {
                    column
                }
                .contentMargins(.bottom, reserve, for: .scrollContent)
                .scrollDismissesKeyboard(.interactively)
                .scrollContentBackground(.hidden)
                .scrollBounceBehavior(.basedOnSize)
            }
        } else {
            ScrollView {
                column
            }
            .contentMargins(.bottom, reserve, for: .scrollContent)
            .scrollDismissesKeyboard(page == .keyboardSwitch ? .never : .interactively)
            .scrollContentBackground(.hidden)
        }
    }

    /// Room for the docked button below a page's content. The button is an
    /// overlay so pictures can run under it, but text and cards must be able
    /// to end above it. The page already keeps `grouping` at its foot.
    private func dockedActionReserve(for page: OnboardingStage) -> CGFloat {
        guard pageAction(for: page) != nil || page == .usageReporting else { return 0 }
        return max(0, dockedActionHeight - VocaMetrics.grouping)
    }

    @ViewBuilder
    private func onboardingHeaderBlock(for page: OnboardingStage) -> some View {
        VStack(alignment: .leading, spacing: VocaMetrics.grouping) {
            if showsWelcomeHeroSlot(for: page) {
                ZStack(alignment: .leading) {
                    Color.clear.frame(height: OnboardingWelcomeVisual.height)
                    OnboardingWelcomeVisual(reduceMotion: reduceMotion)
                }
            }
            if let header = onboardingHeader(for: page) {
                OnboardingStageHeader(title: header.title, subtitle: header.subtitle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func onboardingCTA(for page: OnboardingStage) -> some View {
        // No cream slab under the dock. It ate the video and the picture.
        // Pages without a button must not reserve that space either.
        let asksAboutReporting = page == .usageReporting && readyFlash == .none && !holdingKeyboardOff
        let action = pageAction(for: page)
        if asksAboutReporting || action != nil {
            Group {
                if asksAboutReporting {
                    usageReportingDecision
                } else if let action {
                    VocaPrimaryButton(
                        title: action.title,
                        action: action.perform
                    )
                    .disabled(page == .model && isOnboardingModelActionDisabled)
                }
            }
            .transaction { $0.animation = nil }
            .padding(.horizontal, VocaMetrics.padding)
            .padding(.top, VocaMetrics.padding)
            .padding(.bottom, VocaMetrics.related)
            .safeAreaPadding(.bottom)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
            .background(alignment: .top) {
                if dockHasBackdrop(for: page) {
                    // Canvas under the buttons, fading out above them, so text
                    // scrolled beneath reads as passing behind the dock instead
                    // of through translucent buttons.
                    VStack(spacing: 0) {
                        OnboardingEdgeFade(from: .bottom)
                        Color.vocaCanvas
                    }
                    .padding(.top, -OnboardingEdgeFade.length)
                    .ignoresSafeArea(edges: .bottom)
                    .allowsHitTesting(false)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                dockedActionHeight = height
            }
        }
    }

    /// Pages whose content scrolls under the dock. Set up keyboard is left
    /// bare: its video runs under the button, and a slab there hid it.
    private func dockHasBackdrop(for page: OnboardingStage) -> Bool {
        switch page {
        case .keyboard, .keyboardSwitch, .practice: false
        default: true
        }
    }

    /// Turn on and Not now, the same size and the same weight. An optional
    /// question with a louder yes is a nudge, not a question.
    private var usageReportingDecision: some View {
        HStack(spacing: VocaMetrics.related + VocaMetrics.tight) {
            usageReportingButton(UsageReportingCopy.notNow, enabled: false)
            usageReportingButton(UsageReportingCopy.turnOn, enabled: true)
        }
        .disabled(isAnsweringReporting)
    }

    private func usageReportingButton(_ title: String, enabled: Bool) -> some View {
        Button {
            answerUsageReporting(enabled)
        } label: {
            Text(title)
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.vocaPrimaryText)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(Color.vocaSurface, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.vocaBorder, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Figma row: back, a thick brand bar, Skip on the right of the bar.
    /// At accessibility sizes the bar drops under Back and Skip so "Skip"
    /// is not clipped to 50pt.
    private var onboardingChrome: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: VocaMetrics.related) {
                    HStack(spacing: VocaMetrics.related) {
                        backControl
                        Spacer(minLength: 0)
                        skipControl
                    }
                    progressBar
                }
            } else {
                HStack(spacing: VocaMetrics.related) {
                    backControl
                    progressBar
                    skipControl
                }
            }
        }
        .padding(.horizontal, VocaMetrics.padding)
        .padding(.bottom, VocaMetrics.related)
        .background(Color.vocaCanvas)
        .animation(chromeFade, value: showsChromeControls)
        .animation(chromeFade, value: showsSkip)
    }

    /// One curve for everything that fades rather than travels.
    ///
    /// The page itself pushes on a spring, which is right for something
    /// crossing the screen and wrong for something that only changes opacity.
    /// Letting the chrome inherit that spring — and the docked button inherit
    /// nothing at all — is what made arriving at the last page read as three
    /// unrelated events instead of one.
    private var chromeFade: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.28)
    }

    /// The last page has no chrome. Nothing above it is still in progress, and
    /// Back out of a finished setup is an offer to unfinish it.
    ///
    /// The row keeps its height rather than collapsing. Emptying it costs a
    /// band of space; removing it would slide the page up at the same moment
    /// it is pushing in sideways, and land the hero at a different height from
    /// every page that came before.
    private var showsChromeControls: Bool { stage != .complete }

    /// Skip on Choose model is the no-download answer. Get takes that away.
    private var showsSkip: Bool {
        guard !holdingKeyboardOff, readyFlash == .none else { return false }
        return OnboardingPresentation.showsSkip(stage: stage, modelIsArriving: modelIsArriving)
    }

    @ViewBuilder private var backControl: some View {
        Group {
            if showsChromeControls, OnboardingPresentation.previousStage(before: stage) != nil {
                Button(action: goBack) {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.vocaPrimaryText)
                }
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .modifier(VocaGlassBackButtonModifier())
                .accessibilityLabel("Back")
            } else {
                Color.clear
            }
        }
        .frame(minWidth: 44, minHeight: 44)
        .frame(width: dynamicTypeSize.isAccessibilitySize ? nil : 50, height: 50)
    }

    @ViewBuilder private var progressBar: some View {
        if showsChromeControls {
            OnboardingProgressBar(progress: stage.chromeProgress)
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 0.4),
                    value: stage.chromeProgress
                )
                .accessibilityLabel("Setup progress")
                .accessibilityValue("\(Int((stage.chromeProgress * 100).rounded())) percent")
        } else {
            Color.clear.frame(height: 16)
        }
    }

    @ViewBuilder private var skipControl: some View {
        if stage.allowsSkip {
            Button("Skip", action: skipForward)
                .font(.body)
                .foregroundStyle(Color.vocaSecondaryText)
                .padding(.horizontal, 4)
                .frame(minWidth: 50, minHeight: 44)
                .fixedSize()
                .opacity(showsSkip ? 1 : 0)
                .allowsHitTesting(showsSkip)
                .accessibilityHidden(!showsSkip)
        } else {
            Color.clear
                .frame(minWidth: 50, minHeight: 44)
                .frame(width: dynamicTypeSize.isAccessibilitySize ? nil : 50, height: 50)
                .accessibilityHidden(true)
        }
    }

    /// Waveform lives on welcome only. Other pages start with the title
    /// under the chrome, the same as Choose model.
    private func showsWelcomeHeroSlot(for page: OnboardingStage) -> Bool {
        guard !dynamicTypeSize.isAccessibilitySize else { return false }
        switch page {
        case .welcome: return true
        default: return false
        }
    }

    /// Lifted out of each page so the title does not jump when the stage changes.
    private func onboardingHeader(for page: OnboardingStage) -> (title: String, subtitle: String)? {
        switch page {
        case .welcome:
            ("Dictate into any app", "A keyboard that types what you say.")
        case .source:
            ("Choose where speech becomes text", "On this iPhone, or a gateway you run.")
        case .model:
            ("Choose model", "It turns your voice into text, offline on this iPhone. You can switch later.")
        case .microphone:
            ("Microphone for dictation", "So vocaphone can hear what you say.")
        case .keyboard:
            ("Set up keyboard", "So vocaphone can type in any app.")
        case .keyboardSwitch:
            // One heading for the whole page. Rewriting it to "Still waiting"
            // after twelve seconds changed the room out from under someone who
            // was still reading it, and named a cause it could not know: a
            // vocaphone that is showing with Full Access off reports that
            // itself and lands on the repair page instead.
            keyboardVerification == .fullAccessOff
                ? nil
                : ("Enable keyboard", "Enable the keyboard to use vocaphone anywhere you can type.")
        case .practice:
            // The room genuinely changes purpose here, so unlike Enable
            // keyboard it does say so: until the model lands there is nothing
            // to try, and a heading that insisted otherwise was a promise the
            // page could not keep.
            if modelIsArriving {
                (
                    "Getting your model ready",
                    arrivingModelEstimate.map {
                        "Ready in \($0), then speak into the field below."
                    } ?? "Speak into the field below as soon as it's ready."
                )
            } else if practiceNeedsModel {
                (
                    "Download a model first",
                    "Dictation needs a speech-to-text model on this iPhone."
                )
            } else if let loading = practiceModelLoading {
                // Loading is still going when the user gets here faster than
                // it. Recording does not wait for it — the words are kept and
                // transcribed the moment the model is in — so the page says
                // to start rather than to wait.
                (
                    "Try dictating this",
                    "Loading \(loading.displayName). Start speaking — your words appear once it's ready."
                )
            } else {
                ("Try dictating this", "Speak naturally — ums and repeats get cleaned up.")
            }
        case .usageReporting:
            (UsageReportingCopy.title, "Optional, and off unless you turn it on. You can change it later in Settings.")
        case .complete:
            nil
        }
    }

    /// App Store pattern: Get lives on the cards. The docked button is Continue.
    private var onboardingModelAction: (title: String, perform: () -> Void) {
        ("Continue", continueOnboardingModels)
    }

    /// Keep the next action in reach, including on small screens and at large text sizes.
    /// Figma's glass CTA is text only — no SF Symbol on the green bar.
    private func pageAction(
        for page: OnboardingStage
    ) -> (title: String, perform: () -> Void)? {
        if readyFlash != .none || holdingKeyboardOff {
            nil
        } else {
        switch page {
        case .welcome: ("Continue", advance)
        case .source:
            if localTranscriptionEnabled {
                ("Next", advance)
            } else if status.isSatisfied(.source) {
                ("Next", advance)
            } else {
                ("Set up gateway", { isShowingGatewaySetup = true })
            }
        case .model:
            onboardingModelAction
        case .microphone:
            microphonePageAction
        case .keyboard:
            // Only a report from this visit may name the switch. "Turn on Full
            // Access" on the strength of a keyboard merely being in the list
            // was an instruction to someone who may have just done it.
            switch setupKeyboardVerdict {
            case .addKeyboard: ("Open Settings", openSystemSettings)
            case .turnOnFullAccess: ("Turn on Full Access", openSystemSettings)
            case .ready: ("Continue", advance)
            case .verifyOnEnable: nil
            }
        case .keyboardSwitch where keyboardVerification == .fullAccessOff:
            ("Turn on Full Access", openSystemSettings)
        case .keyboardSwitch:
            nil
        case .practice where practiceNeedsModel:
            nil
        case .practice where hasCompletedKeyboardPractice: ("Continue", advance)
        default: nil
        }
        }
    }

    private var microphonePageAction: (title: String, perform: () -> Void)? {
        switch status.microphone {
        case .granted: return ("Continue", advance)
        case .undetermined:
            return ("Continue", {
                coordinator.requestMicrophonePermission(armQuickDictationOnGrant: false)
            })
        case .denied: return ("Open Settings", openSystemSettings)
        }
    }

    @ViewBuilder private func stageBody(for page: OnboardingStage) -> some View {
        switch page {
        case .welcome:
            welcomeStage
        case .source:
            sourceStage
        case .model:
            modelStage
        case .microphone:
            microphoneStage
        case .keyboard:
            keyboardStage
        case .keyboardSwitch:
            keyboardSwitchStage
        case .practice:
            practiceStage
        case .usageReporting:
            usageReportingStage
        case .complete:
            EmptyView()
        }
    }

    private var welcomeStage: some View {
        VStack(alignment: .leading, spacing: VocaMetrics.related + VocaMetrics.tight) {
            welcomeCard(
                0,
                symbol: "lock.fill",
                title: "Your voice stays on this iPhone",
                detail: "That's the default. A gateway you run is a separate choice."
            )
            welcomeCard(
                1,
                symbol: "infinity",
                title: "No subscriptions or limits",
                detail: "Dictate as much as you want, whenever you want."
            )
            welcomeCard(
                2,
                symbol: "keyboard",
                title: "Works anywhere you can type",
                detail: "Use it in any app with a keyboard."
            )
        }
    }

    /// One of three equal cards. Heights are measured unconstrained and the
    /// tallest wins; a card that later grows (Dynamic Type) raises the rest.
    private func welcomeCard(_ index: Int, symbol: String, title: String, detail: String) -> some View {
        OnboardingBoardCard(
            minContentHeight: welcomeCardHeights.values.max() ?? 0,
            onContentHeight: { height in
                if welcomeCardHeights[index] != height { welcomeCardHeights[index] = height }
            }
        ) {
            OnboardingFeatureCopy(layout: .inline, symbol: symbol, title: title, detail: detail)
        }
    }

    /// Two short lists instead of the Settings paragraphs. The full wording
    /// is one tap away, and the literal payload one more — the lists are what
    /// a person reads before deciding, so they have to fit on one screen.
    private var usageReportingStage: some View {
        VStack(alignment: .leading, spacing: VocaMetrics.padding - VocaMetrics.tight) {
            UsageReportingListCard(
                title: "Shared when on",
                symbol: "checkmark.circle.fill",
                tint: Color.brand,
                items: [
                    "Setup steps you reach",
                    "Whether a dictation worked",
                    "Which model you use",
                    "The app version",
                ]
            )
            UsageReportingListCard(
                title: "Never shared",
                symbol: "xmark.circle.fill",
                tint: Color.vocaSecondaryText,
                items: [
                    "Your voice or audio",
                    "What you say, type or dictate",
                    "Your gateway address",
                    "Anything that identifies you",
                ]
            )
            HStack(spacing: VocaMetrics.padding) {
                Button(UsageReportingCopy.seeWhatIsSent) { isShowingReportingPayload = true }
                Spacer(minLength: 0)
                Button("Full details") { isShowingReportingDetails = true }
            }
            .font(.subheadline.weight(.semibold))
            .tint(Color.brand)
            .frame(minHeight: VocaMetrics.minimumTarget)
            .padding(.horizontal, VocaMetrics.tight)
        }
        .sheet(isPresented: $isShowingReportingPayload) { PendingPayloadSheet() }
        .sheet(isPresented: $isShowingReportingDetails) { UsageReportingDetailsSheet() }
    }

    private var sourceStage: some View {
        VStack(alignment: .leading, spacing: VocaMetrics.grouping) {
            VStack(alignment: .leading, spacing: VocaMetrics.related) {
                SourceChoiceCard(
                    title: "Your phone",
                    detail: "Audio and speech stay on this iPhone.",
                    symbol: "iphone",
                    isSelected: localTranscriptionEnabled
                ) {
                    localTranscriptionEnabled = true
                }

                SourceChoiceCard(
                    title: "Gateway",
                    detail: "Audio goes to a gateway you run.",
                    symbol: "server.rack",
                    isSelected: !localTranscriptionEnabled
                ) {
                    localTranscriptionEnabled = false
                }
            }
        }
    }

    private var modelStage: some View {
        VStack(alignment: .leading, spacing: VocaMetrics.grouping) {
            LocalModelPicker(
                manager: coordinator.localModels,
                onChange: { coordinator.refreshSetupStatus() },
                onboarding: true,
                guidanceLanguage: KeyboardPreferences.transcriptionLanguage.rawValue
            )
        }
        .task { coordinator.refreshSetupStatus() }
    }

    @ViewBuilder private var microphoneStage: some View {
        VStack(alignment: .leading, spacing: VocaMetrics.grouping) {
            OnboardingBoardCard {
                OnboardingFeatureCopy(
                    symbol: "lock.fill",
                    title: "Used only to transcribe what you say",
                    detail: "Speech stays on this iPhone, or a gateway you run."
                )
            }

            switch status.microphone {
            case .granted:
                if readyFlash == .none {
                    CompletionNotice("Microphone ready")
                }
            case .undetermined:
                EmptyView()
            case .denied:
                OnboardingBoardCard {
                    OnboardingFeatureCopy(
                        symbol: "mic.slash.fill",
                        title: "Microphone access is off",
                        detail: "iOS asks only once. Turn on Microphone for vocaphone in Settings, then come back."
                    )
                }
            }
        }
    }

    private var keyboardStage: some View {
        VStack(alignment: .leading, spacing: VocaMetrics.grouping) {
            VStack(alignment: .leading, spacing: VocaMetrics.padding) {
                VocaCard {
                    VStack(alignment: .leading, spacing: VocaMetrics.related) {
                        OnboardingInstructionLine(number: 1, title: "Tap Open Settings")
                        OnboardingInstructionLine(number: 2, title: "Tap Keyboards")
                        OnboardingInstructionLine(
                            number: 3,
                            title: "Turn on vocaphone and Allow Full Access"
                        )
                    }
                }
                if keyboardMissingAfterSettings, setupKeyboardVerdict == .addKeyboard {
                    // iOS Settings, not vocaphone: a Settings app that was
                    // already open can keep drawing this app's page from
                    // before the keyboard was registered, without Keyboards
                    // on it. Relaunching Settings rebuilds the page.
                    OnboardingBoardCard {
                        OnboardingFeatureCopy(
                            layout: .inline,
                            symbol: "questionmark",
                            title: "No Keyboards in Settings?",
                            detail: "Close Settings from the app switcher, then tap Open Settings again."
                        )
                    }
                }
                OnboardingLoopingVideo(
                    resource: "SetupKeyboard",
                    rate: 0.7,
                    cornerRadius: VocaMetrics.cardRadius
                )
            }
        }
    }

    /// Two pages behind one stage, because the two situations need opposite
    /// things said. Once the keyboard has reported Full Access off, "switch to
    /// vocaphone" is advice the user has already taken, and repeating it under
    /// a globe animation buries the one thing they still have to do.
    @ViewBuilder private var keyboardSwitchStage: some View {
        if keyboardVerification == .fullAccessOff {
            fullAccessRepairPage
        } else {
            keyboardSwitchPage
        }
    }

    private var fullAccessRepairPage: some View {
        OnboardingPage {
            Image(systemName: "exclamationmark.shield")
                .font(.system(size: 48, weight: .medium))
                .foregroundStyle(Color.vocaWarning)
                .accessibilityHidden(true)
            Text("Turn on Full Access")
                .font(.title.weight(.bold))
            Text("The keyboard opened, but it cannot reach the app until this switch is on.")
                .font(.body)
                .foregroundStyle(Color.vocaSecondaryText)
                .fixedSize(horizontal: false, vertical: true)

            SettingsReferenceCard(
                title: "Allow Full Access",
                detail: "Keyboards → vocaphone",
                symbol: "checkmark.shield",
                note: "Currently off"
            )

            Text("It only lets the keyboard reach the app. Your typing is never sent anywhere.")
                .font(.footnote)
                .foregroundStyle(Color.vocaSecondaryText)
                .fixedSize(horizontal: false, vertical: true)

            // The bottom button already names the problem, so this one names
            // the destination instead of repeating it.
            Button("Review the keyboard steps") {
                keyboardSettingsRoundTripStarted = false
                moveToStage(.keyboard, backward: true)
            }
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: VocaMetrics.minimumTarget)
        }
    }

    private var keyboardSwitchPage: some View {
        VStack(alignment: .leading, spacing: VocaMetrics.grouping) {
            // Above the video, not in the docked slot at the bottom: this page
            // deliberately keeps the keyboard up to show the globe, and the
            // dock is behind it. The top band is the only part of the page the
            // keyboard cannot cover on any phone.
            VocaCard(padding: 24, cornerRadius: 28) {
                Image("EnableKeyboardGlobe")
                    .resizable()
                    .scaledToFit()
                    .compositingGroup()
                    .shadow(color: .black.opacity(0.16), radius: 12, y: 6)
                    .padding(.horizontal, 36)
                    .overlay { globeFingerOverlay }
            }
            .contentShape(Rectangle())
            .onTapGesture { keyboardProbeFocused = true }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Switch to the vocaphone keyboard")
            .accessibilityHint(
                "The system keyboard is open. Hold the globe and choose vocaphone."
            )
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                keyboardProbeFocused = true
            }
        }
    }

    /// Sits to the right of the vocaphone row so the name stays readable.
    /// The fingertip is the top-left of the PNG; `position` is the view center.
    private var globeFingerOverlay: some View {
        GeometryReader { geo in
            let width = geo.size.width
            OnboardingPointingFinger()
                .frame(width: width * 0.40)
                .position(x: width * 0.82, y: geo.size.height * 0.70 + 35)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var practiceStage: some View {
        if practiceNeedsModel {
            practiceFieldPlaceholder
                .transition(.opacity)
        } else {
            practiceField
                .transition(.opacity)
        }
    }

    /// The field as it looks before it can be used: one well, the transfer
    /// across the top and the prompt underneath it.
    ///
    /// The prompt stays because it is the answer to "where do my words go" —
    /// a page that showed only a progress bar was a promise with nothing
    /// behind it. It is deliberately not the real field: `OnboardingPracticeField`
    /// takes first responder as it appears, and the keyboard it raises would
    /// cover the progress while having nothing to dictate with.
    private var practiceFieldPlaceholder: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: VocaMetrics.tight) {
                ProgressView(value: arrivingModelProgress)
                    .tint(Color.brand)
                Text(downloadingModelLine)
                    .font(.footnote)
                    .foregroundStyle(Color.vocaSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 17)
            .padding(.vertical, 13)

            Rectangle()
                .fill(Color.vocaBorder)
                .frame(height: 1)

            Text(Self.practicePrompt)
                .font(.callout.weight(.medium))
                .foregroundStyle(Color.vocaSecondaryText)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(17)
                .opacity(0.6)
        }
        .modifier(OnboardingPracticeFieldChrome())
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Practice dictation. \(downloadingModelLine)")
    }

    private var arrivingModelProgress: Double {
        guard let id = coordinator.localModels.downloadingModelID else { return 0 }
        return coordinator.localModels.progress(for: id)
    }

    /// Name and bytes. The estimate lives in the page subtitle instead, where
    /// it reads as a sentence rather than a third clause on one line.
    private var downloadingModelLine: String {
        let name = arrivingModel?.displayName ?? "your model"
        if let id = coordinator.localModels.downloadingModelID,
           coordinator.localModels.isOptimizing(id)
        {
            return "Optimizing \(name) for this iPhone"
        }
        guard let id = coordinator.localModels.downloadingModelID,
              let size = coordinator.localModels.downloadSizeProgress(for: id)
        else {
            return "Downloading \(name)"
        }
        return "Downloading \(name) · \(size)"
    }

    /// "about a minute", while there is an estimate worth making.
    private var arrivingModelEstimate: String? {
        guard let id = coordinator.localModels.downloadingModelID,
              !coordinator.localModels.isOptimizing(id)
        else { return nil }
        return coordinator.localModels.downloadTimeRemainingPhrase(for: id)
    }

    @ViewBuilder private var practiceField: some View {
        OnboardingPracticeField(
            text: $practiceText,
            prompt: Self.practicePrompt,
            isFocused: $practiceFocused,
            raisesOnAppear: !holdingKeyboardOff,
            onBecameFirstResponder: {
                keyboardProbeFocused = false
            }
        )
        .frame(maxWidth: .infinity, alignment: .top)
    }

    // MARK: - Actions and state

    private var keyboardWatchID: String {
        "\(stage.rawValue)-\(keyboardVerification == .verified)-\(readyFlash != .none)"
    }

    /// Re-runs the delayed keyboard raise when this page appears.
    private var keyboardProbeFocusToken: String {
        "\(stage.rawValue)-\(readyFlash != .none)-\(holdingKeyboardOff)"
    }

    /// List and Full Access as one value so Set up keyboard can stay or move
    /// without two `onChange` modifiers — the observer chain is already long.
    private var keyboardProofToken: String {
        let listed = status.isKeyboardInstalled.map { $0 ? "1" : "0" } ?? "n"
        return "\(listed)-\(status.isSatisfied(.keyboard))"
    }

    /// Hidden UITextField that raises the system keyboard. Creating it while
    /// Keyboard ready is up, or in the first moments after Settings, hangs.
    private var showsKeyboardProbe: Bool {
        guard readyFlash == .none else { return false }
        guard !holdingKeyboardOff else { return false }
        guard keyboardProbeAllowed else { return false }
        // A field whose IME was just turned off in Settings is the crash.
        if status.isKeyboardInstalled == false { return false }
        if stage == .keyboardSwitch { return keyboardProbeFocused }
        return stage == .practice && !practiceNeedsModel
    }

    private var setupKeyboardVerdict: OnboardingPresentation.SetupKeyboardVerdict {
        OnboardingPresentation.setupKeyboardVerdict(status: status, fullAccessMayHaveChanged: false)
    }

    private var practiceNeedsModel: Bool {
        OnboardingPresentation.practiceIsBlockedUntilModelDownload(status: status)
    }

    private var keyboardVerification: KeyboardVerification {
        OnboardingPresentation.keyboardVerification(
            status: status,
            waitedFor: keyboardWaitSeconds,
            pageOpenedAt: stage == .keyboardSwitch ? keyboardSwitchOpenedAt : nil
        )
    }

    private var requiresMandatorySetup: Bool {
        OnboardingPresentation.requiresFirstRunCover(setupCompleted: setupCompleted)
    }

    private func initializeIfNeeded() {
        guard !hasInitialized else { return }
        hasInitialized = true
        if !setupCompleted {
            coordinator.suspendQuickDictationDuringFirstRun()
        }
        applyOnboardingSourceDefaultIfNeeded()
        rereadKeyboardPracticeProof()
        let persisted = OnboardingStage.persisted(from: persistedStageRaw)
        KeyboardInputLanguages.refresh()
        var next = OnboardingPresentation.initialStage(
            persistedStage: persisted,
            status: status,
            hasCompletedKeyboardPractice: hasCompletedKeyboardPractice,
            modelIsArriving: modelIsArriving,
            hasAnsweredUsageReporting: hasAskedAboutReporting
        )
        var transaction = Transaction()
        transaction.disablesAnimations = true
        // vocaphone was on Set up keyboard, went to Settings, and did not live
        // to see the return: changing Allow Full Access is what ends it. The
        // switch moved, so the keyboard's last report no longer stands — and
        // the only thing that can say which way it moved is the keyboard
        // itself, once it is on screen. That is Enable keyboard.
        if next == .keyboard, keyboardSettingsRoundTripStarted {
            next = .keyboardSwitch
            keyboardSettingsRoundTripStarted = false
            // The keyboard list may still be reloading; Enable keyboard's
            // probe waits this out before building its field.
            returnedFromSettingsAt = Date()
        }
        if next == .complete {
            leaveFirstRun()
        } else {
            markKeyboardSwitchClockIfNeeded(next)
            withTransaction(transaction) {
                stage = next
            }
        }
#if DEBUG
        ModelDownloadTrace.record(
            "kb.cold",
            "stage=\(stage.rawValue) roundTrip=\(keyboardSettingsRoundTripStarted)"
        )
#endif
        skipPracticeIfNothingToDictate()
    }

    private func observeKeyboardPracticeProof() {
        guard darwinObservations.isEmpty else { return }
        darwinObservations.append(
            VocaPhoneDarwinCenter.observe(.keyboardPracticeCompleted) {
                NotificationCenter.default.post(
                    name: .vocaKeyboardPracticeCompleted,
                    object: nil
                )
            }
        )
    }

    private func rereadKeyboardPracticeProof() {
        let completed = KeyboardPreferences.refreshKeyboardPracticeProof()
        if hasCompletedKeyboardPractice != completed {
            hasCompletedKeyboardPractice = completed
        }
    }

    private func moveToStage(_ newStage: OnboardingStage, backward: Bool = false) {
        if newStage == .complete {
            leaveFirstRun()
            return
        }
        guard newStage != stage else { return }
        let order = OnboardingStage.pageOrder
        let from = order.firstIndex(of: stage)
        let to = order.firstIndex(of: newStage)
        movesBackward = backward || (from != nil && to != nil && to! < from!)
        // A push looks the same whatever the distance — only one page is ever
        // on screen — but a resume or a Review setup jump should not animate.
        // Skipping a single room still reads as a step. Cutting the hop
        // from Enable keyboard to home (no model) with no animation snapped.
        let step = from != nil && to != nil && abs(from! - to!) <= 2
        let keepsKeyboard = (stage == .keyboardSwitch && newStage == .practice)
            || (stage == .practice && newStage == .keyboardSwitch)
        var transaction = Transaction()
        if reduceMotion || !step || keepsKeyboard || readyFlash != .none {
            transaction.disablesAnimations = true
        } else {
            transaction.animation = .snappy(duration: 0.32)
        }
        markKeyboardSwitchClockIfNeeded(newStage)
        withTransaction(transaction) {
            stage = newStage
        }
    }

    /// Stamp the Enable keyboard clock before `stage` changes so the first
    /// frame cannot treat a leftover `.ready` as a globe switch.
    private func markKeyboardSwitchClockIfNeeded(_ newStage: OnboardingStage) {
        guard newStage == .keyboardSwitch else { return }
        keyboardSwitchOpenedAt = Date()
    }

    private func persistVisibleStage(_ newStage: OnboardingStage) {
        if requiresMandatorySetup {
            persistedStageRaw = newStage.rawValue
        }
        if newStage != .keyboardSwitch, newStage != .practice {
            keyboardProbeFocused = false
        }
        if newStage != .practice {
            practiceFocused = false
        }
    }

    /// Raises the system keyboard so the globe is there — and, on the Full
    /// Access repair page, so vocaphone can run at all. Turning the switch on
    /// in Settings changes nothing the app can see until the extension next
    /// appears, so a repair page that refused to raise a keyboard could never
    /// observe its own repair.
    private func focusKeyboardProbeIfNeeded() async {
        guard readyFlash == .none, !holdingKeyboardOff, stage == .keyboardSwitch else { return }
        if status.isKeyboardInstalled == false {
            dropBackToSetupKeyboardIfRemoved()
            return
        }
        // Already up. A second call used to set this false, sleep, then true —
        // the keyboard slid away and back on Enable keyboard.
        if keyboardProbeFocused { return }
        // VoiceOver drives the keyboard itself; stealing first responder from
        // under it moves focus out of the page the user is reading.
        guard !UIAccessibility.isVoiceOverRunning else { return }
        // Page push and Settings reload in parallel — max, not sum. The
        // 2.5s crash wait is unchanged; Continue without a fresh Settings
        // trip only waits out the push.
        var settle = Self.keyboardSwitchPageSettle
        if let returnedFromSettingsAt {
            settle = max(
                settle,
                Self.settingsSettle - Date().timeIntervalSince(returnedFromSettingsAt)
            )
        }
        if settle > 0 {
            try? await Task.sleep(for: .seconds(settle))
        }
        guard !Task.isCancelled, stage == .keyboardSwitch else { return }
        // ...and never build the field into the keyboard-list reload.
        await waitOutKeyboardListQuiet()
        guard !Task.isCancelled, stage == .keyboardSwitch else { return }
        // An in-flight raise must not land while Settings still has the IME.
        guard scenePhase == .active else { return }
        coordinator.refreshSetupStatus()
        if status.isKeyboardInstalled == false {
            dropBackToSetupKeyboardIfRemoved()
            return
        }
        guard !UIAccessibility.isVoiceOverRunning else { return }
        keyboardProbeAllowed = true
        keyboardProbeFocused = true
    }

    /// Holds until iOS has finished reloading whatever Settings changed.
    /// Returns immediately when the app did not just come back from there.
    private func waitOutSettingsSettle() async {
        guard let returnedFromSettingsAt else { return }
        let remaining = Self.settingsSettle - Date().timeIntervalSince(returnedFromSettingsAt)
        guard remaining > 0 else { return }
        try? await Task.sleep(for: .seconds(remaining))
    }

    /// `AppleKeyboards` is unreadable for a beat after Keyboards. Do not
    /// raise a field until that read is safe and current.
    private func waitOutKeyboardListQuiet() async {
        while coordinator.isKeyboardListReadUnsafe {
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            guard scenePhase == .active else { return }
            guard UIApplication.shared.applicationState == .active else { return }
        }
    }

    /// vocaphone is the IME. Same beat as Microphone ready — then Try
    /// dictating, or home if there is nothing to dictate with.
    private func advanceToPracticeAfterVocaphoneAppeared() async {
        guard stage == .keyboardSwitch, keyboardVerification == .verified else { return }
        // The checkmark is an in-app overlay; the keyboard sits above it.
        // Do not wait out the whole slide — the picture with keys lingering
        // is slower than a cover that meets the keyboard on the way down.
        resignOnScreenKeyboard()
        if !reduceMotion {
            try? await Task.sleep(for: .milliseconds(90))
            guard stage == .keyboardSwitch, keyboardVerification == .verified else { return }
        }
        let next = OnboardingPresentation.stageAfterKeyboardSwitch(
            status: status,
            modelIsArriving: modelIsArriving
        )
        if next == .complete {
            presentReadyFlash(.keyboard, then: nil)
        } else {
            presentReadyFlash(.keyboard, then: next)
        }
    }

    /// The model landed while Try dictating was waiting for it. The static
    /// placeholder is replaced by the real field in the same frame, and the
    /// field has to be given the caret and the keyboard — otherwise the page
    /// looks ready and answers nothing.
    ///
    /// Setting the flag once is not enough: it is often already true, so the
    /// UIKit view sees no change, and the field it belongs to has just been
    /// created and may not be in a window yet. The same short ladder the
    /// keyboard hand-off uses covers both.
    private func raisePracticeFieldAfterModelArrived() async {
        keyboardProbeFocused = false
        practiceFocused = false
        // One motion at a time: the card finishes turning into a field, and
        // only then is the keyboard asked for.
        try? await Task.sleep(for: .milliseconds(reduceMotion ? 0 : 280))
        guard stage == .practice, !practiceNeedsModel, !holdingKeyboardOff else { return }
        for delay in [16, 80, 200, 400] {
            try? await Task.sleep(for: .milliseconds(delay))
            guard stage == .practice, !practiceNeedsModel, !holdingKeyboardOff else { return }
            practiceFocused = true
        }
    }

    /// Skip on Choose model leaves nothing to dictate. Do not park on Try
    /// dictating with Get cards — first run is over.
    private func skipPracticeIfNothingToDictate() {
        guard stage == .practice, practiceNeedsModel, !modelIsArriving else { return }
        practiceFocused = false
        keyboardProbeFocused = false
        leaveFirstRun()
    }

    /// First-run only, and only when nothing is stored. Writing true into a
    /// missing key must not flip someone who already chose the gateway — that
    /// value lives in Settings too.
    private func applyOnboardingSourceDefaultIfNeeded() {
        guard !setupCompleted else { return }
        let store = UserDefaults(suiteName: AppConfiguration.appGroupIdentifier)
        if store?.object(forKey: LocalTranscriptionPreferences.enabledKey) == nil {
            localTranscriptionEnabled = true
        }
    }

    /// One page forward. Never marks setup done, never opens home.
    private func skipForward() {
        guard showsSkip else { return }
        guard var next = OnboardingPresentation.nextStage(after: stage) else { return }
        if next == .model, !localTranscriptionEnabled {
            next = .microphone
        }
        practiceFocused = false
        keyboardProbeFocused = false
        moveToStage(next)
        UIAccessibility.post(notification: .screenChanged, argument: nil)
    }

    private func goBack() {
        guard showsChromeControls, !holdingKeyboardOff else { return }
        readyFlash = .none
        practiceFocused = false
        keyboardProbeFocused = false
        guard let previous = OnboardingPresentation.previousNavigableStage(
            before: stage,
            localTranscriptionEnabled: localTranscriptionEnabled,
            isKeyboardReady: status.isSatisfied(.keyboard),
            practiceBlockedUntilModel: practiceNeedsModel
        ) else { return }
        moveToStage(previous, backward: true)
        UIAccessibility.post(notification: .screenChanged, argument: nil)
    }

    /// The confirmation itself: the symbol arrives first and the words follow.
    ///
    /// Staggered on purpose. Both at once is a poster, not an event — and a
    /// poster is what this screen used to be: an opaque rectangle cut in at
    /// full size, held, then dissolved, with no motion anywhere except the
    /// dissolve. The haptic lands with the symbol rather than with the text.
    ///
    /// Nothing here overshoots. A spring loose enough to be felt (`damping`
    /// 0.62) travels past its target and comes back, and stacking
    /// `.symbolEffect(.bounce)` on top of it gave the checkmark a second
    /// scale impulse — the glyph bounced twice and read as a wobble. A
    /// confirmation should settle into place, so both are gone and the scale
    /// starts at 0.94: enough to arrive, not enough to pop.
    ///
    /// Every animation is scoped to `readyCoverAppeared`, so a page swap
    /// happening underneath the cover cannot drag this into a second motion.
    private var readyCover: some View {
        ZStack {
            Color.vocaCanvas.ignoresSafeArea()
            VStack(spacing: VocaMetrics.related) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56, weight: .medium))
                    .foregroundStyle(Color.brand)
                    .scaleEffect(showsSettledReadyCover ? 1 : 0.94)
                    .opacity(showsSettledReadyCover ? 1 : 0)
                    .animation(
                        reduceMotion ? nil : .smooth(duration: 0.3),
                        value: readyCoverAppeared
                    )
                    .accessibilityHidden(true)
                Text(readyCoverCopy.title)
                    .font(.title.weight(.bold))
                    .opacity(showsSettledReadyCover ? 1 : 0)
                    .offset(y: showsSettledReadyCover ? 0 : 5)
                    .animation(
                        reduceMotion ? nil : .smooth(duration: 0.28).delay(0.08),
                        value: readyCoverAppeared
                    )
            }
            // The content recedes a moment before the ground does, so the
            // cover reads as one thing leaving rather than a screen dimming.
            .scaleEffect(readyCoverLeaving ? 0.97 : 1)
            .opacity(readyCoverLeaving ? 0 : 1)
            .animation(reduceMotion ? nil : .easeIn(duration: 0.2), value: readyCoverLeaving)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sensoryFeedback(.success, trigger: readyFlash) { _, now in now != .none }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(readyCoverCopy.title)
    }

    /// Reduce Motion gets the finished state immediately: the stagger is the
    /// whole effect, and there is nothing left of it worth half-playing.
    private var showsSettledReadyCover: Bool { readyCoverAppeared || reduceMotion }

    /// Full-screen confirmation, then the next page without a slide.
    /// The title stays on `readyCoverCopy` while opacity fades, so the icon
    /// and copy dissolve in place instead of dropping as the stack collapses.
    ///
    /// `next` nil means first run is over: hold the cover, then write
    /// `setupCompleted`. Fading first would flash the last onboarding page.
    private func presentReadyFlash(_ flash: OnboardingReadyFlash, then next: OnboardingStage?) {
        guard flash != .none else { return }
        // First run is not over while the usage question is unanswered: the
        // cover lifts onto that page instead of home.
        let next = next ?? (asksAboutUsageReporting ? .usageReporting : nil)
        readyCoverCopy = flash
        awaitingSettingsReturn = false
        // Reset while the cover is still transparent, so the previous run's
        // settled state cannot be seen rewinding.
        readyCoverAppeared = false
        readyCoverLeaving = false
        var appear = Transaction()
        // The ground fades rather than cuts. The page underneath does not
        // change until the swap much later, so there is nothing to hide.
        appear.animation = reduceMotion ? nil : .easeOut(duration: 0.16)
        withTransaction(appear) {
            readyFlash = flash
        }
        UIAccessibility.post(notification: .announcement, argument: flash.title)
        Task { @MainActor in
            if !reduceMotion {
                try? await Task.sleep(for: .milliseconds(60))
                guard readyFlash == flash else { return }
                readyCoverAppeared = true
            }
            // Long enough for the symbol to settle and the words to land
            // before anything asks the reader to move on.
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 450 : 940))
            guard readyFlash == flash else { return }
            guard let next else {
                finishSetup()
                return
            }
            var swap = Transaction()
            swap.disablesAnimations = true
            withTransaction(swap) {
                moveToStage(next)
            }
            // Let the next page lay out under the opaque cover. Fading in the
            // same beat as the swap made Microphone ready hitch.
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 16 : 50))
            guard readyFlash == flash else { return }
            readyCoverLeaving = true
            if !reduceMotion {
                try? await Task.sleep(for: .milliseconds(60))
                guard readyFlash == flash else { return }
            }
            var fade = Transaction()
            fade.animation = reduceMotion ? nil : .easeOut(duration: 0.24)
            withTransaction(fade) {
                readyFlash = .none
            }
        }
    }

    /// The docked Continue, for the pages that have one.
    private func advance() {
        switch stage {
        case .welcome:
            break
        case .source:
            if !localTranscriptionEnabled {
                guard status.isSatisfied(.source) else { return }
            }
        case .model:
            // A model on its way counts. `isSatisfied(.source)` means "on
            // disk", which is exactly what is not true yet on the page whose
            // whole point is that you no longer have to wait for it — leaving
            // this guard closed made Continue tappable and inert.
            guard status.isSatisfied(.source) || modelIsArriving else { return }
        case .microphone:
            guard status.isSatisfied(.microphone) else { return }
        case .practice:
            guard hasCompletedKeyboardPractice else { return }
        case .keyboard:
            guard setupKeyboardVerdict == .ready else { return }
        case .keyboardSwitch, .usageReporting, .complete:
            // Enable keyboard moves on the extension's own proof. Usage
            // reporting moves on its own two buttons. `.complete` is leave,
            // not a page.
            return
        }
        guard var next = OnboardingPresentation.nextStage(after: stage) else { return }
        if next == .model, !localTranscriptionEnabled {
            next = .microphone
        }
        if stage == .model {
            next = OnboardingPresentation.stageAfterOnboardingModelDownload(
                status: status,
                hasCompletedKeyboardPractice: hasCompletedKeyboardPractice
            )
        }
        moveToStage(next)
        UIAccessibility.post(notification: .screenChanged, argument: nil)
    }

    /// Files on disk are enough to leave Choose model. Loading the engine is
    /// a background job; dictation will try again if this pass fails.
    private func continueOnboardingModels() {
        let ready = onboardingReadyModels
        let readyIDs = Set(ready.map(\.id))
        guard let model = ready.first(where: { $0.id == LocalTranscriptionPreferences.modelIdentifier })
            ?? onboardingModelPicks.first(where: { readyIDs.contains($0.id) })
            ?? ready.first
        else {
            // Nothing has landed yet. Leaving is still allowed while a
            // transfer runs: whichever one finishes claims the selection
            // through `downloadAndUse`, the same path that claims it today.
            if modelIsArriving { advance() }
            return
        }
        LocalTranscriptionPreferences.modelIdentifier = model.id
        LocalTranscriptionPreferences.enabled = true
        coordinator.refreshSetupStatus()
        advance()
        Task { await prepareOnboardingModelInBackground(model) }
    }

    private func prepareOnboardingModelInBackground(_ model: LocalModelDescriptor) async {
        // Continue is the writer of record. If something else has claimed the
        // selection since, loading this one would leave the resident engine
        // and the stored identifier describing different models.
        guard LocalTranscriptionPreferences.modelIdentifier == model.id else { return }
        await coordinator.localModels.warm(model, language: warmLanguage(for: model))
    }

    /// Changes whenever loading the model might have become possible or
    /// necessary again: a new page, a return to the foreground, a download
    /// landing.
    private var onboardingWarmKey: String {
        [
            stage.rawValue,
            scenePhase == .active ? "active" : "inactive",
            coordinator.localModels.downloadedModelIDs.sorted().joined(separator: ","),
        ].joined(separator: "|")
    }

    /// The on-device model Try dictating will use, if one is chosen and on disk.
    private var selectedOnDeviceModel: LocalModelDescriptor? {
        guard LocalTranscriptionPreferences.enabled,
              let id = LocalTranscriptionPreferences.modelIdentifier,
              coordinator.localModels.isDownloaded(id)
        else { return nil }
        return LocalModelCatalog.descriptor(for: id)
    }

    private func warmSelectedModel() async {
        guard scenePhase == .active,
              OnboardingPresentation.warmsSelectedModel(on: stage),
              let model = selectedOnDeviceModel
        else { return }
        await coordinator.localModels.warm(model, language: warmLanguage(for: model))
    }

    private func warmLanguage(for model: LocalModelDescriptor) -> String {
        ModelLanguageSupport.resolve(
            KeyboardPreferences.transcriptionLanguage,
            modelLanguages: model.selectableLanguageCodes
        ).rawValue
    }

    /// First run ends here. The Ready-to-dictate cover is only for a setup
    /// that can actually dictate — skipped download goes straight to home.
    private func leaveFirstRun() {
        if stage != .usageReporting, asksAboutUsageReporting {
            askAboutUsageReporting()
            return
        }
        // Whether the keys are up right now. Read before letting go: the
        // cover is an in-app overlay and the keyboard is a system window
        // above it, so "Ready to dictate" cannot paint over the keys.
        let dismissingKeyboard = practiceFocused || keyboardProbeFocused
            || (stage == .practice && !practiceNeedsModel)
        holdingKeyboardOff = true
        // Same tap as Continue. Waiting a SwiftUI frame to resign left the
        // field first responder, and Ready to dictate cannot cover a system
        // keyboard.
        resignOnScreenKeyboard()
        if OnboardingPresentation.showsSetupReadyFlash(status: status) {
            Task { @MainActor in
                if dismissingKeyboard {
                    try? await Task.sleep(
                        for: .milliseconds(reduceMotion ? 80 : Self.keyboardDismissal)
                    )
                }
                guard requiresMandatorySetup else { return }
                presentReadyFlash(.setup, then: nil)
            }
            return
        }
        if OnboardingPresentation.canFinishSetup(status: status) {
            finishSetup()
            return
        }
        let fallback = OnboardingPresentation.resumeStage(
            status: status,
            hasCompletedKeyboardPractice: hasCompletedKeyboardPractice,
            allowSkippedModel: true
        )
        if fallback == .complete || fallback == stage {
            finishSetup()
            return
        }
        moveToStage(fallback, backward: true)
    }

    private var asksAboutUsageReporting: Bool {
        OnboardingPresentation.asksAboutUsageReporting(
            status: status,
            hasBeenAsked: hasAskedAboutReporting
        )
    }

    /// The last page. The keyboard goes first: Try dictating leaves it up, and
    /// a page pushing in under a keyboard still sliding away is two motions.
    private func askAboutUsageReporting() {
        let dismissingKeyboard = practiceFocused || keyboardProbeFocused
            || (stage == .practice && !practiceNeedsModel)
        resignOnScreenKeyboard()
        Task { @MainActor in
            if dismissingKeyboard {
                try? await Task.sleep(
                    for: .milliseconds(reduceMotion ? 80 : Self.keyboardDismissal)
                )
            }
            guard requiresMandatorySetup, stage != .usageReporting else { return }
            moveToStage(.usageReporting)
            UIAccessibility.post(notification: .screenChanged, argument: nil)
        }
    }

    /// The choice is written before the question is marked answered. The
    /// other order could lose a Turn on to a suspension in between and then
    /// never ask again, leaving reporting off behind an answered question.
    private func answerUsageReporting(_ enabled: Bool) {
        guard stage == .usageReporting, !hasAskedAboutReporting, !isAnsweringReporting else { return }
        isAnsweringReporting = true
        Task { @MainActor in
            await Telemetry.shared.setEnabled(enabled)
            UserDefaultsTelemetryPreferences().hasBeenAsked = true
            hasAskedAboutReporting = true
            isAnsweringReporting = false
            leaveFirstRun()
        }
    }

    private func finishSetup() {
        setupCompleted = true
        persistedStageRaw = OnboardingStage.complete.rawValue
        keyboardSettingsRoundTripStarted = false
        Telemetry.shared.setupFinished()
        // First-run held Quick Dictation off so the orange standby dot
        // could not look like recording. Home is allowed to arm it now.
        coordinator.prepareQuickDictationIfEnabled()
        // No dismiss: first run *is* the window. `ContentView` swaps in home
        // the moment this flag lands.
    }

    private func refreshAfterForegroundReturn() async {
        let trip = settingsTrip
        let fromSettings = awaitingSettingsReturn
        if fromSettings {
            returnedFromSettingsAt = Date()
            // A Darwin ping from the last time the switch was off must not
            // seal this visit. The globe page re-proves; the repair page
            // only comes back on a report after this clock.
            if stage == .keyboardSwitch {
                keyboardSwitchOpenedAt = Date()
            }
        }
        coordinator.noteKeyboardListMayReload()
        coordinator.refreshSetupStatus()
        dropBackToSetupKeyboardIfRemoved()

        // Control Center and app switcher are not Settings. Restore the
        // globe field without the 2.5s keyboard-list wait those need.
        if !fromSettings {
            keyboardProbeAllowed = true
            if holdingKeyboardOff {
                resignOnScreenKeyboard()
            } else if stage == .keyboardSwitch {
                await focusKeyboardProbeIfNeeded()
            } else if stage == .practice, !practiceNeedsModel {
                practiceFocused = true
            }
        }

        if fromSettings, stage == .keyboard {
            await settleSetupKeyboardAfterSettings(trip: trip)
        } else {
            // iOS can publish a changed permission or keyboard list just after
            // the app becomes active. Re-read briefly so the first return
            // updates in place instead of requiring another trip through
            // Settings.
            //
            // Set up keyboard stays put even if the list is still empty:
            // jumping to Enable keyboard because the user opened Settings
            // stranded anyone who added nothing. Extra reads catch a late
            // `AppleKeyboards` write without leaving the page.
            for delay in [180, 420, 800, 1_500] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard !Task.isCancelled else { return }
                coordinator.refreshSetupStatus()
                dropBackToSetupKeyboardIfRemoved()

            }
        }

        await coordinator.refreshGatewayHealth()
        rereadKeyboardPracticeProof()
        // A newer trip began while this one waited; its notes are its own.
        guard trip == settingsTrip else { return }
        awaitingSettingsReturn = false
        if stage == .keyboard {
            keyboardSettingsRoundTripStarted = false
        }
        guard scenePhase == .active else { return }
        dropBackToSetupKeyboardIfRemoved()
        keyboardProbeAllowed = true
        if holdingKeyboardOff {
            resignOnScreenKeyboard()
        } else if stage == .keyboardSwitch {
            await focusKeyboardProbeIfNeeded()
        } else if stage == .practice, !practiceNeedsModel {
            practiceFocused = true
        }
    }

    /// Back from Settings on Set up keyboard, and the process survived the
    /// trip — so Allow Full Access did not move (changing it would have
    /// terminated vocaphone) and the keyboard's last report still stands.
    ///
    /// Nothing is raised to ask. Only the keyboard list needs a moment: it can
    /// read "not added" for a few seconds after the keyboard was switched on —
    /// long enough that the first version of this wait gave up and said Open
    /// Settings to someone who had just added it.
    ///
    /// The button stays up throughout. Hiding it made it vanish and come back
    /// on every return, and there is nothing to protect: Open Settings and
    /// Turn on Full Access both go to Settings, and Continue cannot be wrong
    /// on a return the app survived. At worst the label catches up in place.
    private func settleSetupKeyboardAfterSettings(trip: Int) async {
        guard stage == .keyboard else { return }
        await waitOutKeyboardListQuiet()
        for delay in [0, 300, 700, 1_200, 2_000] {
            if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
            guard stage == .keyboard, trip == settingsTrip else { return }
            coordinator.refreshSetupStatus()
            if status.isKeyboardInstalled == true { break }
        }
        guard stage == .keyboard, trip == settingsTrip else { return }
#if DEBUG
        ModelDownloadTrace.record(
            "kb.return",
            "installed=\(String(describing: status.isKeyboardInstalled))"
                + " stored=\(status.keyboard) verdict=\(setupKeyboardVerdict)"
        )
#endif
        keyboardMissingAfterSettings = setupKeyboardVerdict == .addKeyboard
        // They came back having done the whole thing: go on without a tap.
        if setupKeyboardVerdict == .ready {
            moveToStage(.keyboardSwitch)
            UIAccessibility.post(notification: .screenChanged, argument: nil)
        }
    }

    /// Asks whoever is on screen to say so, and reads the answer.
    ///
    /// Full Access off is not excluded: turning the switch on in Settings is
    /// invisible until the extension runs again, and this is what notices.
    private func watchForTheKeyboard() async {
        keyboardWaitSeconds = 0
        guard readyFlash == .none, stage == .keyboardSwitch else { return }
        guard keyboardVerification != .verified else { return }
        // `refreshSetupStatus` reads the keyboard list, which is the list iOS
        // is still rewriting on the way back from Settings. Polling it at
        // 2.5 Hz through that window is the other half of the hang.
        await waitOutSettingsSettle()
        guard !Task.isCancelled, stage == .keyboardSwitch else { return }
        let startedAt = Date()
        while !Task.isCancelled {
            // Brisk while the page is still merely patient, then slow. Past
            // the grace period the page has already said what to do, and a
            // stalled page must not hold a 2.5 Hz poll for as long as it is
            // left open.
            let slow = keyboardWaitSeconds >= KeyboardVerification.grace
            try? await Task.sleep(for: .milliseconds(slow ? 2_000 : 400))
            guard !Task.isCancelled else { return }
            keyboardWaitSeconds = Date().timeIntervalSince(startedAt)
            pingTheKeyboard()
            coordinator.refreshSetupStatus()
        }
    }

    /// Only a running extension receives this, so its reply is proof of the
    /// one thing Enable keyboard cannot otherwise see: vocaphone is up now.
    private func pingTheKeyboard() {
        VocaPhoneDarwinCenter.post(.keyboardStatusRequested)
    }

    private func openSystemSettings() {
        settingsTrip += 1
        awaitingSettingsReturn = true
        if stage == .keyboard {
            keyboardSettingsRoundTripStarted = true
        }
        // Drop first responder in this call, not on the next SwiftUI frame —
        // Settings can unload the extension before the field resigns itself.
        resignOnScreenKeyboard()
        coordinator.noteKeyboardListMayReload()
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }

    /// Hide and resign the probe now. `@State` alone would wait a frame.
    private func resignOnScreenKeyboard() {
        keyboardProbeAllowed = false
        keyboardProbeFocused = false
        practiceFocused = false
        // Flip `wantsFocus` on the live view in this call. A queued
        // `becomeFirstResponder` from the practice field would otherwise
        // steal the keys back before SwiftUI's next `updateUIView`.
        PracticeTextView.releaseHeldFocus()
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }

    /// Enable keyboard has a live field. If vocaphone is no longer in the
    /// list, that field's IME is gone — go back to Set up keyboard.
    private func dropBackToSetupKeyboardIfRemoved() {
        guard stage == .keyboardSwitch else { return }
        guard status.isKeyboardInstalled == false else { return }
        resignOnScreenKeyboard()
        moveToStage(.keyboard, backward: true)
    }

    private static let practicePrompt =
        "Hi John. Um, I think I think we should meet at two. Cheers!"
}

// MARK: - Focused setup components

/// Same title + subtitle on every page, so the heading sits on one line
/// under the chrome. Welcome puts the waveform above this.
private struct OnboardingStageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: VocaMetrics.related) {
            Text(title)
                .font(.largeTitle.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .font(.title3)
                .foregroundStyle(Color.vocaSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// First-responder that never draws a caret. Enable Keyboard only needs the
/// system keyboard so the globe is there; a cursor on this page is a leak.
private struct KeyboardSwitchProbeField: UIViewRepresentable {
    @Binding var isFocused: Bool
    var resignsWhenUnfocused = true

    func makeCoordinator() -> Coordinator {
        Coordinator(isFocused: $isFocused)
    }

    func makeUIView(context: Context) -> KeyboardSwitchProbeTextField {
        let field = KeyboardSwitchProbeTextField()
        field.delegate = context.coordinator
        field.backgroundColor = .clear
        field.textColor = .clear
        field.tintColor = .clear
        field.borderStyle = .none
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.smartDashesType = .no
        field.smartQuotesType = .no
        field.smartInsertDeleteType = .no
        field.returnKeyType = .default
        field.clipsToBounds = true
        return field
    }

    func updateUIView(_ field: KeyboardSwitchProbeTextField, context: Context) {
        context.coordinator.isFocused = $isFocused
        if isFocused {
            guard UIApplication.shared.applicationState == .active else { return }
            if !field.isFirstResponder {
                if field.window != nil {
                    field.becomeFirstResponder()
                }
                if !field.isFirstResponder {
                    DispatchQueue.main.async { [weak field] in
                        guard let field, field.window != nil else { return }
                        guard UIApplication.shared.applicationState == .active else { return }
                        field.becomeFirstResponder()
                    }
                }
            }
        } else if resignsWhenUnfocused, field.isFirstResponder {
            field.resignFirstResponder()
        }
    }

    static func dismantleUIView(_ view: KeyboardSwitchProbeTextField, coordinator: Coordinator) {
        view.delegate = nil
        if view.isFirstResponder {
            view.resignFirstResponder()
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var isFocused: Binding<Bool>

        init(isFocused: Binding<Bool>) {
            self.isFocused = isFocused
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            isFocused.wrappedValue = true
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            // Switching to vocaphone resigns this field. Clearing the flag
            // destroyed the probe and dropped the keyboard; steal it back.
            guard isFocused.wrappedValue else { return }
            DispatchQueue.main.async { [weak textField] in
                guard self.isFocused.wrappedValue else { return }
                guard let textField, textField.window != nil else { return }
                guard UIApplication.shared.applicationState == .active else { return }
                if !textField.isFirstResponder {
                    textField.becomeFirstResponder()
                }
            }
        }
    }
}

private final class KeyboardSwitchProbeTextField: UITextField {
    override func caretRect(for position: UITextPosition) -> CGRect { .zero }

    override func selectionRects(for range: UITextRange) -> [UITextSelectionRect] { [] }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        false
    }
}

/// Prompt card that hugs the copy. Never truncates the example.
private struct OnboardingPracticeField: View {
    @Binding var text: String
    var prompt: String
    @Binding var isFocused: Bool
    var raisesOnAppear = true
    var onBecameFirstResponder: () -> Void = {}

    var body: some View {
        OnboardingPracticeFieldView(
            text: $text,
            prompt: prompt,
            isFocused: $isFocused,
            onBecameFirstResponder: onBecameFirstResponder
        )
        .modifier(OnboardingPracticeFieldChrome())
        .accessibilityLabel("Practice dictation")
        .accessibilityHint(prompt)
        .onAppear {
            guard raisesOnAppear else { return }
            isFocused = true
        }
    }
}

/// The well both the live field and its waiting placeholder sit in. Shared so
/// the field cannot appear to move or change shape when it goes live.
private struct OnboardingPracticeFieldChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .top)
            .background(
                Color.vocaSurface,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.vocaBorder, lineWidth: 1)
            )
    }
}

private struct OnboardingPracticeFieldView: UIViewRepresentable {
    @Binding var text: String
    var prompt: String
    @Binding var isFocused: Bool
    var onBecameFirstResponder: () -> Void = {}

    private static let inset: CGFloat = 17
    private static let fontSize: CGFloat = 16
    private static let lineHeight: CGFloat = 19
    private static let minimumHeight: CGFloat = 72

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            isFocused: $isFocused,
            onBecameFirstResponder: onBecameFirstResponder
        )
    }

    func makeUIView(context: Context) -> PracticeTextView {
        let view = PracticeTextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.textColor = UIColor.label
        view.tintColor = BrandPalette.accent
        view.tintAdjustmentMode = .normal
        view.font = Self.fieldFont
        view.text = text
        view.typingAttributes = Self.typingAttributes
        view.textContainerInset = UIEdgeInsets(
            top: Self.inset,
            left: Self.inset,
            bottom: Self.inset,
            right: Self.inset
        )
        view.textContainer.lineFragmentPadding = 0
        view.textContainer.lineBreakMode = .byWordWrapping
        view.adjustsFontForContentSizeCategory = true
        view.isEditable = true
        view.isSelectable = true
        view.isScrollEnabled = true
        view.keyboardDismissMode = .none
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.required, for: .vertical)
        view.accessibilityLabel = "Practice dictation"
        view.placeholderLabel.numberOfLines = 0
        view.placeholderLabel.lineBreakMode = .byWordWrapping
        view.placeholderLabel.font = Self.fieldFont
        view.placeholderLabel.attributedText = NSAttributedString(
            string: prompt,
            attributes: Self.placeholderAttributes
        )
        view.placeholderLabel.isHidden = !text.isEmpty
        view.wantsFocus = isFocused
        view.onBecameFirstResponder = onBecameFirstResponder
        return view
    }

    func updateUIView(_ view: PracticeTextView, context: Context) {
        context.coordinator.text = $text
        context.coordinator.isFocused = $isFocused
        context.coordinator.onBecameFirstResponder = onBecameFirstResponder
        view.onBecameFirstResponder = onBecameFirstResponder
        if view.text != text {
            let selected = view.selectedTextRange
            view.typingAttributes = Self.typingAttributes
            view.text = text
            view.selectedTextRange = selected
        }
        view.placeholderLabel.isHidden = !text.isEmpty
        // Never resign here. A tap makes the view first responder before SwiftUI
        // flips `isFocused`; resigning on that stale false frame hid the keyboard.
        view.wantsFocus = isFocused
        if isFocused {
            DispatchQueue.main.async {
                view.applyFocusIfNeeded()
            }
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: PracticeTextView,
        context: Context
    ) -> CGSize? {
        let width = proposal.width ?? UIView.layoutFittingExpandedSize.width
        let needed = max(Self.minimumHeight, uiView.preferredHeight(forWidth: width))
        let height: CGFloat
        if let proposed = proposal.height, proposed.isFinite, proposed < 10_000 {
            height = min(needed, proposed)
            uiView.isScrollEnabled = needed > proposed + 0.5
        } else {
            height = needed
            uiView.isScrollEnabled = false
        }
        return CGSize(width: width, height: height)
    }

    private static var fieldFont: UIFont {
        UIFontMetrics(forTextStyle: .callout).scaledFont(
            for: UIFont.systemFont(ofSize: fontSize, weight: .medium)
        )
    }

    private static var lineStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        let height = lineHeight * (fieldFont.pointSize / fontSize)
        style.minimumLineHeight = height
        style.maximumLineHeight = height
        return style
    }

    private static var typingAttributes: [NSAttributedString.Key: Any] {
        [
            .font: fieldFont,
            .foregroundColor: UIColor.label,
            .paragraphStyle: lineStyle,
        ]
    }

    private static var placeholderAttributes: [NSAttributedString.Key: Any] {
        [
            .font: fieldFont,
            .foregroundColor: UIColor.tertiaryLabel,
            .paragraphStyle: lineStyle,
        ]
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var text: Binding<String>
        var isFocused: Binding<Bool>
        var onBecameFirstResponder: () -> Void

        init(
            text: Binding<String>,
            isFocused: Binding<Bool>,
            onBecameFirstResponder: @escaping () -> Void
        ) {
            self.text = text
            self.isFocused = isFocused
            self.onBecameFirstResponder = onBecameFirstResponder
        }

        func textViewDidChange(_ textView: UITextView) {
            text.wrappedValue = textView.text ?? ""
            if let practice = textView as? PracticeTextView {
                practice.placeholderLabel.isHidden = !text.wrappedValue.isEmpty
            }
            textView.invalidateIntrinsicContentSize()
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            isFocused.wrappedValue = true
            onBecameFirstResponder()
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            // Trust the SwiftUI flag, not `wantsFocus` on the view:
            // resign from Continue lands before `updateUIView` can flip
            // that, and stealing on the stale true kept the keys up under
            // Ready to dictate.
            if let practice = textView as? PracticeTextView, isFocused.wrappedValue {
                DispatchQueue.main.async {
                    guard self.isFocused.wrappedValue else { return }
                    practice.applyFocusIfNeeded()
                }
                return
            }
            isFocused.wrappedValue = false
        }
    }
}

private final class PracticeTextView: UITextView {
    let placeholderLabel = UILabel()
    var onBecameFirstResponder: () -> Void = {}
    /// The field currently holding, or trying to hold, first responder.
    /// `resignOnScreenKeyboard` flips `wantsFocus` here so a queued raise
    /// cannot outrun SwiftUI.
    private static weak var held: PracticeTextView?
    /// Set from SwiftUI. The hidden Enable-keyboard probe often still holds
    /// first responder after the page change, so we keep stealing it until
    /// this field is first responder and the caret is on screen.
    var wantsFocus = false {
        didSet {
            if wantsFocus != oldValue { focusRetry = 0 }
            if wantsFocus {
                Self.held = self
                applyFocusIfNeeded()
            } else if oldValue, isFirstResponder {
                _ = resignFirstResponder()
            }
        }
    }
    private var focusRetry = 0

    static func releaseHeldFocus() {
        held?.wantsFocus = false
    }

    override var canBecomeFirstResponder: Bool { true }

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        placeholderLabel.numberOfLines = 0
        placeholderLabel.lineBreakMode = .byWordWrapping
        placeholderLabel.adjustsFontForContentSizeCategory = true
        placeholderLabel.isUserInteractionEnabled = false
        // Behind the text and caret. `addSubview` stacked it on top, so the
        // insertion point was there and invisible until the user tapped.
        insertSubview(placeholderLabel, at: 0)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        applyFocusIfNeeded()
    }

    @discardableResult
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            Self.held = self
            revealInsertionPoint()
            onBecameFirstResponder()
        }
        return accepted
    }

    func applyFocusIfNeeded() {
        guard wantsFocus else { return }
        guard window != nil, bounds.width > 8 else {
            scheduleFocusRetry()
            return
        }
        if isFirstResponder {
            revealInsertionPoint()
            onBecameFirstResponder()
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.wantsFocus else { return }
            if !self.isFirstResponder {
                _ = self.becomeFirstResponder()
            }
            if self.isFirstResponder {
                self.revealInsertionPoint()
                self.onBecameFirstResponder()
            } else {
                self.scheduleFocusRetry()
            }
        }
    }

    private func scheduleFocusRetry() {
        guard wantsFocus, focusRetry < 40 else { return }
        focusRetry += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.applyFocusIfNeeded()
        }
    }

    /// Programmatic focus often keeps the keyboard on the hidden probe and
    /// draws no caret here. Collapse the selection and restore tint.
    private func revealInsertionPoint() {
        guard wantsFocus, isFirstResponder else { return }
        tintColor = BrandPalette.accent
        tintAdjustmentMode = .normal
        let offset = (text as NSString?)?.length ?? 0
        selectedRange = NSRange(location: offset, length: 0)
        if let position = position(from: beginningOfDocument, offset: offset) {
            selectedTextRange = textRange(from: position, to: position)
        }
    }

    override var intrinsicContentSize: CGSize {
        let width = bounds.width > 8 ? bounds.width : 320
        return CGSize(width: UIView.noIntrinsicMetric, height: preferredHeight(forWidth: width))
    }

    func preferredHeight(forWidth width: CGFloat) -> CGFloat {
        let inset = textContainerInset
        let inner = max(0, width - inset.left - inset.right)
        let promptHeight = placeholderLabel.sizeThatFits(
            CGSize(width: inner, height: .greatestFiniteMagnitude)
        ).height
        let textHeight = sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude)
        ).height
        let wrappedPrompt = inset.top + promptHeight + inset.bottom
        return max(textHeight, wrappedPrompt)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if wantsFocus, !isFirstResponder {
            applyFocusIfNeeded()
        }
        sendSubviewToBack(placeholderLabel)
        let inset = textContainerInset
        let width = bounds.width - inset.left - inset.right
        let size = placeholderLabel.sizeThatFits(
            CGSize(width: max(0, width), height: .greatestFiniteMagnitude)
        )
        placeholderLabel.frame = CGRect(
            x: inset.left,
            y: inset.top,
            width: width,
            height: size.height
        )
        let contentHeight = sizeThatFits(
            CGSize(width: bounds.width, height: .greatestFiniteMagnitude)
        ).height
        isScrollEnabled = contentHeight > bounds.height + 0.5
    }
}

/// Soft canvas fade where fixed chrome meets scrolling content.
/// Hangs off the chrome; does not eat extra inset.
private struct OnboardingEdgeFade: View {
    static let length: CGFloat = 44
    var from: Edge

    var body: some View {
        LinearGradient(
            stops: [
                .init(color: Color.vocaCanvas, location: 0),
                .init(color: Color.vocaCanvas.opacity(0.7), location: 0.35),
                .init(color: Color.vocaCanvas.opacity(0), location: 1),
            ],
            startPoint: from == .top ? .top : .bottom,
            endPoint: from == .top ? .bottom : .top
        )
        .frame(height: Self.length)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Figma Frame 13: surface fill, 16 continuous, no shadow, no stroke.
private struct OnboardingBoardCard<Content: View>: View {
    /// Cards that sit together as a set share one height, so a one-line card
    /// does not break the column. Reports its natural content height.
    var minContentHeight: CGFloat = 0
    var onContentHeight: ((CGFloat) -> Void)? = nil
    @ViewBuilder var content: Content

    var body: some View {
        content
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                onContentHeight?(height)
            }
            .frame(maxWidth: .infinity, minHeight: minContentHeight, alignment: .leading)
            .padding(16)
            .background(
                Color.vocaSurface,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
    }
}

/// A titled checklist for the usage-reporting page.
private struct UsageReportingListCard: View {
    let title: String
    let symbol: String
    let tint: Color
    let items: [String]

    var body: some View {
        OnboardingBoardCard {
            VStack(alignment: .leading, spacing: VocaMetrics.related + VocaMetrics.tight) {
                Text(title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                ForEach(items, id: \.self) { item in
                    Label {
                        Text(item)
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: symbol)
                            .foregroundStyle(tint)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The Settings wording, word for word, for anyone who wants all of it.
private struct UsageReportingDetailsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: VocaMetrics.padding) {
                    Text(UsageReportingCopy.whatIsSent)
                    Text(UsageReportingCopy.whatIsNeverSent)
                    Text(UsageReportingCopy.noIdentifier + " " + UsageReportingCopy.optOutIsLogged)
                    Text(UsageReportingCopy.changeLater)
                        .foregroundStyle(Color.vocaSecondaryText)
                }
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
                .padding(VocaMetrics.padding)
            }
            .navigationTitle(UsageReportingCopy.settingsTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Title and detail inside a board card. The three welcome features are
/// separate cards, the way they sit on the board.
private struct OnboardingFeatureCopy: View {
    enum Layout {
        /// Symbol on its own line above the copy.
        case stacked
        /// Symbol beside the copy. Welcome's three cards have to fit above
        /// the docked button, and a line per symbol is what pushed the last
        /// one under it.
        case inline
    }

    var layout: Layout = .stacked
    let symbol: String
    let title: String
    let detail: String

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if layout == .inline, !dynamicTypeSize.isAccessibilitySize {
                // Centred on the copy, in a tile of one fixed size. On a text
                // baseline a lock, an infinity sign and a keyboard each sat at
                // a different height and inset, and the column wandered.
                HStack(alignment: .center, spacing: VocaMetrics.padding) {
                    symbolTile
                    copy
                }
            } else {
                VStack(alignment: .leading, spacing: VocaMetrics.related) {
                    symbolImage
                    copy
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var symbolTile: some View {
        Image(systemName: symbol)
            .font(.system(size: 18, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(Color.brand)
            .frame(width: 40, height: 40)
            .background(
                Color.brand.opacity(0.14),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .accessibilityHidden(true)
    }

    private var symbolImage: some View {
        Image(systemName: symbol)
            .font(.title3)
            .foregroundStyle(Color.vocaSecondaryText)
            .accessibilityHidden(true)
    }

    private var copy: some View {
        VStack(alignment: .leading, spacing: VocaMetrics.tight) {
            Text(title)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            Text(detail)
                .font(.body)
                .foregroundStyle(Color.vocaSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct OnboardingPage<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: VocaMetrics.grouping) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(VocaMetrics.grouping)
        .background(
            Color.vocaSurface,
            in: RoundedRectangle(cornerRadius: VocaMetrics.heroRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: VocaMetrics.heroRadius, style: .continuous)
                .strokeBorder(Color.vocaBorder, lineWidth: 1)
        )
    }
}

/// One numbered line inside the setup-keyboard card.
private struct OnboardingInstructionLine: View {
    let number: Int
    let title: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "\(number).circle.fill")
                .font(.title3.weight(.medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.vocaSecondaryText)
                .frame(width: 24)
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(number). \(title)")
    }
}

private struct CompletionNotice: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.brand)
            .accessibilityElement(children: .combine)
    }
}

private struct SourceChoiceCard: View {
    let title: String
    let detail: String
    let symbol: String
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Button(action: action) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: VocaMetrics.related) {
                        HStack(alignment: .top, spacing: VocaMetrics.padding) {
                            Image(systemName: symbol)
                                .font(.title3)
                                .foregroundStyle(isSelected ? Color.brand : Color.vocaSecondaryText)
                            Spacer(minLength: 0)
                            checkbox
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(title)
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text(detail)
                                .font(.subheadline)
                                .foregroundStyle(Color.vocaSecondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } else {
                    HStack(alignment: .top, spacing: VocaMetrics.padding) {
                        Image(systemName: symbol)
                            .font(.title3)
                            .foregroundStyle(isSelected ? Color.brand : Color.vocaSecondaryText)
                            .frame(width: 26)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(title)
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text(detail)
                                .font(.subheadline)
                                .foregroundStyle(Color.vocaSecondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        checkbox
                    }
                }
            }
            .padding(VocaMetrics.padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color.vocaSurface,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(isSelected ? Color.brand.opacity(0.5) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }

    private var checkbox: some View {
        Image(systemName: isSelected ? "checkmark.square.fill" : "square")
            .font(.title3)
            .foregroundStyle(isSelected ? Color.brand : Color.vocaBorder)
            .accessibilityHidden(true)
    }
}

/// The one switch the repair page is about, and where to find it.
///
/// This was a three-state checklist row. Two of the three states had no
/// caller: nothing on this page is ever met or merely pending, because the
/// page only exists once the keyboard has reported the switch off.
private struct SettingsReferenceCard: View {
    let title: String
    var detail: String? = nil
    let symbol: String
    let note: String

    var body: some View {
        HStack(alignment: .top, spacing: VocaMetrics.padding) {
            Image(systemName: "exclamationmark")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Color.onBrand)
                .frame(width: 28, height: 28)
                .background(Color.vocaWarning, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Label(title, systemImage: symbol)
                    .font(.headline)
                if let detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(Color.vocaSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(note)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.vocaWarning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(VocaMetrics.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.vocaRecessedSurface,
            in: RoundedRectangle(cornerRadius: VocaMetrics.cardRadius, style: .continuous)
        )
        .accessibilityElement(children: .combine)
    }
}

/// Compact brand waveform on the welcome screen. No caption — the bars
/// are the whole visual.
private struct OnboardingWelcomeVisual: View {
    let reduceMotion: Bool

    static let height: CGFloat = 56

    @State private var origin = Date()

    private static let barCount = 21
    private static let barWidth: CGFloat = 4
    private static let barSpacing: CGFloat = 3
    private static let waveformHeight: CGFloat = 56
    private static let minBarHeight: CGFloat = 8
    /// ~1.5× slower than the original 3.1 / 7.4 oscillators.
    private static let timeScale: Double = 0.68

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 60 : 1 / 24, paused: reduceMotion)) { context in
            waveform(at: context.date.timeIntervalSince(origin))
                .frame(height: Self.waveformHeight)
        }
        .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sound waveform")
    }

    private func waveform(at time: TimeInterval) -> some View {
        HStack(alignment: .center, spacing: Self.barSpacing) {
            ForEach(0..<Self.barCount, id: \.self) { index in
                Capsule()
                    .fill(Color.brand)
                    .frame(width: Self.barWidth, height: barHeight(for: index, at: time))
            }
        }
    }

    private func barHeight(for index: Int, at time: TimeInterval) -> CGFloat {
        let position = CGFloat(index) / CGFloat(Self.barCount - 1)
        let envelope = 0.32 + 0.68 * sin(position * .pi)
        let range = Self.waveformHeight - Self.minBarHeight
        if reduceMotion {
            return Self.minBarHeight + range * envelope * 0.55
        }
        let t = time * Self.timeScale
        let speak = 0.52 + 0.48 * sin(t * 3.1 + Double(position) * 6.8)
        let detail = 0.85 + 0.15 * sin(t * 7.4 + Double(index) * 1.7)
        return Self.minBarHeight + range * envelope * CGFloat(speak * detail)
    }
}

#if DEBUG

#Preview("Onboarding — welcome") {
    PreviewHost(
        coordinator: RecordingCoordinator(preview: nil, setupStatus: PreviewFixtures.setupFresh),
        hasDictatedOnce: false
    ) {
        SetupView()
    }
}

#Preview("Onboarding — keyboard") {
    PreviewHost(
        coordinator: RecordingCoordinator(
            preview: nil,
            setupStatus: PreviewFixtures.setupKeyboardNeedsFullAccess,
            models: LocalModelManager(preview: [PreviewFixtures.firstModelID])
        )
    ) {
        SetupView()
    }
}

#Preview("Onboarding — matrix", traits: .sizeThatFitsLayout) {
    PreviewMatrix(
        coordinator: RecordingCoordinator(
            preview: nil,
            setupStatus: PreviewFixtures.setupKeyboardNeedsFullAccess,
            models: LocalModelManager(preview: [PreviewFixtures.firstModelID])
        )
    ) {
        SetupView()
    }
}
#endif
