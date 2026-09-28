import Foundation

/// Puts the user's own vocabulary back into a finished transcript, whatever
/// model produced it.
///
/// Only Whisper takes a prompt, so a list of names did nothing for Parakeet,
/// SenseVoice or any other sherpa model — the models the picker recommends
/// first. This runs after the model on every route and fixes the two mistakes
/// a recognizer makes with a word it was never taught:
///
/// - **Spacing and case.** "whisper kit", "Vocaphone", "voca phone" for
///   "WhisperKit" and "VocaPhone". The letters match exactly once spaces and
///   case are gone, so the replacement is certain.
/// - **One letter out.** "Kanish" for "Kanishk", "vocal phone" for
///   "VocaPhone". Deliberately narrow: within one edit for most terms and two
///   for long ones, the same first letter, and never an ordinary dictionary
///   word on its own — "strip" is a word, and must not become "Stripe" because
///   someone works there.
///
/// What it will not do is hear "Cooper Netties" as "Kubernetes". That takes a
/// model that was listening; this only has the text.
///
/// Mirrors `VocabularyCorrection.kt`.
enum VocabularyCorrection {
    /// Shorter terms are too easily one letter from something else.
    static let minimumTermLength = 4

    /// How many transcript words one term may be matched against: its own
    /// word count plus one, because a recognizer splits an unfamiliar word in
    /// two ("voca phone") more often than it joins two into one.
    private static let extraWords = 1

    /// `text` with every near-miss of a term in `terms` replaced by the term as
    /// the user wrote it. `isDictionaryWord` answers for one lowercased word;
    /// a single such word is only ever replaced by an exact match.
    static func apply(
        _ text: String,
        terms: [String],
        isDictionaryWord: (String) -> Bool = { _ in false }
    ) -> String {
        let candidates = terms.compactMap(Term.init).sorted { $0.key.count > $1.key.count }
        guard !candidates.isEmpty, !text.isEmpty else { return text }
        let words = Self.words(in: text)
        guard !words.isEmpty else { return text }

        var replacements: [(range: Range<String.Index>, term: String)] = []
        var index = 0
        while index < words.count {
            var best: (length: Int, term: Term, distance: Int)?
            for term in candidates {
                let longest = min(term.wordCount + extraWords, words.count - index)
                guard longest >= 1 else { continue }
                for length in stride(from: longest, through: 1, by: -1) {
                    let span = words[index..<(index + length)]
                    guard Self.isContiguous(span, in: text) else { continue }
                    let key = span.map(\.key).joined()
                    guard let distance = term.accepts(
                        key,
                        wordCount: length,
                        isDictionaryWord: length == 1 && isDictionaryWord(key)
                    ) else { continue }
                    // A term already written correctly still wins here, so a
                    // longer near-miss cannot swallow it with the next word.
                    if best == nil || distance < best!.distance
                        || (distance == best!.distance && length > best!.length)
                    {
                        best = (length, term, distance)
                    }
                }
            }
            if let best {
                let span = words[index..<(index + best.length)]
                let range = span.first!.range.lowerBound..<span.last!.range.upperBound
                if text[range] != best.term.text {
                    replacements.append((range, best.term.text))
                }
                index += best.length
            } else {
                index += 1
            }
        }
        guard !replacements.isEmpty else { return text }
        var result = text
        for replacement in replacements.reversed() {
            result.replaceSubrange(replacement.range, with: replacement.term)
        }
        return result
    }

    // MARK: - Terms

    private struct Term {
        let text: String
        /// Letters and digits, lowercased: what spacing and case cannot change.
        let key: String
        let wordCount: Int

        init?(_ text: String) {
            let key = VocabularyCorrection.key(text)
            guard key.count >= VocabularyCorrection.minimumTermLength else { return nil }
            self.text = text
            self.key = key
            wordCount = max(1, VocabularyCorrection.words(in: text).count)
        }

        /// The edit distance at which `candidate` is taken to be this term, or
        /// `nil` when it is not.
        func accepts(_ candidate: String, wordCount: Int, isDictionaryWord: Bool) -> Int? {
            if candidate == key { return 0 }
            // An ordinary word on its own is only ever the term if it *is* the
            // term; anything else is a real word the user said.
            guard !isDictionaryWord, candidate.first == key.first else { return nil }
            let allowed = allowedDistance
            guard allowed > 0, abs(candidate.count - key.count) <= allowed else { return nil }
            // One word against a one-word term needs the stricter bar: that is
            // where a real word sits one letter from a name.
            if wordCount == 1, self.wordCount == 1, key.count < 6 { return nil }
            let distance = VocabularyCorrection.distance(candidate, key, limit: allowed)
            return distance <= allowed ? distance : nil
        }

        private var allowedDistance: Int {
            switch key.count {
            case ..<6: 1
            case 6..<11: 1
            default: 2
            }
        }
    }

    // MARK: - Text

    struct Word {
        let range: Range<String.Index>
        let key: String
    }

    /// Runs of letters and digits. An apostrophe ends a word, so "Kanish's"
    /// is corrected to "Kanishk's" and the possessive stays where it was.
    static func words(in text: String) -> [Word] {
        var words: [Word] = []
        var start: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            let isWordCharacter = text[index].isLetter || text[index].isNumber
            if isWordCharacter, start == nil { start = index }
            if !isWordCharacter, let open = start {
                words.append(Word(range: open..<index, key: key(String(text[open..<index]))))
                start = nil
            }
            index = text.index(after: index)
        }
        if let open = start {
            words.append(Word(range: open..<text.endIndex, key: key(String(text[open...]))))
        }
        return words
    }

    /// Words joined by nothing but spaces. "phone, and" is two phrases, and a
    /// term must not swallow the comma between them.
    private static func isContiguous(_ span: ArraySlice<Word>, in text: String) -> Bool {
        var previous: Word?
        for word in span {
            if let previous {
                let gap = text[previous.range.upperBound..<word.range.lowerBound]
                guard !gap.isEmpty, gap.allSatisfy({ $0 == " " }) else { return false }
            }
            previous = word
        }
        return true
    }

    static func key(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// Levenshtein distance, giving up once it is past `limit`.
    static func distance(_ lhs: String, _ rhs: String, limit: Int) -> Int {
        let a = Array(lhs), b = Array(rhs)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            var rowMinimum = current[0]
            for j in 1...b.count {
                let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
                rowMinimum = min(rowMinimum, current[j])
            }
            if rowMinimum > limit { return limit + 1 }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}

/// The shipped English word list, as a set, for the one question vocabulary
/// correction asks of it: is this an ordinary word? Loaded on first use from
/// whichever bundle carries `en.txt` — the app and the keyboard both do.
enum EnglishWords {
    private static let words: Set<String> = {
        guard let url = Bundle.main.url(forResource: "en", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return [] }
        return Set(text.split(whereSeparator: \.isNewline).map { $0.lowercased() })
    }()

    static func contains(_ word: String) -> Bool {
        words.contains(word)
    }
}
