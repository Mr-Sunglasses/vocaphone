import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(RecordingCoordinator.self) private var coordinator
    @AppStorage("gatewayURL") private var gatewayURL = ""
    @AppStorage(GatewayStatusPreferences.healthMessageKey)
    private var healthMessage = "Not tested"
    @AppStorage(GatewayStatusPreferences.engineKey) private var gatewayEngine = ""
    @AppStorage(GatewayStatusPreferences.engineReadyKey)
    private var gatewayEngineReady = false
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
    @AppStorage(
        KeyboardPreferences.transcriptionLanguageKey,
        store: KeyboardPreferences.defaults
    ) private var transcriptionLanguageRawValue = TranscriptionLanguage.automatic.rawValue
    @AppStorage(
        KeyboardPreferences.microphonePreferenceKey,
        store: KeyboardPreferences.defaults
    ) private var microphonePreferenceRawValue = MicrophonePreference.automatic.rawValue
    @State private var token = ""
    @State private var isTestingGateway = false

    var body: some View {
        List {
            gatewaySection
            insertionSection
            transcriptionLanguageSection
            writingStyleSection
            microphoneSection
            permissionsSection
            privacySection
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .task { token = (try? KeychainStore.loadToken()) ?? "" }
        .onChange(of: gatewayURL) {
            healthMessage = "Not tested"
            gatewayEngine = ""
            gatewayEngineReady = false
        }
    }

    private var gatewaySection: some View {
        Section("Transcription gateway") {
            TextField(
                "http://homelabone:8765 or https://dictation.example.com",
                text: $gatewayURL
            )
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)

            if let url = validatedGatewayURL, GatewayEndpoint.usesUnencryptedHTTP(url) {
                Label(
                    "HTTP is unencrypted. Use it only on a trusted private LAN or VPN; "
                        + "use HTTPS for a VPS or any public network.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.footnote)
                .foregroundStyle(.orange)
            } else {
                Text(
                    "Use any reachable HTTP or HTTPS gateway. HTTPS is recommended and "
                        + "required for safe access over the public internet."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            SecureField("Pairing token", text: $token)
                .textInputAutocapitalization(.never)

            Button {
                Task { await saveAndTestGateway() }
            } label: {
                HStack(spacing: 8) {
                    if isTestingGateway {
                        ProgressView().controlSize(.small)
                    }
                    Text(isTestingGateway ? "Testing gateway…" : "Save and test")
                }
            }
            .disabled(isTestingGateway)

            Text(healthMessage)
                .font(.footnote)
                .foregroundStyle(gatewayEngineReady ? .green : .secondary)

            if !gatewayEngine.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Label("Transcription model", systemImage: "cpu")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Label(
                            gatewayEngineReady ? "Ready" : "Not ready",
                            systemImage: gatewayEngineReady
                                ? "checkmark.circle.fill"
                                : "exclamationmark.circle.fill"
                        )
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(gatewayEngineReady ? .green : .orange)
                    }
                    Text(gatewayEngine)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var insertionSection: some View {
        Section("Insertion") {
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
        }
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

            VStack(alignment: .leading, spacing: 4) {
                Text("Example")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(selectedWritingStyle.example)
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)

            Text(
                "Styles only change formatting. Your words, numbers, times, "
                    + "links and contractions are never altered."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    private var transcriptionLanguageSection: some View {
        Section("Transcription language") {
            Picker("Language", selection: $transcriptionLanguageRawValue) {
                ForEach(TranscriptionLanguage.allCases) { language in
                    Text(language.displayName).tag(language.rawValue)
                }
            }
            Text(selectedTranscriptionLanguage.detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var microphoneSection: some View {
        Section("Microphone") {
            Picker("Input selection", selection: $microphonePreferenceRawValue) {
                ForEach(MicrophonePreference.allCases) { preference in
                    Text(preference.displayName).tag(preference.rawValue)
                }
            }
            .disabled(!coordinator.canChangeMicrophone)
            .onChange(of: microphonePreferenceRawValue) { _, rawValue in
                guard let preference = MicrophonePreference(rawValue: rawValue) else { return }
                coordinator.setMicrophonePreference(preference)
            }

            LabeledContent("Input in use", value: coordinator.microphoneStatusLabel)

            Text(selectedMicrophonePreference.detail)
                .font(.footnote)
                .foregroundStyle(.secondary)

            Text(
                "Bluetooth input and output routes are linked by iOS, so choosing a "
                    + "microphone can also change the playback route while recording."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    private var permissionsSection: some View {
        Section("Permissions") {
            Button("Request microphone permission") {
                coordinator.requestMicrophonePermission()
            }
            Button("Open Keyboard Settings") {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            }
            Text(
                "Enable Local Flow under Keyboards and allow Full Access. "
                    + "Full Access is used only for shared session state and communication "
                    + "with your configured gateway."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    private var privacySection: some View {
        Section("Privacy") {
            Text(
                "Audio stays on this phone until upload succeeds. The gateway deletes "
                    + "successful audio by default. No third-party transcription or analytics "
                    + "service is used."
            )
        }
    }

    private var selectedWritingStyle: WritingStyle {
        WritingStyle(rawValue: writingStyleRawValue) ?? .casual
    }

    private var selectedTranscriptionLanguage: TranscriptionLanguage {
        TranscriptionLanguage(rawValue: transcriptionLanguageRawValue) ?? .automatic
    }

    private var selectedMicrophonePreference: MicrophonePreference {
        MicrophonePreference(rawValue: microphonePreferenceRawValue) ?? .automatic
    }

    private var validatedGatewayURL: URL? {
        GatewayEndpoint.validatedURL(from: gatewayURL)
    }

    @MainActor
    private func saveAndTestGateway() async {
        guard let url = validatedGatewayURL else {
            healthMessage = "Enter a valid HTTP or HTTPS gateway URL."
            gatewayEngine = ""
            gatewayEngineReady = false
            return
        }
        do {
            try KeychainStore.saveToken(token)
        } catch {
            healthMessage = "Could not save the pairing token: \(error.localizedDescription)"
            return
        }
        await testGateway(at: url)
    }

    @MainActor
    private func testGateway(at url: URL) async {
        guard !isTestingGateway else { return }
        isTestingGateway = true
        defer { isTestingGateway = false }
        do {
            let client = GatewayClient(baseURL: url, token: token)
            try await client.verifyAuthentication()
            let health = try await client.health()
            healthMessage = health.engineReady
                ? "Gateway, token, and model are ready."
                : "Gateway reachable; model is not ready."
            gatewayEngine = health.engine.trimmingCharacters(in: .whitespacesAndNewlines)
            gatewayEngineReady = health.engineReady
            coordinator.updateGateway(baseURL: url, token: token)
        } catch let GatewayError.api(status, _) where status == 401 {
            healthMessage = "Gateway reachable, but the pairing token was rejected."
            gatewayEngine = ""
            gatewayEngineReady = false
        } catch {
            healthMessage = "Gateway test failed: \(error.localizedDescription)"
            gatewayEngine = ""
            gatewayEngineReady = false
        }
    }
}
