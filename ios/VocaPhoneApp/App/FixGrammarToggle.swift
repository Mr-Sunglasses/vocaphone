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

/// "Check grammar (English)" in Keyboard → Typing: the same model, offered
/// for what is typed. It shares Fix grammar's download, so whichever is turned
/// on first fetches the model and the other is then a plain switch.
///
/// The keyboard cannot load the model itself, so the check runs in this app,
/// which answers only while it is running — Quick Dictation is what keeps it
/// running in the background. The row says so rather than leave a switch
/// that seems to do nothing.
struct TypingGrammarToggle: View {
    let store: GrammarModelStore
    let grammar: GrammarCorrector
    let suggestionsEnabled: Bool

    @AppStorage(
        KeyboardPreferences.typingGrammarKey,
        store: KeyboardPreferences.defaults
    ) private var typingGrammar = KeyboardDefaults.typingGrammar

    var body: some View {
        GrammarModelToggle(
            title: "Check grammar (English)",
            description: "Offers a fix when you pause, while vocaphone is open in the background. "
                + "Nothing changes until you tap it.",
            unavailable: suggestionsEnabled ? nil : "Needs suggestions turned on.",
            isOn: $typingGrammar,
            store: store,
            grammar: grammar
        )
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
