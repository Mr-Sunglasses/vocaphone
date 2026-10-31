import Foundation

/// Writing check inside the keyboard.
///
/// The rules run right here, in the extension: they are small, and they work
/// whether or not VocaPhone is running. The grammar model cannot live here —
/// the extension already runs close to its memory limit — so the sentences it
/// has not seen go to the containing app through the App Group
/// (`TypedGrammarRequest`), and the app's answers come back the same way. The
/// app only hears the question while it is running, which for a keyboard user
/// means while Quick Dictation keeps it in the background; otherwise the rules
/// alone answer. Nothing is sent anywhere else, and nothing in the document
/// changes until the user taps a suggestion.
///
/// Nothing here runs per keystroke beyond restarting a timer. Mirrors
/// android/.../ime/WritingCheckSession.kt.
@MainActor
final class WritingCheckClient {
    /// The document as the keyboard sees it: `text` with the cursor at
    /// `cursor`, in UTF-16 units.
    struct Field: Equatable {
        let text: String
        let cursor: Int
    }

    struct Options: Equatable {
        var categories: Set<WritingCategory> = Set(WritingCategory.allCases)
        var keep: [String] = []
        var tone = true
    }

    struct Report: Equatable {
        let field: Field
        let suggestions: [WritingSuggestion]
        let tones: [WritingCheck.Tone]
        /// What the strip may offer as chips: actionable, nearest the cursor first.
        let chips: [WritingSuggestion]
        let modelPending: Bool

        var count: Int { suggestions.count }
    }

    private(set) var report: Report?
    private(set) var isChecking = false
    /// Called whenever `report` or `isChecking` changes.
    var onChange: (() -> Void)?
    /// The language gate: the rules and the model are English.
    var isEnglish: (String) -> Bool = { _ in true }

    private let store: SharedStore
    private let isAppRunning: () -> Bool
    private let modelReady: () -> Bool
    private let checker: () -> WritingCheck?
    private let pause: Duration
    private let now: () -> Date
    private let observe: (@escaping @Sendable () -> Void) -> VocaPhoneDarwinObservation?
    private var pending: Task<Void, Never>?
    private var observation: VocaPhoneDarwinObservation?
    /// The question in flight. It expires with the request, so an app that
    /// ended before answering cannot block the model for good.
    private var outstanding: (id: UUID, sentences: [String], sentAt: Date)?
    /// The model's answer per sentence, for this field.
    private var answers: [String: String] = [:]
    private var answerOrder: [String] = []
    /// Sentences already asked about in this field; one that came back
    /// unanswered is asked again.
    private var asked = Set<String>()
    /// Suggestions waved away in this field, by `WritingSuggestion.key`.
    private var dismissed = Set<String>()
    private var lastField: Field?
    private var options = Options()

    init(
        store: SharedStore = .shared,
        isAppRunning: @escaping () -> Bool,
        modelReady: @escaping () -> Bool = { KeyboardPreferences.grammarModelReady },
        checker: @escaping () -> WritingCheck?,
        pause: Duration = .milliseconds(700),
        now: @escaping () -> Date = { Date() },
        observe: @escaping (@escaping @Sendable () -> Void) -> VocaPhoneDarwinObservation? = {
            VocaPhoneDarwinCenter.observe(.typedGrammarAnswered, handler: $0)
        }
    ) {
        self.store = store
        self.isAppRunning = isAppRunning
        self.modelReady = modelReady
        self.checker = checker
        self.pause = pause
        self.now = now
        self.observe = observe
    }

    /// The document changed. Suggestions that still fit it are moved to where
    /// their words now are; a new check waits for the pause. `enabled` false
    /// clears everything.
    func textChanged(before: String?, after: String?, enabled: Bool, options: @escaping () -> Options) {
        pending?.cancel()
        guard enabled, let before else {
            pending = nil
            abandonOutstanding()
            lastField = nil
            publish(nil)
            return
        }
        let field = Field(text: before + (after ?? ""), cursor: before.utf16Length)
        let previous = lastField
        lastField = field
        if let report, report.field != field {
            if previous != nil, let moved = rebase(report, to: field) {
                publish(moved)
            } else {
                publish(nil)
            }
        }
        pending = Task { [weak self, pause] in
            try? await Task.sleep(for: pause)
            guard !Task.isCancelled else { return }
            self?.check(field, options())
        }
    }

    /// Checks now, without waiting: the panel's "Check again", or a whole
    /// message the keyboard has just read by walking the cursor.
    func checkNow(_ field: Field? = nil, options: Options) {
        pending?.cancel()
        guard let field = field ?? lastField else { return }
        lastField = field
        check(field, options)
    }

    private func check(_ field: Field, _ options: Options) {
        self.options = options
        guard let checker = checker() else { return }
        guard field.text.contains(where: \.isLetter), isEnglish(field.text) else {
            publish(nil)
            return
        }
        isChecking = true
        defer {
            isChecking = false
            onChange?()
        }
        let modelInUse = modelReady() && isAppRunning()
        var missing: [String] = []
        let answers = self.answers
        let model: WritingCheck.Model? = modelInUse ? { sentence in
            if let answer = answers[sentence] { return answer }
            missing.append(sentence)
            return nil
        } : nil
        let result = checker.check(
            field.text,
            model: model,
            options: WritingCheck.Options(categories: options.categories, keep: Set(options.keep), typed: true)
        )
        report = makeReport(field, result, tone: options.tone)
        if modelInUse { ask(missing.filter { !asked.contains($0) }, keep: options.keep) }
    }

    private func makeReport(_ field: Field, _ result: WritingCheck.Report, tone: Bool) -> Report {
        let word = Self.wordAt(field.text, field.cursor)
        let suggestions = result.suggestions.filter { s in
            // Not the word being typed: it is not finished.
            !dismissed.contains(s.key) && (word == nil || s.markEnd < word!.0 || s.markStart > word!.1)
        }
        return Report(
            field: field,
            suggestions: suggestions,
            tones: tone ? result.tones : [],
            chips: Self.chips(suggestions, cursor: field.cursor),
            modelPending: result.modelPending
        )
    }

    private static func chips(_ suggestions: [WritingSuggestion], cursor: Int) -> [WritingSuggestion] {
        let actionable = suggestions.filter(\.isActionable).enumerated().sorted { a, b in
            let da = abs(a.element.markEnd - cursor)
            let db = abs(b.element.markEnd - cursor)
            return da != db ? da < db : a.offset < b.offset
        }
        return Array(actionable.prefix(3).map(\.element))
    }

    /// The word the cursor touches, as `(start, end)`; nil between words.
    private static func wordAt(_ text: String, _ cursor: Int) -> (Int, Int)? {
        let units = Array(text.utf16)
        func isWord(_ i: Int) -> Bool {
            guard i >= 0, i < units.count, let scalar = Unicode.Scalar(units[i]) else { return false }
            return WritingText.isLetterOrDigit(scalar) || scalar == "'" || scalar == "’"
        }
        var start = cursor
        while isWord(start - 1) { start -= 1 }
        var end = cursor
        while isWord(end) { end += 1 }
        return end > start ? (start, end) : nil
    }

    private func rebase(_ report: Report, to field: Field) -> Report? {
        let moved = WritingCheck.rebase(report.suggestions, old: report.field.text, new: field.text)
        guard !moved.isEmpty else { return nil }
        return Report(
            field: field, suggestions: moved, tones: report.tones,
            chips: Self.chips(moved, cursor: field.cursor), modelPending: report.modelPending
        )
    }

    // MARK: - The model, through the app

    private func ask(_ sentences: [String], keep: [String]) {
        guard !sentences.isEmpty else { return }
        if let outstanding {
            guard now().timeIntervalSince(outstanding.sentAt) > TypedGrammarRequest.maximumAge else { return }
            abandonOutstanding()
        }
        let joined = sentences.joined(separator: " ")
        // Only the protected words these sentences contain. The list includes
        // every contact name `UILexicon` offers, and those have no business in
        // a file because one of them might have been typed.
        let present = Self.wordsPresent(keep, in: joined)
        let request = TypedGrammarRequest(sentences: sentences, keep: present, createdAt: now())
        // Listening before asking: an app that answers before a listener
        // registered afterwards would ping nobody.
        if observation == nil {
            observation = observe { Task { @MainActor [weak self] in self?.collect() } }
        }
        // No Full Access is no App Group, and so no way to ask.
        guard (try? store.saveTypedGrammarRequest(request)) != nil else { return }
        outstanding = (request.id, request.sentences, request.createdAt)
        asked.formUnion(request.sentences)
    }

    /// Reads the app's answer. Called on its ping, and by tests.
    func collect() {
        guard let answer = store.takeTypedGrammarAnswer(),
              let outstanding, answer.id == outstanding.id
        else { return }
        self.outstanding = nil
        for (sentence, corrected) in zip(outstanding.sentences, answer.corrected) {
            if let corrected {
                remember(sentence, corrected)
            } else {
                // The app could not check it; the next pause asks again.
                asked.remove(sentence)
            }
        }
        if let lastField { check(lastField, options) }
    }

    private func remember(_ sentence: String, _ corrected: String) {
        if answers[sentence] == nil { answerOrder.append(sentence) }
        answers[sentence] = corrected
        while answerOrder.count > Self.answerCache {
            answers.removeValue(forKey: answerOrder.removeFirst())
        }
    }

    // MARK: - What the user does

    /// `suggestion` is being applied: it leaves the report, and the others are
    /// moved to where they now sit in the edited text.
    func applied(_ suggestion: WritingSuggestion) {
        guard let report, let edited = WritingCheck.apply(report.field.text, suggestion) else { return }
        let delta = edited.utf16Length - report.field.text.utf16Length
        let cursor = report.field.cursor >= suggestion.end ? report.field.cursor + delta : report.field.cursor
        let field = Field(text: edited, cursor: cursor)
        let rest = WritingCheck.rebase(report.suggestions.filter { $0 != suggestion }, old: report.field.text, new: edited)
        lastField = field
        publish(Report(
            field: field, suggestions: rest, tones: report.tones,
            chips: Self.chips(rest, cursor: cursor), modelPending: report.modelPending
        ))
    }

    /// The user waved `suggestion` away: it is not offered again in this field.
    func dismiss(_ suggestion: WritingSuggestion) {
        dismissed.insert(suggestion.key)
        guard let report else { return }
        let rest = report.suggestions.filter { $0.key != suggestion.key }
        publish(Report(
            field: report.field, suggestions: rest, tones: report.tones,
            chips: Self.chips(rest, cursor: report.field.cursor), modelPending: report.modelPending
        ))
    }

    /// A new field, or the keyboard went away: nothing carries over, and a
    /// question nobody will collect is removed.
    func reset() {
        pending?.cancel()
        pending = nil
        observation?.invalidate()
        observation = nil
        abandonOutstanding()
        answers = [:]
        answerOrder = []
        asked = []
        dismissed = []
        lastField = nil
        publish(nil)
    }

    /// Forgets the question in flight, and removes it and any answer from the
    /// App Group so the typed text does not wait there for nobody.
    private func abandonOutstanding() {
        guard let outstanding else { return }
        asked.subtract(outstanding.sentences)
        self.outstanding = nil
        store.clearTypedGrammarExchange()
    }

    private func publish(_ report: Report?) {
        guard report != self.report else { return }
        self.report = report
        onChange?()
    }

    /// The lowercased `words` that occur in `text` as whole words.
    static func wordsPresent(_ words: [String], in text: String) -> [String] {
        let present = Set(WritingText.tokenize(text).filter(\.isWord).map(\.key))
        return words.filter { word in
            let parts = WritingText.tokenize(word).filter(\.isWord).map(\.key)
            return !parts.isEmpty && parts.allSatisfy(present.contains)
        }
    }

    private static let answerCache = 256
}
