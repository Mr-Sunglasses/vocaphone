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

        /// Whether the system checker recognises the composition.
        var isKnownToChecker = false
        /// Whether the word list contains it.
        var isInWordList = false
        /// Words the user restored after an autocorrect, for this document.
        var assertedWords: Set<String> = []

        var suggestionsEnabled = true
        var autocorrectEnabled = true
        var predictionEnabled = true
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
        return TypingStrip(candidates: candidates, autocorrection: correction)
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

        let typed = context.composition
        // Two-letter words are mostly deliberate, and the shorter the word the
        // more words sit within one edit of it.
        guard typed.count >= 3 else { return nil }

        // Anything the user or the language already recognises stands.
        guard !context.isKnownToChecker,
              !context.isInWordList,
              !contains(context.customWords, typed),
              !contains(context.learnedWords, typed),
              !context.assertedWords.contains(typed.lowercased())
        else { return nil }

        // Letters and apostrophes only. A token with a digit, an `@`, a slash or
        // an underscore is an identifier, a handle, a path or a password hint —
        // never something to "fix".
        guard typed.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "\u{2019}" }) else {
            return nil
        }

        // Acronyms stand. "WIP" is not a misspelling of "wip".
        guard !isAllCaps(typed) else { return nil }

        let guesses = context.systemGuesses.filter {
            $0.caseInsensitiveCompare(typed) != .orderedSame
        }
        guard let best = guesses.first else { return nil }

        // Close enough to be a typo rather than a different word.
        let bestDistance = editDistance(typed.lowercased(), best.lowercased(), maximum: 2)
        guard bestDistance <= 2 else { return nil }

        // A comfortable margin over the runner-up. Two equally close guesses
        // means the checker does not know which either, and picking one is a
        // coin toss played with the user's sentence — "hend" is as near to
        // "hand" as it is to "bend", and only the user knows which.
        //
        // A transposition is the exception, because it is the one typo class
        // with no ambiguity: "teh" is "the" with two keys swapped, and no
        // competing guess explains the letters as well. Without this exception
        // the most famous typo in English would go uncorrected.
        if guesses.count > 1 {
            let second = editDistance(typed.lowercased(), guesses[1].lowercased(), maximum: 3)
            let hasMargin = bestDistance < second
            guard hasMargin || isTransposition(typed.lowercased(), best.lowercased()) else {
                return nil
            }
        }

        // Capitalization is `updateAutomaticShift`'s job. An autocorrect that
        // only changes case is the keyboard fighting the shift key.
        guard best.lowercased() != typed.lowercased() else { return nil }

        return best
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
        if isAllCaps(typed), typed.count > 1 { return replacement.uppercased() }
        if first.isUppercase { return replacement.prefix(1).uppercased() + replacement.dropFirst() }
        return replacement
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
