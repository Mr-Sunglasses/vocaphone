import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject private var coordinator: RecordingCoordinator
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("gatewayURL") private var gatewayURL = ""
    @AppStorage(GatewayStatusPreferences.engineReadyKey)
    private var gatewayEngineReady = false
    @AppStorage(
        KeyboardPreferences.quickDictationKey,
        store: KeyboardPreferences.defaults
    ) private var quickDictationEnabled = true
    @State private var keyboardStatus: KeyboardStatus?
    @State private var testText = ""

    var body: some View {
        NavigationStack {
            List {
                if !isSetupComplete {
                    SetupChecklistView(steps: setupSteps, recheck: reloadKeyboardStatus)
                }
                sessionSection
                transcriptSection
                practiceSection
            }
            .navigationTitle("Local Flow")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .task {
                reloadKeyboardStatus()
                await coordinator.recoverRecentSession()
                coordinator.prepareQuickDictationIfEnabled()
                await coordinator.refreshGatewayHealth()
            }
            .onChange(of: scenePhase) { previousPhase, currentPhase in
                guard previousPhase != .active, currentPhase == .active else { return }
                reloadKeyboardStatus()
                Task { await coordinator.refreshGatewayHealth() }
            }
        }
        .overlay {
            if showsKeyboardReturnGuide {
                KeyboardReturnGuide(
                    meterLevel: coordinator.isKeyboardRecording ? coordinator.meterLevel : 0.42,
                    startedAt: coordinator.activeRecord?.createdAt ?? Date(),
                    finish: coordinator.requestFinish,
                    cancel: coordinator.cancel
                )
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showsKeyboardReturnGuide)
    }

    // MARK: - Setup

    private var setupSteps: [SetupStep] {
        [
            SetupStep(
                id: "gateway",
                title: "Connect your transcription gateway",
                detail: gatewayEngineReady
                    ? "Gateway, token, and model are ready."
                    : "Add the gateway URL and pairing token in Settings, then tap Save and test.",
                isComplete: gatewayEngineReady
            ),
            SetupStep(
                id: "microphone",
                title: "Allow microphone access",
                detail: coordinator.microphonePermissionGranted
                    ? "Local Flow can record on this iPhone."
                    : "Recording happens in this app; the keyboard only receives the transcript.",
                isComplete: coordinator.microphonePermissionGranted
            ),
            SetupStep(
                id: "keyboard",
                title: "Add the keyboard with Full Access",
                detail: keyboardStepDetail,
                isComplete: keyboardStatus?.hasFullAccess == true
            ),
        ]
    }

    private var keyboardStepDetail: String {
        guard let keyboardStatus else {
            return "Enable Local Flow under Settings › General › Keyboards and allow Full "
                + "Access. This confirms itself the first time the keyboard runs."
        }
        let seen = keyboardStatus.lastSeenAt.formatted(date: .abbreviated, time: .shortened)
        return "Keyboard last active \(seen)."
    }

    private var isSetupComplete: Bool {
        setupSteps.allSatisfy(\.isComplete)
    }

    private func reloadKeyboardStatus() {
        keyboardStatus = coordinator.keyboardStatus()
    }

    // MARK: - Sections

    private var sessionSection: some View {
        Section("Current session") {
            LabeledContent("State", value: coordinator.stateLabel)

            if coordinator.isRecording {
                ProgressView(value: Double(coordinator.meterLevel))
                    .tint(.red)
                Text("Recording continues while you return to the previous app.")
                    .font(.footnote)
            }

            if coordinator.isQuickDictationReady,
               let expiresAt = coordinator.quickDictationExpiresAt
            {
                LabeledContent("Quick Dictation", value: "Ready")
                Text(
                    "Microphone ready until "
                        + expiresAt.formatted(date: .omitted, time: .shortened)
                        + ". Later Dictate taps stay in the current app."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                Button("Turn off Quick Dictation", role: .destructive) {
                    quickDictationEnabled = false
                }
            }

            if let message = coordinator.message {
                Text(message)
                    .foregroundStyle(coordinator.hasError ? .red : .secondary)
            }

            if coordinator.isRecording {
                Button("Finish recording") { coordinator.requestFinish() }
                    .buttonStyle(.borderedProminent)
                Button("Cancel", role: .destructive) { coordinator.cancel() }
            } else {
                Button("Start microphone test") { coordinator.startInAppTest() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var transcriptSection: some View {
        Section("Transcripts") {
            if let transcript = coordinator.transcript, !transcript.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Latest")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(transcript)
                        .textSelection(.enabled)
                }
                Button {
                    UIPasteboard.general.string = transcript
                } label: {
                    Label("Copy latest transcript", systemImage: "doc.on.doc")
                }
            }
            NavigationLink {
                TranscriptHistoryView()
            } label: {
                Label("All transcripts", systemImage: "clock.arrow.circlepath")
            }
        }
    }

    private var practiceSection: some View {
        Section("Try the keyboard") {
            TextField("Switch to the Local Flow keyboard here", text: $testText, axis: .vertical)
                .lineLimit(3...6)

            if coordinator.isDictatingIntoContainingApp {
                // Dictating into this field needs no app switch, so the flow is
                // explained inline instead of behind a full-screen hand-off.
                HStack(spacing: 8) {
                    Circle()
                        .fill(.red)
                        .frame(width: 10, height: 10)
                    Text("Listening")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    ProgressView(value: Double(coordinator.meterLevel))
                        .tint(.red)
                        .frame(width: 90)
                }
                .accessibilityElement(children: .combine)

                Text("Tap Finish on the keyboard and the transcript drops into this field.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Button("Finish recording") { coordinator.requestFinish() }
                    .buttonStyle(.borderedProminent)
                Button("Cancel", role: .destructive) { coordinator.cancel() }
            } else {
                Text(
                    "Dictating here keeps you in Local Flow. From another app, the "
                        + "keyboard opens Local Flow to record — swipe back once recording "
                        + "begins, then tap Finish in the keyboard."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var showsKeyboardReturnGuide: Bool {
        if coordinator.isKeyboardRecording { return true }
#if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-previewKeyboardReturnGuide")
#else
        return false
#endif
    }
}

private struct KeyboardReturnGuide: View {
    let meterLevel: Float
    let startedAt: Date
    let finish: () -> Void
    let cancel: () -> Void
    @State private var arrowOffset: CGFloat = -18

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(uiColor: .systemBackground),
                    Color(uiColor: .secondarySystemBackground),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 18) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(.red)
                        .frame(width: 10, height: 10)
                    Text("RECORDING")
                        .font(.caption.bold())
                    Spacer()
                    Text(startedAt, style: .timer)
                        .font(.subheadline.monospacedDigit().weight(.medium))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(.thinMaterial, in: Capsule())

                Spacer(minLength: 4)

                ZStack {
                    Circle()
                        .fill(Color.red.opacity(0.12))
                        .frame(width: 108, height: 108)
                    Circle()
                        .fill(.red)
                        .frame(
                            width: 58 + CGFloat(meterLevel) * 18,
                            height: 58 + CGFloat(meterLevel) * 18
                        )
                        .animation(.linear(duration: 0.12), value: meterLevel)
                    Image(systemName: "mic.fill")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(.white)
                }

                VStack(spacing: 10) {
                    Text("Local Flow is listening")
                        .font(.title.bold())
                        .multilineTextAlignment(.center)
                    Text("Now return to the app where you were typing. Recording will continue safely in the background.")
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 28)
                            .fill(.thinMaterial)
                            .frame(height: 74)
                        Capsule()
                            .fill(.primary.opacity(0.75))
                            .frame(width: 112, height: 5)
                            .offset(y: 23)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundStyle(.blue)
                            .offset(x: arrowOffset, y: -10)
                    }
                    Text("Swipe right across the bottom edge")
                        .font(.headline)
                }

                Text("When the keyboard reappears, tap Finish—or use Finish in the Dynamic Island.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 4)

                Button("Finish recording here instead", action: finish)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                Button("Cancel recording", role: .destructive, action: cancel)
                    .font(.subheadline)
            }
            .padding(20)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true)) {
                arrowOffset = 18
            }
        }
    }
}
