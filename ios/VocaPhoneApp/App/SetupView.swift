import SwiftUI
import UIKit

/// Whether setup is being shown as the first-run experience or reopened from
/// Settings. A configured user should see a useful status overview, never an
/// unexpected replay of the welcome lesson.
enum SetupViewMode {
    case onboarding
    case review
}

/// Focused iOS setup. Each page owns one action and reconciles against the real
/// state from `SetupStatus`; no Continue button can manufacture a permission,
/// model, keyboard, or transcript that has not actually worked.
struct SetupView: View {
    @Environment(RecordingCoordinator.self) private var coordinator
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let mode: SetupViewMode

    @AppStorage(
        KeyboardPreferences.setupCompletedKey,
        store: KeyboardPreferences.defaults
    ) private var setupCompleted = false
    @AppStorage(
        KeyboardPreferences.onboardingStageKey,
        store: KeyboardPreferences.defaults
    ) private var persistedStageRaw = OnboardingStage.welcome.rawValue
    @AppStorage(
        KeyboardPreferences.keyboardPracticeKey,
        store: KeyboardPreferences.defaults
    ) private var hasCompletedKeyboardPractice = false
    @AppStorage(
        LocalTranscriptionPreferences.enabledKey,
        store: UserDefaults(suiteName: AppConfiguration.appGroupIdentifier)
    ) private var localTranscriptionEnabled = false

    @State private var stage = OnboardingStage.welcome
    @State private var isShowingFlow: Bool
    @State private var hasInitialized = false
    @State private var keyboardProbeText = ""
    @State private var practiceText = ""
    @FocusState private var keyboardProbeFocused: Bool
    @FocusState private var practiceFocused: Bool
    @State private var hasAskedAboutReporting = UserDefaultsTelemetryPreferences().hasBeenAsked
    @State private var hasCopiedSettingsPath = false
    @AppStorage(
        KeyboardPreferences.keyboardSettingsRoundTripKey,
        store: KeyboardPreferences.defaults
    ) private var keyboardSettingsRoundTripStarted = false

    private let telemetryPreferences = UserDefaultsTelemetryPreferences()

    init(mode: SetupViewMode = .review) {
        self.mode = mode
        _isShowingFlow = State(initialValue: mode == .onboarding)
    }

    private var status: SetupStatus { coordinator.setupStatus }
    private var proofCount: Int {
        OnboardingPresentation.completedProofCount(
            status: status,
            hasCompletedKeyboardPractice: hasCompletedKeyboardPractice
        )
    }
    private var proofProgress: Double {
        OnboardingPresentation.progress(
            status: status,
            hasCompletedKeyboardPractice: hasCompletedKeyboardPractice
        )
    }

    var body: some View {
        Group {
            if isShowingFlow {
                onboardingBody
            } else {
                overviewBody
            }
        }
        .background(Color.vocaCanvas)
        .navigationTitle(isShowingFlow ? "Set up vocaphone" : "Guided setup")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(mode == .onboarding && requiresMandatorySetup)
        .toolbar { toolbarContent }
        .task {
            // Establish the saved page immediately. A slow gateway health
            // check must not make a relaunch look as though setup restarted.
            coordinator.refreshSetupStatus()
            initializeIfNeeded()
            await coordinator.refreshGatewayHealth()
        }
        .task(id: keyboardWatchID) {
            await watchForTheKeyboard()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UITextInputMode.currentInputModeDidChangeNotification
            )
        ) { _ in
            coordinator.refreshSetupStatus()
        }
        .onChange(of: scenePhase) { previousPhase, currentPhase in
            guard previousPhase != .active, currentPhase == .active else { return }
            Task { await refreshAfterForegroundReturn() }
        }
        .onChange(of: localTranscriptionEnabled) { _, _ in
            coordinator.refreshSetupStatus()
        }
        .onChange(of: hasCompletedKeyboardPractice) { _, complete in
            guard complete, stage == .practice else { return }
            UIAccessibility.post(
                notification: .announcement,
                argument: "Your words were inserted through the vocaphone keyboard."
            )
        }
        .onChange(of: stage) { _, newStage in
            guard mode == .onboarding, requiresMandatorySetup else { return }
            persistedStageRaw = newStage.rawValue
        }
    }

    // MARK: - First-run flow

    private var onboardingBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VocaMetrics.grouping) {
                if stage.showsProofProgress { progressHeader }

                stageBody
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(stage)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))

                if stage != .complete {
                    Label("Required once to use dictation", systemImage: "checkmark.shield")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("These setup steps are required once to use dictation.")
                }
            }
            .padding(.horizontal, VocaMetrics.padding)
            .padding(.vertical, VocaMetrics.grouping)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var progressHeader: some View {
        VStack(alignment: .leading, spacing: VocaMetrics.related) {
            HStack {
                Label("Required setup", systemImage: "checkmark.shield")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("Step \(stage.requiredStepNumber ?? 1) of \(OnboardingStage.requiredStepCount)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ProgressView(
                value: Double(stage.requiredStepNumber ?? 1),
                total: Double(OnboardingStage.requiredStepCount)
            )
                .accessibilityLabel("Setup progress")
                .accessibilityValue(
                    "Step \(stage.requiredStepNumber ?? 1) of \(OnboardingStage.requiredStepCount)"
                )
            HStack(spacing: 6) {
                ForEach(1...OnboardingStage.requiredStepCount, id: \.self) { number in
                    Capsule()
                        .fill(number <= (stage.requiredStepNumber ?? 1) ? Color.brand : Color.vocaBorder)
                        .frame(maxWidth: .infinity, minHeight: 5, maxHeight: 5)
                }
            }
            .accessibilityHidden(true)
        }
        .padding(VocaMetrics.padding)
        .background(
            Color.vocaSurface,
            in: RoundedRectangle(cornerRadius: VocaMetrics.cardRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: VocaMetrics.cardRadius, style: .continuous)
                .strokeBorder(Color.vocaBorder, lineWidth: 1)
        )
    }

    @ViewBuilder private var stageBody: some View {
        switch stage {
        case .welcome:
            welcomeStage
        case .handoff:
            handoffStage
        case .source:
            sourceStage
        case .microphone:
            microphoneStage
        case .keyboard:
            keyboardStage
        case .keyboardSwitch:
            keyboardSwitchStage
        case .practice:
            practiceStage
        case .complete:
            completionStage
        }
    }

    private var welcomeStage: some View {
        OnboardingPage {
            OnboardingWelcomeVisual(reduceMotion: reduceMotion)
            Text("Dictate into any app")
                .font(.largeTitle.weight(.bold))
            Text(
                "Speak naturally, then place the finished text at your cursor with the vocaphone keyboard."
            )
            .font(.body)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            OnboardingFactRow(symbol: "lock", text: "Choose on-device speech to text or your own gateway.")
            OnboardingFactRow(symbol: "text.cursor", text: "Insert text directly where you are typing.")
            OnboardingFactRow(symbol: "keyboard", text: "Keep a familiar keyboard for everyday typing.")

            VocaPrimaryButton(title: "See how it works", symbol: "arrow.right", action: advance)
        }
    }

    private var handoffStage: some View {
        OnboardingPage {
            SwipeBackCoach(reduceMotion: reduceMotion, compact: true)
            Text("The keyboard and app work together")
                .font(.title.weight(.bold))
            Text(
                "Tap Dictate in the keyboard. vocaphone opens and records, then you swipe back to finish and insert from the keyboard."
            )
            .font(.body)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            VocaCard(padding: VocaMetrics.padding) {
                Label(
                    "iOS keyboards cannot use the microphone directly, so recording happens in vocaphone.",
                    systemImage: "info.circle"
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            VocaPrimaryButton(title: "Set up dictation", symbol: "arrow.right", action: advance)
        }
    }

    private var sourceStage: some View {
        OnboardingPage {
            Image(systemName: "waveform.badge.magnifyingglass")
                .font(.system(size: 48, weight: .medium))
                .foregroundStyle(Color.brand)
                .accessibilityHidden(true)
            Text("Choose where speech becomes text")
                .font(.title.weight(.bold))
            Text("Both routes are private by design. Choose the one you want to use first.")
                .font(.body)
                .foregroundStyle(.secondary)

            SourceChoiceCard(
                title: "On this iPhone",
                detail: "Audio and the speech-to-text model stay on this iPhone after the model is downloaded.",
                symbol: "iphone",
                isSelected: localTranscriptionEnabled
            ) {
                localTranscriptionEnabled = true
            }

            SourceChoiceCard(
                title: "Your gateway",
                detail: "Audio goes to the gateway you configured. It runs the speech-to-text model and returns text.",
                symbol: "server.rack",
                isSelected: !localTranscriptionEnabled
            ) {
                localTranscriptionEnabled = false
            }

            if localTranscriptionEnabled {
                NavigationLink {
                    OnDeviceModelSetupView()
                } label: {
                    Label(
                        status.source.isReady ? "Review speech-to-text model" : "Choose a speech-to-text model",
                        systemImage: "arrow.down.circle"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            } else {
                NavigationLink {
                    GatewaySetupView()
                } label: {
                    Label(
                        status.source.isReady ? "Review your gateway" : "Pair or configure your gateway",
                        systemImage: "arrow.right"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            if status.isSatisfied(.source) {
                CompletionNotice("Speech-to-text is ready")
                VocaPrimaryButton(title: "Continue", symbol: "arrow.right", action: advance)
            } else {
                Text(status.detail(for: .source))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var microphoneStage: some View {
        OnboardingPage {
            Image(systemName: status.microphone == .granted ? "mic.badge.checkmark" : "mic")
                .font(.system(size: 50, weight: .medium))
                .foregroundStyle(status.microphone == .granted ? Color.brand : Color.vocaRecording)
                .accessibilityHidden(true)
            Text("Allow recording on this iPhone")
                .font(.title.weight(.bold))
            Text(
                "vocaphone records in the app because iOS keyboards cannot access the microphone. Your selected route decides where the recording is processed."
            )
            .font(.body)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            switch status.microphone {
            case .granted:
                CompletionNotice("Microphone ready")
                VocaPrimaryButton(title: "Continue", symbol: "arrow.right", action: advance)
            case .undetermined:
                VocaPrimaryButton(
                    title: "Allow microphone access",
                    symbol: "mic.fill",
                    action: coordinator.requestMicrophonePermission
                )
            case .denied:
                VocaCard {
                    VStack(alignment: .leading, spacing: VocaMetrics.related) {
                        Text("Microphone access is off")
                            .font(.headline)
                        Text(
                            "iOS shows its permission prompt only once. Turn the Microphone setting back on for vocaphone, then return here."
                        )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                }
                VocaPrimaryButton(title: "Open vocaphone Settings", symbol: "gear", action: openSystemSettings)
            }
        }
    }

    private var keyboardStage: some View {
        OnboardingPage {
            Image(systemName: "keyboard")
                .font(.system(size: 48, weight: .medium))
                .foregroundStyle(Color.brand)
                .accessibilityHidden(true)
            Text("Enable the vocaphone keyboard")
                .font(.title.weight(.bold))
            Text(
                "Add vocaphone, then turn on Full Access. The next screen will show you how to switch to it."
            )
            .font(.body)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: VocaMetrics.related) {
                SettingsReferenceCard(
                    number: 1,
                    title: "Add the keyboard",
                    detail: "Settings → General → Keyboard → Keyboards → Add New Keyboard → vocaphone",
                    symbol: "keyboard"
                )
                SettingsReferenceCard(
                    number: 2,
                    title: "Allow Full Access",
                    detail: "Tap vocaphone in the Keyboards list, then turn on Allow Full Access.",
                    symbol: "checkmark.shield"
                )
            }

            VocaPrimaryButton(title: "Open vocaphone Settings", symbol: "gear", action: openSystemSettings)
            Button(action: copySettingsPath) {
                Label(
                    hasCopiedSettingsPath ? "Settings path copied" : "Copy Settings path",
                    systemImage: hasCopiedSettingsPath ? "checkmark" : "doc.on.doc"
                )
            }
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: VocaMetrics.minimumTarget)

            if status.isSatisfied(.keyboard) {
                CompletionNotice("Full Access is already verified")
                VocaPrimaryButton(
                    title: "Continue to keyboard switch",
                    symbol: "arrow.right",
                    action: advance
                )
            } else if status.isKeyboardInstalled == true {
                // Being in the keyboard list is observable; Full Access is not.
                // Say only the part we actually checked — the next page is what
                // proves the rest.
                CompletionNotice("vocaphone is in your keyboard list")
                VocaCard(padding: VocaMetrics.padding) {
                    Label(
                        "Full Access cannot be checked from here. iOS confirms it only once vocaphone opens as the keyboard, which the next step walks you through.",
                        systemImage: "checkmark.shield"
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                VocaPrimaryButton(
                    title: "Continue to keyboard switch",
                    symbol: "arrow.right",
                    action: advance
                )
            } else if status.isKeyboardInstalled == nil, keyboardSettingsRoundTripStarted {
                // iOS did not publish the keyboard list, so there is nothing to
                // check against. Blocking here would strand the user.
                VocaCard(padding: VocaMetrics.padding) {
                    Label(
                        "iOS did not report your keyboard list, so this cannot be confirmed here. The next step verifies Full Access for real.",
                        systemImage: "questionmark.circle"
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                VocaPrimaryButton(
                    title: "Continue to keyboard switch",
                    symbol: "arrow.right",
                    action: advance
                )
            } else {
                Button(action: {}) {
                    Label("Add the keyboard to continue", systemImage: "lock.fill")
                        .frame(maxWidth: .infinity, minHeight: VocaMetrics.minimumTarget)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(true)

                if keyboardSettingsRoundTripStarted {
                    Text("vocaphone is not in your keyboard list yet. In Settings, use Add New Keyboard to add it, then turn on Allow Full Access.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    // iOS can publish the keyboard list a moment behind the
                    // change. Without this the page would look like a dead end
                    // to someone who has in fact just added the keyboard.
                    Button("Check again") {
                        Task { await refreshAfterForegroundReturn() }
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: VocaMetrics.minimumTarget)
                }
            }
        }
    }

    private var keyboardSwitchStage: some View {
        OnboardingPage {
            Text("Switch to vocaphone")
                .font(.title.weight(.bold))
            Text("Tap the field, hold the globe, then choose vocaphone. This confirms Full Access automatically.")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            KeyboardSwitchCoach(reduceMotion: reduceMotion)

            VStack(alignment: .leading, spacing: VocaMetrics.related) {
                Label("Try it now", systemImage: "hand.tap")
                    .font(.headline)

                TextField("Tap here to show the keyboard", text: $keyboardProbeText, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .textFieldStyle(.plain)
                    .padding(VocaMetrics.padding)
                    .background(
                        Color.vocaSurface,
                        in: RoundedRectangle(cornerRadius: VocaMetrics.fieldRadius, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: VocaMetrics.fieldRadius, style: .continuous)
                            .strokeBorder(keyboardProbeFocused ? Color.brand : Color.vocaBorder, lineWidth: 2)
                    )
                    .focused($keyboardProbeFocused)

                Button {
                    keyboardProbeFocused = true
                } label: {
                    Label("Open the keyboard", systemImage: "keyboard")
                        .frame(maxWidth: .infinity, minHeight: VocaMetrics.minimumTarget)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .padding(VocaMetrics.padding)
            .background(
                Color.vocaRecessedSurface,
                in: RoundedRectangle(cornerRadius: VocaMetrics.cardRadius, style: .continuous)
            )

            if status.isSatisfied(.keyboard) {
                CompletionNotice("vocaphone opened with Full Access")
                VocaPrimaryButton(title: "Continue to test dictation", symbol: "arrow.right", action: advance)
            } else {
                Label("Waiting for vocaphone to open", systemImage: "circle.dotted")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)

                // Always offer the way back. This page waits on the extension
                // running, and a keyboard that was never added — or was removed
                // again — will never make that happen, so a state-specific
                // escape hatch left those users watching a spinner forever.
                Button(keyboardSwitchReviewLabel) {
                    keyboardSettingsRoundTripStarted = false
                    stage = .keyboard
                }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: VocaMetrics.minimumTarget)
            }
        }
    }

    @ViewBuilder private var practiceStage: some View {
        OnboardingPage {
            Text("Make your first dictation")
                .font(.title.weight(.bold))
            Text(
                "Use the real field and keyboard below. The Dictate button appears after you switch to vocaphone."
            )
            .font(.body)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            DictationPracticeCoach(reduceMotion: reduceMotion)

            VStack(alignment: .leading, spacing: VocaMetrics.padding) {
                Label("Now do it yourself", systemImage: "hand.tap")
                    .font(.headline)

                TextField("Your dictated words will appear here", text: $practiceText, axis: .vertical)
                    .lineLimit(3...6)
                    .textFieldStyle(.plain)
                    .padding(VocaMetrics.padding)
                    .background(
                        Color.vocaSurface,
                        in: RoundedRectangle(cornerRadius: VocaMetrics.fieldRadius, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: VocaMetrics.fieldRadius, style: .continuous)
                            .strokeBorder(practiceFocused ? Color.brand : Color.vocaBorder, lineWidth: 2)
                    )
                    .focused($practiceFocused)

                if hasCompletedKeyboardPractice {
                    CompletionNotice("Your words were inserted successfully")
                } else if coordinator.isDictatingIntoContainingApp {
                    VStack(alignment: .leading, spacing: VocaMetrics.related) {
                        HStack {
                            Label("Speak now", systemImage: "record.circle")
                                .font(.headline)
                                .foregroundStyle(Color.vocaRecording)
                            Spacer()
                            RecordingMeter()
                                .frame(width: 108)
                        }
                        Text("When you finish speaking, return to the keyboard and tap Finish.")
                            .font(.subheadline.weight(.semibold))
                    }
                } else if let record = coordinator.activeRecord,
                          [.finalizing, .uploading, .transcribing, .readyToInsert, .inserting].contains(record.state)
                {
                    VocaStatusLine(
                        status: record.state == .readyToInsert ? .ready : .working,
                        title: practiceStateTitle(for: record),
                        detail: practiceStateDetail(for: record)
                    )
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        PracticeDirection(number: 1, text: "Tap the field to show the keyboard")
                        PracticeDirection(number: 2, text: "Choose vocaphone with the globe")
                        PracticeDirection(number: 3, text: "Tap Dictate and say a short sentence")
                    }
                    VocaPrimaryButton(title: "Start in the field", symbol: "keyboard") {
                        practiceFocused = true
                    }
                }
            }
            .padding(VocaMetrics.padding)
            .background(
                Color.vocaRecessedSurface,
                in: RoundedRectangle(cornerRadius: VocaMetrics.cardRadius, style: .continuous)
            )

            if hasCompletedKeyboardPractice {
                VocaPrimaryButton(title: "Continue", symbol: "arrow.right", action: advance)
            }
        }
    }

    @ViewBuilder private var completionStage: some View {
        OnboardingPage {
            HStack(alignment: .top, spacing: VocaMetrics.padding) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48, weight: .medium))
                    .foregroundStyle(Color.brand)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: VocaMetrics.related) {
                    Text("You're ready to dictate")
                        .font(.title.weight(.bold))
                    Text("Your first keyboard dictation was inserted successfully.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)

            VocaCard(padding: VocaMetrics.padding) {
                VStack(alignment: .leading, spacing: VocaMetrics.related) {
                    Text("In any app")
                        .font(.headline)
                    OnboardingFactRow(symbol: "globe", text: "Choose vocaphone with the globe key.")
                    OnboardingFactRow(symbol: "mic.fill", text: "Tap Dictate and speak.")
                    OnboardingFactRow(
                        symbol: "arrow.right",
                        text: "Swipe back, then tap Finish and Insert."
                    )
                }
            }

            usageReportingSection
            VocaPrimaryButton(title: "Start using vocaphone", symbol: "arrow.right", action: finishSetup)
        }
    }

    @ViewBuilder private var usageReportingSection: some View {
        if status.isReadyToDictate && !hasAskedAboutReporting {
            UsageReportingSetupSection { enabled in
                Task { await Telemetry.shared.setEnabled(enabled) }
                telemetryPreferences.hasBeenAsked = true
                hasAskedAboutReporting = true
            }
        }
    }

    // MARK: - Review

    private var overviewBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VocaMetrics.grouping) {
                VocaCard {
                    VStack(alignment: .leading, spacing: VocaMetrics.related) {
                        VocaStatusLine(
                            status: status.isReadyToDictate ? .ready : .attention,
                            title: status.isReadyToDictate ? "Ready to dictate" : "Setup needs attention",
                            detail: status.isReadyToDictate
                                ? "vocaphone will keep checking these requirements when it returns to the foreground."
                                : status.attentionDetail
                        )
                        ProgressView(value: proofProgress)
                        Text("\(proofCount) of \(SetupStep.allCases.count) steps proven")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(spacing: VocaMetrics.related) {
                    ForEach(SetupStep.allCases) { step in
                        SetupReviewCard(
                            step: step,
                            detail: reviewDetail(for: step),
                            isComplete: isCompleteForReview(step)
                        )
                    }
                }

                if hasCompletedKeyboardPractice {
                    CompletionNotice("Keyboard practice completed")
                }

                VocaPrimaryButton(
                    title: status.isReadyToDictate && hasCompletedKeyboardPractice
                        ? "Practice again"
                        : "Continue setup",
                    symbol: "arrow.right"
                ) {
                    stage = OnboardingPresentation.resumeStage(
                        status: status,
                        hasCompletedKeyboardPractice: hasCompletedKeyboardPractice
                    )
                    withAnimation(.easeInOut(duration: 0.2)) { isShowingFlow = true }
                }
            }
            .padding(VocaMetrics.padding)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Actions and state

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        if isShowingFlow, let previous = OnboardingPresentation.previousStage(before: stage) {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { stage = previous }
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
            }
        }
    }

    /// Names the reason this page is still waiting, so the way back to the
    /// Settings instructions describes the user's actual situation.
    private var keyboardSwitchReviewLabel: String {
        if status.isKeyboardInstalled == false {
            return "vocaphone is not in your keyboard list — review Settings"
        }
        if case .seenWithoutFullAccess = status.keyboard {
            return "Full Access is still off — review Settings"
        }
        return "Not working? Review the Settings steps"
    }

    private var keyboardWatchID: String {
        "\(isShowingFlow)-\(stage.rawValue)-\(status.isSatisfied(.keyboard))"
    }

    private var requiresMandatorySetup: Bool {
        OnboardingPresentation.requiresFirstRunCover(
            setupCompleted: setupCompleted,
            hasCompletedKeyboardPractice: hasCompletedKeyboardPractice
        )
    }

    private func initializeIfNeeded() {
        guard !hasInitialized else { return }
        hasInitialized = true
        stage = OnboardingPresentation.initialStage(
            setupCompleted: setupCompleted,
            persistedStage: OnboardingStage(rawValue: persistedStageRaw),
            status: status,
            hasCompletedKeyboardPractice: hasCompletedKeyboardPractice
        )
    }

    private func advance() {
        switch stage {
        case .source:
            guard status.isSatisfied(.source) else { return }
        case .microphone:
            guard status.isSatisfied(.microphone) else { return }
        case .keyboardSwitch:
            guard status.isSatisfied(.keyboard) else { return }
        case .keyboard:
            guard OnboardingPresentation.canAdvanceFromKeyboardEnablement(
                status: status,
                returnedFromSettings: keyboardSettingsRoundTripStarted
            ) else { return }
        case .practice:
            guard hasCompletedKeyboardPractice else { return }
        case .complete:
            finishSetup()
            return
        case .welcome, .handoff:
            break
        }
        guard let next = OnboardingPresentation.nextStage(after: stage) else { return }
        if stage == .keyboard {
            keyboardSettingsRoundTripStarted = false
        }
        withAnimation(.snappy(duration: 0.32)) { stage = next }
        UIAccessibility.post(notification: .screenChanged, argument: nil)
    }

    private func finishSetup() {
        guard status.isReadyToDictate, hasCompletedKeyboardPractice else { return }
        setupCompleted = true
        persistedStageRaw = OnboardingStage.complete.rawValue
        keyboardSettingsRoundTripStarted = false
        Telemetry.shared.setupFinished()
        dismiss()
    }

    private func refresh() async {
        coordinator.refreshSetupStatus()
        await coordinator.refreshGatewayHealth()
    }

    private func refreshAfterForegroundReturn() async {
        coordinator.refreshSetupStatus()

        // iOS can publish a changed permission or keyboard list just after the
        // app becomes active. Re-read briefly so the first return updates in
        // place instead of requiring another trip through Settings.
        for delay in [180, 420, 800] {
            try? await Task.sleep(for: .milliseconds(delay))
            guard !Task.isCancelled else { return }
            coordinator.refreshSetupStatus()
        }

        await coordinator.refreshGatewayHealth()
    }

    private func watchForTheKeyboard() async {
        guard isShowingFlow, stage == .keyboardSwitch, !status.isSatisfied(.keyboard) else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(400))
            coordinator.refreshSetupStatus()
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        if stage == .keyboard {
            keyboardSettingsRoundTripStarted = true
        }
        UIApplication.shared.open(url)
    }

    private func copySettingsPath() {
        UIPasteboard.general.string = AppConfiguration.fullAccessSettingsPath
        hasCopiedSettingsPath = true
    }

    private func isCompleteForReview(_ step: SetupStep) -> Bool {
        step == .firstDictation ? hasCompletedKeyboardPractice : status.isSatisfied(step)
    }

    private func reviewDetail(for step: SetupStep) -> String {
        if step == .firstDictation {
            return hasCompletedKeyboardPractice
                ? "A transcript was inserted through the vocaphone keyboard."
                : "Try a real keyboard dictation to prove the full loop."
        }
        return status.detail(for: step)
    }

    private func practiceStateTitle(for record: SessionRecord) -> String {
        switch record.state {
        case .finalizing: "Finishing recording"
        case .uploading:
            record.processingLocation == .gateway ? "Sending to your gateway" : "Preparing on this iPhone"
        case .transcribing:
            record.processingLocation == .gateway ? "Transcribing on your gateway" : "Transcribing on this iPhone"
        case .readyToInsert: "Your text is ready"
        case .inserting: "Inserting text"
        default: record.state.displayName
        }
    }

    private func practiceStateDetail(for record: SessionRecord) -> String? {
        switch record.state {
        case .readyToInsert: "Tap Insert in the keyboard to place your words in the field above."
        case .inserting: "Placing your words at the cursor."
        default: record.processingLocation == .onDevice
            ? "The speech-to-text model is running on this iPhone."
            : record.processingLocation == .gateway
                ? "Your gateway is running its speech-to-text model."
                : nil
        }
    }
}

// MARK: - Focused setup components

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

private struct OnboardingFactRow: View {
    let symbol: String
    let text: String

    var body: some View {
        Label {
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(Color.brand)
        }
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

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: VocaMetrics.padding) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.brand : .secondary)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.brand : .secondary)
                    .accessibilityHidden(true)
            }
            .padding(VocaMetrics.padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? Color.brand.opacity(0.08) : Color.vocaRecessedSurface,
                in: RoundedRectangle(cornerRadius: VocaMetrics.cardRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: VocaMetrics.cardRadius, style: .continuous)
                    .strokeBorder(isSelected ? Color.brand : Color.vocaBorder, lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }
}

private struct SettingsReferenceCard: View {
    let number: Int
    let title: String
    let detail: String
    let symbol: String

    var body: some View {
        HStack(alignment: .top, spacing: VocaMetrics.padding) {
            Text("\(number)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(Color.onBrand)
                .frame(width: 28, height: 28)
                .background(Color.brand, in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Label(title, systemImage: symbol)
                    .font(.headline)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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

private struct SetupReviewCard: View {
    let step: SetupStep
    let detail: String
    let isComplete: Bool

    var body: some View {
        VocaCard {
            HStack(alignment: .top, spacing: VocaMetrics.related + 2) {
                Image(systemName: isComplete ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isComplete ? Color.brand : .secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(step.title)
                        .font(.headline)
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(isComplete ? "Done" : "Needs attention")
    }
}

private struct OnDeviceModelSetupView: View {
    @Environment(RecordingCoordinator.self) private var coordinator

    var body: some View {
        List {
            LocalModelPicker(manager: coordinator.localModels) {
                coordinator.refreshSetupStatus()
            }
        }
        .navigationTitle("Speech-to-text model")
        .navigationBarTitleDisplayMode(.inline)
        .task { coordinator.refreshSetupStatus() }
    }
}

private struct OnboardingWelcomeVisual: View {
    let reduceMotion: Bool
    @State private var textAppeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: VocaMetrics.related) {
            HStack(spacing: 4) {
                ForEach(0..<12, id: \.self) { index in
                    Capsule()
                        .fill(Color.brand.opacity(textAppeared ? 0.35 : 0.85))
                        .frame(width: 4, height: CGFloat(8 + (index % 5) * 5))
                }
            }
            Text("Meet me by the station at six.")
                .font(.body)
                .foregroundStyle(textAppeared ? Color.vocaPrimaryText : .clear)
            Rectangle()
                .fill(Color.brand)
                .frame(width: 2, height: 20)
                .opacity(textAppeared ? 1 : 0)
        }
        .padding(VocaMetrics.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.vocaRecessedSurface,
            in: RoundedRectangle(cornerRadius: VocaMetrics.cardRadius, style: .continuous)
        )
        .task {
            guard !reduceMotion else {
                textAppeared = true
                return
            }
            try? await Task.sleep(for: .milliseconds(320))
            withAnimation(.easeInOut(duration: 0.2)) { textAppeared = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("A short waveform becomes text at the cursor.")
    }
}

private struct KeyboardSwitchCoach: View {
    private enum Step: Int, CaseIterable, Identifiable {
        case field
        case globe
        case vocaphone

        var id: Int { rawValue }

        var number: Int { rawValue + 1 }

        var title: String {
            switch self {
            case .field: "Tap the text field"
            case .globe: "Touch and hold the globe"
            case .vocaphone: "Choose vocaphone"
            }
        }

        var detail: String {
            switch self {
            case .field: "The keyboard appears at the bottom of the screen."
            case .globe: "Keep holding until the keyboard list opens."
            case .vocaphone: "Slide to vocaphone, then lift your finger."
            }
        }
    }

    let reduceMotion: Bool

    @State private var step = Step.field
    @State private var replayID = 0

    var body: some View {
        VStack(alignment: .leading, spacing: VocaMetrics.padding) {
            HStack(alignment: .firstTextBaseline) {
                Text(step.title)
                    .font(.title3.weight(.bold))
                    .contentTransition(.opacity)
                Spacer()
                Button {
                    replayID += 1
                } label: {
                    Label("Replay", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                        .frame(width: VocaMetrics.minimumTarget, height: VocaMetrics.minimumTarget)
                }
                .accessibilityLabel("Replay keyboard switch demonstration")
            }

            Text(step.detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)

            GeometryReader { proxy in
                let width = proxy.size.width
                let height = proxy.size.height

                ZStack {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(Color.vocaSurface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 28, style: .continuous)
                                .strokeBorder(Color.vocaBorder, lineWidth: 2)
                        )

                    VStack(spacing: 0) {
                        HStack(spacing: 5) {
                            Text(step == .field ? "Tap to type" : "Cursor is ready")
                                .font(.subheadline)
                                .foregroundStyle(step == .field ? .secondary : Color.vocaPrimaryText)
                            Rectangle()
                                .fill(Color.brand)
                                .frame(width: 2, height: 20)
                                .opacity(step == .field ? 0 : 1)
                            Spacer()
                        }
                        .padding(.horizontal, VocaMetrics.padding)
                        .frame(height: 52)
                        .background(
                            step == .field ? Color.brand.opacity(0.1) : Color.vocaRecessedSurface,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(step == .field ? Color.brand : Color.vocaBorder, lineWidth: 2)
                        )
                        .padding(VocaMetrics.padding)

                        Spacer(minLength: 8)
                        simulatedKeyboard
                    }

                    if step != .field {
                        keyboardMenu
                            .frame(width: min(width * 0.58, 220))
                            .offset(x: -width * 0.12, y: height * 0.05)
                            .transition(.scale(scale: 0.86, anchor: .bottomLeading).combined(with: .opacity))
                    }

                    gestureMarker
                        .offset(markerOffset(width: width, height: height))
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: advanceDemo)
            }
            .frame(height: 250)

            HStack(spacing: 8) {
                ForEach(Step.allCases) { candidate in
                    Capsule()
                        .fill(candidate == step ? Color.brand : Color.vocaBorder)
                        .frame(width: candidate == step ? 30 : 8, height: 8)
                        .animation(.snappy(duration: 0.25), value: step)
                }
            }
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
        }
        .padding(VocaMetrics.padding)
        .background(
            Color.vocaRecessedSurface,
            in: RoundedRectangle(cornerRadius: VocaMetrics.cardRadius, style: .continuous)
        )
        .task(id: replayID) {
            guard !reduceMotion else {
                step = .vocaphone
                return
            }
            step = .field
            for candidate in [Step.globe, .vocaphone] {
                try? await Task.sleep(for: .milliseconds(candidate == .globe ? 900 : 1_150))
                guard !Task.isCancelled else { return }
                withAnimation(.snappy(duration: 0.42)) { step = candidate }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(step.number) of 3. \(step.title). \(step.detail)")
        .accessibilityAction(named: "Next step", advanceDemo)
    }

    private var simulatedKeyboard: some View {
        VStack(spacing: 7) {
            ForEach(0..<2, id: \.self) { row in
                HStack(spacing: 6) {
                    ForEach(0..<(row == 0 ? 8 : 7), id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.vocaSurface)
                            .frame(height: 28)
                    }
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "globe")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(step == .globe ? Color.onBrand : Color.vocaPrimaryText)
                    .frame(width: 48, height: 38)
                    .background(
                        step == .globe ? Color.brand : Color.vocaSurface,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .scaleEffect(step == .globe ? 1.12 : 1)
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.vocaSurface)
                    .overlay(Text("space").font(.caption).foregroundStyle(.secondary))
                    .frame(maxWidth: .infinity, minHeight: 38)
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.vocaSurface)
                    .frame(width: 54, height: 38)
            }
        }
        .padding(10)
        .background(Color.vocaBorder.opacity(0.65))
    }

    private var keyboardMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("English", systemImage: "keyboard")
                .foregroundStyle(.secondary)
                .padding(12)
            Label("vocaphone", systemImage: step == .vocaphone ? "checkmark" : "keyboard")
                .fontWeight(.semibold)
                .foregroundStyle(step == .vocaphone ? Color.onBrand : Color.vocaPrimaryText)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(step == .vocaphone ? Color.brand : Color.vocaSurface)
        }
        .font(.subheadline)
        .background(
            Color.vocaSurface,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.vocaBorder, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.16), radius: 12, y: 5)
    }

    private var gestureMarker: some View {
        ZStack {
            Circle()
                .fill(Color.brand.opacity(0.18))
                .frame(width: 64, height: 64)
            Circle()
                .fill(Color.brand)
                .frame(width: 44, height: 44)
            Image(systemName: step == .globe ? "hand.tap.fill" : "hand.point.up.left.fill")
                .foregroundStyle(Color.onBrand)
        }
        .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
        .allowsHitTesting(false)
    }

    private func markerOffset(width: CGFloat, height: CGFloat) -> CGSize {
        switch step {
        case .field:
            CGSize(width: width * 0.24, height: -height * 0.31)
        case .globe:
            CGSize(width: -width * 0.37, height: height * 0.34)
        case .vocaphone:
            CGSize(width: -width * 0.03, height: height * 0.03)
        }
    }

    private func advanceDemo() {
        let next = Step(rawValue: (step.rawValue + 1) % Step.allCases.count) ?? .field
        withAnimation(.snappy(duration: 0.36)) { step = next }
    }
}

private struct PracticeDirection: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: VocaMetrics.related) {
            Text("\(number)")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(Color.onBrand)
                .frame(width: 24, height: 24)
                .background(Color.brand, in: Circle())
            Text(text)
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct DictationPracticeCoach: View {
    private enum Phase: Int, CaseIterable, Identifiable {
        case field
        case keyboard
        case dictate
        case finish

        var id: Int { rawValue }
        var number: Int { rawValue + 1 }

        var title: String {
            switch self {
            case .field: "Tap the real field below"
            case .keyboard: "Choose vocaphone"
            case .dictate: "Tap Dictate in the keyboard"
            case .finish: "Speak, return, then finish"
            }
        }

        var detail: String {
            switch self {
            case .field: "This opens the actual iOS keyboard."
            case .keyboard: "Hold the globe and select vocaphone if it is not already visible."
            case .dictate: "The Dictate button exists inside the vocaphone keyboard—not on this screen."
            case .finish: "Swipe back, tap Finish, then Insert to put your words in the field."
            }
        }

        var symbol: String {
            switch self {
            case .field: "text.cursor"
            case .keyboard: "globe"
            case .dictate: "mic.fill"
            case .finish: "checkmark.circle.fill"
            }
        }
    }

    let reduceMotion: Bool

    @State private var phase = Phase.field
    @State private var replayID = 0

    var body: some View {
        VStack(alignment: .leading, spacing: VocaMetrics.padding) {
            HStack(alignment: .firstTextBaseline) {
                Label("Follow these steps below", systemImage: "keyboard")
                    .font(.headline)
                Spacer()
                Button {
                    replayID += 1
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: VocaMetrics.minimumTarget, height: VocaMetrics.minimumTarget)
                }
                .accessibilityLabel("Replay dictation demonstration")
            }

            HStack(alignment: .top, spacing: VocaMetrics.padding) {
                ZStack {
                    Circle()
                        .fill(Color.brand)
                        .frame(width: 54, height: 54)
                    Image(systemName: phase.symbol)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(Color.onBrand)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Step \(phase.number) of \(Phase.allCases.count)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.brand)
                    Text(phase.title)
                        .font(.title3.weight(.bold))
                        .contentTransition(.opacity)
                    Text(phase.detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 126, alignment: .topLeading)
            .padding(VocaMetrics.padding)
            .background(
                Color.vocaSurface,
                in: RoundedRectangle(cornerRadius: VocaMetrics.cardRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: VocaMetrics.cardRadius, style: .continuous)
                    .strokeBorder(Color.brand.opacity(0.45), lineWidth: 2)
            )

            HStack(spacing: 8) {
                ForEach(Phase.allCases) { candidate in
                    Capsule()
                        .fill(candidate == phase ? Color.brand : Color.vocaBorder)
                        .frame(width: candidate == phase ? 30 : 8, height: 8)
                        .animation(.snappy(duration: 0.25), value: phase)
                }
            }
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)

            Label(
                "All taps happen in the field or keyboard below—this card only shows the order.",
                systemImage: "arrow.down"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(VocaMetrics.padding)
        .background(
            Color.vocaRecessedSurface,
            in: RoundedRectangle(cornerRadius: VocaMetrics.cardRadius, style: .continuous)
        )
        .task(id: replayID) {
            guard !reduceMotion else {
                phase = .dictate
                return
            }
            phase = .field
            for candidate in [Phase.keyboard, .dictate, .finish] {
                try? await Task.sleep(for: .milliseconds(1_350))
                guard !Task.isCancelled else { return }
                withAnimation(.snappy(duration: 0.42)) { phase = candidate }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(phase.number) of 4. \(phase.title). \(phase.detail)")
    }
}

#if DEBUG

#Preview("Onboarding — welcome") {
    PreviewHost(
        coordinator: RecordingCoordinator(preview: nil, setupStatus: PreviewFixtures.setupFresh),
        hasDictatedOnce: false
    ) {
        NavigationStack { SetupView(mode: .onboarding) }
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
        NavigationStack { SetupView(mode: .review) }
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
        NavigationStack { SetupView(mode: .review) }
    }
}
#endif
