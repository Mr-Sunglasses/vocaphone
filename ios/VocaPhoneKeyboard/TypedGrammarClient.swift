import Foundation

/// The keyboard's half of "Check grammar while typing".
///
/// This extension cannot load the grammar model — it already runs close to its
/// memory limit — so it asks the containing app, which can. After the user
/// pauses, the sentences before the cursor go to the app through the App Group
/// (`TypedGrammarRequest`), and the app's answer comes back the same way. The
/// app only hears the question while it is running, which for a keyboard user
/// means while Quick Dictation keeps it in the background, so nothing is asked
/// otherwise. Nothing is sent anywhere else, and nothing is changed in the
/// document until the user taps the fix.
///
/// Nothing here runs per keystroke beyond restarting a timer: the file write
/// waits for `pause` of quiet, and only the newest question is ever answered.
@MainActor
final class TypedGrammarClient {
    /// The fix the strip offers, if any.
    private(set) var fix: TypedGrammar.Fix?
    /// Called whenever `fix` changes.
    var onChange: (() -> Void)?
    /// The language gate: only English goes to an English grammar model.
    var isEnglish: (String) -> Bool = { _ in true }

    private let store: SharedStore
    private let isAppRunning: () -> Bool
    private let pause: Duration
    private let now: () -> Date
    private let observe: (@escaping @Sendable () -> Void) -> VocaPhoneDarwinObservation?
    private var pending: Task<Void, Never>?
    private var observation: VocaPhoneDarwinObservation?
    /// The question in flight, so an answer to an older one is dropped. It
    /// expires with the request: an app that ended before answering, or that
    /// dropped the request as stale, must not block that sentence for good.
    private var outstanding: (id: UUID, text: String, sentAt: Date)?
    /// The text before the cursor at the last change, for judging whether an
    /// answer still describes the document when it lands.
    private var lastBefore = ""
    /// The last text answered, whatever the answer was, so a pause that
    /// changes nothing does not ask again. An applied fix's result and a
    /// dismissed fix's text land here too.
    private var settled: String?
    /// Fixes waved away in this field, as "words → replacement".
    private var dismissed: Set<String> = []

    init(
        store: SharedStore = .shared,
        isAppRunning: @escaping () -> Bool,
        pause: Duration = .milliseconds(700),
        now: @escaping () -> Date = { Date() },
        observe: @escaping (@escaping @Sendable () -> Void) -> VocaPhoneDarwinObservation? = {
            VocaPhoneDarwinCenter.observe(.typedGrammarAnswered, handler: $0)
        }
    ) {
        self.store = store
        self.isAppRunning = isAppRunning
        self.pause = pause
        self.now = now
        self.observe = observe
    }

    /// The document changed. `before` is the text before the cursor; a fix
    /// that no longer describes it goes at once, and a new question waits for
    /// the pause. `enabled` false drops everything on screen.
    func textChanged(before: String?, enabled: Bool, keep: @escaping () -> [String]) {
        pending?.cancel()
        guard enabled, let before else {
            // An answer already on its way must not bring the fix back once
            // checking is off, the layout has changed or the context is gone.
            pending = nil
            abandonOutstanding()
            lastBefore = ""
            publish(nil)
            return
        }
        lastBefore = before
        if let fix, !TypedGrammar.stillDescribes(fix, window: before) { publish(nil) }
        pending = Task { [weak self, pause] in
            try? await Task.sleep(for: pause)
            guard !Task.isCancelled else { return }
            self?.ask(before: before, keep: keep())
        }
    }

    private func ask(before: String, keep: [String]) {
        // A host's context has no way to say it was cut short. A short one
        // almost never is, and a long one is assumed to start mid-sentence.
        let startKnown = before.count < Self.shortContext
        guard let region = TypedGrammar.region(before: before, startKnown: startKnown) else {
            publish(nil)
            return
        }
        if let outstanding, now().timeIntervalSince(outstanding.sentAt) > TypedGrammarRequest.maximumAge {
            abandonOutstanding()
        }
        guard region != settled, region != fix?.checked, region != outstanding?.text else { return }
        guard isEnglish(region) else {
            settled = region
            publish(nil)
            return
        }
        guard isAppRunning() else { return }
        // Only the protected words this text contains. The list includes
        // every contact name `UILexicon` offers, and those have no business
        // in a file because one of them might have been typed.
        let request = TypedGrammarRequest(
            text: region,
            keep: TypedGrammar.wordsPresent(keep, in: region),
            createdAt: now()
        )
        // Listening before asking: an app that answers before a listener
        // registered afterwards would ping nobody, and the answer would wait
        // unread.
        if observation == nil {
            observation = observe { Task { @MainActor [weak self] in self?.collect() } }
        }
        // No Full Access is no App Group, and so no way to ask.
        guard (try? store.saveTypedGrammarRequest(request)) != nil else { return }
        outstanding = (request.id, region, request.createdAt)
    }

    /// Reads the app's answer. Called on its ping, and by tests.
    func collect() {
        guard let answer = store.takeTypedGrammarAnswer(),
              let outstanding, answer.id == outstanding.id
        else { return }
        self.outstanding = nil
        // The app could not check it; the next pause asks again.
        guard let corrected = answer.corrected else { return }
        settled = outstanding.text
        guard let fix = TypedGrammar.fix(checked: outstanding.text, corrected: corrected),
              !dismissed.contains(Self.key(fix)),
              TypedGrammar.stillDescribes(fix, window: lastBefore)
        else {
            publish(nil)
            return
        }
        publish(fix)
    }

    /// Hands the fix over to be applied, and remembers its result as checked.
    func take() -> TypedGrammar.Fix? {
        pending?.cancel()
        guard let taken = fix else { return nil }
        settled = taken.corrected
        publish(nil)
        return taken
    }

    /// The user waved the fix away: it is not offered again in this field.
    func dismiss() {
        guard let fix else { return }
        settled = fix.checked
        dismissed.insert(Self.key(fix))
        publish(nil)
    }

    /// A new field, or the keyboard went away: nothing carries over, and a
    /// question nobody will collect is removed.
    func reset() {
        pending?.cancel()
        pending = nil
        observation?.invalidate()
        observation = nil
        abandonOutstanding()
        settled = nil
        dismissed = []
        lastBefore = ""
        publish(nil)
    }

    /// Forgets the question in flight, and removes it and any answer from the
    /// App Group so the typed text does not wait there for nobody.
    private func abandonOutstanding() {
        guard outstanding != nil else { return }
        outstanding = nil
        store.clearTypedGrammarExchange()
    }

    private func publish(_ fix: TypedGrammar.Fix?) {
        guard fix != self.fix else { return }
        self.fix = fix
        onChange?()
    }

    private static func key(_ fix: TypedGrammar.Fix) -> String {
        "\(fix.original)\u{0}\(fix.replacement)"
    }

    /// Characters of context below which the host is taken to have given the
    /// whole paragraph.
    static let shortContext = 200
}
