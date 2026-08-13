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
    @AppStorage(
        KeyboardPreferences.recordingSoundsKey,
        store: KeyboardPreferences.defaults
    ) private var recordingSoundsEnabled = false
    // The App Group store, not the keyboard's: on-device decoding happens in
    // this app, and the keyboard has no use for either of these.
    @AppStorage(
        LocalTranscriptionPreferences.qualityKey,
        store: UserDefaults(suiteName: AppConfiguration.appGroupIdentifier)
    ) private var transcriptionQualityRawValue = TranscriptionQuality.default.rawValue
    @AppStorage(
        LocalTranscriptionPreferences.vocabularyKey,
        store: UserDefaults(suiteName: AppConfiguration.appGroupIdentifier)
    ) private var savedCustomVocabulary = ""
    @State private var customVocabularyDraft = ""
    /// A `List` row re-runs `onAppear` when it scrolls back into view, and
    /// reloading the draft there would throw away a half-typed word.
    @State private var hasLoadedVocabularyDraft = false
    @State private var diagnosticExportURL: URL?
    @State private var isSharingDiagnostics = false
    @State private var diagnosticsStatus: String?

    /// Every explanation on this screen is a `Section` footer, not a row.
    /// Explanatory paragraphs used to sit in rows of their own, so each one drew
    /// a cell with separators above and below and pushed the next control off
    /// the screen — the settings read as a column of slabs instead of a list.
    var body: some View {
        List {
            setupSection
            localModelsSection
            insertionSection
            quickDictationSection
            transcriptionLanguageSection
            writingStyleSection
            microphoneSection
            recordingFeedbackSection
            permissionsSection
            diagnosticsSection
            privacySection
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isSharingDiagnostics, onDismiss: removeDiagnosticExport) {
            if let diagnosticExportURL {
                DiagnosticShareSheet(activityItems: [diagnosticExportURL])
            }
        }
    }

    private var setupSection: some View {
        Section {
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

            if let dashboardURL = validatedGatewayURL {
                Link(destination: dashboardURL) {
                    Label("Open web dashboard", systemImage: "arrow.up.right.square")
                }
            } else {
                Button {} label: {
                    Label("Open web dashboard", systemImage: "arrow.up.right.square")
                }
                    .disabled(true)
                    .accessibilityHint("Configure a transcription gateway first")
            }

            if !gatewayEngine.isEmpty {
                LabeledContent("Model") {
                    Text(gatewayEngine)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                }
            }
        } header: {
            Text("Setup")
        } footer: {
            Text(
                "For more customization, including choosing the speech-to-text model, "
                + "open your gateway's web dashboard."
            )
        }
    }

    @ViewBuilder private var localModelsSection: some View {
        Section {
            Toggle(
                "Use on-device transcription",
                isOn: Binding(
                    get: { LocalTranscriptionPreferences.enabled },
                    set: { LocalTranscriptionPreferences.enabled = $0 }
                )
            )
        } header: {
            Text("On-device models")
        } footer: {
            Text(
                "Models run privately on this iPhone through WhisperKit/Core ML. "
                    + "Every file, including the tokenizer, is pinned and checked with "
                    + "SHA-256 before it can load, so transcription needs no network at "
                    + "all. The keyboard extension never loads the model itself."
            )
        }

        LocalModelPicker(manager: coordinator.localModels)

        Section {
            Picker("Accuracy", selection: $transcriptionQualityRawValue) {
                ForEach(TranscriptionQuality.allCases) { quality in
                    Text(quality.displayName).tag(quality.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: transcriptionQualityRawValue) { _, _ in reloadLocalEngine() }
            if let loading = coordinator.localModels.loadingMessage {
                Text(loading).foregroundStyle(.secondary)
            }
        } header: {
            Text("On-device accuracy")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text(selectedTranscriptionQuality.detail)
                Text(
                    "This governs models running on this iPhone. Transcription on "
                        + "your gateway is unaffected."
                )
            }
        }

        customWordsSection
    }

    /// Saved on request rather than on every keystroke: the terms are parsed at
    /// inference time, and a half-typed name being persisted mid-word is a
    /// spelling nobody asked to be biased toward.
    @ViewBuilder private var customWordsSection: some View {
        Section {
            TextEditor(text: $customVocabularyDraft)
                .frame(minHeight: 88)
                .font(.body)
            Button("Save words") { savedCustomVocabulary = customVocabularyDraft }
                .disabled(customVocabularyDraft == savedCustomVocabulary)
        } header: {
            Text("Custom words")
        } footer: {
            let terms = CustomVocabulary.terms(customVocabularyDraft)
            VStack(alignment: .leading, spacing: 8) {
                Text(
                    "Names, places and jargon an on-device Whisper model is unlikely "
                        + "to know. One per line, or separated by commas."
                )
                Text(
                    terms.isEmpty
                        ? "No custom words. Transcription is unchanged."
                        : "\(terms.count) word\(terms.count == 1 ? "" : "s") will bias the "
                            + "decoder. This nudges spelling rather than guaranteeing it, and "
                            + "a very long list starts to crowd out the speech itself."
                )
                // Said plainly rather than letting the list quietly do nothing:
                // only Whisper's decoder has somewhere to put a vocabulary.
                if let unsupported = unsupportedVocabularyModel, !terms.isEmpty {
                    Text(
                        "\(unsupported) cannot use these words. Only Whisper models take a "
                            + "vocabulary; the list is kept for when you switch back to one."
                    )
                    .foregroundStyle(.red)
                }
            }
        }
        .onAppear {
            guard !hasLoadedVocabularyDraft else { return }
            customVocabularyDraft = savedCustomVocabulary
            hasLoadedVocabularyDraft = true
        }
    }

    private var selectedTranscriptionQuality: TranscriptionQuality {
        TranscriptionQuality.fromStored(transcriptionQualityRawValue)
    }

    /// A sherpa engine has its decoding method baked in, so changing the
    /// accuracy rebuilds it. Doing that here means it happens while the user is
    /// still on this screen rather than in front of the next dictation. Best
    /// effort: the dictation that follows attempts the same load and reports
    /// whatever went wrong where the user is looking.
    private func reloadLocalEngine() {
        guard LocalTranscriptionPreferences.enabled,
              let descriptor = LocalModelCatalog.descriptor(
                  for: LocalTranscriptionPreferences.modelIdentifier
              )
        else { return }
        Task { @MainActor in
            try? await coordinator.localModels.prepare(
                descriptor,
                language: KeyboardPreferences.effectiveTranscriptionLanguage.rawValue
            )
        }
    }

    /// The selected on-device model when it cannot take a vocabulary, so the
    /// word list can say so instead of silently doing nothing.
    private var unsupportedVocabularyModel: String? {
        guard LocalTranscriptionPreferences.enabled,
              let descriptor = LocalModelCatalog.descriptor(
                  for: LocalTranscriptionPreferences.modelIdentifier
              ),
              !descriptor.supportsCustomVocabulary
        else { return nil }
        return descriptor.displayName
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

    private var recordingFeedbackSection: some View {
        Section {
            Toggle("Play recording start and stop sounds", isOn: $recordingSoundsEnabled)
        } header: {
            Text("Recording feedback")
        } footer: {
            Text(
                "Short, quiet tones play outside the captured audio, so they are not "
                    + "included in the transcript. Haptic feedback remains available."
            )
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

    private var diagnosticsSection: some View {
        Section {
            Button {
                do {
                    diagnosticExportURL = try DiagnosticLog.makeExportFile()
                    diagnosticsStatus = nil
                    isSharingDiagnostics = true
                } catch {
                    DiagnosticLog.record(
                        .operationFailed,
                        metadata: .error(.diagnosticExportFailed)
                    )
                    diagnosticsStatus = "The diagnostic export could not be prepared."
                }
            } label: {
                Label("Export diagnostics", systemImage: "square.and.arrow.up")
            }

            Button(role: .destructive) {
                DiagnosticLog.clear()
                diagnosticsStatus = "Diagnostics cleared."
            } label: {
                Label("Clear diagnostics", systemImage: "trash")
            }
        } header: {
            Text("Diagnostics")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text(
                    "The bounded export contains up to seven days of build information, app/keyboard "
                        + "source, state transitions, and lifecycle errors only. It never "
                        + "contains transcripts, typed text, audio, addresses, or credentials."
                )
                if let diagnosticsStatus { Text(diagnosticsStatus) }
            }
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

    private var validatedGatewayURL: URL? {
        GatewayEndpoint.validatedURL(from: gatewayURL)
    }

    private func removeDiagnosticExport() {
        if let diagnosticExportURL {
            try? FileManager.default.removeItem(at: diagnosticExportURL)
        }
        diagnosticExportURL = nil
    }
}

private struct DiagnosticShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(
        _ uiViewController: UIActivityViewController,
        context: Context
    ) {}
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
