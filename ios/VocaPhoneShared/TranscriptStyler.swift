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
        // Whisper and Parakeet Title-Case content words. Flatten those before
        // Clean/Formal/Casual so mid-sentence capitals are not left as-is.
        // Mixed-case names and ALL-CAPS acronyms stay.
        let flattened: String
        switch style {
        case .raw, .veryCasual:
            flattened = normalized
        default:
            flattened = flattenModelCaps(normalized)
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

    /// Drop Title Case the model invented, keep tokens that look like names.
    private static func flattenModelCaps(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        let characters = Array(text)
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
                result.append(contentsOf: characters[start..<index])
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
                result += softenToken(String(characters[start..<index]))
            } else {
                result.append(character)
                index += 1
            }
        }
        return result
    }

    private static func softenToken(_ token: String) -> String {
        if isPronounI(token) {
            let body = token.drop { !$0.isLetter }
            return String(token.dropLast(body.count)) + "I" + body.dropFirst()
        }
        let letters = token.filter(\.isLetter)
        if letters.isEmpty { return token }
        let hasLower = letters.contains { $0.isLowercase }
        let hasUpper = letters.contains { $0.isUppercase }
        if !hasLower && (2...4).contains(letters.count) { return token }
        if !hasLower && letters.count > 4 { return token.lowercased() }
        if hasLower && hasUpper {
            let body = token.drop { !$0.isLetter }
            guard let first = body.first else { return token }
            let titleCase = first.isUppercase && !body.dropFirst().contains(where: \.isUppercase)
            if !titleCase { return token }
        }
        return token.lowercased()
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
