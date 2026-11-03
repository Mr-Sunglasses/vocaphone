import Foundation

/// Works out which words the user respelled in text a dictation typed, by
/// comparing the dictated span as it was inserted with the same span later.
///
/// Only spelling fixes count: a name spelled differently, a casing change, or
/// words joined into one term. Rewording a sentence is the user writing, not a
/// transcription mistake, and is ignored; so is swapping one ordinary word for
/// another ("there" → "their"), which no dictionary entry could help with.
///
/// A port of VocaMac's `CorrectionLearner`. Mirrors `CorrectionLearner.kt`;
/// both run the same cases in their tests.
enum CorrectionLearner {

    struct Correction: Equatable, Sendable {
        let heard: String
        let corrected: String
    }

    /// Longest edited region, in words, that is still a fix rather than a rewrite.
    static let maximumEditedWords = 12

    /// Corrections the user made inside the dictated text.
    ///
    /// - Parameters:
    ///   - inserted: The text the dictation typed.
    ///   - before: The text around it just after it was typed.
    ///   - after: The same text now.
    ///   - caretLocation: Caret position in `before`, in characters, used to
    ///     find the right copy of `inserted` when it appears more than once.
    ///   - isKnownWord: Whether a lowercase word is ordinary vocabulary.
    static func corrections(
        inserted: String,
        before: String,
        after: String,
        caretLocation: Int? = nil,
        isKnownWord: (String) -> Bool
    ) -> [Correction] {
        let dictated = inserted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dictated.isEmpty, before != after else { return [] }
        let old = Array(before)
        let new = Array(after)
        guard let insertedRange = locate(Array(dictated), in: old, caretLocation: caretLocation) else { return [] }

        // The single region where the two texts differ.
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix] {
            suffix += 1
        }

        // Widen to whole words so "Namratha" → "Namrata" compares whole names.
        while prefix > 0, isWordCharacter(old[prefix - 1]) { prefix -= 1 }
        while suffix > 0, isWordCharacter(old[old.count - suffix]) { suffix -= 1 }

        let oldChanged = prefix..<(old.count - suffix)
        let newChanged = prefix..<(new.count - suffix)
        let touches = oldChanged.overlaps(insertedRange)
            || (oldChanged.isEmpty && insertedRange.contains(prefix))
        guard touches else { return [] }
        // An edit reaching well outside the dictation is the user writing.
        guard oldChanged.lowerBound >= insertedRange.lowerBound - 1,
              oldChanged.upperBound <= insertedRange.upperBound + 1 else {
            return []
        }

        let oldWords = words(in: String(old[oldChanged]))
        // Which corrected words open a sentence: there a capital is only
        // sentence case, not evidence of a name.
        let opensSentence = Self.opensSentence(after: new[..<newChanged.lowerBound])
        let newTokens = wordsMarkingSentenceStarts(in: String(new[newChanged]), startsSentence: opensSentence)
        let newWords = newTokens.map(\.word)
        guard !oldWords.isEmpty, !newWords.isEmpty,
              oldWords.count <= maximumEditedWords, newWords.count <= maximumEditedWords else {
            return []
        }

        var found: [Correction] = []
        for block in substitutions(from: oldWords, to: newWords)
        where (1...3).contains(block.old.count) && (1...2).contains(block.new.count) {
            let heard = block.old.joined(separator: " ")
            let corrected = block.new.joined(separator: " ")
            let atSentenceStart = newTokens.indices.contains(block.newStart) && newTokens[block.newStart].startsSentence
            if isLikelyCorrection(
                heard: heard, corrected: corrected, atSentenceStart: atSentenceStart, isKnownWord: isKnownWord
            ) {
                found.append(Correction(heard: heard, corrected: corrected))
            }
        }
        return Array(found.prefix(3))
    }

    /// Whether changing `heard` to `corrected` looks like fixing a
    /// transcription (spelling, casing, joining) rather than rewording.
    ///
    /// - Parameter atSentenceStart: `corrected` opens a sentence, so its
    ///   first capital is sentence case: "Whether is nice" → "Weather is
    ///   nice" swaps two ordinary words, it doesn't name anything.
    static func isLikelyCorrection(
        heard: String, corrected: String, atSentenceStart: Bool = false, isKnownWord: (String) -> Bool
    ) -> Bool {
        guard heard != corrected,
              corrected.count <= 40,
              corrected.contains(where: \.isLetter) else { return false }
        let heardKey = VocabularyCorrection.key(heard)
        let correctedKey = VocabularyCorrection.key(corrected)
        guard correctedKey.count >= 2, !heardKey.isEmpty else { return false }

        if heardKey == correctedKey {
            // Same letters: a casing or joining fix. Capitalizing an ordinary
            // word ("hello" → "Hello") is sentence case, not a new term.
            if isSentenceCase(corrected), !corrected.contains(" "), isKnownWord(corrected.lowercased()) {
                return false
            }
            return true
        }

        // Swapping one ordinary word for another ("their" → "there") is a
        // grammar fix the dictionary can't help with.
        let correctedWords = corrected.split(separator: " ").map(String.init)
        if corrected == corrected.lowercased(), correctedWords.allSatisfy(isKnownWord) {
            return false
        }
        // The same at a sentence start, where the first capital is the
        // sentence's: "Their" → "There", "Whether" → "Weather".
        if atSentenceStart, isSentenceCase(corrected),
           correctedWords.allSatisfy({ isKnownWord($0.lowercased()) }) {
            return false
        }

        guard VocabularyCorrection.firstSound(heardKey) == VocabularyCorrection.firstSound(correctedKey) else {
            return false
        }
        let longest = max(heardKey.count, correctedKey.count)
        let distance = VocabularyCorrection.distance(heardKey, correctedKey, limit: longest)
        return Double(distance) / Double(longest) <= 0.4
    }

    /// Where `needle` sits in `haystack`, preferring the copy ending nearest
    /// the caret (the one just typed), else the last.
    static func locate(_ needle: [Character], in haystack: [Character], caretLocation: Int?) -> Range<Int>? {
        guard !needle.isEmpty, needle.count <= haystack.count else { return nil }
        var ranges: [Range<Int>] = []
        var start = 0
        while start + needle.count <= haystack.count {
            if haystack[start] == needle[0], Array(haystack[start..<(start + needle.count)]) == needle {
                ranges.append(start..<(start + needle.count))
                start += needle.count
            } else {
                start += 1
            }
        }
        guard let caretLocation else { return ranges.last }
        return ranges.min { abs($0.upperBound - caretLocation) < abs($1.upperBound - caretLocation) }
    }

    /// Whether `edited` is still the dictation, edited, rather than what
    /// replaced it after it was sent or deleted: half of a longer dictation's
    /// words are still there, or a short one is still spelled mostly the same
    /// ("Pria" → "Priya", not "hello there" → "ok").
    static func isStillDictation(_ edited: String, of dictated: String) -> Bool {
        let dictatedWords = plainWords(dictated)
        let editedWords = plainWords(edited)
        guard !editedWords.isEmpty else { return false }
        if dictatedWords.count >= 4 {
            var remaining: [String: Int] = [:]
            for word in editedWords { remaining[word, default: 0] += 1 }
            var kept = 0
            for word in dictatedWords where remaining[word, default: 0] > 0 {
                remaining[word, default: 0] -= 1
                kept += 1
            }
            return kept * 2 >= dictatedWords.count
        }
        let a = dictatedWords.joined(separator: " ")
        let b = editedWords.joined(separator: " ")
        let longest = max(a.count, b.count)
        return Double(VocabularyCorrection.distance(a, b, limit: longest)) <= Double(longest) * 0.5
    }

    /// Whether `text` reads as the language `isKnownWord` knows: at least half
    /// its words are in the list. Learning leans on that list to tell
    /// rewording from respelling, so text in another language — where every
    /// word looks unknown — is not learned from at all.
    static func readsAsKnownLanguage(_ text: String, isKnownWord: (String) -> Bool) -> Bool {
        let words = plainWords(text).filter { $0.contains(where: \.isLetter) }
        guard !words.isEmpty else { return false }
        return words.filter(isKnownWord).count * 2 >= words.count
    }

    /// Whether `text` is one ordinary word, so a replacement from it would
    /// rewrite ordinary speech.
    static func isOrdinaryWord(_ text: String, isKnownWord: (String) -> Bool) -> Bool {
        let words = plainWords(text)
        return words.count == 1 && isKnownWord(words[0])
    }

    /// Whether a fix names something: it has a capital ("Priya", "GitHub") or
    /// a word the list doesn't know ("kubectl"). A plain lowercase word is
    /// grammar, not spelling.
    static func namesATerm(_ corrected: String, isKnownWord: (String) -> Bool) -> Bool {
        if corrected.contains(where: \.isUppercase) { return true }
        let words = corrected.split(whereSeparator: { !$0.isLetter }).map { String($0).lowercased() }
        return words.contains { !isKnownWord($0) }
    }

    // MARK: - Words

    private static func words(in text: String) -> [String] {
        text.components(separatedBy: .whitespacesAndNewlines)
            .map(trimmedWord)
            .filter { !$0.isEmpty }
    }

    /// Lowercased runs of letters, digits and apostrophes.
    private static func plainWords(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'" || $0 == "’") })
            .map(String.init)
    }

    private static func trimmedWord(_ token: String) -> String {
        token.trimmingCharacters(in: CharacterSet.punctuationCharacters.subtracting(CharacterSet(charactersIn: "'’-_.")))
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    private static func opensSentence(after text: ArraySlice<Character>) -> Bool {
        guard let last = text.last(where: { !$0.isWhitespace || $0.isNewline }) else { return true }
        return last.isNewline || ".!?…".contains(last)
    }

    /// `words(in:)`, each marked with whether it opens a sentence: it comes
    /// first and `startsSentence`, or follows a line break or a token ending
    /// in `.` `!` `?` `…`.
    static func wordsMarkingSentenceStarts(
        in text: String, startsSentence: Bool
    ) -> [(word: String, startsSentence: Bool)] {
        var result: [(word: String, startsSentence: Bool)] = []
        var opens = startsSentence
        var token = ""
        func finish() {
            guard !token.isEmpty else { return }
            let word = trimmedWord(token)
            if !word.isEmpty { result.append((word, opens)) }
            let end = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'”’)]"))
            if let last = end.last {
                opens = ".!?…".contains(last)
            } else if !word.isEmpty {
                opens = false
            }
            token = ""
        }
        for character in text {
            if character.isWhitespace {
                finish()
                if character.isNewline { opens = true }
            } else {
                token.append(character)
            }
        }
        finish()
        return result
    }

    private struct Block {
        let old: [String]
        let new: [String]
        /// Where the block's words begin in `new`.
        let newStart: Int
    }

    /// Runs of words that were replaced, from a longest-common-subsequence
    /// alignment of the two word lists.
    private static func substitutions(from old: [String], to new: [String]) -> [Block] {
        var table = [[Int]](repeating: [Int](repeating: 0, count: new.count + 1), count: old.count + 1)
        for i in stride(from: old.count - 1, through: 0, by: -1) {
            for j in stride(from: new.count - 1, through: 0, by: -1) {
                if old[i] == new[j] {
                    table[i][j] = table[i + 1][j + 1] + 1
                } else {
                    table[i][j] = max(table[i + 1][j], table[i][j + 1])
                }
            }
        }

        var blocks: [Block] = []
        var pendingOld: [String] = []
        var pendingNew: [String] = []
        var i = 0
        var j = 0
        func flush() {
            if !pendingOld.isEmpty && !pendingNew.isEmpty {
                blocks.append(Block(old: pendingOld, new: pendingNew, newStart: j - pendingNew.count))
            }
            pendingOld = []
            pendingNew = []
        }
        while i < old.count || j < new.count {
            if i < old.count, j < new.count, old[i] == new[j] {
                flush()
                i += 1
                j += 1
            } else if j < new.count, i == old.count || table[i][j + 1] >= table[i + 1][j] {
                pendingNew.append(new[j])
                j += 1
            } else {
                pendingOld.append(old[i])
                i += 1
            }
        }
        flush()
        return blocks
    }

    private static func isSentenceCase(_ text: String) -> Bool {
        guard let first = text.first else { return false }
        return text == first.uppercased() + text.dropFirst().lowercased()
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "'" || character == "’"
    }
}
