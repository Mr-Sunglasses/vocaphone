import SwiftUI

/// "Fix grammar (English)" in Dictation → Output, after Clean up speech.
///
/// The setting cannot be on without a verified model: turning it on while the
/// model is missing asks before a download and says how big it is, and the
/// preference is written only once the files have passed their checksums.
/// Mirrors android/.../ui/FixGrammarRow.kt.
struct FixGrammarToggle: View {
    let store: GrammarModelStore
    let grammar: GrammarCorrector
    let style: WritingStyle

    @AppStorage(
        KeyboardPreferences.fixGrammarKey,
        store: KeyboardPreferences.defaults
    ) private var fixGrammar = KeyboardDefaults.fixGrammar

    var body: some View {
        GrammarModelToggle(
            title: "Fix grammar (English)",
            description: "Common grammar slips, on this iPhone.",
            unavailable: style == .raw ? "Not applied to the Raw style." : nil,
            isOn: $fixGrammar,
            store: store,
            grammar: grammar
        )
    }
}

/// "Writing check (English)" in Keyboard settings: Grammarly's keyboard, on
/// this iPhone. Checking while typing needs no download — the rules ship in
/// the keyboard — and the grammar model is an optional download that catches
/// more, shared with dictation's Fix grammar. Mirrors
/// android/.../ui/FixGrammarRow.kt's WritingCheckSettingsGroup.
struct WritingCheckSettingsSection: View {
    let store: GrammarModelStore
    let grammar: GrammarCorrector
    let suggestionsEnabled: Bool
    @Binding var learnMore: LearnMoreTopic?
    /// The Writing check screen; nil hides the row.
    var onOpenEditor: (() -> Void)?

    @AppStorage(KeyboardPreferences.typingGrammarKey, store: KeyboardPreferences.defaults)
    private var checkWhileTyping = KeyboardDefaults.typingGrammar
    @AppStorage(KeyboardPreferences.grammarSureOnlyKey, store: KeyboardPreferences.defaults)
    private var sureOnly = KeyboardDefaults.grammarSureOnly
    @AppStorage(KeyboardPreferences.writingClarityKey, store: KeyboardPreferences.defaults)
    private var clarity = KeyboardDefaults.writingClarity
    @AppStorage(KeyboardPreferences.writingEngagementKey, store: KeyboardPreferences.defaults)
    private var engagement = KeyboardDefaults.writingEngagement
    @AppStorage(KeyboardPreferences.writingDeliveryKey, store: KeyboardPreferences.defaults)
    private var delivery = KeyboardDefaults.writingDelivery
    @AppStorage(KeyboardPreferences.writingToneKey, store: KeyboardPreferences.defaults)
    private var tone = KeyboardDefaults.writingTone
    @AppStorage(KeyboardPreferences.typoAutoFixKey, store: KeyboardPreferences.defaults)
    private var typoAutoFix = KeyboardDefaults.typoAutoFix

    @State private var offering = false

    private var size: String { DownloadReadiness.byteLabel(store.sizeBytes) }

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { checkWhileTyping && suggestionsEnabled }, set: { checkWhileTyping = $0 })) {
                SettingLabel(
                    "Check while typing",
                    detail: suggestionsEnabled
                        ? "Suggestions in the toolbar when you pause. Nothing changes until you tap."
                        : "Needs suggestions turned on."
                )
            }
            .disabled(!suggestionsEnabled)
            if let onOpenEditor {
                Button(action: onOpenEditor) {
                    SettingLabel(
                        "Check text in vocaphone",
                        detail: "Paste or write something and see every suggestion, a score and how it sounds."
                    )
                }
            }
            modelRow
            Toggle(isOn: $sureOnly) {
                SettingLabel("Only sure fixes", detail: "Fewer grammar suggestions, each more likely to be right.")
            }
            Toggle(isOn: $clarity) {
                SettingLabel("Clarity", detail: "Wordy phrases, passive voice, long sentences.")
            }
            Toggle(isOn: $engagement) {
                SettingLabel("Engagement", detail: "“Very good” → “great”, and words used too often.")
            }
            Toggle(isOn: $delivery) {
                SettingLabel("Delivery", detail: "Hedging like “I just wanted to”.")
            }
            Toggle(isOn: $tone) {
                SettingLabel("Tone", detail: "Says how your text sounds: friendly, formal, urgent…")
            }
            Toggle(isOn: $typoAutoFix) {
                SettingLabel(
                    "Fix obvious typos as I type",
                    detail: "“recieve” → “receive”, “dont” → “don't”, with Undo in the suggestion row."
                )
            }
            .disabled(!checkWhileTyping)
        } header: {
            LearnMoreHeader(title: "Writing check (English)", topic: SettingsHelp.writing, presented: $learnMore)
        } footer: {
            Text("Runs on this iPhone. Nothing you type is sent anywhere. The keyboard uses the grammar "
                + "model while vocaphone is running in the background.")
        }
    }

    @ViewBuilder
    private var modelRow: some View {
        switch store.phase {
        case .ready:
            LabeledContent("Grammar model", value: "On this iPhone")
        case let .downloading(fraction):
            Button("Cancel download", role: .cancel) { store.cancel() }
            ProgressView(value: fraction) { Text("Downloading the grammar model") }
        case let .failed(reason):
            downloadButton(detail: reason.plainText)
        case .absent:
            downloadButton(detail: "Catches more grammar slips. \(size), runs on this iPhone.")
        }
    }

    /// The offer to download, first time or again after a failure. The dialog
    /// travels with the button, so whichever phase shows it can open it.
    private func downloadButton(detail: String) -> some View {
        Button { offering = true } label: {
            SettingLabel("Download the grammar model", detail: detail)
        }
        .confirmationDialog("Download the grammar model?", isPresented: $offering, titleVisibility: .visible) {
            Button("Download \(size)") { download() }
            Button("Not now", role: .cancel) {}
        } message: {
            Text("Writing check works without it. The \(size) model runs on this iPhone and catches "
                + "more grammar slips, like “he don't know”. Your words are checked here and never "
                + "sent anywhere.")
        }
    }

    private func download() {
        Task {
            if (try? await store.download()) != nil { grammar.modelChanged() }
        }
    }
}

private struct GrammarModelToggle: View {
    let title: String
    let description: String
    let unavailable: String?
    @Binding var isOn: Bool
    let store: GrammarModelStore
    let grammar: GrammarCorrector

    @State private var offering = false

    private var size: String { DownloadReadiness.byteLabel(store.sizeBytes) }

    var body: some View {
        toggle
        // The toggle is disabled while the files arrive, so this is the one
        // way to change your mind about a 28 MB download.
        if isDownloading {
            Button("Cancel download", role: .cancel) { store.cancel() }
        }
    }

    private var toggle: some View {
        Toggle(isOn: Binding(
            get: { isOn && store.isReady && unavailable == nil },
            set: { on in
                if !on {
                    isOn = false
                } else if store.isReady {
                    isOn = true
                } else {
                    offering = true
                }
            }
        )) {
            SettingLabel(title, detail: detail)
        }
        .disabled(unavailable != nil || isDownloading)
        .confirmationDialog(
            "Download the grammar model?",
            isPresented: $offering,
            titleVisibility: .visible
        ) {
            Button("Download \(size)") { download() }
            Button("Not now", role: .cancel) {}
        } message: {
            Text(
                "Grammar checking uses a \(size) model that runs on this iPhone. Your words are "
                    + "checked here and never sent anywhere. It fixes common English grammar "
                    + "and spelling slips, and can occasionally change a sentence that was "
                    + "already right."
            )
        }
    }

    private var isDownloading: Bool {
        if case .downloading = store.phase { return true }
        return false
    }

    private var detail: String {
        if let unavailable { return unavailable }
        switch store.phase {
        case let .downloading(fraction):
            return "Downloading the grammar model · \(Int(fraction * 100))%"
        case let .failed(reason):
            return reason.plainText
        case .ready:
            return description
        case .absent:
            return "\(description) \(size) download."
        }
    }

    private func download() {
        Task {
            do {
                try await store.download()
                grammar.modelChanged()
                isOn = true
            } catch {
                // `phase` says why; the setting stays off.
            }
        }
    }
}
