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
/// Nothing here runs per keystroke beyond restarting a timer, and the check
/// itself runs off the main thread so it never holds up a key. Mirrors
/// android/.../ime/WritingCheckSession.kt.
@MainActor
final class WritingCheckClient {
    /// The document as the keyboard sees it: `text` with the cursor at
    /// `cursor`, in UTF-16 units.
    struct Field: Equatable, Sendable {
        let text: String
        let cursor: Int
        /// The part of `text` the keyboard can edit from where the cursor is,
        /// in UTF-16 units; nil is all of it. A whole message read by walking
        /// the cursor reaches past the window iOS hands the keyboard, and a fix
        /// out there cannot be made from here.
        var reach: Range<Int>? = nil
    }

    struct Options: Equatable, Sendable {
        var categories: Set<WritingCategory> = Set(WritingCategory.allCases)
        var keep: [String] = []
        var tone = true
    }

    struct Report: Equatable {
        let field: Field
        let suggestions: [WritingSuggestion]
        let tones: [WritingCheck.Tone]
        /// What the strip may offer as chips: actionable and within reach,
        /// nearest the cursor first.
        let chips: [WritingSuggestion]
        let modelPending: Bool

        var count: Int { suggestions.count }

        /// Whether Accept can make `suggestion` from where the cursor is.
        func canApply(_ suggestion: WritingSuggestion) -> Bool {
            suggestion.isActionable && field.isReachable(suggestion)
        }
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
    /// The check under way. A newer check, an edit, or a reset makes its
    /// result stale; `generation` says which one is current.
    private var running: Task<Void, Never>?
    private var generation = 0
    private var observation: VocaPhoneDarwinObservation?
    /// The question in flight. It expires with the request, so an app that
    /// ended before answering cannot block the model for good. Only these
    /// sentences count as asked.
    private var outstanding: (id: UUID, sentences: [String], sentAt: Date)?
    /// The model's answer per sentence, for this field.
    private var answers: [String: String] = [:]
    private var answerOrder: [String] = []
    /// How many times the app answered a sentence with nothing (the model
    /// failed to load, or is turned off there). Such a sentence waits for the
    /// next pause, and is given up on after `maximumAsks`.
    private var unanswered: [String: Int] = [:]
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
        let field = before.map { Field(text: $0 + (after ?? ""), cursor: $0.utf16Length) }
        // A whole message the keyboard read, seen again through the window:
        // nothing in it changed, so neither does the report.
        if enabled, let before, let last = lastField, last.reach != nil,
           let window = Self.window(before: before, after: after ?? "", in: last) {
            lastField = window
            if let report, report.field != window {
                publish(Self.report(report, field: window, suggestions: report.suggestions))
            }
            return
        }
        pending?.cancel()
        guard enabled, let field else {
            pending = nil
            stopChecking()
            abandonOutstanding()
            lastField = nil
            publish(nil)
            return
        }
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
            self?.check(field, options(), retry: true)
        }
    }

    /// Checks now, without waiting: the panel's "Check again", or a whole
    /// message the keyboard has just read by walking the cursor.
    func checkNow(_ field: Field? = nil, options: Options) {
        pending?.cancel()
        guard let field = field ?? lastField else { return }
        lastField = field
        check(field, options, retry: true)
    }

    /// Waits for the pause and the check under way, if any. For tests.
    func settle() async {
        await pending?.value
        await running?.value
    }

    /// Starts a check of `field`. The rules (and the answers the model has
    /// already given) run off the main thread; the report is published only
    /// if nothing newer has started and the field is still the one checked.
    /// `retry` lets sentences the app could not answer be asked again: true
    /// after a pause or a tap, false when an answer has just come in.
    private func check(_ field: Field, _ options: Options, retry: Bool) {
        self.options = options
        guard let checker = checker() else { return }
        guard field.text.contains(where: \.isLetter), isEnglish(field.text) else {
            stopChecking()
            publish(nil)
            return
        }
        generation += 1
        let current = generation
        let modelInUse = modelReady() && isAppRunning()
        let known: [String: String]? = modelInUse ? answers : nil
        let checkOptions = WritingCheck.Options(categories: options.categories, keep: Set(options.keep), typed: true)
        if !isChecking {
            isChecking = true
            onChange?()
        }
        running = Task { [weak self] in
            let (result, missing) = await Task.detached(priority: .userInitiated) {
                var missing: [String] = []
                let model: WritingCheck.Model? = known.map { known in
                    { sentence in
                        if let answer = known[sentence] { return answer }
                        missing.append(sentence)
                        return nil
                    }
                }
                return (checker.check(field.text, model: model, options: checkOptions), missing)
            }.value
            guard let self, current == generation else { return }
            isChecking = false
            guard lastField == field, self.options == options else {
                onChange?()
                return
            }
            report = makeReport(field, result, tone: options.tone)
            onChange?()
            if modelInUse { askFor(missing, keep: options.keep, retry: retry) }
        }
    }

    /// Makes any check under way stale and says nothing is being checked.
    private func stopChecking() {
        generation += 1
        running = nil
        if isChecking {
            isChecking = false
            onChange?()
        }
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
            chips: Self.chips(suggestions, in: field),
            modelPending: result.modelPending
        )
    }

    private static func report(_ report: Report, field: Field, suggestions: [WritingSuggestion]) -> Report {
        Report(
            field: field, suggestions: suggestions, tones: report.tones,
            chips: chips(suggestions, in: field), modelPending: report.modelPending
        )
    }

    private static func chips(_ suggestions: [WritingSuggestion], in field: Field) -> [WritingSuggestion] {
        let actionable = suggestions.filter { $0.isActionable && field.isReachable($0) }.enumerated().sorted { a, b in
            let da = abs(a.element.markEnd - field.cursor)
            let db = abs(b.element.markEnd - field.cursor)
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

    /// `last` with its reach moved to the window `before`|`after`, when that
    /// window is exactly the text around `last`'s cursor; nil otherwise.
    private static func window(before: String, after: String, in last: Field) -> Field? {
        let start = last.cursor - before.utf16Length
        let end = last.cursor + after.utf16Length
        guard start >= 0, end <= last.text.utf16Length,
              last.text.utf16Slice(start, last.cursor) == before,
              last.text.utf16Slice(last.cursor, end) == after
        else { return nil }
        return Field(text: last.text, cursor: last.cursor, reach: start..<end)
    }

    private func rebase(_ report: Report, to field: Field) -> Report? {
        let moved = WritingCheck.rebase(report.suggestions, old: report.field.text, new: field.text)
        guard !moved.isEmpty else { return nil }
        return Self.report(report, field: field, suggestions: moved)
    }

    // MARK: - The model, through the app

    /// Asks the app about the sentences the model has not answered: not the
    /// ones already in flight, and one the app answered with nothing only on a
    /// `retry`, and only `maximumAsks` times in all.
    private func askFor(_ missing: [String], keep: [String], retry: Bool) {
        // An expired question is forgotten first, or its sentences would
        // count as asked forever.
        expireOutstanding()
        let inFlight = Set(outstanding?.sentences ?? [])
        var seen = Set<String>()
        let sentences = missing.filter { sentence in
            guard !inFlight.contains(sentence), seen.insert(sentence).inserted else { return false }
            let failed = unanswered[sentence] ?? 0
            return retry ? failed < Self.maximumAsks : failed == 0
        }
        ask(sentences, keep: keep)
    }

    private func expireOutstanding() {
        guard let outstanding, now().timeIntervalSince(outstanding.sentAt) > TypedGrammarRequest.maximumAge else { return }
        abandonOutstanding()
    }

    private func ask(_ sentences: [String], keep: [String]) {
        guard !sentences.isEmpty, outstanding == nil else { return }
        let joined = sentences.joined(separator: " ")
        // Only the protected words these sentences contain. The list includes
        // every contact name `UILexicon` offers, and those have no business in
        // a file because one of them might have been typed.
        let present = Self.wordsPresent(keep, in: joined)
        let request = TypedGrammarRequest(sentences: sentences, keep: present, createdAt: now())
        // Listening before asking: an app that answers before a listener
        // registered afterwards would ping nobody.
        if observation == nil {
            observation = observe { [weak self] in Task { @MainActor [weak self] in self?.collect() } }
        }
        // No Full Access is no App Group, and so no way to ask.
        guard (try? store.saveTypedGrammarRequest(request)) != nil else { return }
        outstanding = (request.id, request.sentences, request.createdAt)
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
                unanswered[sentence] = nil
            } else {
                // The app could not check it: the rules' report stands, and
                // the next pause may ask again.
                if unanswered.count >= Self.answerCache { unanswered = [:] }
                unanswered[sentence, default: 0] += 1
            }
        }
        // Rebuilt with the new answers; nothing that just came back empty is
        // asked again until the user pauses.
        if let lastField { check(lastField, options, retry: false) }
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
        let old = report.field
        let delta = edited.utf16Length - old.text.utf16Length
        let cursor = old.cursor >= suggestion.end ? old.cursor + delta : old.cursor
        let reach = old.reach.map { $0.lowerBound..<max($0.lowerBound, $0.upperBound + delta) }
        let field = Field(text: edited, cursor: cursor, reach: reach)
        let rest = WritingCheck.rebase(report.suggestions.filter { $0 != suggestion }, old: old.text, new: edited)
        lastField = field
        publish(Self.report(report, field: field, suggestions: rest))
    }

    /// The user waved `suggestion` away: it is not offered again in this field.
    func dismiss(_ suggestion: WritingSuggestion) {
        dismiss(key: suggestion.key)
    }

    /// The change `key` names (`WritingSuggestion.key`) is not offered again
    /// in this field, wherever it is.
    func dismiss(key: String) {
        dismissed.insert(key)
        guard let report else { return }
        let rest = report.suggestions.filter { $0.key != key }
        publish(Self.report(report, field: report.field, suggestions: rest))
    }

    /// A new field, or the keyboard went away: nothing carries over, and a
    /// question nobody will collect is removed.
    func reset() {
        pending?.cancel()
        pending = nil
        stopChecking()
        observation?.invalidate()
        observation = nil
        abandonOutstanding()
        answers = [:]
        answerOrder = []
        unanswered = [:]
        dismissed = []
        lastField = nil
        publish(nil)
    }

    /// Forgets the question in flight, and removes it and any answer from the
    /// App Group so the typed text does not wait there for nobody.
    private func abandonOutstanding() {
        guard outstanding != nil else { return }
        outstanding = nil
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
    /// How many empty answers a sentence gets before it is left to the rules.
    private static let maximumAsks = 2
}

extension WritingCheckClient.Field {
    /// Whether `suggestion` lies within what the keyboard can edit.
    func isReachable(_ suggestion: WritingSuggestion) -> Bool {
        guard let reach else { return true }
        return reach.lowerBound <= suggestion.start && suggestion.end <= reach.upperBound
    }
}

/// An automatic typo fix, and what its Undo needs. The fixed words are found
/// again by what the fix left behind the cursor (`tail`), never by searching
/// for the replacement, which could just as well be a correct word elsewhere.
struct WritingAutoFix: Equatable, Sendable {
    let label: String
    /// `WritingSuggestion.key`: dismissed on Undo so the fix is not made again.
    let key: String
    let typed: String
    let wrote: String
    /// The replacement and everything after it up to the cursor, as the fix
    /// leaves it. Undo is offered only while the text before the cursor still
    /// ends with exactly this; any later edit retires it.
    let tail: String

    /// The fix `suggestion` makes in `field`; nil when it is not before the cursor.
    init?(_ suggestion: WritingSuggestion, in field: WritingCheckClient.Field) {
        guard let replacement = suggestion.replacement, suggestion.end <= field.cursor,
              field.cursor <= field.text.utf16Length
        else { return nil }
        label = suggestion.label
        key = suggestion.key
        typed = suggestion.original
        wrote = replacement
        tail = replacement + field.text.utf16Slice(suggestion.end, field.cursor)
    }

    /// Whether the text before the cursor is still as the fix left it.
    func isCurrent(before: String?) -> Bool {
        guard let before else { return false }
        return before.utf16Length >= tail.utf16Length
            && before.utf16Slice(before.utf16Length - tail.utf16Length, before.utf16Length) == tail
    }

    /// How far back from the cursor the fixed words end, in UTF-16 units.
    var distance: Int { tail.utf16Length - wrote.utf16Length }
}
