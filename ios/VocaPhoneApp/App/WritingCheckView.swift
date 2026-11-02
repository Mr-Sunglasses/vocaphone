import SwiftUI
import UIKit

/// The text a Writing check screen opens on, from the keyboard's "Open app".
struct WritingCheckRequest: Identifiable, Equatable {
    let id = UUID()
    let text: String
}

/// Writing check in the app: Grammarly's editor, on this iPhone. Paste or
/// write, and every suggestion is underlined in its group's colour, with a
/// card for each, a score, readability and how the text sounds. The rules run
/// here; the grammar model joins in when it is downloaded. Nothing is sent
/// anywhere. Mirrors android/.../ui/WritingCheckScreen.kt.
struct WritingCheckView: View {
    @Environment(RecordingCoordinator.self) private var coordinator
    @Environment(\.colorScheme) private var colorScheme
    @State private var text: String
    @State private var report: WritingCheck.Report?
    @State private var isChecking = false
    /// The text last found not to be English: nothing is suggested for it.
    @State private var notEnglish: String?
    @State private var selected: String?
    @State private var filter: WritingCategory?
    @State private var didCopy = false
    @State private var dismissed = Set<String>()
    @State private var checker: WritingCheck?

    init(initialText: String = "") {
        _text = State(initialValue: initialText)
    }

    private var isDark: Bool { colorScheme == .dark }

    /// The report, only while it describes the text on screen. Its offsets
    /// are into the text it checked, so after an edit or a paste its marks
    /// would land on other words and Accept would edit the wrong place; until
    /// the next check finishes there is nothing to show. As on Android.
    private var current: WritingCheck.Report? {
        report.flatMap { $0.text == text ? $0 : nil }
    }

    private var suggestions: [WritingSuggestion] {
        (current?.suggestions ?? []).filter { !dismissed.contains($0.key) && (filter == nil || $0.category == filter) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                Section {
                    UnderlinedTextView(
                        text: $text,
                        marks: (current?.suggestions ?? []).filter { !dismissed.contains($0.key) },
                        isDark: isDark,
                        onCaret: { caret in
                            guard let hit = current?.suggestions.first(where: { $0.markStart <= caret && caret <= $0.markEnd }) else { return }
                            selected = hit.identity
                            withAnimation { proxy.scrollTo(hit.identity, anchor: .center) }
                        }
                    )
                    .frame(minHeight: 180)
                    .accessibilityLabel("Text to check")
                } footer: {
                    if text.isEmpty {
                        Text("Paste or write something. It is checked on this iPhone and never sent anywhere.")
                    }
                }
                if notEnglish == text, !text.isEmpty {
                    Section {
                        Text("Writing check works on English text.")
                            .foregroundStyle(.secondary)
                    }
                } else if report != nil, !text.isEmpty {
                    if let current {
                        Section { summary(current) }
                        if !current.suggestions.isEmpty {
                            Section { filterBar(current) }
                        }
                    }
                    Section {
                        if suggestions.isEmpty {
                            Text(isChecking || current == nil ? "Checking…" : "No issues found")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(suggestions, id: \.identity) { s in
                            card(s).id(s.identity)
                        }
                    } header: {
                        HStack {
                            Text("Suggestions")
                            Spacer()
                            let mechanical = suggestions.filter { $0.isActionable && $0.mechanical }
                            if mechanical.count >= 2 {
                                Button("Accept all \(mechanical.count)") { accept(mechanical) }
                                    .textCase(nil)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Writing check")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // The system Paste control draws its own filled background, which
            // has no place inside iOS 26's shared glass group: there it sat as
            // a square-cornered block jammed against the group's left end. So
            // it stands on its own, as a round button beside the group.
            ToolbarItem(placement: .topBarTrailing) {
                PasteButton(payloadType: String.self) { strings in
                    if let pasted = strings.first { text = pasted }
                }
                .labelStyle(.iconOnly)
                .buttonBorderShape(.circle)
            }
            .standaloneOnGlass()
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    UIPasteboard.general.string = text
                    didCopy = true
                } label: {
                    Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                }
                .disabled(text.isEmpty)
                ShareLink(item: text) { Label("Share", systemImage: "square.and.arrow.up") }
                    .disabled(text.isEmpty)
            }
        }
        .task {
            if checker == nil {
                checker = await Task.detached(priority: .userInitiated) {
                    WritingRules.bundled().map { WritingCheck(rules: $0) }
                }.value
            }
        }
        // Keyed on the text, so an edit, a paste or leaving the screen cancels
        // the check under way, and `check()` passes that on to its work.
        .task(id: TaskKey(text: text, ready: checker != nil)) {
            didCopy = false
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            await check()
        }
    }

    private struct TaskKey: Equatable {
        let text: String
        let ready: Bool
    }

    // MARK: - Checking

    private enum Outcome: Sendable {
        case checked(WritingCheck.Report)
        case notEnglish
        case cancelled
    }

    private func check() async {
        guard let checker, !text.isEmpty else {
            report = nil
            notEnglish = nil
            return
        }
        isChecking = true
        defer { isChecking = false }
        let snapshot = text
        let grammar = coordinator.grammar
        let modelReady = coordinator.grammarModel.isReady
        let keep = DictatedTranscript.grammarKeeps(
            vocabulary: CustomVocabulary.terms(LocalTranscriptionPreferences.customVocabulary)
                + LearnedWordStore().snapshot().words,
            snippets: SnippetStore.snippets
        )
        let options = WritingCheck.Options(categories: Self.categories(), keep: keep, typed: true)
        let tone = KeyboardPreferences.writingTone
        let work = Task.detached(priority: .userInitiated) { () -> Outcome in
            // The rules are English ones; on another language they would
            // "correct" words that are right. As the keyboard does.
            guard WritingCheck.applies(to: snapshot) else { return .notEnglish }
            // The user opened Writing check to have this text checked: the thorough tier.
            let model: WritingCheck.Model? = modelReady ? { grammar.correctTyped($0, keeping: keep, thorough: true) } : nil
            guard let report = await checker.checkUntilCancelled(snapshot, model: model, options: options) else {
                return .cancelled
            }
            return .checked(report)
        }
        // A detached task does not inherit this one's cancellation: passed on,
        // so a check of text that has since changed stops asking the model.
        let outcome = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
        guard !Task.isCancelled, snapshot == text else { return }
        let result: WritingCheck.Report
        switch outcome {
        case .cancelled:
            return
        case .notEnglish:
            report = nil
            notEnglish = snapshot
            return
        case let .checked(checked):
            notEnglish = nil
            result = checked
        }
        // Tone off in Settings: how the text sounds is not shown, as in the
        // keyboard and on Android.
        report = tone ? result : WritingCheck.Report(
            text: result.text, suggestions: result.suggestions, tones: [], stats: result.stats,
            modelPending: result.modelPending
        )
    }

    private static func categories() -> Set<WritingCategory> {
        var categories: Set<WritingCategory> = [.correctness]
        if KeyboardPreferences.writingClarity { categories.insert(.clarity) }
        if KeyboardPreferences.writingEngagement { categories.insert(.engagement) }
        if KeyboardPreferences.writingDelivery { categories.insert(.delivery) }
        return categories
    }

    /// Applies `chosen` from the last back, so each leaves the earlier
    /// offsets alone, and moves the rest of the report with the text.
    private func accept(_ chosen: [WritingSuggestion]) {
        guard let report = current else { return }
        var edited = text
        var remaining = report.suggestions
        for s in chosen.sorted(by: { $0.start > $1.start }) {
            guard let next = WritingCheck.apply(edited, s) else { continue }
            remaining = WritingCheck.rebase(remaining.filter { $0 != s }, old: edited, new: next)
            edited = next
        }
        self.report = WritingCheck.Report(
            text: edited, suggestions: remaining, tones: report.tones, stats: report.stats,
            modelPending: report.modelPending
        )
        text = edited
    }

    // MARK: - Views

    private func summary(_ report: WritingCheck.Report) -> some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: CGFloat(report.stats.score ?? 0) / 100)
                    .stroke(Color.brand, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(report.stats.score.map(String.init) ?? "–")
                    .font(.title3.weight(.semibold))
            }
            .frame(width: 56, height: 56)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Score \(report.stats.score ?? 0) out of 100")
            VStack(alignment: .leading, spacing: 3) {
                Text("\(report.stats.words) words · \(Self.duration(report.stats.readingSeconds)) to read")
                    .font(.subheadline.weight(.medium))
                if let label = report.stats.readabilityLabel {
                    Text("Readability \(report.stats.readability ?? 0) · \(label)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if !report.tones.isEmpty {
                    Text("Sounds " + report.tones.map { "\($0.emoji) \($0.label)" }.joined(separator: " · "))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func filterBar(_ report: WritingCheck.Report) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("All \(report.suggestions.filter { !dismissed.contains($0.key) }.count)", nil)
                ForEach(WritingCategory.allCases, id: \.self) { category in
                    let count = report.suggestions.filter { $0.category == category && !dismissed.contains($0.key) }.count
                    if count > 0 { chip("\(WritingColors.name(category)) \(count)", category) }
                }
            }
        }
    }

    private func chip(_ title: String, _ category: WritingCategory?) -> some View {
        Button(title) { filter = category }
            .buttonStyle(.bordered)
            .tint(category.map { WritingColors.of($0, isDark: isDark) } ?? .brand)
            .opacity(filter == category ? 1 : 0.6)
    }

    private func card(_ s: WritingSuggestion) -> some View {
        let color = WritingColors.of(s.category, isDark: isDark)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text("\(WritingColors.name(s.category)) · \(s.title)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            if let replacement = s.shownReplacement {
                HStack(spacing: 8) {
                    if !s.shownOriginal.isEmpty {
                        Text(s.shownOriginal).strikethrough().foregroundStyle(.secondary)
                    }
                    Text(replacement.isEmpty ? "(remove)" : replacement)
                        .fontWeight(.semibold)
                        .foregroundStyle(color)
                }
            }
            Text(s.message).font(.subheadline)
            HStack(spacing: 18) {
                if s.isActionable {
                    Button("Accept") { accept([s]) }.fontWeight(.semibold)
                }
                Button("Ignore") { dismissed.insert(s.key) }
                if s.kind == "spelling", !s.shownOriginal.contains(where: \.isWhitespace) {
                    Button("Add to dictionary") {
                        // The keyboard's learned words: never flagged or
                        // corrected again, here or while typing.
                        let word = s.shownOriginal
                        LearnedWordStore().update { $0.learn(word) }
                        dismissed.insert(s.key)
                    }
                }
            }
            .buttonStyle(.borderless)
            .font(.subheadline)
        }
        .padding(.vertical, 2)
        .listRowBackground(selected == s.identity ? color.opacity(0.08) : nil)
    }

    private static func duration(_ seconds: Int) -> String {
        seconds < 60 ? "\(max(seconds, 1)) s" : "\(Int((Double(seconds) / 60).rounded(.up))) min"
    }
}

/// A `UITextView` that underlines each suggestion in its group's colour, as
/// Grammarly does, without disturbing the text or the caret as the marks
/// change. Tapping into a mark reports where.
private struct UnderlinedTextView: UIViewRepresentable {
    @Binding var text: String
    let marks: [WritingSuggestion]
    let isDark: Bool
    let onCaret: (Int) -> Void

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.isScrollEnabled = false
        view.autocorrectionType = .no
        view.spellCheckingType = .no
        view.delegate = context.coordinator
        view.text = text
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        if view.text != text {
            let selection = view.selectedRange
            view.text = text
            view.selectedRange = NSRange(location: min(selection.location, (text as NSString).length), length: 0)
        }
        let storage = view.textStorage
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.removeAttribute(.underlineStyle, range: full)
        storage.removeAttribute(.underlineColor, range: full)
        for mark in marks {
            let range = NSRange(location: mark.markStart, length: mark.markEnd - mark.markStart)
            guard range.length > 0, NSMaxRange(range) <= storage.length else { continue }
            storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.thick.rawValue, range: range)
            storage.addAttribute(.underlineColor, value: UIColor(WritingColors.of(mark.category, isDark: isDark)), range: range)
        }
        storage.endEditing()
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: UnderlinedTextView

        init(parent: UnderlinedTextView) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard textView.selectedRange.length == 0 else { return }
            parent.onCaret(textView.selectedRange.location)
        }
    }
}

private extension ToolbarContent {
    /// Keeps an item out of iOS 26's shared glass background, for a control
    /// that brings its own.
    @ToolbarContentBuilder
    func standaloneOnGlass() -> some ToolbarContent {
        if #available(iOS 26, *) {
            sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}
