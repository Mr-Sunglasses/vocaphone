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
///   someone works there. English only: the dictionary that guards real words
///   is the English one, so in any other language every word one letter from a
///   term would be fair game — German "Wagen" would become a colleague called
///   "Wagner".
///
/// - **Sounds alike.** Double Metaphone (`DoubleMetaphone`) says when a heard
///   spelling sounds like a term, and then the slip may be wider: one more
///   edit, two more for a term of eight letters or more ("Postgersql" for
///   "PostgreSQL", "Kayzer" for "Kaiser"), and the first letter may differ
///   within one sound (c/k/q, s/z, f/ph). Only for a span with a word that is
///   not an ordinary word, and only words that are not, where the span has
///   more words than the term: sounding alike is no reason to respell real
///   ones.
/// - **Several words heard for one.** "cooper netties" for "Kubernetes", "pie
///   torch" for "PyTorch": two or three words whose letters sound exactly like
///   a term of six letters or more. Real words are never respelled on spelling
///   alone, so this needs evidence the engine misheard them: the engine
///   decoded one of the words with low confidence (`RecognitionConfidence`),
///   or, for an engine that reports no confidence, one of them is not an
///   ordinary word. Such an engine leaves a run of real words alone, and a
///   single real word is never respelled —
///   "cloud" stays "cloud" with Claude listed. VocaMac's rules.
///
/// Mirrors `VocabularyCorrection.kt`.
enum VocabularyCorrection {
    /// Shorter terms are too easily one letter from something else.
    static let minimumTermLength = 4

    /// How many transcript words one term may be matched against: its own
    /// word count plus one, because a recognizer splits an unfamiliar word in
    /// two ("voca phone") more often than it joins two into one.
    private static let extraWords = 1

    /// The longest run of transcript words ever compared with one term.
    private static let maximumSpan = 8

    /// How many near-miss comparisons one transcript may spend. Exact
    /// matches — spacing and case — are a lookup and never count against it.
    /// A realistic list of a few hundred names never comes close; a pasted
    /// list of thousands that share their first letters stops looking for
    /// one-letter slips before it can hold up the transcript.
    static let fuzzyComparisonBudget = 60_000

    /// `text` with every near-miss of a term in `terms` replaced by the term as
    /// the user wrote it. `isDictionaryWord` answers for one lowercased word;
    /// a single such word is only ever replaced by an exact match. Words that
    /// overlap `protectedRanges` — snippet triggers, which expand after this
    /// runs — are never touched. With `nearMisses` false only the spacing and
    /// case of a term are corrected, which is certain in any language.
    /// `lowConfidenceWords` are the keys the engine was unsure of
    /// (`RecognitionConfidence.lowConfidenceWords`), or nil when it reports
    /// nothing.
    ///
    /// Every term is used, however long the list. An exact match is a lookup;
    /// for a near miss, terms are filed by first sound and length, the two
    /// things every match already has to share, so each run of words is only
    /// compared with the terms that could match it.
    static func apply(
        _ text: String,
        terms: [String],
        isDictionaryWord: (String) -> Bool = { _ in false },
        protectedRanges: [Range<String.Index>] = [],
        nearMisses: Bool = true,
        lowConfidenceWords: Set<String>? = nil
    ) -> String {
        guard !text.isEmpty else { return text }
        var exact: [String: Term] = [:]
        var filed: [Character: [Int: [Term]]] = [:]
        var widest = 0
        for term in terms.compactMap(Term.init) {
            if exact[term.key] == nil { exact[term.key] = term }
            filed[term.sound, default: [:]][term.key.count, default: []].append(term)
            widest = max(widest, term.wordCount + extraWords)
        }
        guard !filed.isEmpty else { return text }
        var budget = nearMisses ? fuzzyComparisonBudget : 0
        let words = Self.words(in: text)
        guard !words.isEmpty else { return text }
        let protected = Set(words.indices.filter { index in
            protectedRanges.contains { $0.overlaps(words[index].range) }
        })
        var phonetic = PhoneticKeys()

        var replacements: [(range: Range<String.Index>, term: String)] = []
        var index = 0
        while index < words.count {
            var best: (length: Int, term: Term, distance: Int)?
            let longest = min(widest, maximumSpan, words.count - index)
            for length in stride(from: longest, through: 1, by: -1) {
                guard !(index..<(index + length)).contains(where: protected.contains) else { continue }
                let span = words[index..<(index + length)]
                let key = span.map(\.key).joined()
                if let term = exact[key], term.wordCount + extraWords >= length,
                   Self.isContiguous(span, in: text, allowing: term.joiners)
                {
                    if best == nil || best!.distance > 0 || length > best!.length {
                        best = (length, term, 0)
                    }
                    continue
                }
                guard budget > 0, !key.isEmpty else { continue }
                // An ordinary word on its own is only ever the term if it *is*
                // the term; anything else is a real word the user said.
                if length == 1, isDictionaryWord(key) { continue }
                let candidate = Candidate(
                    key: key,
                    wordCount: length,
                    unknownWords: span.filter { !isDictionaryWord($0.key) }.count
                )
                for sound in Self.soundsToSearch(key) {
                    guard let byLength = filed[sound] else { continue }
                    for termLength in max(1, key.count - maximumDistance)...(key.count + maximumDistance) {
                        for term in byLength[termLength] ?? []
                        where term.wordCount + extraWords >= length
                            && Self.isContiguous(span, in: text, allowing: term.joiners)
                        {
                            budget -= 1
                            guard let distance = term.accepts(candidate, phonetic: &phonetic) else { continue }
                            // A term already written correctly still wins here, so
                            // a longer near-miss cannot swallow it with the next word.
                            if best == nil || distance < best!.distance
                                || (distance == best!.distance && length > best!.length)
                            {
                                best = (length, term, distance)
                            }
                        }
                    }
                }
            }
            if best == nil, budget > 0, let joined = soundAlikeJoin(
                at: index,
                words: words,
                text: text,
                filed: filed,
                protected: protected,
                isDictionaryWord: isDictionaryWord,
                lowConfidenceWords: lowConfidenceWords,
                budget: &budget,
                phonetic: &phonetic
            ) {
                best = (length: joined.length, term: joined.term, distance: Int.max)
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

    /// The most edits any near miss is allowed: two for a long term, one more
    /// when it sounds alike.
    private static let maximumDistance = 3

    /// A sound-alike term must be at least this long, as in VocaMac: shorter
    /// keys share their Metaphone keys with too many words.
    private static let minimumSoundAlikeLength = 5

    /// The shortest term a run of words may be joined into by sound alone.
    private static let minimumJoinedTermLength = 6

    /// The most transcript words joined into one term by sound.
    private static let maximumJoinedWords = 3

    private struct Candidate {
        /// The span's words' keys, joined.
        let key: String
        let wordCount: Int
        /// How many of the span's words are not ordinary words.
        let unknownWords: Int

        /// Whether sounding like `term` may widen the match: a word in the
        /// span is not an ordinary word — every word, when the span has more
        /// words than the term, so the wider budget never takes a real word
        /// along with the name beside it. (Joining real words by sound is
        /// `soundAlikeJoin`'s, under its own rules.)
        func mayWiden(for term: Term) -> Bool {
            wordCount > term.wordCount ? unknownWords == wordCount : unknownWords > 0
        }
    }

    private struct Term {
        let text: String
        /// Letters and digits, lowercased: what spacing and case cannot change.
        let key: String
        /// `firstSound(key)`, the bucket the term is filed under.
        let sound: Character
        let wordCount: Int
        /// What may sit between the transcript words matched against this
        /// term: a space, and whatever punctuation the term itself uses inside
        /// it, so "o'brien" can become "O'Brien" without a term swallowing
        /// punctuation it never had.
        let joiners: Set<Character>

        init?(_ text: String) {
            let key = VocabularyCorrection.key(text)
            guard key.count >= VocabularyCorrection.minimumTermLength,
                  let sound = VocabularyCorrection.firstSound(key)
            else { return nil }
            self.text = text
            self.key = key
            self.sound = sound
            wordCount = max(1, VocabularyCorrection.words(in: text).count)
            joiners = Set(text.filter { !$0.isLetter && !$0.isNumber }).union([" "])
        }

        /// The edit distance at which `candidate` is taken to be this term, or
        /// `nil` when it is not. A single ordinary word never gets here.
        func accepts(_ candidate: Candidate, phonetic: inout PhoneticKeys) -> Int? {
            let heard = candidate.key
            if heard == key { return 0 }
            // One word against a one-word term needs the stricter bar: that is
            // where a real word sits one letter from a name.
            if candidate.wordCount == 1, wordCount == 1, key.count < 6 { return nil }
            let sameLetter = heard.first == key.first
            guard sameLetter || VocabularyCorrection.firstSound(heard) == sound else { return nil }
            var allowed = allowedDistance
            let alike = candidate.mayWiden(for: self) && key.count >= VocabularyCorrection.minimumSoundAlikeLength
                && abs(heard.count - key.count) <= VocabularyCorrection.maximumDistance
                && phonetic.soundAlike(heard, key)
            if alike {
                allowed = key.count >= 8 ? max(allowed + 1, 3) : allowed + 1
            }
            // A different first letter is only the same first sound when the
            // whole word sounds alike: "Kayzer" may be "Caesar", "cable" not.
            guard sameLetter || alike else { return nil }
            guard abs(heard.count - key.count) <= allowed else { return nil }
            let distance = VocabularyCorrection.distance(heard, key, limit: allowed)
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

    // MARK: - Sounding alike

    /// Double Metaphone keys, worked out once per dictation and spelling.
    private struct PhoneticKeys {
        private var keys: [String: DoubleMetaphone.Key?] = [:]

        mutating func key(_ text: String) -> DoubleMetaphone.Key? {
            if let known = keys[text] { return known }
            let key = DoubleMetaphone.encode(text)
            keys[text] = key
            return key
        }

        /// Whether two letter keys sound alike: their Double Metaphone keys
        /// meet, or, for what Metaphone cannot key, their Soundex codes agree.
        mutating func soundAlike(_ heard: String, _ term: String) -> Bool {
            if let heardKey = key(heard), let termKey = key(term) {
                return heardKey.matches(termKey)
            }
            guard let code = VocabularyCorrection.soundex(heard) else { return false }
            return code == VocabularyCorrection.soundex(term)
        }
    }

    /// Term lengths worth comparing with a joined run of `heardLength` letters:
    /// within a third of the term's length (at least two), closest first, then
    /// shorter. Spelled out step by step because the one-expression version
    /// is more than Xcode 26's type checker will finish.
    private static func joinCandidateLengths(heardLength: Int) -> [Int] {
        let upper = max(minimumJoinedTermLength, heardLength * 2)
        var lengths: [Int] = []
        for length in minimumJoinedTermLength...upper {
            let distance: Int = abs(length - heardLength)
            let allowed: Int = max(2, length / 3)
            if distance <= allowed { lengths.append(length) }
        }
        lengths.sort { (lhs: Int, rhs: Int) -> Bool in
            let lhsDistance: Int = abs(lhs - heardLength)
            let rhsDistance: Int = abs(rhs - heardLength)
            if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
            return lhs < rhs
        }
        return lengths
    }

    /// Two or three words heard for one longer term that sounds exactly like
    /// them: their joined letters and the term share a primary Metaphone key.
    /// Needs evidence the engine misheard: a word it decoded with low
    /// confidence, or, from an engine that reports no confidence, a word that
    /// is not an ordinary word. The term itself must not be an ordinary word,
    /// or "cooper" and "pans" could become "Copperpans".
    private static func soundAlikeJoin(
        at index: Int,
        words: [Word],
        text: String,
        filed: [Character: [Int: [Term]]],
        protected: Set<Int>,
        isDictionaryWord: (String) -> Bool,
        lowConfidenceWords: Set<String>?,
        budget: inout Int,
        phonetic: inout PhoneticKeys
    ) -> (length: Int, term: Term)? {
        let longest = min(maximumJoinedWords, words.count - index)
        guard longest >= 2 else { return nil }
        for length in stride(from: longest, through: 2, by: -1) {
            guard !(index..<(index + length)).contains(where: protected.contains) else { continue }
            let span = words[index..<(index + length)]
            guard isContiguous(span, in: text, allowing: [" ", "-"]) else { continue }
            let keys = span.map(\.key)
            // An engine that reports confidence has said which words it
            // doubted, and a word missing from a 10 000-word list is no
            // evidence beside that: "said Ruth" is not "Siddharth" because
            // "Ruth" is a name. Only an engine that says nothing is judged
            // by the list.
            let misheard = if let lowConfidenceWords {
                keys.contains(where: lowConfidenceWords.contains)
            } else {
                keys.contains { !isDictionaryWord($0) }
            }
            guard misheard else { continue }
            let joined = keys.joined()
            guard let heardKey = phonetic.key(joined), heardKey.primary.count >= 3 else { continue }
            // Closest length first, then the order the user wrote them in.
            let lengths = joinCandidateLengths(heardLength: joined.count)
            for sound in soundsToSearch(joined) {
                guard let byLength = filed[sound] else { continue }
                for termLength in lengths {
                    for term in byLength[termLength] ?? [] {
                        guard budget > 0 else { return nil }
                        budget -= 1
                        guard firstSound(joined) == term.sound,
                              phonetic.key(term.key)?.primary == heardKey.primary,
                              !isDictionaryWord(term.key)
                        else { continue }
                        return (length, term)
                    }
                }
            }
        }
        return nil
    }

    /// Rough first sound, so a near miss never swaps a word for a term that
    /// starts differently: c/k/q, s/z and ph/f are each one sound.
    static func firstSound(_ key: String) -> Character? {
        if key.hasPrefix("ph") { return "f" }
        guard let first = key.first else { return nil }
        switch first {
        case "c", "q": return "k"
        case "z": return "s"
        default: return first
        }
    }

    /// The buckets that hold every term a key could be matched with: its own
    /// first sound, and for a "p" word the "f" bucket too, where a "ph" term
    /// with the same first letter is filed.
    private static func soundsToSearch(_ key: String) -> [Character] {
        guard let sound = firstSound(key) else { return [] }
        guard key.first == "p" else { return [sound] }
        return sound == "f" ? ["f", "p"] : ["p", "f"]
    }

    /// American Soundex of a lowercase ASCII key, or nil for anything else.
    /// It only ever widens a match, never makes one.
    static func soundex(_ key: String) -> String? {
        guard let first = key.first, key.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        func code(_ character: Character) -> Character? {
            switch character {
            case "b", "f", "p", "v": "1"
            case "c", "g", "j", "k", "q", "s", "x", "z": "2"
            case "d", "t": "3"
            case "l": "4"
            case "m", "n": "5"
            case "r": "6"
            default: nil
            }
        }
        var result = String(first)
        var previous = code(first)
        for character in key.dropFirst() {
            let current = code(character)
            if let current, current != previous {
                result.append(current)
                if result.count == 4 { break }
            }
            // "h" and "w" do not separate equal codes; vowels do.
            if character != "h" && character != "w" { previous = current }
        }
        return result.padding(toLength: 4, withPad: "0", startingAt: 0)
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

    /// Words joined only by `joiners`. "phone, and" is two phrases, and a term
    /// must not swallow the comma between them.
    private static func isContiguous(
        _ span: ArraySlice<Word>,
        in text: String,
        allowing joiners: Set<Character>
    ) -> Bool {
        var previous: Word?
        for word in span {
            if let previous {
                let gap = text[previous.range.upperBound..<word.range.lowerBound]
                guard !gap.isEmpty, gap.allSatisfy(joiners.contains) else { return false }
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
