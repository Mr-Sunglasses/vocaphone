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
        /// Everything the check found that still fits the text, including what
        /// touches the word the cursor is in. Kept so that leaving that word
        /// brings its suggestions back without another check; edits, Accept and
        /// dismissals work on this list.
        let all: [WritingSuggestion]
        /// What the user is shown (the count, the chips and the panel): `all`
        /// without the word the cursor is in, which is being typed or has just
        /// been gone back into, and is not finished.
        let suggestions: [WritingSuggestion]
        let tones: [WritingCheck.Tone]
        /// What the strip may offer as chips: actionable and within reach,
        /// nearest the cursor first.
        let chips: [WritingSuggestion]
        let modelPending: Bool

        init(field: Field, all: [WritingSuggestion], tones: [WritingCheck.Tone], modelPending: Bool) {
            self.field = field
            self.all = all
            suggestions = WritingCheckClient.outsideCurrentWord(all, in: field)
            self.tones = tones
            chips = WritingCheckClient.chips(suggestions, in: field)
            self.modelPending = modelPending
        }

        var count: Int { suggestions.count }

        /// Whether Accept can make `suggestion` from where the cursor is.
        func canApply(_ suggestion: WritingSuggestion) -> Bool {
            suggestion.isActionable && field.isReachable(suggestion)
        }

        /// The fix "Fix obvious typos as I type" may make without a tap: a
        /// known misspelling or missing apostrophe the user has finished
        /// typing, the latest one before the cursor.
        var autoFix: WritingSuggestion? {
            suggestions.filter {
                $0.source == .rule && ($0.kind == "spelling" || $0.kind == "apostrophe") && canApply($0)
                    && $0.end < field.cursor
            }.max(by: { $0.start < $1.start })
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
    /// The Writing check button's check, waiting out its beat; `buttonTaps`
    /// says which tap is the latest.
    private var buttonCheck: Task<Void, Never>?
    private var buttonTaps = 0
    /// The check under way. A newer check, an edit, or a reset makes its
    /// result stale; `generation` says which one is current.
    private var running: Task<Void, Never>?
    private var generation = 0
    private var observation: VocaPhoneDarwinObservation?
    /// The question in flight. It expires with the request, so an app that
    /// ended before answering cannot block the model for good. Only these
    /// sentences count as asked.
    private var outstanding: (id: UUID, sentences: [String], sentAt: Date, thorough: Bool)?
    /// The model's answer per tier and sentence (`answerKey`), for this field.
    private var answers: [String: String] = [:]
    /// The user asked for a check in this field with the button: every check
    /// of it from then on is thorough (`GrammarTagger.thoroughKeepBias` in the
    /// app), so a pause never trades the suggestions the button found for
    /// fewer. A new field starts over. Mirrors `following` on Android.
    private var thorough = false
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
    /// their words now are; a new check waits for the pause when `autoCheck`
    /// ("Check while typing") is on. Off, a report the user asked for with the
    /// Writing check button keeps following the text, and nothing new is
    /// checked until the next tap. `enabled` false (a field Writing check does
    /// not read) clears everything.
    func textChanged(
        before: String?, after: String?, enabled: Bool, autoCheck: Bool = true,
        options: @escaping () -> Options
    ) {
        let field = before.map { Field(text: $0 + (after ?? ""), cursor: $0.utf16Length) }
        // A whole message the keyboard read, seen again through the window:
        // nothing in it changed, so neither does the report.
        if enabled, let before, let last = lastField, last.reach != nil,
           let window = Self.window(before: before, after: after ?? "", in: last) {
            lastField = window
            if let report, report.field != window {
                publish(Self.report(report, field: window, all: report.all))
            }
            return
        }
        pending?.cancel()
        guard enabled, let field else {
            pending = nil
            stopChecking()
            abandonOutstanding()
            thorough = false
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
        guard autoCheck else {
            pending = nil
            return
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

    /// The Writing check button: checks after `delay`, so its pulse shows for
    /// a beat. The field is read when the wait ends, not when the button was
    /// tapped, so the check is always of the text as it is now; `read`
    /// returning nil (the panel closed, the field changed) checks nothing.
    /// A newer tap, ``cancelButtonCheck()`` and ``reset()`` drop it too.
    /// `finished` runs once the wait is over, checked or not, unless a newer
    /// tap took its place.
    func checkAfterPause(
        _ delay: Duration, read: @escaping () -> Field?, options: @escaping () -> Options,
        finished: @escaping () -> Void = {}
    ) {
        buttonCheck?.cancel()
        buttonTaps += 1
        thorough = true
        let tap = buttonTaps
        buttonCheck = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, tap == buttonTaps else { return }
            buttonCheck = nil
            if !Task.isCancelled, let field = read() { checkNow(field, options: options()) }
            finished()
        }
    }

    /// Drops a button check still waiting out its beat.
    func cancelButtonCheck() {
        buttonCheck?.cancel()
    }

    /// Waits for the button's beat, the pause and the check under way, if
    /// any. For tests.
    func settle() async {
        await buttonCheck?.value
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
        let thorough = thorough
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
                        if let answer = known[Self.answerKey(sentence, thorough: thorough)] { return answer }
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
            if modelInUse { askFor(missing, keep: options.keep, thorough: thorough, retry: retry) }
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
        Report(
            field: field,
            all: result.suggestions.filter { !dismissed.contains($0.key) },
            tones: tone ? result.tones : [],
            modelPending: result.modelPending
        )
    }

    /// `report` on `field` with `all`, its tones and model state unchanged.
    private static func report(_ report: Report, field: Field, all: [WritingSuggestion]) -> Report {
        Report(field: field, all: all, tones: report.tones, modelPending: report.modelPending)
    }

    nonisolated fileprivate static func chips(_ suggestions: [WritingSuggestion], in field: Field) -> [WritingSuggestion] {
        let actionable = suggestions.filter { $0.isActionable && field.isReachable($0) }.enumerated().sorted { a, b in
            let da = abs(a.element.markEnd - field.cursor)
            let db = abs(b.element.markEnd - field.cursor)
            return da != db ? da < db : a.offset < b.offset
        }
        return Array(actionable.prefix(3).map(\.element))
    }

    /// `suggestions` without those touching the word the cursor is in: it is
    /// being typed, or the user has just gone back into it, and is not
    /// finished.
    nonisolated fileprivate static func outsideCurrentWord(_ suggestions: [WritingSuggestion], in field: Field) -> [WritingSuggestion] {
        guard let word = wordAt(field.text, field.cursor) else { return suggestions }
        return suggestions.filter { $0.markEnd < word.0 || $0.markStart > word.1 }
    }

    /// The word the cursor touches, as `(start, end)`; nil between words.
    nonisolated private static func wordAt(_ text: String, _ cursor: Int) -> (Int, Int)? {
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

    /// `report` moved onto `field`: everything it found, even what the word
    /// the cursor was in hid, so leaving that word shows it again. Nil when
    /// none of it could be placed.
    private func rebase(_ report: Report, to field: Field) -> Report? {
        let moved = WritingCheck.rebase(report.all, old: report.field.text, new: field.text)
        guard !moved.isEmpty else { return nil }
        return Self.report(report, field: field, all: moved)
    }

    // MARK: - The model, through the app

    /// Asks the app about the sentences the model has not answered: not the
    /// ones already in flight, and one the app answered with nothing only on a
    /// `retry`, and only `maximumAsks` times in all.
    private func askFor(_ missing: [String], keep: [String], thorough: Bool, retry: Bool) {
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
        ask(sentences, keep: keep, thorough: thorough)
    }

    private func expireOutstanding() {
        guard let outstanding, now().timeIntervalSince(outstanding.sentAt) > TypedGrammarRequest.maximumAge else { return }
        abandonOutstanding()
    }

    private func ask(_ sentences: [String], keep: [String], thorough: Bool) {
        guard !sentences.isEmpty, outstanding == nil else { return }
        let joined = sentences.joined(separator: " ")
        // Only the protected words these sentences contain. The list includes
        // every contact name `UILexicon` offers, and those have no business in
        // a file because one of them might have been typed.
        let present = Self.wordsPresent(keep, in: joined)
        let request = TypedGrammarRequest(sentences: sentences, keep: present, createdAt: now(), thorough: thorough)
        // Listening before asking: an app that answers before a listener
        // registered afterwards would ping nobody.
        if observation == nil {
            observation = observe { [weak self] in Task { @MainActor [weak self] in self?.collect() } }
        }
        // No Full Access is no App Group, and so no way to ask.
        guard (try? store.saveTypedGrammarRequest(request)) != nil else { return }
        outstanding = (request.id, request.sentences, request.createdAt, thorough)
    }

    /// Reads the app's answer. Called on its ping, and by tests.
    func collect() {
        guard let answer = store.takeTypedGrammarAnswer(),
              let outstanding, answer.id == outstanding.id
        else { return }
        self.outstanding = nil
        for (sentence, corrected) in zip(outstanding.sentences, answer.corrected) {
            if let corrected {
                remember(Self.answerKey(sentence, thorough: outstanding.thorough), corrected)
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

    /// The model answers a sentence differently per tier, so each tier keeps its own.
    nonisolated private static func answerKey(_ sentence: String, thorough: Bool) -> String {
        (thorough ? "T\u{0}" : "B\u{0}") + sentence
    }

    private func remember(_ key: String, _ corrected: String) {
        if answers[key] == nil { answerOrder.append(key) }
        answers[key] = corrected
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
        let rest = WritingCheck.rebase(report.all.filter { $0 != suggestion }, old: old.text, new: edited)
        lastField = field
        publish(Self.report(report, field: field, all: rest))
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
        let rest = report.all.filter { $0.key != key }
        publish(Self.report(report, field: report.field, all: rest))
    }

    /// A new field, or the keyboard went away: nothing carries over, and a
    /// question nobody will collect is removed.
    func reset() {
        pending?.cancel()
        pending = nil
        cancelButtonCheck()
        stopChecking()
        observation?.invalidate()
        observation = nil
        abandonOutstanding()
        answers = [:]
        answerOrder = []
        unanswered = [:]
        dismissed = []
        thorough = false
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

/// "Fix obvious typos as I type": one automatic fix at a time, each with its
/// own Undo.
///
/// Making a fix changes the report, and a changed report asks for the next
/// automatic fix. Without the guard that nested ask fixed a second typo while
/// the first was still being made, and the first then saved its Undo over the
/// second's: two words changed, one of them for good.
@MainActor
final class WritingAutoFixer {
    /// The fix Undo takes back, until the next edit.
    private(set) var offer: WritingAutoFix?
    private var isFixing = false

    /// Makes `report`'s automatic fix, unless one is being made or its Undo
    /// is still offered. `apply` makes the edit and says whether it did; it
    /// may come back here, and is then turned away. `before` is the text
    /// before the cursor once it has. Undo is offered only for the fix exactly
    /// where it was made.
    func fix(in report: WritingCheckClient.Report, apply: (WritingSuggestion) -> Bool, before: () -> String?) {
        guard !isFixing, offer == nil, let fix = report.autoFix, let made = WritingAutoFix(fix, in: report.field)
        else { return }
        isFixing = true
        defer { isFixing = false }
        guard apply(fix) else { return }
        offer = made.isCurrent(before: before()) ? made : nil
    }

    /// Ends the Undo offer, and hands back what it was.
    @discardableResult
    func clear() -> WritingAutoFix? {
        defer { offer = nil }
        return offer
    }
}

/// "Whole message": iOS hands a keyboard a window onto the document, often
/// just the paragraph. This reads past it by moving the cursor to each end, a
/// window at a time, waiting for the field to catch up after every move, and
/// then puts the cursor back where it found it.
///
/// The user can still tap in the field, or the app change its text, during
/// any of those waits. After every move the window the field shows must fit
/// what has been read, at the place the walk put the cursor; if it does not,
/// someone else moved the cursor or changed the text, and the walk stops on
/// the spot. It does not move the cursor again: the user put it where it is.
@MainActor
final class WholeMessageWalk {
    /// The text either side of the cursor, as the field hands it over.
    struct Window {
        var before: String?
        var after: String?
        var hasSelection = false
    }

    /// Whether the walk ended because something else moved the cursor or
    /// changed the text.
    private(set) var wasInterrupted = false
    /// How far the cursor is from where the walk found it, in UTF-16 units.
    private(set) var moved = 0

    private let window: () -> Window
    private let move: (Int) -> Void
    private let wait: () async -> Bool
    private var isStopped = false
    /// The walk's last move, until the field has been seen to follow it. The
    /// field can lag a move by a moment, so a window read meanwhile may still
    /// show the cursor where it was before this move.
    private var unconfirmed = 0
    /// What has been read, either side of where the cursor started.
    private var before = ""
    private var after = ""

    /// `wait` lets the field catch up after a move, and says whether the walk
    /// may go on: false when it was cancelled or the field changed.
    init(window: @escaping () -> Window, move: @escaping (Int) -> Void, wait: @escaping () async -> Bool) {
        self.window = window
        self.move = move
        self.wait = wait
    }

    /// Reads the document around the cursor, and leaves the cursor where it
    /// was. Nil when the walk was stopped or interrupted on the way.
    func read() async -> WritingCheckClient.Field? {
        let start = window()
        guard !isStopped, !start.hasSelection, let first = start.before else { return nil }
        before = first
        after = start.after ?? ""
        var current = (before: first, after: after)
        // Back, a window at a time, while there is more.
        for _ in 0..<Self.steps {
            let step = current.before.utf16Length
            guard step > 0, before.utf16Length < Self.limit else { break }
            guard let now = await go(by: -step) else { return nil }
            current = now
            guard !now.before.isEmpty else { break }
            before = now.before + before
        }
        guard let home = await go(by: -moved) else { return nil }
        current = home
        // Forward the same way.
        for _ in 0..<Self.steps {
            let step = current.after.utf16Length
            guard step > 0, after.utf16Length < Self.limit else { break }
            guard let now = await go(by: step) else { return nil }
            current = now
            guard !now.after.isEmpty else { break }
            after += now.after
        }
        guard let end = await go(by: -moved) else { return nil }
        isStopped = true
        // Only the window iOS hands the keyboard can be edited from here; a
        // fix past it is shown but cannot be accepted.
        let cursor = before.utf16Length
        return WritingCheckClient.Field(
            text: before + after,
            cursor: cursor,
            reach: (cursor - end.before.utf16Length)..<(cursor + end.after.utf16Length)
        )
    }

    /// Stops the walk and puts the cursor back where it found it, before the
    /// keys can type again: a key pressed mid-walk would land wherever the walk
    /// had got to. Not after an interruption, which put the cursor where the
    /// user wants it.
    ///
    /// This runs mid-wait, before the walk has checked the field after its
    /// last move, so the field is checked here first, the same way. The window
    /// must show the cursor where the walk put it, or, the field not having
    /// caught up yet, where it was just before that move: the move is still on
    /// its way, and the one back is made after it, so either way the cursor
    /// ends where it started. Anything else is the user or the app moving the
    /// cursor or changing the text during the wait, and the cursor is left
    /// where they put it; moving back from there would put it somewhere else.
    func restore() {
        guard !isStopped else { return }
        isStopped = true
        guard moved != 0 else { return }
        let now = window()
        let shown = (before: now.before ?? "", after: now.after ?? "")
        guard !now.hasSelection, fits(shown, at: moved) || fits(shown, at: moved - unconfirmed) else {
            wasInterrupted = true
            return
        }
        move(-moved)
        moved = 0
        unconfirmed = 0
    }

    /// Stops the walk where it is, without moving the cursor again.
    func stop() {
        isStopped = true
    }

    /// Moves the cursor by `offset`, waits, and reads the window there. Nil
    /// when the walk must end: stopped, or the window does not fit what was
    /// read.
    private func go(by offset: Int) async -> (before: String, after: String)? {
        guard !isStopped else { return nil }
        if offset != 0 {
            move(offset)
            moved += offset
            unconfirmed = offset
            guard await wait(), !isStopped else { return nil }
        }
        let now = window()
        let shown = (before: now.before ?? "", after: now.after ?? "")
        guard !now.hasSelection, fits(shown, at: moved) else {
            wasInterrupted = true
            isStopped = true
            return nil
        }
        unconfirmed = 0
        return shown
    }

    /// Whether `shown` agrees with what has been read, around the cursor
    /// `offset` from where the walk found it. Only the overlap is compared: a
    /// window can reach past what has been read, or stop short of it.
    private func fits(_ shown: (before: String, after: String), at offset: Int) -> Bool {
        let text = Array((before + after).utf16)
        let at = before.utf16Length + offset
        guard at >= 0, at <= text.count else { return false }
        let left = Array(shown.before.utf16)
        let right = Array(shown.after.utf16)
        let leftOverlap = min(left.count, at)
        let rightOverlap = min(right.count, text.count - at)
        return left.suffix(leftOverlap).elementsEqual(text[(at - leftOverlap)..<at])
            && right.prefix(rightOverlap).elementsEqual(text[at..<(at + rightOverlap)])
    }

    private static let steps = 20
    private static let limit = 8_000
}

/// Whether the Writing check button shows, read from the field on each text
/// change. iOS often answers a keyboard's read with nothing for a moment — in
/// chat apps above all — and taking that as "the field is empty" made the
/// button blink in and out while the user typed. So an unanswered read keeps
/// the button as it is, words show it at once, and a field that reads as
/// wordless hides it only once it still reads that way after a pause.
enum WritingButtonVisibility: Equatable {
    case show
    case hide
    /// Leave it as it is.
    case keep
    /// Read the field again after a pause, and hide only if it is still wordless.
    case hideAfterPause

    static func decide(_ snapshot: DocumentSnapshot, eligible: Bool, isNewField: Bool, showing: Bool) -> Self {
        guard eligible else { return .hide }
        guard let hasWords = hasWords(snapshot) else { return isNewField ? .hide : .keep }
        if hasWords { return .show }
        if isNewField { return .hide }
        return showing ? .hideAfterPause : .keep
    }

    /// Whether the field has a letter in it; nil when iOS did not answer.
    static func hasWords(_ snapshot: DocumentSnapshot) -> Bool? {
        guard snapshot.hasContent != nil else { return nil }
        return (snapshot.before?.contains(where: \.isLetter) ?? false)
            || (snapshot.after?.contains(where: \.isLetter) ?? false)
    }

    static let pause: Duration = .milliseconds(700)
}
