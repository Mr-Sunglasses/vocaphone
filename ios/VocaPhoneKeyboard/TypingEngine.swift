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
    /// How likely each letter is to be typed next, for the key grid's hit map.
    /// Published on every composition change, including the empty one that
    /// clears it.
    var onNextCharacters: (([Character: Double]) -> Void)?

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

        /// Whether the correction is still the text immediately before the
        /// cursor.
        ///
        /// A revert deletes a fixed number of characters and types the original
        /// in their place, which is only meaningful where the replacement
        /// actually is. Once the cursor has moved, those characters belong to
        /// something else — and reverting there would delete four characters of
        /// unrelated text and insert a word the user typed a paragraph ago.
        ///
        /// Checked against the document rather than remembered, for the same
        /// reason ``SwipeAlternates/isArmed(word:documentBefore:)`` is: the
        /// document is the thing that can be trusted, and a keyboard that
        /// deletes on faith deletes the wrong thing.
        func isArmed(documentBefore: String?) -> Bool {
            guard let documentBefore else { return false }
            return documentBefore.hasSuffix(replacement + boundary)
        }
    }

    private let checker: any SpellChecking
    /// How long the hand has to be still before the checker is asked anything.
    ///
    /// `UITextChecker` is the most expensive thing this keyboard does — 50 to
    /// 135 ms for a prefix it has not seen — and it is main-actor isolated, so
    /// there is nowhere else to do it. What there is instead is *when*: a
    /// keystroke is 120 ms from the next one at a brisk pace, and asking after
    /// every one of them put that block in every gap between two letters, which
    /// is exactly where the next finger lands.
    ///
    /// The pause has to be longer than the roughly 120 ms between brisk
    /// keystrokes. At 90 ms the checker began its 50-135 ms main-actor block
    /// just before the next finger landed, turning the debounce into a source of
    /// dropped frames. The shipped word list keeps the strip responsive during
    /// this pause; the system checker joins only after the hand has really
    /// stopped.
    private static let checkerQuietPeriod: Duration = .milliseconds(250)
    private var pendingCheck: Task<Void, Never>?
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
        /// `userInput` folded once, when the entry arrives.
        ///
        /// This list is not the handful of replacements someone typed into
        /// Settings — `UILexicon` also carries every name in their address
        /// book. Lowercasing each of them to compare against the word being
        /// typed allocated a string per entry per keystroke, twice over, and
        /// measured on device that was most of the 4.2 ms a keystroke spent
        /// assembling its context.
        let lowered: String

        init(userInput: String, documentText: String) {
            self.userInput = userInput
            self.documentText = documentText
            lowered = userInput.lowercased()
        }
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
    private var hasResolvedLanguage = false
    private let availableLanguages: @MainActor () -> [String]
    private var emojiTriggers: [String: String] = [:]
    private var precedingWord: String?
    private var hasDocumentContext = false
    private var customWords: [String] = []
    /// `customWords` folded once. See ``LexiconEntry/lowered``.
    private var loweredCustomWords: [String] = []

    init(
        checker: any SpellChecking = SystemSpellChecker(),
        learned: LearnedWordStore = LearnedWordStore(),
        wordList: TypingWordList? = nil,
        availableLanguages: @escaping @MainActor () -> [String] = SystemSpellChecker.availableLanguages
    ) {
        self.checker = checker
        self.learned = learned
        self.availableLanguages = availableLanguages
        // Bundled resources wait until the view appears; system dictionaries
        // wait until a typing pause. Neither belongs in view construction.
        if let wordList {
            self.wordList = wordList
            hasLoaded = true
        }
        customWords = CustomVocabulary.terms(LocalTranscriptionPreferences.customVocabulary)
        loweredCustomWords = customWords.map { $0.lowercased() }
    }

    private var hasLoaded = false

    /// Starts only the bundled resources off-thread after the keyboard appears.
    /// System dictionaries stay deferred until the checker quiet period.
    func prepareResources() {
        guard !hasLoaded else { return }
        hasLoaded = true
        // Pure Swift, so unlike the checker this may leave the main actor.
        Task.detached(priority: .utility) {
            let loaded = TypingWordList.load(from: Bundle(for: TypingEngine.self))
            // Parse the suggestion table off the main actor too. It is small,
            // but the first keystroke is the wrong moment to notice — and the
            // strip is no longer its only reader, so this warms what dictation
            // needs from it as well.
            EmojiTable.warmUp()
            let emojiTriggers = EmojiTable.triggers
            await MainActor.run { [weak self] in
                self?.installResources(wordList: loaded, emojiTriggers: emojiTriggers)
            }
        }
    }

    /// Resource delivery is another reason to update the row, even if the user
    /// has stopped typing. Rebuild from the current field, never from the word
    /// that happened to start the background load.
    func installResources(wordList: TypingWordList, emojiTriggers: [String: String]) {
        self.wordList = wordList
        self.emojiTriggers = emojiTriggers
        onWordListLoaded?(wordList)
        publishNextCharacters()
        refreshCurrentCandidates()
    }

    /// Installs the user's replacements and contacts when UIKit delivers them.
    /// Delivery is asynchronous and often arrives after a word has already been
    /// typed, so it is itself a reason to rebuild the visible candidates.
    func installLexicon(_ entries: [LexiconEntry]) {
        guard entries != lexiconEntries else { return }
        lexiconEntries = entries
        refreshCurrentCandidates()
    }

    /// Picks up vocabulary edited in the containing app while this extension
    /// instance was suspended. iOS commonly reuses the instance on return.
    func installCustomVocabulary(_ rawValue: String) {
        let words = CustomVocabulary.terms(rawValue)
        guard words != customWords else { return }
        customWords = words
        loweredCustomWords = words.map { $0.lowercased() }
        refreshCurrentCandidates()
    }

    private func refreshCurrentCandidates() {
        guard hasDocumentContext,
              policy.allowsTypingIntelligence,
              KeyboardPreferences.typingSuggestionsEnabled,
              pendingSwipe == nil, pendingRevert == nil
        else { return }
        let key = SuggestionCache.Key(prefix: composer.text.lowercased(), language: language)
        publishStrip(for: context(
            composition: composer.text,
            origin: composer.origin,
            preceding: precedingWord,
            checked: cache.value(for: key)
        ))
    }

    var isPersistentLearningAvailable: Bool { learned.isPersistent }

    var learnedWordCount: Int { learned.snapshot().count }

    // MARK: - Document

    /// Adopts the current field. Resets everything document-scoped: a new field
    /// is a new document, and carrying an assertion or a half-typed word across
    /// is how a keyboard corrects a password field's contents into a message.
    ///
    /// Also retires any deferred checker task. The quiet-period wait is 90 ms,
    /// and without a cancel plus a generation bump a task born in the previous
    /// field wakes, sees a matching generation, and publishes that field's
    /// completions into this one.
    func documentChanged(policy newPolicy: TypingFieldPolicy) {
        pendingCheck?.cancel()
        pendingCheck = nil
        generation += 1
        pendingSwipe = nil
        policy = newPolicy
        composer.reset()
        precedingWord = nil
        hasDocumentContext = false
        assertedWords.removeAll()
        pendingRevert = nil
        cache.removeAll()
        publish(.none)
        publishNextCharacters()
    }

    /// Retire field work before UIKit starts switching apps or keyboards.
    func suspend() {
        documentChanged(policy: policy)
    }

    /// Reconciles the composition against what the document says, then
    /// recomputes. Called after a cursor move, a dictation insertion, or any
    /// edit this keyboard did not make itself.
    func reconcile(document: DocumentSnapshot) {
        isMidWord = document.isMidWord
        composer.reconcile(documentBefore: document.before)
        // The swipe's own insertion is what triggers the first of these. The
        // word is still the tail of the document, so its alternates stand —
        // reconciling the composer to an empty composition must not take them
        // down with it.
        if let pendingSwipe,
           SwipeAlternates.isArmed(word: pendingSwipe.word, documentBefore: document.before)
        {
            publishSwipeAlternates()
            return
        }
        pendingSwipe = nil
        refresh(document: document)
    }

    // MARK: - Typing

    func insert(_ text: String, origin: WordComposer.Origin = .typed, document: DocumentSnapshot) {
        pendingRevert = nil
        pendingSwipe = nil
        isMidWord = document.isMidWord
        measured("composer.insert") { composer.insert(text, origin: origin) }
        refresh(document: document)
    }

    func deleteBackward(document: DocumentSnapshot) {
        pendingRevert = nil
        pendingSwipe = nil
        isMidWord = document.isMidWord
        composer.deleteBackward()
        refresh(document: document)
    }

    func resetComposition(origin: WordComposer.Origin = .typed, document: DocumentSnapshot) {
        pendingSwipe = nil
        isMidWord = document.isMidWord
        composer.reset(origin: origin)
        refresh(document: document)
    }

    /// The word the user asserted by tapping their own spelling. It stops being
    /// corrected, and — if learning is on — becomes a word the keyboard knows.
    func assert(_ word: String) {
        assertedWords.insert(word.lowercased())
        pendingRevert = nil
        guard KeyboardPreferences.learnAsITypeEnabled else { return }
        learned.update { $0.learn(word) }
    }

    /// Records that an autocorrect was applied, so the next Delete can undo it
    /// and the strip can offer the original back.
    ///
    /// Must be called *after* the boundary has been fed through ``insert(_:origin:document:)``,
    /// not before: every insertion clears the pending revert, so a correction
    /// noted first was wiped by the space that applied it — which left Delete
    /// with nothing to restore and the feature switched off in practice.
    func noteCorrection(typed: String, replacement: String, boundary: String) {
        pendingRevert = AppliedCorrection(
            typed: typed,
            replacement: replacement,
            boundary: boundary
        )
        guard policy.allowsTypingIntelligence else { return }
        publish(TypingCandidates.revertStrip(typed: typed))
    }

    /// Consumes the pending revert. Asserting the restored word is the point:
    /// a user who put their word back once should not have to do it again.
    func takeRevert(documentBefore: String?) -> AppliedCorrection? {
        guard let pendingRevert,
              pendingRevert.isArmed(documentBefore: documentBefore)
        else {
            // Either there was nothing to revert, or the cursor has left the
            // correction behind. Both mean the offer is over.
            self.pendingRevert = nil
            return nil
        }
        self.pendingRevert = nil
        publish(.none)
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
        pendingCheck?.cancel()
        pendingCheck = nil
        generation += 1
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
                let entries = delivery.value.entries.map {
                    LexiconEntry(userInput: $0.userInput, documentText: $0.documentText)
                }
                self?.installLexicon(entries)
            }
        }
        controller.requestSupplementaryLexicon(completion: handler)
    }

    // MARK: - Computation

    private func refresh(document: DocumentSnapshot) {
        // Retire the previous composition even when this refresh exits early.
        pendingCheck?.cancel()
        pendingCheck = nil
        generation += 1
        measured("nextCharacters") { publishNextCharacters() }
        guard KeyboardPreferences.typingSuggestionsEnabled, policy.allowsTypingIntelligence
        else {
            publish(.none)
            return
        }

        // A correction that can still be taken back owns the strip, the same way
        // a swiped word owns it while its alternates stand.
        //
        // This is also what retires the offer. `reconcile` runs on every
        // keystroke in this field, so clearing the revert there would clear it
        // on the very keystroke that applied the correction — the boundary key
        // — and undo would be dead again. Asking the document instead means the
        // offer survives exactly as long as the correction is still in front of
        // the cursor, and disarms itself the moment the cursor moves away.
        if let pendingRevert {
            guard pendingRevert.isArmed(documentBefore: document.before) else {
                self.pendingRevert = nil
                publish(.none)
                return
            }
            publish(TypingCandidates.revertStrip(typed: pendingRevert.typed))
            return
        }

        let generation = generation
        let composition = composer.text
        if !composition.isEmpty { prepareResources() }
        let origin = composer.origin
        let preceding = measured("precedingWord") {
            PrecedingWord.lastWord(in: document.before)
        }
        precedingWord = preceding
        hasDocumentContext = true

        // Nothing being composed: prediction needs no checker, so it renders on
        // this turn rather than costing a hop.
        guard !composition.isEmpty else {
            publishStrip(
                for: context(composition: "", origin: origin, preceding: preceding, checked: nil)
            )
            return
        }

        let key = SuggestionCache.Key(prefix: composition.lowercased(), language: language)
        if let cached = cache.value(for: key) {
            publishStrip(
                for: context(
                    composition: composition,
                    origin: origin,
                    preceding: preceding,
                    checked: cached
                )
            )
            return
        }

        // Nothing is asked while the hand is moving.
        //
        // The strip still updates on this keystroke, from the shipped word list
        // — that is the `publishStrip` below, and it costs a quarter of a
        // millisecond. What waits is the checker, and every further keystroke
        // cancels the wait and starts it again, so a burst of typing asks it
        // nothing at all and a pause asks it once.
        publishStrip(
            for: context(
                composition: composition,
                origin: origin,
                preceding: preceding,
                checked: nil
            )
        )
        pendingCheck?.cancel()
        pendingCheck = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.checkerQuietPeriod)
            guard !Task.isCancelled, let self, generation == self.generation else { return }
            if !self.hasResolvedLanguage {
                self.language = TypingLanguage.resolve(
                    preferred: Locale.preferredLanguages,
                    available: self.availableLanguages()
                )
                self.hasResolvedLanguage = true
            }
            let key = SuggestionCache.Key(prefix: composition.lowercased(), language: self.language)
            let value = SuggestionCache.Value(
                completions: self.checker.completions(for: composition, language: self.language),
                guesses: self.checker.guesses(for: composition, language: self.language),
                isKnown: self.checker.isKnown(composition, language: self.language),
                // Computed here rather than inside `context`, which the
                // cache-hit path also runs.
                similar: self.wordList.similarWords(to: composition, limit: 2)
            )
            guard generation == self.generation else { return }
            self.cache.insert(value, for: key)
            self.publishStrip(
                for: self.context(
                    composition: composition,
                    origin: origin,
                    preceding: preceding,
                    checked: value
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
        measured("build context") {
            buildContext(
                composition: composition,
                origin: origin,
                preceding: preceding,
                checked: checked
            )
        }
    }

    private func buildContext(
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
        let lowered = composition.lowercased()
        // One pass for both, over the folded copies: the prefix matches that
        // reach the strip, and the exact match that outranks it.
        var lexiconCompletions: [String] = []
        var lexiconExpansion: String?
        if !composition.isEmpty {
            for entry in lexiconEntries where entry.lowered.hasPrefix(lowered) {
                lexiconCompletions.append(entry.documentText)
                if lexiconExpansion == nil,
                   entry.lowered == lowered,
                   !entry.documentText.isEmpty
                {
                    lexiconExpansion = entry.documentText
                }
            }
        }
        context.lexiconEntries = lexiconCompletions
        // An *exact* match is an instruction rather than a suggestion: the user
        // told Settings that "omw" means something, and iOS hands keyboards the
        // lexicon precisely so it can be honoured. It used to reach the strip as
        // a chip and stop there, so the expansion only ever happened if the user
        // noticed it and tapped.
        context.lexiconExpansion = lexiconExpansion
        // Folded once with the vocabulary, for the same reason.
        context.customWords = composition.isEmpty
            ? []
            : zip(customWords, loweredCustomWords)
                .filter { $0.1.hasPrefix(lowered) }
                .map(\.0)
        context.learnedWords = snapshot.completions(for: composition, limit: 3)
        context.systemCompletions = Array((checked?.completions ?? []).prefix(8))
        // The checker's guesses first, the list's own near-matches behind them:
        // together they still answer when either one draws a blank.
        context.systemGuesses = TypingCandidates.merged(
            Array((checked?.guesses ?? []).prefix(4)),
            checked?.similar ?? []
        )
        context.listCompletions = wordList.completions(for: composition, limit: 3)
        // One dictionary lookup per guess, half a dozen of them. What it buys is
        // the difference between "both" and "coth" — see `correctionCost`.
        var listRanks: [String: Int] = [:]
        for guess in context.systemGuesses {
            let guessed = guess.lowercased()
            if let rank = wordList.rank(of: guessed) { listRanks[guessed] = rank }
        }
        // And every way the word could be cut in two, for the split that puts a
        // missed space back. Dictionary lookups, one per cut, on a word.
        if lowered.count >= 4, lowered.allSatisfy({ $0.isLetter }) {
            let characters = Array(lowered)
            for cut in 2...(characters.count - 2) {
                for half in [String(characters[..<cut]), String(characters[cut...])]
                where listRanks[half] == nil {
                    if let rank = wordList.rank(of: half) { listRanks[half] = rank }
                }
            }
        }
        context.listRanks = listRanks
        context.predictions = preceding.map { wordList.nextWords(after: $0, limit: 3) } ?? []
        // The same bigrams, but as evidence about the word being typed rather
        // than a guess about the next one. A wider window than the strip shows,
        // because this only has to contain the right answer, not display it.
        context.contextualFollowers = preceding.map {
            wordList.nextWords(after: $0, limit: 12)
        } ?? []
        context.isMidWord = isMidWord
        context.hasCheckerAnswer = checked != nil
        context.isKnownToChecker = checked?.isKnown ?? false
        context.isInWordList = wordList.contains(composition)
        context.assertedWords = assertedWords
        // Exact word only, so nothing appears while the user is partway into a
        // different one.
        // This snapshot arrives from the background loader, so the keystroke
        // never waits on a lazy static initializer.
        context.emojiSuggestion = emojiTriggers[composition.lowercased()]
        context.emojiEnabled = KeyboardPreferences.emojiSuggestionsEnabled
        context.suggestionsEnabled = KeyboardPreferences.typingSuggestionsEnabled
        context.autocorrectEnabled = KeyboardPreferences.autocorrectIsActive
        context.predictionEnabled = KeyboardPreferences.nextWordPredictionEnabled
        context.allowsTypingIntelligence = policy.allowsTypingIntelligence
        return context
    }

    /// The touch model's language half, recomputed whenever the composition
    /// moves.
    ///
    /// Guarded by the same policy as everything else here: a password field gets
    /// no prediction, which means its keys get no bias either. Bounded scan, so
    /// this stays affordable on the keystroke path — see
    /// ``TypingWordList/nextCharacterWeights(after:scanLimit:)``.
    private func publishNextCharacters() {
        guard let onNextCharacters else { return }
        let composition = composer.text
        guard policy.allowsTypingIntelligence, !composition.isEmpty, hasLoaded else {
            if !lastNextCharacters.isEmpty {
                lastNextCharacters = [:]
                onNextCharacters([:])
            }
            return
        }
        let weights = wordList.nextCharacterWeights(after: composition)
        guard weights != lastNextCharacters else { return }
        lastNextCharacters = weights
        onNextCharacters(weights)
    }

    private var lastNextCharacters: [Character: Double] = [:]

    /// Whether the cursor sits inside a word rather than at the end of one.
    ///
    /// Set from the document's *trailing* context, which is the piece this
    /// subsystem never read. Without it, tapping into the middle of
    /// "helloworld" after "hello" left a composition of "hello" that the next
    /// space would happily autocorrect — rewriting the first half of a word the
    /// keyboard could only see half of.
    private var isMidWord = false

    /// Times one phase of a keystroke into the trace. See the twin of this in
    /// the controller: the phases are measured because guessing at them cost a
    /// round of work that moved the median by 0.2 ms.
    private func measured<T>(_ name: String, _ body: () -> T) -> T {
        guard TouchTrace.isEnabled else { return body() }
        let startedAt = CACurrentMediaTime()
        defer {
            TouchTrace.note(
                String(format: "    %@ %.1fms", name, (CACurrentMediaTime() - startedAt) * 1000)
            )
        }
        return body()
    }

    /// Publishes the strip for `context`, and — while a touch trace is armed —
    /// records what the next boundary would do with the word, and why.
    ///
    /// The refusal is the part worth recording. A word that stands looks the
    /// same whether the rule found it already correct, found two equally good
    /// readings, or was switched off, and those are three different bugs.
    private func publishStrip(for context: TypingCandidates.Context) {
        TouchTrace.note(
            "compose \"\(context.composition)\" "
                + TypingCandidates.autocorrectDecision(context).outcomeDescription
        )
        let strip = measured("candidates.strip") { TypingCandidates.strip(context) }
        measured("publish") { publish(strip) }
    }

    private func publish(_ newStrip: TypingStrip) {
        guard newStrip != strip else { return }
        strip = newStrip
        onStrip?(newStrip)
    }
}
