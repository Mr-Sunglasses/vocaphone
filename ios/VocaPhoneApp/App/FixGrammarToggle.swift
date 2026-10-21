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
    @State private var offering = false

    private var size: String { DownloadReadiness.byteLabel(store.sizeBytes) }

    var body: some View {
        Toggle(isOn: Binding(
            get: { fixGrammar && store.isReady && style != .raw },
            set: { on in
                if !on {
                    fixGrammar = false
                } else if store.isReady {
                    fixGrammar = true
                } else {
                    offering = true
                }
            }
        )) {
            SettingLabel("Fix grammar (English)", detail: detail)
        }
        .disabled(style == .raw || isDownloading)
        .confirmationDialog(
            "Download the grammar model?",
            isPresented: $offering,
            titleVisibility: .visible
        ) {
            Button("Download \(size)") { download() }
            Button("Not now", role: .cancel) {}
        } message: {
            Text(
                "Fix grammar uses a \(size) model that runs on this iPhone. Your words are "
                    + "corrected here and never sent anywhere. It fixes common English grammar "
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
        if style == .raw { return "Not applied to the Raw style." }
        switch store.phase {
        case let .downloading(fraction):
            return "Downloading the grammar model · \(Int(fraction * 100))%"
        case let .failed(reason):
            return reason.plainText
        case .ready:
            return "Common grammar slips, on this iPhone."
        case .absent:
            return "Common grammar slips, on this iPhone. \(size) download."
        }
    }

    private func download() {
        Task {
            do {
                try await store.download()
                grammar.modelChanged()
                fixGrammar = true
            } catch {
                // `phase` says why; the setting stays off.
            }
        }
    }
}
