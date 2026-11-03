import Combine
import SwiftUI

extension SettingsHelp {
    static let learnedCorrections = LearnMoreTopic(
        title: "Learning from your corrections",
        parts: [
            .init(heading: "What it does", paragraphs: [
                "When you fix a word in something you just dictated, using the vocaphone "
                    + "keyboard, the keyboard notices the new spelling and suggests it "
                    + "here: \u{201C}Namratha\u{201D} fixed to \u{201C}Namrata\u{201D}, "
                    + "\u{201C}git hub\u{201D} to \u{201C}GitHub\u{201D}.",
                "Only spelling fixes count: a name spelled another way, different "
                    + "capitals, or words joined into one. Rewording, and swapping one "
                    + "ordinary word for another, are ignored, and so is text that is not "
                    + "in English.",
            ]),
            .init(heading: "What is read and kept", paragraphs: [
                "To see what you changed, the keyboard compares the text around the "
                    + "dictation as you edit it, for up to 20 seconds, until your next "
                    + "dictation, or until the keyboard closes. That text stays in the "
                    + "keyboard's memory on this iPhone and is never saved.",
                "Only the pair of words, what was heard and how you wrote it, is passed "
                    + "to the app through its shared storage on this iPhone and kept here. "
                    + "Nothing is read in secure, one-time-code, card-number or number-pad "
                    + "fields, and nothing leaves the iPhone.",
            ]),
            .init(heading: "Adding", paragraphs: [
                "Add puts the word in your custom words, so dictation spells it your way "
                    + "and listens for it, and adds a replacement when dictation heard "
                    + "different letters. A name or term you fix the same way twice is "
                    + "added for you; remove it from Custom words or Replacements if that "
                    + "was wrong.",
                "Turn learning off to stop all of this. Clear Suggestions forgets every "
                    + "suggestion and dismissal; words already added stay until you remove "
                    + "them.",
            ]),
        ]
    )
}

/// Spellings the keyboard learned from the user's fixes to dictated text:
/// Add or Dismiss each, with the switch that turns learning off.
struct CorrectionSuggestionsSettingsView: View {
    @AppStorage(
        CorrectionLearningPreferences.enabledKey,
        store: UserDefaults(suiteName: AppConfiguration.appGroupIdentifier)
    ) private var enabled = true
    @State private var suggestions: [CorrectionSuggestion] = CorrectionLearningPreferences.suggestions
    @State private var dismissedCount = CorrectionLearningPreferences.dismissed.count
    @State private var confirmingClear = false
    @State private var learnMore: LearnMoreTopic?

    var body: some View {
        List {
            Section {
                Toggle(isOn: $enabled) {
                    SettingLabel("Learn from my corrections", detail: "Only the words you fixed are kept.")
                }
            } header: {
                LearnMoreHeader(title: "Learning", topic: SettingsHelp.learnedCorrections, presented: $learnMore)
            } footer: {
                Text(enabled
                    ? "Spellings you fix after dictating with the vocaphone keyboard appear below."
                    : "Off. The keyboard does not look at your fixes.")
            }
            Section("Suggested") {
                if suggestions.isEmpty {
                    Text("Nothing yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(suggestions) { suggestion in
                        CorrectionSuggestionRow(
                            suggestion: suggestion,
                            onAdd: { add(suggestion) },
                            onDismiss: { dismiss(suggestion) }
                        )
                    }
                }
            }
            if !suggestions.isEmpty || dismissedCount > 0 {
                Section {
                    Button("Clear Suggestions", role: .destructive) { confirmingClear = true }
                }
            }
        }
        .navigationTitle("Suggested Words")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $learnMore) { LearnMoreSheet(topic: $0) }
        .confirmationDialog("Clear suggestions?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Clear", role: .destructive) {
                CorrectionLearningPreferences.clear()
                reload()
            }
        } message: {
            Text("Forgets every suggested and dismissed spelling. Words already added stay.")
        }
        .onAppear {
            CorrectionLearningPreferences.collectFromKeyboard()
            reload()
        }
        // The app collects the keyboard's fixes as it comes forward, which can
        // be while this screen is open.
        .onReceive(
            NotificationCenter.default.publisher(for: CorrectionLearningPreferences.didChange)
                .receive(on: DispatchQueue.main)
        ) { _ in
            reload()
        }
        .onChange(of: enabled) { _, isOn in
            // Off means nothing waits on disk either.
            if !isOn { SharedStore.shared.removeLearnedCorrections() }
        }
    }

    private func add(_ suggestion: CorrectionSuggestion) {
        CorrectionLearningPreferences.accept(suggestion)
        reload()
    }

    private func dismiss(_ suggestion: CorrectionSuggestion) {
        CorrectionLearningPreferences.dismiss(suggestion)
        reload()
    }

    private func reload() {
        suggestions = CorrectionLearningPreferences.suggestions
        dismissedCount = CorrectionLearningPreferences.dismissed.count
    }
}

private struct CorrectionSuggestionRow: View {
    let suggestion: CorrectionSuggestion
    let onAdd: () -> Void
    let onDismiss: () -> Void

    private var detail: String {
        let heard = "Heard \u{201C}\(suggestion.heard)\u{201D}"
        return suggestion.occurrences > 1 ? heard + " · fixed \(suggestion.occurrences) times" : heard
    }

    var body: some View {
        HStack(spacing: VocaMetrics.tight) {
            VStack(alignment: .leading, spacing: 2) {
                Text(suggestion.corrected)
                    .font(.body.weight(.semibold))
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("Dismiss", action: onDismiss)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            Button("Add", action: onAdd)
                .buttonStyle(.borderless)
                .fontWeight(.semibold)
        }
        .accessibilityElement(children: .contain)
    }
}
