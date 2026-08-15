import SwiftUI
import UIKit

/// Guided setup.
///
/// The dominant failure mode for this app is an unfinished setup spread across
/// iOS Settings, a self-hosted gateway and two permission prompts — none of
/// which the app can complete on the user's behalf. So every step says what the
/// access is for and carries the button that starts it.
///
/// None of those steps report back when they are finished, and the keyboard one
/// completes while this screen is still on top, so the state is re-read from
/// three angles: on return to the foreground, on a keyboard switch, and on a
/// short poll while the keyboard step is outstanding.
struct SetupView: View {
    @Environment(RecordingCoordinator.self) private var coordinator
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @AppStorage(
        KeyboardPreferences.setupCompletedKey,
        store: KeyboardPreferences.defaults
    ) private var setupCompleted = false
    @AppStorage(
        LocalTranscriptionPreferences.enabledKey,
        store: UserDefaults(suiteName: AppConfiguration.appGroupIdentifier)
    ) private var localTranscriptionEnabled = false
    @State private var keyboardProbeText = ""
    @State private var typingProbeText = ""

    private var status: SetupStatus { coordinator.setupStatus }

    var body: some View {
        List {
            introSection
            sourceSection
            stepsSection
            finishSection
            privacySection
        }
        .navigationTitle("Set up vocaphone")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            coordinator.refreshSetupStatus()
            await coordinator.refreshGatewayHealth()
        }
        .task(id: status.isSatisfied(.keyboard)) {
            await watchForTheKeyboard()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UITextInputMode.currentInputModeDidChangeNotification
            )
        ) { _ in
            // Switching into the vocaphone keyboard happens without the app
            // ever leaving the foreground. This is the only signal iOS gives
            // for it, and it lands before the poll would notice.
            coordinator.refreshSetupStatus()
        }
        .onChange(of: scenePhase) { previousPhase, currentPhase in
            // Every step here is finished somewhere else — iOS Settings, a
            // permission alert, the keyboard itself — so returning is the only
            // reliable moment to re-read them.
            guard previousPhase != .active, currentPhase == .active else { return }
            coordinator.refreshSetupStatus()
            Task { await coordinator.refreshGatewayHealth() }
        }
        .onChange(of: localTranscriptionEnabled) { _, _ in
            coordinator.refreshSetupStatus()
        }
    }

    // MARK: - Sections

    private var introSection: some View {
        Section {
            VStack(alignment: .leading, spacing: VocaMetrics.related) {
                BrandMark(size: 36)
                    .padding(.bottom, 2)
                Text("Dictate into any app")
                    .font(.title3.weight(.semibold))
                Text(
                    "vocaphone records on this iPhone and turns it into text either "
                        + "here on the phone or on a gateway you run yourself. Nothing "
                        + "goes to a third-party transcription service. Four steps and "
                        + "you are done."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, VocaMetrics.tight)
            .accessibilityElement(children: .combine)

            VStack(alignment: .leading, spacing: VocaMetrics.related) {
                Text("\(status.completedStepCount) of \(status.stepCount) steps done")
                    .font(.subheadline.weight(.semibold))
                // No completion colour of its own: the app's tint *is* the
                // "this is fine" colour now, so switching to a second green at
                // 100% only said that two greens exist.
                ProgressView(value: status.progress)
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: - Step 1: a choice, not two requirements

    /// Both routes are real and either one finishes the step, so they are
    /// presented as a segmented choice with the selected one's own setup below
    /// it. The previous screen showed the gateway as the step and the on-device
    /// model as a smaller alternative underneath, which read as "the gateway is
    /// required and this is a workaround".
    @ViewBuilder private var sourceSection: some View {
        Section {
            SetupStepLabel(
                step: .source,
                detail: status.detail(for: .source),
                isComplete: status.isSatisfied(.source)
            )

            Picker("Speech to text", selection: $localTranscriptionEnabled) {
                Text("On this iPhone").tag(true)
                Text("Your gateway").tag(false)
            }
            .pickerStyle(.segmented)

            Text(status.source.boundaryDetail)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !localTranscriptionEnabled {
                NavigationLink {
                    GatewaySetupView()
                } label: {
                    Label("Pair or configure your gateway", systemImage: "server.rack")
                }
            }
        } header: {
            Text("Transcription source")
        }

        // The picker brings its own sections — installed models, available
        // models, and its status line — so it sits beside this one rather than
        // inside it.
        if localTranscriptionEnabled {
            LocalModelPicker(manager: coordinator.localModels) {
                coordinator.refreshSetupStatus()
            }
        }
    }

    private var stepsSection: some View {
        Section {
            microphoneStep
            keyboardStep
            firstDictationStep
            typingStep
        } footer: {
            Text(
                "Full Access is used only to share session state with vocaphone and to "
                    + "reach the gateway you configured. The keyboard never sees what you "
                    + "type in other apps."
            )
        }
    }

    @ViewBuilder private var microphoneStep: some View {
        SetupStepLabel(
            step: .microphone,
            detail: status.detail(for: .microphone),
            isComplete: status.isSatisfied(.microphone)
        )
        switch status.microphone {
        case .undetermined:
            stepAction("Allow microphone access") {
                coordinator.requestMicrophonePermission()
            }
        case .denied:
            // iOS shows its permission alert only once, so re-prompting here
            // would do nothing at all.
            stepAction("Open iOS Settings", action: openSystemSettings)
        case .granted:
            EmptyView()
        }
    }

    @ViewBuilder private var keyboardStep: some View {
        SetupStepLabel(
            step: .keyboard,
            detail: status.detail(for: .keyboard),
            isComplete: status.isSatisfied(.keyboard)
        )

        if !status.isSatisfied(.keyboard) {
            // Not labelled as a deep link to Keyboard settings, because iOS
            // offers none: this URL opens vocaphone's own settings pane, and the
            // path below is the part that actually gets the user there.
            stepAction("Open iOS Settings", action: openSystemSettings)

            VStack(alignment: .leading, spacing: VocaMetrics.related - 2) {
                Text(AppConfiguration.fullAccessSettingsPath)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                // Two switches, named, because that screen is genuinely
                // confusing the first time: one adds the keyboard and the other
                // is a second tap *inside* it.
                VStack(alignment: .leading, spacing: 2) {
                    Label("Add “vocaphone” under Keyboards", systemImage: "1.circle")
                    Label("Tap it, then turn on “Allow Full Access”", systemImage: "2.circle")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)

                // The app is only told the keyboard exists once the extension
                // actually runs, and it only runs when it is switched to. A
                // field right here is the shortest path to that.
                TextField("Tap here, then hold 🌐 and pick vocaphone", text: $keyboardProbeText)
                    .textInputAutocapitalization(.never)
                Text("Switching to vocaphone here ticks this step automatically.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 32)
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder private var firstDictationStep: some View {
        SetupStepLabel(
            step: .firstDictation,
            detail: status.detail(for: .firstDictation),
            isComplete: status.isSatisfied(.firstDictation)
        )

        if coordinator.isRecording {
            RecordingMeter()
                .padding(.leading, 32)
            stepAction("Finish and transcribe") { coordinator.requestFinish() }
            stepAction("Cancel", role: .destructive) { coordinator.cancel() }
        } else if !status.isSatisfied(.firstDictation) {
            stepAction("Start test recording") { coordinator.startInAppTest() }
                .disabled(!canRunTestDictation)
            if !canRunTestDictation {
                Text("Finish the transcription source and microphone steps first.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 32)
            }
        }

        if let message = coordinator.message, coordinator.activeRecord != nil {
            Text(message)
                .font(.footnote)
                .foregroundStyle(coordinator.hasError ? Color.vocaError : .secondary)
                .padding(.leading, 32)
        }
    }

    /// The product's second half had no moment in onboarding at all: someone
    /// could finish setup without ever learning the keyboard completes and
    /// corrects. Optional, and last, because dictation is still the headline.
    @ViewBuilder private var typingStep: some View {
        if status.isSatisfied(.keyboard) {
            VStack(alignment: .leading, spacing: VocaMetrics.related - 2) {
                Text("Try typing")
                    .font(.subheadline.weight(.semibold))
                Text(
                    "Switch to the vocaphone keyboard here and type a few words. "
                        + "Suggestions appear in the row above the keys; tap one to "
                        + "use it, or keep typing to ignore them."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                TextField("Type a sentence", text: $typingProbeText)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(.vertical, 2)
        }
    }

    /// Indented to sit under its step's text rather than its checkmark, so a
    /// button reads as belonging to the line above it.
    private func stepAction(
        _ title: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(title, role: role, action: action)
            .padding(.leading, 32)
    }

    private var finishSection: some View {
        Section {
            Button(action: leaveSetup) {
                Text("Start dictating")
                    .frame(maxWidth: .infinity)
            }
            .brandProminentButton()
            .controlSize(.large)
            .disabled(!status.isReadyToDictate)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            if !status.isReadyToDictate {
                // Leaving has to stay possible: a gateway may be something the
                // user can only stand up later, and trapping them on this
                // screen until then helps nobody.
                Button(action: leaveSetup) {
                    Text("Skip for now")
                        .frame(maxWidth: .infinity)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        } footer: {
            if status.isReadyToDictate {
                Text(
                    status.isComplete
                        ? "Everything is ready. You can reopen this screen from Settings."
                        : "Dictation will work. The test recording is optional, but it is "
                            + "the only thing that proves the whole chain end to end."
                )
            } else {
                Text(
                    "Still to do: "
                        + status.remainingSteps.map(\.label).joined(separator: ", ")
                        + ". vocaphone will remind you on the main screen."
                )
            }
        }
    }

    /// A closing note, so it is a footer rather than a paragraph in a cell.
    private var privacySection: some View {
        Section {
        } footer: {
            Text(
                "Audio stays on this phone until transcription succeeds. A gateway "
                    + "deletes successfully transcribed audio by default. No third-party "
                    + "transcription or analytics service is involved."
            )
        }
    }

    // MARK: - Actions

    private var canRunTestDictation: Bool {
        status.isSatisfied(.source) && status.isSatisfied(.microphone)
    }

    /// The keyboard writes its status from another process into a file nothing
    /// can observe, and it does so while this app is still in the foreground —
    /// so waiting for a scene-phase change leaves the step stuck on screen
    /// long after it is actually done. Re-reading it costs one small file read,
    /// and only runs while the step is outstanding and this screen is up.
    private func watchForTheKeyboard() async {
        guard !status.isSatisfied(.keyboard) else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(400))
            coordinator.refreshSetupStatus()
        }
    }

    private func leaveSetup() {
        setupCompleted = true
        dismiss()
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

/// One checklist line: state, what the step is, and where it currently stands.
struct SetupStepLabel: View {
    let step: SetupStep
    let detail: String
    let isComplete: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: isComplete ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isComplete ? Color.brand : .secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(step.title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityValue(isComplete ? "Done" : "Not done")
    }
}

#if DEBUG

// MARK: - Previews

// Guided setup is four steps that each complete somewhere else — iOS Settings,
// a permission alert, the keyboard itself — so reaching a particular
// combination on a device means undoing real system state. These are the
// combinations that change what the screen says.

#Preview("Setup — nothing done yet") {
    PreviewHost(
        coordinator: RecordingCoordinator(
            preview: nil,
            setupStatus: PreviewFixtures.setupFresh
        ),
        store: PreviewFixtures.gatewayUnpairedStore
    ) {
        NavigationStack { SetupView() }
    }
}

#Preview("Setup — microphone declined") {
    PreviewHost(
        coordinator: RecordingCoordinator(
            preview: nil,
            setupStatus: PreviewFixtures.setupMicrophoneDenied
        )
    ) {
        NavigationStack { SetupView() }
    }
}

/// The most common stuck point: listed under Keyboards, never granted Full
/// Access, so the extension has never reached the shared container.
#Preview("Setup — keyboard needs Full Access") {
    PreviewHost(
        coordinator: RecordingCoordinator(
            preview: nil,
            setupStatus: PreviewFixtures.setupKeyboardNeedsFullAccess,
            models: LocalModelManager(preview: [PreviewFixtures.firstModelID])
        )
    ) {
        NavigationStack { SetupView() }
    }
}

#Preview("Setup — keyboard has gone silent") {
    PreviewHost(
        coordinator: RecordingCoordinator(
            preview: nil,
            setupStatus: PreviewFixtures.setupKeyboardSilent
        )
    ) {
        NavigationStack { SetupView() }
    }
}

/// Dictation works and only the optional trial run is outstanding — the state
/// that must *not* warn on the home screen.
#Preview("Setup — ready, test dictation left") {
    PreviewHost(
        coordinator: RecordingCoordinator(
            preview: nil,
            setupStatus: PreviewFixtures.setupReadyToDictate
        )
    ) {
        NavigationStack { SetupView() }
    }
}

#Preview("Setup — recording the test dictation") {
    PreviewHost(
        coordinator: .preview(
            .recording,
            setupStatus: PreviewFixtures.setupReadyToDictate,
            message: "Listening…",
            meterLevel: 0.55,
            isRecording: true
        )
    ) {
        NavigationStack { SetupView() }
    }
}

#Preview("Setup — complete") {
    PreviewHost(
        coordinator: RecordingCoordinator(
            preview: nil,
            setupStatus: PreviewFixtures.setupComplete
        )
    ) {
        NavigationStack { SetupView() }
    }
}

/// The five hardcoded `padding(.leading, 32)` indents in this file are the
/// reason this matrix exists: at `.accessibility5` they eat a third of the
/// width, and right to left they land on the wrong side.
#Preview("Setup — matrix", traits: .sizeThatFitsLayout) {
    PreviewMatrix(
        coordinator: RecordingCoordinator(
            preview: nil,
            setupStatus: PreviewFixtures.setupFresh
        ),
        store: PreviewFixtures.gatewayUnpairedStore
    ) {
        NavigationStack { SetupView() }
    }
}

#Preview("Setup step label — done and not done", traits: .sizeThatFitsLayout) {
    PreviewHost {
        VStack(alignment: .leading, spacing: VocaMetrics.grouping) {
            ForEach(SetupStep.allCases) { step in
                SetupStepLabel(
                    step: step,
                    detail: PreviewFixtures.setupKeyboardNeedsFullAccess.detail(for: step),
                    isComplete: PreviewFixtures.setupKeyboardNeedsFullAccess.isSatisfied(step)
                )
            }
        }
        .padding()
        .frame(width: 380)
    }
}
#endif
