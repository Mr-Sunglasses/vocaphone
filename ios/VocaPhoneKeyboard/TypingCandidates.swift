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
}

/// Everything the strip needs to draw itself for one keystroke.
struct TypingStrip: Equatable {
    var candidates: [TypingCandidate] = []
    /// The replacement a boundary key will apply, or `nil` when the typed word
    /// stands. Always mirrored by an emphasised chip.
    var autocorrection: String?

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
        var isKnownToChecker = false
        /// Whether the word list contains it.
        var isInWordList = false
        /// Words the user restored after an autocorrect, for this document.
        var assertedWords: Set<String> = []

        /// The emoji for the word being composed, when there is an obvious one.
        var emojiSuggestion: String?

        var suggestionsEnabled = true
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
            autocorrection: correction
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
    static func autocorrection(_ context: Context) -> String? {
        guard context.suggestionsEnabled,
              context.autocorrectEnabled,
              context.allowsTypingIntelligence
        else { return nil }

        // Only keystrokes. A dictated word, an accepted swipe and a tapped
        // suggestion were all chosen by something the user saw.
        guard context.origin == .typed else { return nil }

        // The cursor is inside a longer word. The keyboard is holding a prefix
        // of something it cannot see the end of, and rewriting that prefix
        // corrupts a word the user never finished typing in the first place.
        guard !context.isMidWord else { return nil }

        let typed = context.composition
        guard !typed.isEmpty else { return nil }

        // The user's own assertion outranks every source below, including the
        // curated table: someone who put their spelling back once has answered
        // this question already.
        guard !contains(context.customWords, typed),
              !contains(context.learnedWords, typed),
              !context.assertedWords.contains(typed.lowercased())
        else { return nil }

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
            return expansion
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
        guard !isAllCaps(typed) else { return nil }

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
            return replacement
        }

        // Two-letter words are mostly deliberate, and the shorter the word the
        // more words sit within one edit of it. Anything genuinely worth fixing
        // at that length is in the table above.
        guard typed.count >= 3 else { return nil }

        // Anything the user or the language already recognises stands.
        guard !context.isKnownToChecker,
              !context.isInWordList
        else { return nil }

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
        guard context.emojiSuggestion == nil else { return nil }

        // Letters and apostrophes only. A token with a digit, an `@`, a slash or
        // an underscore is an identifier, a handle, a path or a password hint —
        // never something to "fix".
        guard typed.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "\u{2019}" }) else {
            return nil
        }

        let guesses = context.systemGuesses.filter {
            $0.caseInsensitiveCompare(typed) != .orderedSame
        }
        guard !guesses.isEmpty else { return nil }

        // Re-ranked rather than taken in the order the checker offered them.
        //
        // `UITextChecker` ranks by spelling alone, which is the one thing a
        // keyboard can improve on: it knows where the fingers were, and it knows
        // what word came before. Both are folded into a single cost here, so the
        // margin rule below compares like with like.
        let scored = guesses
            .map { (word: $0, cost: correctionCost(typed: typed, candidate: $0, context: context)) }
            .sorted { $0.cost < $1.cost }
        guard let best = scored.first else { return nil }

        // Close enough to be a typo rather than a different word. Measured
        // unweighted, because "is this a typo at all" is a question about how
        // many characters moved, not about which keys they were near.
        let bestEdits = editDistance(typed.lowercased(), best.word.lowercased(), maximum: 2)
        guard bestEdits <= 2 else { return nil }

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
            let hasProximityMargin = scored[1].cost - best.cost >= 0.7
            let isContextual = contains(context.contextualFollowers, best.word)
            guard hasSpellingMargin
                || hasProximityMargin
                || isContextual
                || isTransposition(typed.lowercased(), best.word.lowercased())
            else { return nil }
        }

        // Capitalization is `updateAutomaticShift`'s job. An autocorrect that
        // only changes case is the keyboard fighting the shift key.
        guard best.word.lowercased() != typed.lowercased() else { return nil }

        return best.word
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
