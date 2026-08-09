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

    /// Every explanation on this screen is a `Section` footer, not a row.
    /// Explanatory paragraphs used to sit in rows of their own, so each one drew
    /// a cell with separators above and below and pushed the next control off
    /// the screen — the settings read as a column of slabs instead of a list.
    var body: some View {
        List {
            setupSection
            insertionSection
            quickDictationSection
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
                    // The dot and the word, not one or the other. A bare `Circle`
                    // is not an accessibility element in SwiftUI, so the label on
                    // it was not reliably announced — and it left colour as the
                    // only carrier of readiness, which a red/green deficiency
                    // reads as no signal at all.
                    HStack(spacing: 6) {
                        Circle()
                            .fill(gatewayEngineReady ? Color.brand : .orange)
                            .frame(width: 7, height: 7)
                        Text(gatewayEngineReady ? "Ready" : "Not ready")
                    }
                    .accessibilityElement(children: .combine)
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
                LabeledContent("Model") {
                    Text(gatewayEngine)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var insertionSection: some View {
        Section {
            Toggle("Insert transcript automatically", isOn: $autoInsertTranscripts)
        } header: {
            Text("Insertion")
        } footer: {
            Text(
                autoInsertTranscripts
                    ? "The keyboard inserts text as soon as transcription finishes."
                    : "The keyboard waits for you to tap Insert."
            )
        }
    }

    private var quickDictationSection: some View {
        Section {
            Toggle("Keep Quick Dictation ready for 10 minutes", isOn: $quickDictationEnabled)
                .onChange(of: quickDictationEnabled) { _, enabled in
                    coordinator.setQuickDictationEnabled(enabled)
                }
        } footer: {
            Text(
                "After vocaphone gets microphone access, it keeps an active background "
                    + "input for up to 10 minutes. Standby audio is discarded and never "
                    + "saved or uploaded. The orange microphone indicator remains visible."
            )
        }
    }

    private var writingStyleSection: some View {
        Section {
            Picker("Transcript style", selection: $writingStyleRawValue) {
                ForEach(WritingStyle.allCases) { style in
                    Label(style.displayName, systemImage: style.symbolName)
                        .tag(style.rawValue)
                }
            }
        } header: {
            Text("Writing style")
        } footer: {
            // The example earns its place in the footer by being the thing that
            // actually shows what the style does.
            VStack(alignment: .leading, spacing: 8) {
                Text(selectedWritingStyle.detail)
                Text("“\(selectedWritingStyle.example)”")
                Text(
                    "Styles only change formatting. Your words, numbers, times, "
                        + "links and contractions are never altered."
                )
            }
        }
    }

    /// One row that pushes to the full list, the way a `Picker` behaves in a
    /// form. Listing all 27 languages inline buried every setting below it, and a
    /// `Picker` cannot grey out the ones the loaded model cannot honour — hence a
    /// `NavigationLink` to a list that can do both.
    private var transcriptionLanguageSection: some View {
        Section {
            NavigationLink {
                TranscriptionLanguageList(selection: $transcriptionLanguageRawValue)
            } label: {
                LabeledContent(
                    "Language",
                    value: KeyboardPreferences.effectiveTranscriptionLanguage.displayName
                )
            }
        } header: {
            Text("Transcription language")
        } footer: {
            Text(KeyboardPreferences.effectiveTranscriptionLanguage.detail)
        }
    }

    private var microphoneSection: some View {
        Section {
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
        } header: {
            Text("Microphone")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text(selectedMicrophonePreference.detail)
                Text(
                    "Bluetooth input and output routes are linked by iOS, so choosing a "
                        + "microphone can also change the playback route while recording."
                )
            }
        }
    }

    private var permissionsSection: some View {
        Section {
            Button("Request microphone permission") {
                coordinator.requestMicrophonePermission()
            }
            Button("Open Keyboard Settings") {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            }
        } header: {
            Text("Permissions")
        } footer: {
            Text(
                "Enable vocaphone under Keyboards and allow Full Access. "
                    + "Full Access is used only for shared session state and communication "
                    + "with your configured gateway."
            )
        }
    }

    /// Prose with no control to attach to, so it is a footer with no rows above
    /// it rather than a paragraph dressed up as a settings cell.
    private var privacySection: some View {
        Section {
        } header: {
            Text("Privacy")
        } footer: {
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

    private var selectedMicrophonePreference: MicrophonePreference {
        MicrophonePreference(rawValue: microphonePreferenceRawValue) ?? .automatic
    }
}

/// The full language list, reached from Settings. Search matters at 27 entries,
/// and the ones the gateway's model cannot honour are grouped at the bottom and
/// greyed rather than hidden: a language that simply disappears reads as
/// unsupported by the app, when the fix is to change the model on the gateway.
struct TranscriptionLanguageList: View {
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var modelLanguages: Set<String> { KeyboardPreferences.modelLanguages }
    private var detectsLanguage: Bool { KeyboardPreferences.modelDetectsLanguage }

    private func matches(_ language: TranscriptionLanguage) -> Bool {
        query.isEmpty
            || language.displayName.localizedCaseInsensitiveContains(query)
            || language.rawValue.localizedCaseInsensitiveContains(query)
    }

    private func isSelectable(_ language: TranscriptionLanguage) -> Bool {
        ModelLanguageSupport.isSelectable(
            language,
            modelLanguages: modelLanguages,
            detectsLanguageAutomatically: detectsLanguage
        )
    }

    private var available: [TranscriptionLanguage] {
        TranscriptionLanguage.allCases.filter { matches($0) && isSelectable($0) }
    }

    private var unavailable: [TranscriptionLanguage] {
        TranscriptionLanguage.allCases.filter { matches($0) && !isSelectable($0) }
    }

    var body: some View {
        List {
            if !available.isEmpty {
                Section {
                    ForEach(available) { language in
                        row(language, selectable: true)
                    }
                } footer: {
                    if let restriction = ModelLanguageSupport.restriction(
                        modelLanguages: modelLanguages,
                        detectsLanguageAutomatically: detectsLanguage
                    ) {
                        Text(restriction)
                    }
                }
            }
            if !unavailable.isEmpty {
                Section("Needs a different model") {
                    ForEach(unavailable) { language in
                        row(language, selectable: false)
                    }
                }
            }
            if available.isEmpty && unavailable.isEmpty {
                Text("No language matches “\(query)”.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Language")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search languages")
    }

    private func row(_ language: TranscriptionLanguage, selectable: Bool) -> some View {
        Button {
            selection = language.rawValue
            KeyboardPreferences.noteTranscriptionLanguageUse(language)
            dismiss()
        } label: {
            HStack {
                Text(language.displayName)
                    .foregroundStyle(selectable ? .primary : .secondary)
                Spacer()
                // Ticks what is in force, so the mark never sits on a row the
                // loaded model cannot honour.
                if language == ModelLanguageSupport.resolve(
                    TranscriptionLanguage(rawValue: selection) ?? .automatic,
                    modelLanguages: modelLanguages,
                    detectsLanguageAutomatically: detectsLanguage
                ) {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Selected")
                }
            }
        }
        .disabled(!selectable)
    }
}
