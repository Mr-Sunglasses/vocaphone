import Foundation

/// One chip in the typing strip.
struct TypingCandidate: Equatable {
    enum Kind: Equatable {
        /// Exactly what the user typed, shown in quotes when an autocorrect is
        /// about to replace it. Tapping it asserts the word.
        case literal
        /// A longer word starting with what has been typed.
        case completion
        /// A different word, for something the checker does not recognise.
        case correction
        /// What usually follows the word just finished.
        case prediction
        /// An emoji for the word being typed. Never competes with the word
        /// candidates for a slot — it is offered beside them or not at all.
        case emoji
        /// A word the swipe recogniser ranked below the one it committed.
        /// Distinct from ``correction`` because replacing it has to take the
        /// space the swipe inserted with it — see ``SwipeAlternates``.
        case swipeAlternate
        /// The word the user actually typed, offered back immediately after an
        /// autocorrect replaced it.
        ///
        /// The system keyboard draws a small bubble under the corrected word
        /// carrying the original. An extension cannot: the word is in the host
        /// app's text view, in another process, at coordinates this keyboard is
        /// never told. The strip is the surface this keyboard does own, so the
        /// offer goes there — visible for exactly as long as the correction is
        /// still the last thing that happened.
        case revert
    }

    let text: String
    let kind: Kind
    /// The one chip a boundary key would apply on its own. At most one chip is
    /// emphasised, and only when something really would be applied — an
    /// emphasised chip that space does not apply is a lie the user only catches
    /// after losing a word.
    var isEmphasised = false

    /// What makes this chip *this* chip on screen.
    ///
    /// The row is rebuilt on every keystroke, and identifying a chip by its
    /// position means the suggestion for a new prefix inherits the identity —
    /// and the running animation — of the word that was there before it.
    var identity: String { "\(kind)-\(text)" }
}

/// Everything the strip needs to draw itself for one keystroke.
struct TypingStrip: Equatable {
    var candidates: [TypingCandidate] = []
    /// The replacement a boundary key will apply, or `nil` when the typed word
    /// stands. Always mirrored by an emphasised chip.
    var autocorrection: String?
    /// The word that replacement was worked out for.
    ///
    /// The strip is not cleared while the checker is being consulted, so between
    /// one letter and the checker's answer it still carries the correction for
    /// the word as it stood a keystroke ago. A space arriving in that window
    /// used to apply it — rewriting "howit" with a correction meant for "howi".
    /// The boundary now checks that the offer is about the word in hand.
    var autocorrectionTarget: String?

    var isEmpty: Bool { candidates.isEmpty }

    static let none = TypingStrip()
}

/// Ranks candidates and decides whether to autocorrect.
///
/// Entirely pure, and driven by an injected dictionary in tests. `UITextChecker`
/// reads the user's own device dictionaries, which differ between machines and
/// between iOS versions, so asserting "teh → the" against the real checker is a
/// flake waiting to happen.
enum TypingCandidates {
    /// How many chips the strip can show.
    static let slotCount = 3

    /// Everything the decision depends on, gathered in one place so a test can
    /// vary exactly one fact.
    struct Context: Equatable {
        var composition = ""
        var origin: WordComposer.Origin = .typed
        /// The word before the cursor, for prediction. Lowercased.
        var precedingWord: String?

        // Sources, in priority order: what this device has learned about the
        // user first, then what iOS offers, then the shipped list.
        var lexiconEntries: [String] = []
        var customWords: [String] = []
        var learnedWords: [String] = []
        var systemCompletions: [String] = []
        var systemGuesses: [String] = []
        var listCompletions: [String] = []
        var predictions: [String] = []
        /// What usually follows ``precedingWord``. Distinct from ``predictions``
        /// — which is the same data used to fill an *empty* strip — because here
        /// it is evidence about the word being typed rather than a guess about
        /// the next one. "I'll be there son" and "sooner" are the same distance
        /// from "son"; only "be there" says which.
        var contextualFollowers: [String] = []

        /// The user's own text replacement for exactly this input, if they have
        /// one. iOS hands keyboards the lexicon specifically so that "omw" can
        /// mean what its owner told Settings it means.
        var lexiconExpansion: String?

        /// Whether the cursor sits inside a longer word rather than at the end
        /// of one. Nothing may be replaced there: the composition is a prefix of
        /// a word the keyboard can only see half of.
        var isMidWord = false

        /// Whether the system checker recognises the composition.
        /// Whether the checker has answered for this word yet.
        ///
        /// It is asked only once the hand pauses, so for the length of a brisk
        /// keystroke there is no answer and `isKnownToChecker` is `false` — which
        /// is not the same as "not a word". Rules that read that flag as
        /// evidence must wait; rules that merely rank may proceed.
        var hasCheckerAnswer = false
        var isKnownToChecker = false
        /// Whether the word list contains it.
        var isInWordList = false
        /// Words the user restored after an autocorrect, for this document.
        var assertedWords: Set<String> = []

        /// The emoji for the word being composed, when there is an obvious one.
        var emojiSuggestion: String?

        var suggestionsEnabled = true
        /// Where each system guess sits in the shipped frequency list, if the list
    /// knows it at all. Keyed lowercase.
    var listRanks: [String: Int] = [:]
    var autocorrectEnabled = true
        var predictionEnabled = true
        var emojiEnabled = true
        var allowsTypingIntelligence = true
    }

    // MARK: - Strip

    static func strip(_ context: Context) -> TypingStrip {
        guard context.suggestionsEnabled, context.allowsTypingIntelligence else { return .none }

        guard !context.composition.isEmpty else {
            guard context.predictionEnabled else { return .none }
            let predictions = deduplicated(context.predictions)
                .prefix(slotCount)
                .map { TypingCandidate(text: $0, kind: .prediction) }
            return TypingStrip(candidates: Array(predictions), autocorrection: nil)
        }

        let correction = autocorrection(context)
        var ranked = rankedSuggestions(context)

        // The correction, if there is one, owns the emphasised slot — it is
        // what space will apply, so it must be the chip the eye lands on.
        if let correction {
            ranked.removeAll { $0.caseInsensitiveCompare(correction) == .orderedSame }
            ranked.insert(correction, at: 0)
        }

        var candidates: [TypingCandidate] = []
        // The literal only earns a slot when something is about to replace it.
        // Showing the user their own word back on every keystroke would waste a
        // third of the strip saying nothing.
        if correction != nil {
            candidates.append(TypingCandidate(text: context.composition, kind: .literal))
        }
        for (index, suggestion) in ranked.enumerated() {
            guard candidates.count < slotCount else { break }
            let kind: TypingCandidate.Kind =
                correction != nil && index == 0 ? .correction : .completion
            candidates.append(
                TypingCandidate(
                    text: suggestion,
                    kind: kind,
                    isEmphasised: correction != nil && index == 0
                )
            )
        }
        return TypingStrip(
            candidates: appendingEmoji(to: candidates, context: context),
            autocorrection: correction,
            autocorrectionTarget: correction == nil ? nil : context.composition
        )
    }

    /// The strip shown for as long as a just-applied autocorrect can still be
    /// taken back — the extension's stand-in for the system keyboard's revert
    /// bubble, which needs coordinates in the host app that no extension is
    /// given. One chip, carrying what the user actually typed.
    static func revertStrip(typed: String) -> TypingStrip {
        TypingStrip(
            candidates: [TypingCandidate(text: typed, kind: .revert)],
            autocorrection: nil
        )
    }

    /// The emoji goes last, and takes the lowest-ranked word's slot when the
    /// strip is already full.
    ///
    /// A fourth chip was the intention — the three word slots are what the
    /// strip is for — but on a 320 pt phone four chips plus the Dictate button
    /// push the emoji off the visible row entirely. A suggestion the user has
    /// to scroll sideways to discover is not a suggestion, so on a full strip
    /// the emoji displaces the *last* candidate: the third-ranked completion,
    /// which is the least likely word on the row.
    ///
    /// The literal and the emphasised correction are never at risk. They sit at
    /// the front, and the one that space would apply must always be visible.
    private static func appendingEmoji(
        to candidates: [TypingCandidate],
        context: Context
    ) -> [TypingCandidate] {
        guard context.emojiEnabled,
              let glyph = context.emojiSuggestion,
              !candidates.contains(where: { $0.kind == .emoji })
        else { return candidates }
        var kept = candidates
        if kept.count >= slotCount { kept.removeLast() }
        return kept + [TypingCandidate(text: glyph, kind: .emoji)]
    }

    /// Suggestions in priority order, deduplicated, never echoing the typed word.
    ///
    /// Personal sources come first at equal quality: someone who taught the app
    /// their surname should not have to scroll past the dictionary to find it.
    static func rankedSuggestions(_ context: Context) -> [String] {
        var ordered: [String] = []
        ordered.append(contentsOf: context.lexiconEntries)
        ordered.append(contentsOf: context.customWords)
        ordered.append(contentsOf: context.learnedWords)
        // Exact-prefix completions before corrections, from both sources: a
        // longer version of what is already typed is nearly always closer to
        // the user's intent than a different word.
        ordered.append(contentsOf: context.systemCompletions)
        ordered.append(contentsOf: context.listCompletions)
        ordered.append(contentsOf: context.systemGuesses)
        return deduplicated(ordered).filter {
            $0.caseInsensitiveCompare(context.composition) != .orderedSame
        }
    }

    // MARK: - Autocorrect

    /// The replacement a boundary key should apply, or `nil` to leave the typed
    /// word alone.
    ///
    /// Every condition here exists because an autocorrect that fires wrongly is
    /// worse than no autocorrect at all: it takes a word the user typed
    /// deliberately and replaces it after they have stopped looking. The rules
    /// are individually tested, and each test fails if its rule is removed.
    /// Whether the next boundary should replace the word, and when it should
    /// not, what stopped it.
    ///
    /// The reason is not decoration. This rule is a ladder of fifteen refusals,
    /// each one written against a case where correcting would have been worse
    /// than leaving the word alone — and from the outside every one of them
    /// looks identical: the word stands. Working out which rung a given word
    /// fell off by reading the ladder is guesswork; making it say so is not.
    static func autocorrectDecision(_ context: Context) -> AutocorrectDecision {
        guard context.suggestionsEnabled,
              context.autocorrectEnabled,
              context.allowsTypingIntelligence
        else { return .refused("off") }

        // Only keystrokes. A dictated word, an accepted swipe and a tapped
        // suggestion were all chosen by something the user saw.
        guard context.origin == .typed else { return .refused("not typed") }

        // The cursor is inside a longer word. The keyboard is holding a prefix
        // of something it cannot see the end of, and rewriting that prefix
        // corrupts a word the user never finished typing in the first place.
        guard !context.isMidWord else { return .refused("mid-word") }

        let typed = context.composition
        guard !typed.isEmpty else { return .refused("nothing composed") }

        // The user's own assertion outranks every source below, including the
        // curated table: someone who put their spelling back once has answered
        // this question already.
        guard !contains(context.customWords, typed),
              !contains(context.learnedWords, typed),
              !context.assertedWords.contains(typed.lowercased())
        else { return .refused("the user asserted this spelling") }

        // A text replacement the user configured in Settings. Not a guess — an
        // instruction — which is why it outranks everything below it.
        //
        // But it has to be a real *expansion*. `UILexicon` is not just the
        // shortcuts someone typed into Settings: it also carries names from
        // Contacts and the system's own proper nouns, as a lowercase
        // `userInput` mapped to a properly-cased `documentText` — "world" to
        // "World", "iphone" to "iPhone". Applying those on an exact match meant
        // any ordinary word that happened to be in the user's address book was
        // silently capitalised mid-sentence, with no way to tell which words
        // would do it. That is the same thing the case-only guard further down
        // exists to prevent, and this path was walking straight past it.
        //
        // A case-only lexicon entry is still *offered*: it reaches the strip
        // through `lexiconEntries`, at the top of `rankedSuggestions`. Offering
        // it is right. Imposing it is not.
        if let expansion = context.lexiconExpansion,
           expansion.lowercased() != typed.lowercased()
        {
            return .apply(expansion)
        }

        // The curated short-word table, ahead of every guard below it. Each of
        // those guards would refuse these words — "i" is too short, "dont" is
        // only a case and apostrophe away from nothing the checker will guess —
        // and refusing them is what made this keyboard visibly worse than the
        // system one at the corrections people notice first.
        // Acronyms stand. "WIP" is not a misspelling of "wip", and "DONT"
        // typed with caps lock on is not asking to become "don't" — someone
        // shouting has still chosen their letters.
        //
        // Above the curated table rather than below it, which is where this
        // check used to sit: the table would otherwise rewrite a shouted
        // contraction before the acronym rule ever ran. Deliberately *below*
        // the lexicon, because a text replacement is an instruction the user
        // configured, and "OMW" should expand whatever case it is typed in.
        guard !isAllCaps(typed) else { return .refused("shouted") }

        // Exact comparison here, and here it *is* the whole point: "i" → "I" is
        // a case-only change, which is precisely what the general path below
        // refuses and precisely what this table exists to allow.
        //
        // Safe here and not for the lexicon above because this table is
        // curated: thirty-odd entries, each one a word whose capital is
        // unambiguous in English. The lexicon is whatever happens to be in
        // someone's contacts.
        if let replacement = ShortWordCorrections.replacement(for: typed),
           replacement != typed
        {
            return .apply(replacement)
        }

        // Two-letter words are mostly deliberate, and the shorter the word the
        // more words sit within one edit of it. Anything genuinely worth fixing
        // at that length is in the table above.
        guard typed.count >= 3 else { return .refused("shorter than three letters") }

        // Anything the user or the language already recognises stands.
        guard !context.isKnownToChecker,
              !context.isInWordList
        else { return .refused("already a word") }

        // A word this keyboard has a curated emoji for is a word people type on
        // purpose. Most of them — "omg", "lmao", "haha", "yay", "ugh", "meh",
        // "congrats" — are absent from the shipped word list, so without this
        // the keyboard would offer 😱 for "omg" while quietly preparing to turn
        // it into "org" on the next space. Offering a suggestion for a word and
        // correcting that same word away is the keyboard disagreeing with
        // itself, and the user only finds out afterwards.
        //
        // Independent of whether the emoji chip is switched on: the setting
        // controls whether a chip is drawn, not whether the word was meant.
        guard context.emojiSuggestion == nil else { return .refused("a word with an emoji of its own") }

        // Letters and apostrophes only. A token with a digit, an `@`, a slash or
        // an underscore is an identifier, a handle, a path or a password hint —
        // never something to "fix".
        guard typed.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "\u{2019}" }) else {
            return .refused("not a word token")
        }

        let typedIsLowercase = typed == typed.lowercased()
        let typedIsSplit = typed.contains("-") || typed.contains(" ")
        // A word that is two words with the space missed.
        //
        // This is the correction the typing in front of me actually needed:
        // "howit", "sothis", "thisi", "worksn" — every one of them a space that
        // did not register, and every one of them offered back by the checker
        // as a hyphenation ("how-it", "so-this") because a spell checker's job
        // is to spell one word rather than to notice there are two.
        //
        // Deliberately strict, because splitting a word the user meant is worse
        // than leaving one they did not: both halves have to be words the
        // shipped list knows, both at least two letters, and the split has to be
        // the only one that works. "into" is not "in to" — the whole word is
        // known, and this is only reached for words that are not.
        // And only once the checker has answered. Until it does,
        // `isKnownToChecker` is false for every word, so the guard above lets
        // real compounds through — and the shipped ten thousand does not contain
        // "sometime", "backend", "frontend", "logout", "weekday" or "standup".
        // Splitting those is not a correction, it is damage.
        if context.hasCheckerAnswer,
           let split = wordSplit(typed, context: context)
        {
            return .apply(split)
        }

        let guesses = context.systemGuesses
            .filter { $0.caseInsensitiveCompare(typed) != .orderedSame }
            // One word typed becomes one word corrected.
            //
            // `UITextChecker` answers "howit" with "how-it" and "sothis" with
            // "so-this": it splits the word at a hyphen, which is not what
            // anybody meant and is exactly what a keyboard correcting "howit"
            // to "how-it" looks like from the outside. Measured across a
            // session's typing, these split guesses were also the ones
            // defeating the margin rule below — "so-this and sot-his both fit"
            // is two pieces of nonsense agreeing that a real typo stands.
            .filter { typedIsSplit || !$0.contains(where: { $0 == "-" || $0 == " " }) }
            // And a word typed in lowercase does not become a proper noun. The
            // checker's dictionary carries place names and abbreviations —
            // "Sotho" for "sothi", "IoW" for "sow" — and a sentence being typed
            // in lowercase did not ask for either. Capitalisation that is
            // *wanted* comes from the curated table and the lexicon above,
            // both of which have already had their say.
            .filter { !typedIsLowercase || $0.first?.isUppercase != true }
        guard !guesses.isEmpty else { return .refused("the checker offered nothing") }

        // Re-ranked rather than taken in the order the checker offered them.
        //
        // `UITextChecker` ranks by spelling alone, which is the one thing a
        // keyboard can improve on: it knows where the fingers were, and it knows
        // what word came before. Both are folded into a single cost here, so the
        // margin rule below compares like with like.
        let scored = guesses
            .map { (word: $0, cost: correctionCost(typed: typed, candidate: $0, context: context)) }
            .sorted { $0.cost < $1.cost }
        guard let best = scored.first else { return .refused("nothing scored") }

        // Close enough to be a typo rather than a different word. Measured
        // unweighted, because "is this a typo at all" is a question about how
        // many characters moved, not about which keys they were near.
        let bestEdits = editDistance(typed.lowercased(), best.word.lowercased(), maximum: 2)
        guard bestEdits <= 2 else { return .refused("too far: \(bestEdits) edits to \(best.word)") }

        // A comfortable margin over the runner-up. Two equally good guesses
        // means nothing here knows which either, and picking one is a coin toss
        // played with the user's sentence — "hend" is as near to "hand" as it is
        // to "bend", and only the user knows which.
        //
        // Two exceptions, both cases where the ambiguity is only apparent:
        //
        // - A transposition. "teh" is "the" with two keys swapped, and no
        //   competing guess explains the letters as well. Without this the most
        //   famous typo in English would go uncorrected.
        // - A word the preceding word actually predicts. "be there son" and
        //   "be there soon" are the same edit from "son"; the bigram is the
        //   evidence that breaks the tie, and it is evidence the checker never
        //   had.
        if scored.count > 1 {
            // Two margins, and either one is enough.
            //
            // Spelling first: a runner-up that needs strictly more edits is
            // plainly the worse reading, whatever the fingers were doing. This
            // is the rule that was here before proximity weighting, and it has
            // to stay — weighted costs compress the range, so "hand" (one
            // substitution) and "blend" (an insertion *and* a substitution) came
            // out only 0.4 apart and the obvious correction stopped firing.
            //
            // Proximity second, and only by a wide gap. Being near the key the
            // finger actually hit is evidence, not proof: it should settle a
            // contest between two readings the dictionary rates the same, and
            // never manufacture a winner where there genuinely is not one.
            // "hend" is one edit from "hand" and one from "bend", and no amount
            // of knowing that "b" is under "h" makes that a question the
            // keyboard is entitled to answer.
            let secondEdits = editDistance(
                typed.lowercased(),
                scored[1].word.lowercased(),
                maximum: 3
            )
            let hasSpellingMargin = secondEdits > bestEdits
            // Not proximity alone, whatever this used to be called. The cost
            // compared here now carries three things — how far the fingers
            // travelled, whether the sentence predicts the word, and how well
            // the shipped list knows it — and the last can clear the threshold
            // by itself: a common word against one the list has never heard of
            // differs by 0.85 before a finger is considered. That is deliberate,
            // and it is what stopped "both" losing to "coth".
            let hasCostMargin = scored[1].cost - best.cost >= 0.7
            let isContextual = contains(context.contextualFollowers, best.word)
            guard hasSpellingMargin
                || hasCostMargin
                || isContextual
                || isTransposition(typed.lowercased(), best.word.lowercased())
            else { return .refused("ambiguous: \(best.word) and \(scored[1].word) both fit") }
        }

        // Capitalization is `updateAutomaticShift`'s job. An autocorrect that
        // only changes case is the keyboard fighting the shift key.
        guard best.word.lowercased() != typed.lowercased() else { return .refused("a change of case only") }

        return .apply(best.word)
    }

    /// What the boundary should do with the word, and why.
    enum AutocorrectDecision: Equatable {
        case apply(String)
        case refused(String)

        var replacement: String? {
            switch self {
            case let .apply(word): word
            case .refused: nil
            }
        }

        /// What happened, in the words the decision was made in.
        var outcomeDescription: String {
            switch self {
            case let .apply(word): "would apply \(word)"
            case let .refused(reason): "stands — \(reason)"
            }
        }

        var refusal: String? {
            switch self {
            case .apply: nil
            case let .refused(reason): reason
            }
        }
    }

    static func autocorrection(_ context: Context) -> String? {
        autocorrectDecision(context).replacement
    }

    /// The one way `typed` reads as two words, or `nil` if there is not exactly
    /// one.
    ///
    /// Both halves must be in the shipped frequency list — which is ten thousand
    /// words in order of how often they are written — and common enough that the
    /// pair is a sentence rather than a coincidence. Ambiguity is refused the
    /// same way it is everywhere else here: two possible splits mean the
    /// keyboard does not know which, and guessing costs the user their word.
    static func wordSplit(_ typed: String, context: Context) -> String? {
        let lowered = typed.lowercased()
        guard lowered.count >= 4, lowered.allSatisfy({ $0.isLetter }) else { return nil }
        let characters = Array(lowered)
        var found: String?
        for cut in 2...(characters.count - 2) {
            let left = String(characters[..<cut])
            let right = String(characters[cut...])
            guard let leftRank = context.listRanks[left],
                  let rightRank = context.listRanks[right]
            else { continue }
            // Common on both sides. A rare word paired with a rare word is how
            // "themes" becomes "the mes".
            guard leftRank < 3000, rightRank < 3000 else { continue }
            // A second way to cut it means the keyboard has no idea which.
            guard found == nil else { return nil }
            found = matchingCase(of: typed, applyingTo: left + " " + right)
        }
        return found
    }

    /// How reluctant the keyboard should be to replace `typed` with `candidate`.
    /// Lower is better; the units are edits, so the margin threshold above means
    /// something concrete.
    static func correctionCost(typed: String, candidate: String, context: Context) -> Double {
        var cost = KeyProximity.weightedDistance(
            typed.lowercased(),
            candidate.lowercased(),
            maximum: 3
        )
        // The preceding word predicts this one. Worth about half an edit: enough
        // to settle a tie, never enough to beat a plainly closer spelling.
        // Worth more than a neighbouring-key substitution discount, and
        // deliberately so: which word the sentence wants is better evidence than
        // which key the finger was near. Not enough to beat a plainly closer
        // spelling, which the margin rule above still requires.
        if contains(context.contextualFollowers, candidate) { cost -= 0.7 }
        // The shipped list is frequency-ordered and the checker is not, so a
        // guess the list knows is the more likely reading of the two.
        if contains(context.listCompletions, candidate) { cost -= 0.1 }
        // And how well it knows it.
        //
        // `UITextChecker` ranks nothing: "coth" comes back beside "both" as an
        // equal reading of "coth"'s neighbour, and the margin rule below then
        // refuses to choose between them — which is how "both" went uncorrected
        // eight times in one session. The shipped list is ten thousand words in
        // frequency order, so it can say what the checker cannot: that one of
        // the two is a word people write and the other is not.
        //
        // Bounded like every other adjustment here. A word the list has never
        // heard of is not disqualified — plenty of real words are outside ten
        // thousand — it simply stops counting as an equal.
        if let rank = context.listRanks[candidate.lowercased()] {
            cost -= rank < 2000 ? 0.35 : 0.15
        } else {
            cost += 0.5
        }
        return cost
    }

    // MARK: - Helpers

    /// Whether `right` is `left` with exactly one adjacent pair swapped.
    ///
    /// The highest-confidence typo signal there is: two fingers arriving in the
    /// wrong order, which no other word explains.
    static func isTransposition(_ left: String, _ right: String) -> Bool {
        let a = Array(left)
        let b = Array(right)
        guard a.count == b.count, a.count >= 2 else { return false }
        var differences: [Int] = []
        for index in a.indices where a[index] != b[index] {
            differences.append(index)
            if differences.count > 2 { return false }
        }
        guard differences.count == 2 else { return false }
        let (first, second) = (differences[0], differences[1])
        return second == first + 1 && a[first] == b[second] && a[second] == b[first]
    }

    static func isAllCaps(_ word: String) -> Bool {
        let letters = word.filter(\.isLetter)
        return !letters.isEmpty && letters.allSatisfy(\.isUppercase)
    }

    /// Applies the typed word's capitalization to a replacement, so correcting
    /// "Teh" gives "The" rather than "the".
    static func matchingCase(of typed: String, applyingTo replacement: String) -> String {
        guard let first = typed.first else { return replacement }
        // A replacement that carries its own capitalization is not a spelling of
        // the typed word — it is a substitution the keyboard was told to make.
        // "omw" must not become "ON MY WAY!" because the user happened to have
        // caps lock on, and "i" must stay "I" rather than being lowercased back.
        guard !carriesOwnCase(replacement) else { return replacement }
        if isAllCaps(typed), typed.count > 1 { return replacement.uppercased() }
        if first.isUppercase { return replacement.prefix(1).uppercased() + replacement.dropFirst() }
        return replacement
    }

    /// Whether a replacement's capitalization is deliberate: a text replacement,
    /// a phrase, or anything already carrying an uppercase letter.
    static func carriesOwnCase(_ replacement: String) -> Bool {
        replacement.contains(where: \.isWhitespace)
            || replacement.contains(where: \.isUppercase)
    }

    /// Concatenates without duplicates, keeping the first occurrence's order.
    static func merged(_ first: [String], _ second: [String]) -> [String] {
        deduplicated(first + second)
    }

    private static func contains(_ words: [String], _ word: String) -> Bool {
        words.contains { $0.caseInsensitiveCompare(word) == .orderedSame }
    }

    private static func deduplicated(_ words: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for word in words {
            let key = word.lowercased()
            guard !word.isEmpty, seen.insert(key).inserted else { continue }
            result.append(word)
        }
        return result
    }

    /// Damerau-Levenshtein, bounded. Bounded because the answer is only ever
    /// compared against a small threshold, and a full matrix over a ten-thousand
    /// word list is work with no reader.
    static func editDistance(_ left: String, _ right: String, maximum: Int) -> Int {
        if left == right { return 0 }
        let a = Array(left)
        let b = Array(right)
        if abs(a.count - b.count) > maximum { return maximum + 1 }
        if a.isEmpty { return min(b.count, maximum + 1) }
        if b.isEmpty { return min(a.count, maximum + 1) }

        var previousPrevious = [Int](repeating: 0, count: b.count + 1)
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)

        for i in 1...a.count {
            current[0] = i
            var rowMinimum = current[0]
            for j in 1...b.count {
                let substitution = a[i - 1] == b[j - 1] ? 0 : 1
                var value = min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + substitution
                )
                // Transposition: "teh" is one edit from "the", not two.
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    value = min(value, previousPrevious[j - 2] + 1)
                }
                current[j] = value
                rowMinimum = min(rowMinimum, value)
            }
            if rowMinimum > maximum { return maximum + 1 }
            swap(&previousPrevious, &previous)
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
