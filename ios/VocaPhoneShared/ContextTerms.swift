import Foundation

/// Names and identifiers in the text around the cursor: the words a speech
/// model is most likely to get wrong and the person is most likely to say.
/// Mirrored by `ContextTerms.kt` on Android, and ported from VocaMac's
/// `ScreenContextTerms`, which reads the focused field through Accessibility.
///
/// A phone keyboard already sees that text. The keyboard extracts the terms in
/// its own memory; only the terms, never the text, travel on to the app (see
/// `CursorContextTerms`), and they live for one dictation. They are used two
/// ways: as the least important recognition hints (`RecognitionHints.terms`),
/// and by `correct`, which respells a transcript word only when its letters
/// match a term exactly.
enum ContextTerms {

    /// As many as `RecognitionHints` will take from this source.
    static let maximumTerms = RecognitionHints.maximumContextTerms

    /// How much text either side of the cursor is read. A message or two:
    /// enough for the names in a conversation, little enough to read in one go.
    static let maximumCharactersEachSide = 1_000

    // MARK: - Extraction

    /// Not inside a longer run of letters, digits or underscores. Written out
    /// rather than `\b` so ICU and Java agree on every character.
    private static let start = #"(?<![\p{L}\p{N}_])"#
    private static let end = #"(?![\p{L}\p{N}_])"#

    private static let patterns: [NSRegularExpression] = [
        // camelCase and iOS-style names: userId, iPhone, macOS
        #"[a-z][a-z0-9]*[A-Z][A-Za-z0-9]*"#,
        // Capitals inside a word: GitHub, OpenAI, UserService
        #"[A-Z][a-z0-9]+[A-Z][A-Za-z0-9]*"#,
        // snake_case and SCREAMING_CASE
        #"[A-Za-z][A-Za-z0-9]*(?:_[A-Za-z0-9]+)+"#,
        // kebab-case
        #"[a-z][a-z0-9]*(?:-[a-z0-9]+)+"#,
    ].compactMap { try? NSRegularExpression(pattern: start + $0 + end) }

    /// Capitalized words; kept only when they do not start a sentence and are
    /// not ordinary words, which would make "Apple" out of "apple".
    private static let capitalizedWord = try? NSRegularExpression(pattern: start + #"[A-Z][a-z]{2,}"# + end)

    /// Words that start with two capitals: CUDA, ONNX, OAuth, URLSession.
    /// Not in VocaMac; added because acronyms are much of what people dictate
    /// at work. Kept only when they are not an ordinary word in capitals
    /// ("PLEASE"), wherever they stand in a sentence.
    private static let acronym = try? NSRegularExpression(
        pattern: start + #"[A-Z][A-Z0-9]+(?:[a-z][A-Za-z0-9]*)?"# + end
    )

    /// The terms in the text either side of the cursor, most relevant first,
    /// at most `maximumTerms`. Reads at most `maximumCharactersEachSide` of
    /// each, nearest the cursor.
    ///
    /// `isKnownWord` answers for a lowercased word: is it ordinary English?
    /// Pass `{ _ in true }` when no word list is loaded yet, which keeps only
    /// the identifier shapes and drops every capitalized word.
    static func extract(before: String?, after: String?, isKnownWord: (String) -> Bool) -> [String] {
        let before = String((before ?? "").suffix(maximumCharactersEachSide))
        let after = String((after ?? "").prefix(maximumCharactersEachSide))
        return extract(from: before + after, caret: (before as NSString).length, isKnownWord: isKnownWord)
    }

    /// The terms in `text`, ranked: shown more often first (up to three
    /// times; past that, more says little), then nearest `caret`, a UTF-16
    /// offset, then first shown. Without a caret, the middle of the text.
    static func extract(from text: String, caret: Int? = nil, isKnownWord: (String) -> Bool) -> [String] {
        guard !text.isEmpty else { return [] }
        let source = text as NSString
        let fullRange = NSRange(location: 0, length: source.length)

        var found: [(location: Int, term: String)] = []
        for regex in patterns {
            for match in regex.matches(in: text, range: fullRange) {
                found.append((match.range.location, source.substring(with: match.range)))
            }
        }
        if let acronym {
            for match in acronym.matches(in: text, range: fullRange) {
                let word = source.substring(with: match.range)
                if !isKnownWord(word.lowercased()) {
                    found.append((match.range.location, word))
                }
            }
        }
        if let capitalizedWord {
            for match in capitalizedWord.matches(in: text, range: fullRange)
            where !startsSentence(at: match.range.location, in: source) {
                let word = source.substring(with: match.range)
                if !isKnownWord(word.lowercased()) {
                    found.append((match.range.location, word))
                }
            }
        }

        let focus = caret ?? source.length / 2
        var ranked: [String: (count: Int, distance: Int, first: Int)] = [:]
        var counted = Set<String>()
        for item in found where VocabularyCorrection.key(item.term).count >= 3 {
            // Two patterns can match the same word; it was still shown once.
            guard counted.insert("\(item.location):\(item.term)").inserted else { continue }
            let distance = abs(item.location - focus)
            if let rank = ranked[item.term] {
                ranked[item.term] = (rank.count + 1, min(rank.distance, distance), min(rank.first, item.location))
            } else {
                ranked[item.term] = (1, distance, item.location)
            }
        }
        return ranked.sorted { lhs, rhs in
            let lhsCount = min(lhs.value.count, 3), rhsCount = min(rhs.value.count, 3)
            if lhsCount != rhsCount { return lhsCount > rhsCount }
            if lhs.value.distance != rhs.value.distance { return lhs.value.distance < rhs.value.distance }
            if lhs.value.first != rhs.value.first { return lhs.value.first < rhs.value.first }
            return lhs.key < rhs.key
        }.prefix(maximumTerms).map(\.key)
    }

    /// Whether the word at `location` opens a sentence or a line, where a
    /// capital letter says nothing about it being a name. The start of the
    /// text counts: what was read may begin mid-sentence.
    private static func startsSentence(at location: Int, in source: NSString) -> Bool {
        var index = location - 1
        while index >= 0 {
            let unit = source.character(at: index)
            if unit == 0x20 || unit == 0x09 {
                index -= 1
                continue
            }
            return sentenceOpeners.contains(unit)
        }
        return true
    }

    /// Newline, sentence ends, quotes and the marks that start a list item or
    /// a heading, as UTF-16 code units.
    private static let sentenceOpeners: Set<unichar> = Set(
        "\n\r.!?\"“#-*>".utf16
    )

    // MARK: - Correction

    /// A code identifier rather than a name: camelCase, or anything with an
    /// underscore, hyphen, dot or digit in it.
    static func isIdentifierShaped(_ term: String) -> Bool {
        guard let first = term.first else { return false }
        if first.isLowercase && term.contains(where: \.isUppercase) { return true }
        return term.contains { $0 == "_" || $0 == "-" || $0 == "." || $0.isNumber }
    }

    /// The longest run of transcript words one term is matched against.
    private static let maximumSpan = 4

    /// `text` with each run of words whose letters and digits are exactly a
    /// term's, ignoring case and spacing, written as the term is: "git hub"
    /// becomes "GitHub" when the field shows GitHub. Never a near miss: the
    /// field only says a word is on screen, not that the person said it.
    ///
    /// - The user's own `vocabulary` wins: a term with the same letters as one
    ///   of theirs is dropped, so their spelling, applied before this, stays.
    /// - A single ordinary word (`isDictionaryWord`, lowercased) is never
    ///   respelled, whatever the term: "email" stays "email" when the field
    ///   shows `e-mail`.
    /// - An identifier (`isIdentifierShaped`) only ever replaces one word, so
    ///   "set up" never becomes `setUp`.
    /// - Words overlapping `protectedRanges`, snippet triggers, are left alone.
    static func correct(
        _ text: String,
        terms: [String],
        vocabulary: [String] = [],
        isDictionaryWord: (String) -> Bool = { _ in false },
        protectedRanges: [Range<String.Index>] = []
    ) -> String {
        guard !text.isEmpty, !terms.isEmpty else { return text }
        let userKeys = Set(vocabulary.map(VocabularyCorrection.key))
        var exact: [String: (text: String, wordCount: Int, joiners: Set<Character>, identifier: Bool)] = [:]
        for term in terms {
            let key = VocabularyCorrection.key(term)
            guard key.count >= VocabularyCorrection.minimumTermLength,
                  !userKeys.contains(key), exact[key] == nil
            else { continue }
            exact[key] = (
                term,
                max(1, VocabularyCorrection.words(in: term).count),
                Set(term.filter { !$0.isLetter && !$0.isNumber }).union([" "]),
                isIdentifierShaped(term)
            )
        }
        guard !exact.isEmpty else { return text }
        let words = VocabularyCorrection.words(in: text)
        let protected = Set(words.indices.filter { index in
            protectedRanges.contains { $0.overlaps(words[index].range) }
        })

        var replacements: [(range: Range<String.Index>, term: String)] = []
        var index = 0
        while index < words.count {
            var matched = 0
            for length in stride(from: min(maximumSpan, words.count - index), through: 1, by: -1) {
                let span = words[index..<(index + length)]
                guard !(index..<(index + length)).contains(where: protected.contains),
                      let term = exact[span.map(\.key).joined()],
                      length <= term.wordCount + 1,
                      length == 1 || !term.identifier,
                      length > 1 || !isDictionaryWord(span.first!.key),
                      isContiguous(span, in: text, allowing: term.joiners)
                else { continue }
                let range = span.first!.range.lowerBound..<span.last!.range.upperBound
                if text[range] != term.text {
                    replacements.append((range, term.text))
                }
                matched = length
                break
            }
            index += max(matched, 1)
        }
        guard !replacements.isEmpty else { return text }
        var result = text
        for replacement in replacements.reversed() {
            result.replaceSubrange(replacement.range, with: replacement.term)
        }
        return result
    }

    /// Words joined only by `joiners`: "hub, and" must not be swallowed whole.
    private static func isContiguous(
        _ span: ArraySlice<VocabularyCorrection.Word>,
        in text: String,
        allowing joiners: Set<Character>
    ) -> Bool {
        var previous: VocabularyCorrection.Word?
        for word in span {
            if let previous {
                let gap = text[previous.range.upperBound..<word.range.lowerBound]
                guard !gap.isEmpty, gap.allSatisfy(joiners.contains) else { return false }
            }
            previous = word
        }
        return true
    }
}

/// The terms the keyboard found around the cursor, handed to the containing
/// app for one dictation.
///
/// The keyboard writes them beside the session record when it starts a
/// dictation (`SharedStore.saveCursorContextTerms`); the app takes them —
/// reads and deletes in one step — when it claims the session, and keeps
/// them in memory until that dictation is finished. Saving the record in a
/// state past transcription, deleting the session, or the orphan sweep removes
/// a file nobody took. Only the extracted terms are written, never the text
/// they came from.
struct CursorContextTerms: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let terms: [String]

    init(terms: [String]) {
        schemaVersion = Self.schemaVersion
        self.terms = Array(terms.prefix(ContextTerms.maximumTerms))
    }
}
