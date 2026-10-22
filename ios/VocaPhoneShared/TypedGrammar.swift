import Foundation

/// "Check grammar while typing": which typed text goes to the grammar model,
/// and how its answer becomes one edit at the cursor.
///
/// Pure, so every decision here is unit-tested without a keyboard or a model.
/// The keyboard asks `region(before:startKnown:)` what to check after the user
/// pauses, hands it to the containing app — the only process that may load the
/// model — turns the answer into a `Fix` the strip can show, and on a tap asks
/// `edit(_:before:)` for the deletions and insertion that apply it, against the
/// document as it is then. Nothing is ever changed without that tap.
///
/// Mirrors `android/.../grammar/TypedGrammar.kt`; both are tested against
/// `assets/grammar/typed_fixtures.json`. Counts here are in `Character`s,
/// because `deleteBackward()` removes one at a time.
enum TypedGrammar {
    /// The most text one check sends to the model: two ordinary sentences.
    static let maxRegion = 400

    /// Fewer words than this give the model nothing to read a sentence from.
    static let minWords = 2

    /// A correction the strip can offer: `checked` is the typed text the model
    /// read, `corrected` what it suggests, and the two agree for their first
    /// `start` characters. `original` and `replacement` are the changed words
    /// alone, for the chip.
    struct Fix: Equatable, Sendable {
        let checked: String
        let corrected: String
        let start: Int
        let original: String
        let replacement: String

        /// What the chip says: the words as typed, and what they become.
        var label: String {
            if replacement.isEmpty { return "Remove \u{201C}\(original)\u{201D}" }
            if original.isEmpty { return "Add \u{201C}\(replacement)\u{201D}" }
            return "\(original) \u{2192} \(replacement)"
        }
    }

    /// Delete `deleteBefore` characters before the cursor, then insert `insert`.
    struct Edit: Equatable, Sendable {
        let deleteBefore: Int
        let insert: String
    }

    /// The text to check, given the text before the cursor, or `nil` when there
    /// is nothing to check yet.
    ///
    /// Only at a word boundary: a check mid-word would read "kno" as a word to
    /// correct. Only the cursor's own paragraph, and only its last two
    /// sentences, finished or not. `startKnown` says whether `before` begins at
    /// the start of the field; when it does not — and a host's
    /// `documentContextBeforeInput` never says — its first sentence is
    /// probably cut off, and is left out unless it reads like a sentence start.
    static func region(before: String, startKnown: Bool) -> String? {
        guard let last = before.last else { return nil }
        if last.isLetter || last.isNumber || wordJoiners.contains(last) { return nil }
        let body = trimmingTrailingWhitespace(before)
        guard !body.isEmpty else { return nil }
        let characters = Array(body)
        let paragraphStart = (characters.lastIndex { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }).map { $0 + 1 } ?? 0
        let paragraph = String(characters[paragraphStart...])
        let known = startKnown || paragraphStart > 0
        var starts: [Int] = []
        if known || paragraph.first?.isUppercase == true { starts.append(0) }
        starts += boundaryEnds(in: paragraph)
        let length = paragraph.count
        starts = starts.filter { $0 < length }
        guard !starts.isEmpty,
              let start = starts.suffix(2).first(where: { length - $0 <= maxRegion })
        else { return nil }
        let region = String(paragraph.dropFirst(start))
        guard latinWordCount(region) >= minWords else { return nil }
        return region
    }

    /// The fix the model's `corrected` text offers for `checked`, or `nil` when
    /// there is nothing worth a chip.
    ///
    /// Two things the model does are taken back first, because on typed text
    /// they are not corrections: a full stop added to a sentence still being
    /// written, and a capital put on a first word the user typed lower case on
    /// purpose, which is how people write in chat. Past that, a change of case
    /// alone is offered only when it is the pronoun "I".
    static func fix(checked: String, corrected: String) -> Fix? {
        var out = Array(corrected)
        let typed = Array(checked)
        let typedRun = typed.reversed().prefix { trailingPunctuation.contains($0) }.count
        let outRun = out.reversed().prefix { trailingPunctuation.contains($0) }.count
        if outRun > typedRun,
           Array(out[(out.count - outRun)...].prefix(typedRun)) == Array(typed[(typed.count - typedRun)...])
        {
            out.removeLast(outRun - typedRun)
            out = Array(trimmingTrailingWhitespace(String(out)))
        }
        if let first = typed.first, first.isLowercase,
           !isPronounI(String(typed.prefix { !$0.isWhitespace })),
           let offered = out.first, String(offered) == String(first).uppercased()
        {
            out[0] = first
        }
        let outText = String(out)
        guard outText != checked, !outText.allSatisfy(\.isWhitespace) else { return nil }
        let typedWords = words(typed)
        let offeredWords = words(out)
        if outText.lowercased() == checked.lowercased(),
           !zip(typedWords, offeredWords).contains(where: { a, b in
               let word = String(typed[a])
               return isPronounI(word) && word != String(out[b])
           })
        {
            return nil
        }
        // Whole words, matched from both ends, so the chip says "don't →
        // doesn't" rather than "n't → esn't". A word only counts as unchanged
        // where it also sits at the same place, which is what lets the edit
        // keep everything before the first change.
        let shorter = min(typedWords.count, offeredWords.count)
        var prefix = 0
        while prefix < shorter, typedWords[prefix] == offeredWords[prefix],
              typed[typedWords[prefix]] == out[offeredWords[prefix]]
        {
            prefix += 1
        }
        var suffix = 0
        while suffix < shorter - prefix {
            let a = typedWords[typedWords.count - 1 - suffix]
            let b = offeredWords[offeredWords.count - 1 - suffix]
            guard typed.count - a.lowerBound == out.count - b.lowerBound, typed[a] == out[b] else { break }
            suffix += 1
        }
        let start = prefix == 0 ? 0 : typedWords[prefix - 1].upperBound
        let end = suffix == 0 ? typed.count : typedWords[typedWords.count - suffix].lowerBound
        let tail = typed.count - end
        return Fix(
            checked: checked,
            corrected: outText,
            start: start,
            original: String(typed[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines),
            replacement: String(out[start..<(out.count - tail)]).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// How to apply `fix` to the text before the cursor as it is now, or `nil`
    /// when that text no longer ends with what was checked — the user typed
    /// on, moved the cursor or edited the sentence — so the fix no longer
    /// describes it. Whitespace typed after the check is kept.
    static func edit(_ fix: Fix, before: String) -> Edit? {
        let body = trimmingTrailingWhitespace(before)
        guard body.hasSuffix(fix.checked) else { return nil }
        let trailing = String(before.dropFirst(body.count))
        return Edit(
            deleteBefore: fix.checked.count - fix.start + trailing.count,
            insert: String(fix.corrected.dropFirst(fix.start)) + trailing
        )
    }

    /// Whether a fix found for an earlier read still describes the text before
    /// the cursor: the two have to end the same way.
    static func stillDescribes(_ fix: Fix, window: String) -> Bool {
        let body = trimmingTrailingWhitespace(window)
        guard !body.isEmpty else { return false }
        return body.hasSuffix(fix.checked) || fix.checked.hasSuffix(body)
    }

    // MARK: - Pieces

    private static let wordJoiners: Set<Character> = ["'", "\u{2019}", "-"]
    private static let trailingPunctuation: Set<Character> = [".", ",", "!", "?", ";", ":"]
    private static let sentenceEnds: Set<Character> = [".", "!", "?"]
    private static let closers: Set<Character> = ["\"", "'", "\u{201D}", "\u{2019}", ")", "]"]

    /// Where each sentence after the first starts: past a full stop, question
    /// or exclamation mark, any closing quotes or brackets, and the space after.
    private static func boundaryEnds(in text: String) -> [Int] {
        let characters = Array(text)
        var ends: [Int] = []
        var index = 0
        while index < characters.count {
            guard sentenceEnds.contains(characters[index]) else {
                index += 1
                continue
            }
            var cursor = index + 1
            while cursor < characters.count, closers.contains(characters[cursor]) { cursor += 1 }
            var spaced = cursor
            while spaced < characters.count, characters[spaced].isWhitespace { spaced += 1 }
            if spaced > cursor { ends.append(spaced) }
            index = max(spaced, index + 1)
        }
        return ends
    }

    private static func latinWordCount(_ text: String) -> Int {
        var count = 0
        var inWord = false
        for scalar in text.unicodeScalars {
            let latin = (scalar.value >= 65 && scalar.value <= 90) || (scalar.value >= 97 && scalar.value <= 122)
            if latin, !inWord { count += 1 }
            if latin {
                inWord = true
            } else if scalar != "'", scalar != "\u{2019}" {
                inWord = false
            }
        }
        return count
    }

    private static func words(_ characters: [Character]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start: Int?
        for (index, character) in characters.enumerated() {
            if character.isWhitespace {
                if let open = start { ranges.append(open..<index) }
                start = nil
            } else if start == nil {
                start = index
            }
        }
        if let open = start { ranges.append(open..<characters.count) }
        return ranges
    }

    private static func isPronounI(_ word: String) -> Bool {
        word == "i" || word == "I" || ["i'", "i\u{2019}", "I'", "I\u{2019}"].contains { word.hasPrefix($0) }
    }

    private static func trimmingTrailingWhitespace(_ text: String) -> String {
        var characters = Substring(text)
        while let last = characters.last, last.isWhitespace { characters.removeLast() }
        return String(characters)
    }
}
