import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject private var coordinator: RecordingCoordinator
    @AppStorage("gatewayURL") private var gatewayURL = ""
    @AppStorage("gatewayHealthMessage") private var healthMessage = "Not tested"
    @AppStorage(
        KeyboardPreferences.autoInsertKey,
        store: KeyboardPreferences.defaults
    ) private var autoInsertTranscripts = true
    @AppStorage(
        KeyboardPreferences.quickDictationKey,
        store: KeyboardPreferences.defaults
    ) private var quickDictationEnabled = true
    @AppStorage(
        KeyboardPreferences.writingStyleKey,
        store: KeyboardPreferences.defaults
    ) private var writingStyleRawValue = WritingStyle.casual.rawValue
    @State private var token = ""
    @State private var testText = ""

    var body: some View {
        NavigationStack {
            List {
                statusSection
                writingStyleSection
                setupSection
                testSection
                privacySection
            }
            .navigationTitle("Local Flow")
            .task {
                token = (try? KeychainStore.loadToken()) ?? ""
                await coordinator.recoverRecentSession()
                coordinator.prepareQuickDictationIfEnabled()
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

    private var writingStyleSection: some View {
        Section("Writing style") {
            Picker("Transcript style", selection: $writingStyleRawValue) {
                ForEach(WritingStyle.allCases) { style in
                    Label(style.displayName, systemImage: style.symbolName)
                        .tag(style.rawValue)
                }
            }

            Text(selectedWritingStyle.detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var selectedWritingStyle: WritingStyle {
        WritingStyle(rawValue: writingStyleRawValue) ?? .casual
    }

    private var showsKeyboardReturnGuide: Bool {
        if coordinator.isKeyboardRecording { return true }
#if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-previewKeyboardReturnGuide")
#else
        return false
#endif
    }

    private var statusSection: some View {
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
                Text("Microphone ready until \(expiresAt.formatted(date: .omitted, time: .shortened)). Later Dictate taps stay in the current app.")
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
            if let transcript = coordinator.transcript, !transcript.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Latest transcript")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(transcript)
                        .textSelection(.enabled)
                }
            }
            if coordinator.isRecording {
                Button("Finish recording") { coordinator.requestFinish() }
                    .buttonStyle(.borderedProminent)
                Button("Cancel", role: .destructive) { coordinator.cancel() }
            } else {
                Button("Start microphone test") {
                    coordinator.startInAppTest()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var setupSection: some View {
        Section("Private Mac gateway") {
            TextField("https://your-mac.tailnet-name.ts.net", text: $gatewayURL)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
            SecureField("Pairing token", text: $token)
                .textInputAutocapitalization(.never)
            Button("Save and test") {
                Task { await saveAndTestGateway() }
            }
            Text(healthMessage)
                .font(.footnote)

            Toggle("Insert transcript automatically", isOn: $autoInsertTranscripts)
            Text(
                autoInsertTranscripts
                    ? "The keyboard inserts text as soon as transcription finishes."
                    : "The keyboard waits for you to tap Insert."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)

            Toggle("Keep Quick Dictation ready for 10 minutes", isOn: $quickDictationEnabled)
                .onChange(of: quickDictationEnabled) { _, enabled in
                    coordinator.setQuickDictationEnabled(enabled)
                }
            Text(
                "After Local Flow gets microphone access, it keeps an active background "
                    + "input for up to 10 minutes. Standby audio is discarded and never "
                    + "saved or uploaded. The orange microphone indicator remains visible."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)

            Button("Request microphone permission") {
                coordinator.requestMicrophonePermission()
            }
            Button("Open Keyboard Settings") {
                UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
            }
            Text(
                "Enable Local Flow under Keyboards and allow Full Access. "
                    + "Full Access is used only for shared session state and communication "
                    + "with your own Mac."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    private var testSection: some View {
        Section("Insertion test") {
            Text(
                "Use Start microphone test above to verify capture and transcription "
                    + "without involving the keyboard."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            TextField("Switch to the Local Flow keyboard here", text: $testText, axis: .vertical)
                .lineLimit(3...6)
            Text(
                "The keyboard opens this app to start recording. Once recording begins, "
                    + "swipe back to the original app, then tap Finish in the keyboard."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    private var privacySection: some View {
        Section("Privacy") {
            Text(
                "Audio stays on this phone until upload succeeds. The Mac gateway deletes "
                    + "successful audio by default. No third-party transcription or analytics "
                    + "service is used."
            )
        }
    }

    @MainActor
    private func saveAndTestGateway() async {
        do {
            guard let url = URL(string: gatewayURL),
                  url.scheme == "https"
                    || (url.scheme == "http" && url.host == "127.0.0.1")
            else {
                healthMessage = "Enter a valid tailnet HTTPS URL."
                return
            }
            try KeychainStore.saveToken(token)
            let client = GatewayClient(baseURL: url, token: token)
            let health = try await client.health()
            healthMessage = health.engineReady
                ? "Gateway and model are ready."
                : "Gateway reachable; model is not ready."
            coordinator.updateGateway(baseURL: url, token: token)
        } catch {
            healthMessage = "Health check failed: \(error.localizedDescription)"
        }
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
