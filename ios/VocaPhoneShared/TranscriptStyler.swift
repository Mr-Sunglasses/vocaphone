import Foundation

/// Local equivalent of the gateway's presentation-only transcript styles.
/// Words are never added, removed, or substituted; only case, spacing, and
/// sentence punctuation may change.
///
/// Dropping a filler or inserting a missing sentence break would both break
/// that contract, which is why they are ``TranscriptRepair``'s job and run
/// before this stage under a switch of their own.
enum TranscriptStyler {
    static func apply(
        _ text: String?,
        style: WritingStyle,
        language: String = "auto"
    ) -> String {
        let source = text ?? ""
        if style == .raw { return source.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }

        let punctuation = SentencePunctuation.resolve(language: language, text: source)
        let spans = ProtectedSpans.mask(source)
        let normalized = normalizeSentenceTerminators(
            normalizeSpacing(spans.text),
            punctuation: punctuation
        )
        // A model can Title-Case a whole sentence, and a chunk join capitalizes
        // the word it lands on. Flatten those before Clean/Formal/Casual, while
        // names, mixed-case words and ALL-CAPS acronyms stay.
        let flattened: String
        switch style {
        case .raw, .veryCasual:
            flattened = normalized
        default:
            flattened = flattenModelCaps(normalized, punctuation: punctuation)
        }
        let result: String
        switch style {
        case .raw:
            result = normalized
        case .clean:
            result = ensureTerminator(flattened, punctuation: punctuation)
        case .formal:
            result = ensureTerminator(
                capitalizeSentenceStarts(flattened, punctuation: punctuation),
                punctuation: punctuation
            )
        case .casual:
            result = casual(flattened, punctuation: punctuation)
        case .veryCasual:
            result = veryCasual(segments(normalized, punctuation: punctuation), punctuation: punctuation)
        case .excited:
            result = excited(segments(flattened, punctuation: punctuation), punctuation: punctuation)
        }
        let lowered = style == .veryCasual
            ? ProtectedSpans.mapOutsidePlaceholders(result) { $0.lowercased() }
            : result
        return spans.restore(lowered)
    }

    private static func normalizeSpacing(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(
                of: "\\s+([.!?。！？।۔،,;:])",
                with: "$1",
                options: .regularExpression
            )
    }

    /// A model often emits an ASCII full stop even when it correctly decoded
    /// Hindi text. Once the script is known, canonicalize sentence boundaries
    /// while leaving masked URLs, decimals, abbreviations, and ellipses intact.
    private static func normalizeSentenceTerminators(
        _ text: String,
        punctuation: SentencePunctuation
    ) -> String {
        guard punctuation.terminator == "।" else { return text }
        let characters = Array(text)
        var result = ""
        result.reserveCapacity(text.count)
        for index in characters.indices {
            let character = characters[index]
            guard character == "." else {
                result.append(character)
                continue
            }
            let previous = index > characters.startIndex ? characters[index - 1] : nil
            let nextIndex = index + 1
            let next = nextIndex < characters.endIndex ? characters[nextIndex] : nil
            let isEllipsis = previous == "." || next == "."
            let isSentenceBoundary = next == nil || next?.isWhitespace == true
            result.append(isSentenceBoundary && !isEllipsis ? "।" : character)
        }
        return result
    }

    private static func ensureTerminator(
        _ text: String,
        punctuation: SentencePunctuation
    ) -> String {
        guard !text.isEmpty, !punctuation.terminator.isEmpty else { return text }
        guard let last = text.last, !punctuation.terminators.contains(last) else { return text }
        return text + punctuation.terminator
    }

    private enum Shape { case lower, title, acronym, shout, mixed, pronounI }

    private struct Token {
        var text: String
        var isWord = false
        var shape = Shape.lower
        var sentence = 0
        var opensSentence = false
    }

    /// Closed-class words a chunk join or a Title-Casing model capitalizes and
    /// a name almost never is. "will", "may" and "a" are left out on purpose:
    /// "Will", "May" and "Plan A" are names as often as not.
    private static let functionWords: Set<String> = [
        "the", "an", "and", "or", "but", "so", "if", "then", "than", "because",
        "of", "to", "in", "on", "at", "by", "for", "with", "from", "as", "into",
        "about", "over", "after", "before",
        "is", "are", "was", "were", "be", "been", "am", "it's", "that's",
        "do", "does", "did", "have", "has", "had", "would", "could", "should", "can",
        "it", "its", "this", "that", "these", "those", "there", "here",
        "we", "you", "he", "she", "they", "me", "him", "her", "them",
        "my", "your", "his", "our", "their",
        "what", "when", "where", "why", "how", "who", "which",
        "not", "just", "also", "very", "yes", "no",
    ]

    /// Drop Title Case the model invented, keep tokens that look like names.
    ///
    /// Some models Title-Case a whole sentence ("The Keyboard Is Ready"). When
    /// a sentence shows that — nearly every word after the first capitalized —
    /// every Title-Case word in it is the model's and is flattened. Anywhere
    /// else a capital is far more likely a name someone said ("I met Sarah in
    /// Paris on Monday"), so the only thing flattened is a function word a
    /// chunk join capitalized ("hello there How are you"), and not even that
    /// next to another capitalized word, where it may be part of a name.
    /// Mixed-case names and short ALL-CAPS acronyms always stay; a longer
    /// ALL-CAPS word is the model shouting and is flattened.
    private static func flattenModelCaps(
        _ text: String,
        punctuation: SentencePunctuation
    ) -> String {
        let tokens = tokenize(text, punctuation: punctuation)
        let sentenceCount = (tokens.last?.sentence ?? 0) + 1
        var eligible = [Int](repeating: 0, count: sentenceCount)
        var titled = [Int](repeating: 0, count: sentenceCount)
        var titledFunctionWords = [Int](repeating: 0, count: sentenceCount)
        for token in tokens where token.isWord && !token.opensSentence {
            guard token.shape == .lower || token.shape == .title else { continue }
            eligible[token.sentence] += 1
            guard token.shape == .title else { continue }
            titled[token.sentence] += 1
            if functionWords.contains(functionKey(token.text)) {
                titledFunctionWords[token.sentence] += 1
            }
        }
        // Three in four is well clear of a sentence that is simply full of
        // names ("meet Sarah and John in Paris on Monday" is four in seven).
        // A sentence too short for a ratio is the model's only when every word
        // is capitalized and one of them is a function word: "Do It", not
        // "Call Sarah".
        let titleCased = (0..<sentenceCount).map { sentence in
            (eligible[sentence] >= 3 && titled[sentence] * 4 >= eligible[sentence] * 3)
                || (titled[sentence] == eligible[sentence] && titledFunctionWords[sentence] > 0)
        }

        var result = ""
        result.reserveCapacity(text.count)
        let words = tokens.filter(\.isWord)
        var wordPosition = -1
        for token in tokens {
            guard token.isWord else {
                result += token.text
                continue
            }
            wordPosition += 1
            switch token.shape {
            case .pronounI:
                let body = token.text.drop { !$0.isLetter }
                result += String(token.text.dropLast(body.count)) + "I" + body.dropFirst()
            case .shout:
                result += token.text.lowercased()
            case .lower, .acronym, .mixed:
                result += token.text
            case .title:
                let flatten: Bool
                if titleCased[token.sentence] {
                    flatten = true
                } else if token.opensSentence || !functionWords.contains(functionKey(token.text)) {
                    flatten = false
                } else {
                    let neighbours = [wordPosition - 1, wordPosition + 1]
                        .filter { words.indices.contains($0) }
                        .map { words[$0] }
                    flatten = !neighbours.contains { neighbour in
                        neighbour.sentence == token.sentence
                            && !neighbour.opensSentence
                            && [Shape.title, .acronym, .mixed].contains(neighbour.shape)
                    }
                }
                result += flatten ? token.text.lowercased() : token.text
            }
        }
        return result
    }

    private static func functionKey(_ token: String) -> String {
        token.lowercased().replacingOccurrences(of: "’", with: "'")
    }

    private static func tokenize(_ text: String, punctuation: SentencePunctuation) -> [Token] {
        var tokens: [Token] = []
        let characters = Array(text)
        var sentence = 0
        var opensSentence = true
        var index = 0
        while index < characters.count {
            // Copy a protected span whole: flatten would lowercase the digits
            // inside it, and restore could not match the placeholder afterwards.
            if characters[index] == ProtectedSpans.open {
                let start = index
                while index < characters.count, characters[index] != ProtectedSpans.close {
                    index += 1
                }
                if index < characters.count { index += 1 }
                tokens.append(Token(text: String(characters[start..<index]), sentence: sentence))
                opensSentence = false
                continue
            }
            let character = characters[index]
            if character.isLetter {
                let start = index
                index += 1
                while index < characters.count {
                    let next = characters[index]
                    if next.isLetter || next == "'" || next == "’" {
                        index += 1
                    } else {
                        break
                    }
                }
                let word = String(characters[start..<index])
                tokens.append(Token(
                    text: word,
                    isWord: true,
                    shape: shape(of: word),
                    sentence: sentence,
                    opensSentence: opensSentence
                ))
                opensSentence = false
            } else {
                tokens.append(Token(text: String(character), sentence: sentence))
                if punctuation.terminators.contains(character) {
                    sentence += 1
                    opensSentence = true
                }
                index += 1
            }
        }
        return tokens
    }

    private static func shape(of token: String) -> Shape {
        if isPronounI(token) { return .pronounI }
        let letters = token.filter(\.isLetter)
        guard let first = letters.first else { return .lower }
        let hasLower = letters.contains { $0.isLowercase }
        let hasUpper = letters.contains { $0.isUppercase }
        if !hasUpper { return .lower }
        if !hasLower && (2...4).contains(letters.count) { return .acronym }
        if !hasLower && letters.count > 4 { return .shout }
        let titleCase = first.isUppercase && !letters.dropFirst().contains(where: \.isUppercase)
        return titleCase ? .title : .mixed
    }

    private static func isPronounI(_ token: String) -> Bool {
        let letters = token.filter(\.isLetter)
        guard let first = letters.first, first == "I" || first == "i" else { return false }
        let rest = String(letters.dropFirst()).lowercased()
        if rest.isEmpty { return true }
        let contracted = token.contains("'") || token.contains("’")
        return contracted && ["m", "ll", "d", "ve", "re", "s"].contains(rest)
    }

    private static func capitalizeSentenceStarts(
        _ text: String,
        punctuation: SentencePunctuation
    ) -> String {
        var result = ""
        var shouldCapitalize = true
        for character in text {
            if shouldCapitalize, character.isLetter {
                result += String(character).uppercased()
                shouldCapitalize = false
            } else {
                result.append(character)
            }
            if punctuation.terminators.contains(character) { shouldCapitalize = true }
        }
        return result
    }

    private static func casual(_ text: String, punctuation: SentencePunctuation) -> String {
        let capitalized = capitalizeSentenceStarts(text, punctuation: punctuation)
        guard !punctuation.terminator.isEmpty, !capitalized.hasSuffix("..") else { return capitalized }
        return capitalized.hasSuffix(punctuation.terminator)
            ? String(capitalized.dropLast(punctuation.terminator.count))
            : capitalized
    }

    private static func segments(
        _ text: String,
        punctuation: SentencePunctuation
    ) -> [String] {
        guard !text.isEmpty else { return [] }
        let characters = Array(text)
        var result: [String] = []
        var start = 0
        var index = 0
        while index < characters.count {
            let character = characters[index]
            let ellipsis = character == "."
                && (index > 0 && characters[index - 1] == "."
                    || index + 1 < characters.count && characters[index + 1] == ".")
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            let boundary = punctuation.terminators.contains(character)
                && !ellipsis
                && (next == nil || next?.isWhitespace == true || punctuation.join.isEmpty)
            if boundary {
                result.append(String(characters[start...index]))
                start = index + 1
                while start < characters.count, characters[start].isWhitespace { start += 1 }
                index = start
            } else {
                index += 1
            }
        }
        if start < characters.count { result.append(String(characters[start...])) }
        return result.isEmpty ? [text] : result
    }

    private static func splitTerminator(
        _ sentence: String,
        punctuation: SentencePunctuation
    ) -> (body: String, terminator: String) {
        let body = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = body.last,
              punctuation.terminators.contains(last),
              !(last == "." && body.hasSuffix(".."))
        else { return (body, "") }
        return (String(body.dropLast()), String(last))
    }

    private static func veryCasual(
        _ sentences: [String],
        punctuation: SentencePunctuation
    ) -> String {
        var parts: [String] = []
        for (index, sentence) in sentences.enumerated() {
            let split = splitTerminator(sentence, punctuation: punctuation)
            guard !split.body.isEmpty else { continue }
            if index == sentences.index(before: sentences.endIndex) {
                parts.append(split.body)
            } else if split.terminator.isEmpty || split.terminator == punctuation.terminator {
                parts.append(split.body + punctuation.separator)
            } else {
                parts.append(split.body + split.terminator)
            }
        }
        return parts.joined(separator: punctuation.join)
    }

    private static func excited(
        _ sentences: [String],
        punctuation: SentencePunctuation
    ) -> String {
        sentences.compactMap { sentence in
            let split = splitTerminator(sentence, punctuation: punctuation)
            guard !split.body.isEmpty else { return nil }
            if split.terminator == punctuation.question {
                return capitalizeSentenceStarts(split.body, punctuation: punctuation) + split.terminator
            }
            return capitalizeSentenceStarts(split.body, punctuation: punctuation) + punctuation.exclamation
        }
        .joined(separator: punctuation.join)
    }
}
