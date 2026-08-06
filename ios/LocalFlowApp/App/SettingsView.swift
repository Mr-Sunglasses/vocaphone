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

    var body: some View {
        List {
            setupSection
            insertionSection
            transcriptionLanguageSection
            writingStyleSection
            microphoneSection
            permissionsSection
            privacySection
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var setupSection: some View {
        Section("Setup") {
            NavigationLink {
                GatewaySetupView()
            } label: {
                LabeledContent {
                    Label(
                        gatewayEngineReady ? "Ready" : "Not ready",
                        systemImage: gatewayEngineReady
                            ? "checkmark.circle.fill"
                            : "exclamationmark.circle.fill"
                    )
                    .labelStyle(.titleAndIcon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(gatewayEngineReady ? .green : .orange)
                } label: {
                    Text("Transcription gateway")
                    Text(gatewayURL.isEmpty ? healthMessage : gatewayURL)
                        .font(.footnote)
                }
            }

            NavigationLink {
                SetupView()
            } label: {
                Label("Guided setup", systemImage: "checklist")
            }

            if !gatewayEngine.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Transcription model")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
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

    /// A `Picker` cannot disable individual rows, so the languages the gateway's
    /// model cannot honour are listed explicitly and greyed. Greyed rather than
    /// hidden: a language that simply vanishes reads as unsupported by the app,
    /// when the fix is to change the model on the gateway.
    private var transcriptionLanguageSection: some View {
        Section("Transcription language") {
            ForEach(TranscriptionLanguage.allCases) { language in
                let selectable = ModelLanguageSupport.isSelectable(
                    language,
                    modelLanguages: KeyboardPreferences.modelLanguages,
                    detectsLanguageAutomatically: KeyboardPreferences.modelDetectsLanguage
                )
                Button {
                    transcriptionLanguageRawValue = language.rawValue
                } label: {
                    HStack {
                        Text(language.displayName)
                            .foregroundStyle(selectable ? .primary : .tertiary)
                        Spacer()
                        if language.rawValue == transcriptionLanguageRawValue {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                }
                .disabled(!selectable)
            }
            Text(selectedTranscriptionLanguage.detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let restriction = ModelLanguageSupport.restriction(
                modelLanguages: KeyboardPreferences.modelLanguages,
                detectsLanguageAutomatically: KeyboardPreferences.modelDetectsLanguage
            ) {
                Text(restriction)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
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
}
