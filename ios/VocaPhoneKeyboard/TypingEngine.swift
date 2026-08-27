import UIKit

/// Turns keystrokes into a strip, without ever making a keystroke wait.
///
/// The obvious design puts the checker on a serial background queue. It cannot
/// go there: `UITextChecker` is annotated `NS_SWIFT_UI_ACTOR` in the SDK, a
/// per-class decision of Apple's, and using it off the main actor is
/// unsupported. So the same guarantee — *a keystroke never waits for a
/// candidate* — is met three other ways:
///
/// 1. **Ordering.** Text goes into the document synchronously on touch-up. The
///    computation is enqueued as a separate main-actor task, so it runs after
///    the keystroke has been handled and the frame committed.
/// 2. **Generations.** Every enqueued task carries the generation it was born
///    with. A fast typist enqueues one per key and all but the last bail on
///    their first line, so the checker runs once for the burst rather than once
///    per letter.
/// 3. **Caching.** Prefixes already seen never reach the checker at all, which
///    covers backspacing and re-typing — most of what fast typing actually is.
///
/// If device measurement still finds this too expensive, the fallback is
/// already built: ``TypingWordList`` completes and corrects on its own, in pure
/// Swift that *can* run off the main actor.
@MainActor
final class TypingEngine {
    /// Called with a strip whose generation is still current. Never called with
    /// a stale result.
    var onStrip: ((TypingStrip) -> Void)?
    /// Handed the word list once it has parsed, so the swipe recogniser has
    /// something to rank against.
    var onWordListLoaded: ((TypingWordList) -> Void)?

    private(set) var composer = WordComposer()
    private(set) var policy = TypingFieldPolicy.allowed
    private(set) var strip = TypingStrip.none

    /// Words the user restored after an autocorrect. Kept for the life of the
    /// document, because a word asserted once in a message is nearly always
    /// meant again three sentences later.
    private(set) var assertedWords: Set<String> = []

    /// What the last boundary key replaced, so the next Delete can put it back.
    private(set) var pendingRevert: AppliedCorrection?

    struct AppliedCorrection: Equatable {
        let typed: String
        let replacement: String
        /// The space or punctuation that went in with it. A revert has to put
        /// that back too, or the sentence loses its spacing along with its
        /// correction.
        let boundary: String
    }

    private let checker: any SpellChecking
    private let learned: LearnedWordStore
    private var cache = SuggestionCache()
    private var generation = 0
    private var wordList = TypingWordList.empty
    private var lexiconEntries: [LexiconEntry] = []

    /// One of the user's own text replacements. A named type rather than a
    /// tuple so it can cross an isolation boundary as `Sendable`.
    struct LexiconEntry: Sendable, Equatable {
        let userInput: String
        let documentText: String
    }

    /// Carries a main-actor-isolated object from a background callback back to
    /// the main actor without touching it on the way.
    ///
    /// The `@unchecked` is doing real work and is safe for exactly one reason:
    /// the value is never read outside the main actor. Reading it in the
    /// callback is what trapped.
    private struct UncheckedBox<Value>: @unchecked Sendable {
        let value: Value

        init(_ value: Value) { self.value = value }
    }
    private var language = TypingLanguage.fallback
    private var customWords: [String] = []

    init(
        checker: any SpellChecking = SystemSpellChecker(),
        learned: LearnedWordStore = LearnedWordStore(),
        wordList: TypingWordList? = nil
    ) {
        self.checker = checker
        self.learned = learned
        // Nothing expensive here. Everything this subsystem needs is built the
        // first time the user types, because a keyboard extension's whole memory
        // budget has to survive *launch* first — see `ensureLoaded`.
        if let wordList {
            self.wordList = wordList
            hasLoaded = true
        }
        customWords = CustomVocabulary.terms(LocalTranscriptionPreferences.customVocabulary)
    }

    private var hasLoaded = false

    /// Pays for the dictionaries, once, on the first keystroke.
    ///
    /// Deliberately not in `init`: the engine is created while the keyboard is
    /// still assembling its views, and loading ten thousand words plus the
    /// system dictionaries there put the extension over the jetsam threshold
    /// before it had drawn a key.
    private func ensureLoaded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        language = TypingLanguage.resolve(
            preferred: Locale.preferredLanguages,
            available: SystemSpellChecker.availableLanguages()
        )
        // Pure Swift, so unlike the checker this may leave the main actor.
        Task.detached(priority: .utility) {
            let loaded = TypingWordList.load(from: Bundle(for: TypingEngine.self))
            // Parse the suggestion table off the main actor too. It is small,
            // but the first keystroke is the wrong moment to notice.
            _ = EmojiSuggestions.triggers
            await MainActor.run { [weak self] in
                self?.wordList = loaded
                self?.onWordListLoaded?(loaded)
            }
        }
    }

    var isPersistentLearningAvailable: Bool { learned.isPersistent }

    var learnedWordCount: Int { learned.snapshot().count }

    // MARK: - Document

    /// Adopts the current field. Resets everything document-scoped: a new field
    /// is a new document, and carrying an assertion or a half-typed word across
    /// is how a keyboard corrects a password field's contents into a message.
    func documentChanged(policy newPolicy: TypingFieldPolicy) {
        policy = newPolicy
        composer.reset()
        assertedWords.removeAll()
        pendingRevert = nil
        cache.removeAll()
        publish(.none)
    }

    /// Reconciles the composition against what the document says, then
    /// recomputes. Called after a cursor move, a dictation insertion, or any
    /// edit this keyboard did not make itself.
    func reconcile(documentBefore: String?) {
        composer.reconcile(documentBefore: documentBefore)
        // The swipe's own insertion is what triggers the first of these. The
        // word is still the tail of the document, so its alternates stand —
        // reconciling the composer to an empty composition must not take them
        // down with it.
        if let pendingSwipe,
           SwipeAlternates.isArmed(word: pendingSwipe.word, documentBefore: documentBefore)
        {
            publishSwipeAlternates()
            return
        }
        pendingSwipe = nil
        refresh(documentBefore: documentBefore)
    }

    // MARK: - Typing

    func insert(_ text: String, origin: WordComposer.Origin = .typed, documentBefore: String?) {
        pendingRevert = nil
        pendingSwipe = nil
        composer.insert(text, origin: origin)
        refresh(documentBefore: documentBefore)
    }

    func deleteBackward(documentBefore: String?) {
        pendingRevert = nil
        pendingSwipe = nil
        composer.deleteBackward()
        refresh(documentBefore: documentBefore)
    }

    func resetComposition(origin: WordComposer.Origin = .typed, documentBefore: String?) {
        pendingSwipe = nil
        composer.reset(origin: origin)
        refresh(documentBefore: documentBefore)
    }

    /// The word the user asserted by tapping their own spelling. It stops being
    /// corrected, and — if learning is on — becomes a word the keyboard knows.
    func assert(_ word: String) {
        assertedWords.insert(word.lowercased())
        pendingRevert = nil
        guard KeyboardPreferences.learnAsITypeEnabled else { return }
        learned.update { $0.learn(word) }
    }

    /// Records that an autocorrect was applied, so the next Delete can undo it.
    func noteCorrection(typed: String, replacement: String, boundary: String) {
        pendingRevert = AppliedCorrection(
            typed: typed,
            replacement: replacement,
            boundary: boundary
        )
    }

    /// Consumes the pending revert. Asserting the restored word is the point:
    /// a user who put their word back once should not have to do it again.
    func takeRevert() -> AppliedCorrection? {
        guard let pendingRevert else { return nil }
        self.pendingRevert = nil
        assertedWords.insert(pendingRevert.typed.lowercased())
        if KeyboardPreferences.learnAsITypeEnabled {
            learned.update { $0.learn(pendingRevert.typed) }
        }
        return pendingRevert
    }

    /// A word the swipe recogniser chose. It becomes the composition so the
    /// strip can offer the runners-up for one tap, but it is marked `.swipe` and
    /// is therefore never autocorrected: the recogniser already picked from the
    /// dictionary, and correcting its answer would be two guesses stacked.
    func noteSwipeWord(_ word: String, alternates: [String]) {
        composer.adopt(word, origin: .swipe)
        // Kept beside the composer rather than inside it. The document reads
        // "word " and the composer describes the word the cursor is inside, so
        // after a swipe the composition is empty and correct — see
        // ``SwipeAlternates``.
        pendingSwipe = PendingSwipe(word: word, alternates: alternates)
        pendingRevert = nil
        publishSwipeAlternates()
    }

    /// The swiped word still standing before the cursor, if there is one.
    var pendingSwipeWord: String? { pendingSwipe?.word }
    var pendingSwipeAlternates: [String] { pendingSwipe?.alternates ?? [] }

    private func publishSwipeAlternates() {
        guard let pendingSwipe else { return }
        publish(
            TypingStrip(
                candidates: pendingSwipe.alternates
                    .prefix(TypingCandidates.slotCount)
                    .map {
                        // Shown in the case they would be inserted in, so a
                        // swipe made with shift on does not offer lowercase
                        // chips that arrive capitalised.
                        TypingCandidate(
                            text: TypingCandidates.matchingCase(
                                of: pendingSwipe.word,
                                applyingTo: $0
                            ),
                            kind: .swipeAlternate
                        )
                    },
                autocorrection: nil
            )
        )
    }

    private struct PendingSwipe {
        let word: String
        let alternates: [String]
    }

    /// Cleared the moment the document stops ending in the swiped word, which
    /// is any keystroke, any deletion, or a cursor that has moved on.
    private var pendingSwipe: PendingSwipe?

    /// Counts a completed word toward learning. A word typed three times and
    /// never reverted is a word the user means.
    func noteCompletedWord(_ word: String) {
        guard KeyboardPreferences.learnAsITypeEnabled,
              policy.allowsTypingIntelligence,
              word.count >= 3,
              word.allSatisfy({ $0.isLetter || $0 == "'" }),
              !wordList.contains(word)
        else { return }
        let snapshot = learned.snapshot()
        // Already known: nothing to learn, and no reason to touch the file.
        guard !snapshot.contains(word) else { return }
        learned.update { $0.note(word) }
    }

    func resetLearnedWords() {
        learned.removeAll()
    }

    // MARK: - Lexicon

    /// The user's own text replacements and contact names, which Apple exposes
    /// to keyboard extensions specifically so that "omw" can mean "On my way!"
    /// for the person who set that up. Requested once per keyboard instance.
    /// The handler is explicitly `@Sendable`, and that is not decoration.
    ///
    /// A closure written inside a `@MainActor` type inherits that isolation, so
    /// Swift compiles a main-thread assertion into it. UIKit delivers this
    /// particular completion on a background queue — which turned the assertion
    /// into `BUG IN CLIENT OF LIBDISPATCH: Block was expected to execute on
    /// queue [com.apple.main-thread]`, a SIGTRAP about two seconds after the
    /// keyboard appeared. A keyboard extension that traps is not reported to
    /// the user as a crash: iOS just puts the previous keyboard back, so the
    /// symptom is "the vocaphone keyboard will not open".
    ///
    /// Marking the closure `@Sendable` opts it out of inheriting isolation, and
    /// the hop back to the main actor is then explicit.
    func loadLexicon(from controller: UIInputViewController) {
        let handler: @Sendable (UILexicon) -> Void = { [weak self] lexicon in
            // `UILexicon.entries` is itself main-actor isolated, so the read has
            // to happen *after* the hop, not before it. The lexicon travels
            // across in a box because it is not `Sendable` — which is true, and
            // safe here precisely because nothing touches it until it is back on
            // the main actor.
            let delivery = UncheckedBox(lexicon)
            Task { @MainActor [weak self] in
                self?.lexiconEntries = delivery.value.entries.map {
                    LexiconEntry(userInput: $0.userInput, documentText: $0.documentText)
                }
            }
        }
        controller.requestSupplementaryLexicon(completion: handler)
    }

    // MARK: - Computation

    private func refresh(documentBefore: String?) {
        guard KeyboardPreferences.typingSuggestionsEnabled, policy.allowsTypingIntelligence
        else {
            publish(.none)
            return
        }

        generation += 1
        let generation = generation
        let composition = composer.text
        if !composition.isEmpty { ensureLoaded() }
        let origin = composer.origin
        let preceding = PrecedingWord.lastWord(in: documentBefore)

        // Nothing being composed: prediction needs no checker, so it renders on
        // this turn rather than costing a hop.
        guard !composition.isEmpty else {
            publish(
                TypingCandidates.strip(
                    context(composition: "", origin: origin, preceding: preceding, checked: nil)
                )
            )
            return
        }

        let key = SuggestionCache.Key(prefix: composition.lowercased(), language: language)
        if let cached = cache.value(for: key) {
            publish(
                TypingCandidates.strip(
                    context(
                        composition: composition,
                        origin: origin,
                        preceding: preceding,
                        checked: cached
                    )
                )
            )
            return
        }

        // Enqueued rather than called: this returns immediately, the keystroke
        // that triggered it finishes, and the checker runs on a later turn.
        Task { @MainActor [weak self] in
            guard let self, generation == self.generation else { return }
            let value = SuggestionCache.Value(
                completions: self.checker.completions(for: composition, language: self.language),
                guesses: self.checker.guesses(for: composition, language: self.language),
                isKnown: self.checker.isKnown(composition, language: self.language)
            )
            // Checked again: the user may have typed on while this task waited
            // its turn, and a strip two keystrokes behind is worse than none.
            guard generation == self.generation else { return }
            self.cache.insert(value, for: key)
            self.publish(
                TypingCandidates.strip(
                    self.context(
                        composition: composition,
                        origin: origin,
                        preceding: preceding,
                        checked: value
                    )
                )
            )
        }
    }

    private func context(
        composition: String,
        origin: WordComposer.Origin,
        preceding: String?,
        checked: SuggestionCache.Value?
    ) -> TypingCandidates.Context {
        let snapshot = learned.snapshot()
        var context = TypingCandidates.Context()
        context.composition = composition
        context.origin = origin
        context.precedingWord = preceding
        context.lexiconEntries = lexiconEntries
            .filter {
                !composition.isEmpty
                    && $0.userInput.lowercased().hasPrefix(composition.lowercased())
            }
            .map(\.documentText)
        context.customWords = customWords.filter {
            !composition.isEmpty && $0.lowercased().hasPrefix(composition.lowercased())
        }
        context.learnedWords = snapshot.completions(for: composition, limit: 3)
        context.systemCompletions = Array((checked?.completions ?? []).prefix(8))
        // The checker's guesses first, the list's own near-matches behind them:
        // together they still answer when either one draws a blank.
        context.systemGuesses = TypingCandidates.merged(
            Array((checked?.guesses ?? []).prefix(4)),
            wordList.similarWords(to: composition, limit: 2)
        )
        context.listCompletions = wordList.completions(for: composition, limit: 3)
        context.predictions = preceding.map { wordList.nextWords(after: $0, limit: 3) } ?? []
        context.isKnownToChecker = checked?.isKnown ?? false
        context.isInWordList = wordList.contains(composition)
        context.assertedWords = assertedWords
        // Exact word only, so nothing appears while the user is partway into a
        // different one.
        context.emojiSuggestion = EmojiSuggestions.glyph(for: composition)
        context.emojiEnabled = KeyboardPreferences.emojiSuggestionsEnabled
        context.suggestionsEnabled = KeyboardPreferences.typingSuggestionsEnabled
        context.autocorrectEnabled = KeyboardPreferences.autocorrectIsActive
        context.predictionEnabled = KeyboardPreferences.nextWordPredictionEnabled
        context.allowsTypingIntelligence = policy.allowsTypingIntelligence
        return context
    }

    private func publish(_ newStrip: TypingStrip) {
        guard newStrip != strip else { return }
        strip = newStrip
        onStrip?(newStrip)
    }
}
