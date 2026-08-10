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
    @State private var keyboardProbeText = ""

    private var status: SetupStatus { coordinator.setupStatus }

    var body: some View {
        List {
            introSection
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
    }

    // MARK: - Sections

    private var introSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                BrandMark(size: 36)
                    .padding(.bottom, 2)
                Text("Dictate into any app")
                    .font(.title3.weight(.semibold))
                Text(
                    "vocaphone records on this iPhone and transcribes through "
                        + "your gateway or privately on this phone. Nothing is sent to a "
                        + "third-party transcription service. Four steps and "
                        + "you are done."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)

            VStack(alignment: .leading, spacing: 8) {
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

    private var stepsSection: some View {
        Section {
            gatewayStep
            microphoneStep
            keyboardStep
            firstDictationStep
        } footer: {
            Text(
                "Full Access is used only to share session state with Local "
                    + "Flow and to reach the gateway you configured. The "
                    + "keyboard never sees what you type in other apps."
            )
        }
    }

    private var gatewayStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            NavigationLink {
                GatewaySetupView()
            } label: {
                SetupStepLabel(
                    step: .gateway,
                    detail: status.detail(for: .gateway),
                    isComplete: status.isSatisfied(.gateway)
                )
            }
            Text("Or use an on-device model")
                .font(.subheadline.weight(.semibold))
                .padding(.leading, 32)
            LocalModelPicker(
                manager: coordinator.localModels,
                leadingPadding: 32,
                onChange: { coordinator.refreshSetupStatus() }
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
            stepAction("Open iOS Settings", action: openSystemSettings)

            // The app is only told the keyboard exists once the extension
            // actually runs, and it only runs when it is switched to. A field
            // right here is the shortest path to that.
            VStack(alignment: .leading, spacing: 6) {
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
                .foregroundStyle(coordinator.hasError ? .red : .secondary)
                .padding(.leading, 32)
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
                        : "Dictation will work. The test recording is optional."
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
                "Audio stays on this phone until upload succeeds, and your "
                    + "gateway deletes it after a successful transcription by "
                    + "default. No third-party transcription or analytics "
                    + "service is involved."
            )
        }
    }

    // MARK: - Actions

    private var canRunTestDictation: Bool {
        status.isSatisfied(.gateway) && status.isSatisfied(.microphone)
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
