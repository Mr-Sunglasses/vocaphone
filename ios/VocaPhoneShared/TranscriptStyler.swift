import Foundation

/// Local equivalent of the gateway's presentation-only transcript styles.
/// Words are never added, removed, or substituted; only case, spacing, and
/// sentence punctuation may change.
enum TranscriptStyler {
    private struct Punctuation {
        let terminator: String
        let separator: String
        let exclamation: String
        let question: String
        let terminators: String
        let join: String
    }

    private struct Masked {
        let text: String
        let tokens: [String]
    }

    private static let universalTerminators = ".!?。！？।۔။။།؟"
    private static let latin = Punctuation(
        terminator: ".", separator: ",", exclamation: "!", question: "?",
        terminators: ".!?", join: " "
    )
    private static let cjk = Punctuation(
        terminator: "。", separator: "、", exclamation: "！", question: "？",
        terminators: "。！？.!?", join: ""
    )
    private static let arabic = Punctuation(
        terminator: ".", separator: "،", exclamation: "!", question: "؟",
        terminators: ".!?؟", join: " "
    )
    private static let urdu = Punctuation(
        terminator: "۔", separator: "،", exclamation: "!", question: "؟",
        terminators: "۔.!?؟", join: " "
    )
    private static let danda = Punctuation(
        terminator: "।", separator: ",", exclamation: "!", question: "?",
        terminators: "।.!?", join: " "
    )
    private static let indicLatin = Punctuation(
        terminator: ".", separator: ",", exclamation: "!", question: "?",
        terminators: "।.!?", join: " "
    )
    private static let unterminated = Punctuation(
        terminator: "", separator: " ", exclamation: "!", question: "?",
        terminators: "!?", join: " "
    )
    private static let burmese = Punctuation(
        terminator: "။", separator: "၊", exclamation: "!", question: "?",
        terminators: "။.!?", join: " "
    )
    private static let khmer = Punctuation(
        terminator: "។", separator: ",", exclamation: "!", question: "?",
        terminators: "។.!?", join: " "
    )
    private static let tibetan = Punctuation(
        terminator: "།", separator: "།", exclamation: "!", question: "?",
        terminators: "།.!?", join: " "
    )

    private static let protectedPattern = "(?i)(https?://[^\\s]+[^\\s.,;:!?\\\"“”'\\)\\]]|[\\w.+-]+@(?:[\\w-]+\\.)+[A-Za-z]{2,}|(?:[\\w-]+\\.)+[A-Za-z]{2,}(?:/[^\\s.,;:!?\\\"“”'\\)\\]]*)?|\\d+(?:[.,:/]\\d+)+|\\d+(?:st|nd|rd|th)\\b|(?:[A-Za-z]\\.){2,})"
    private static let placeholderPattern = "__VOCA_TOKEN_(\\d+)__"

    static func apply(
        _ text: String?,
        style: WritingStyle,
        language: String = "auto"
    ) -> String {
        let source = text ?? ""
        if style == .raw { return source.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }

        let punctuation = punctuation(for: language, text: source)
        let masked = mask(source)
        let normalized = normalizeSentenceTerminators(
            normalizeSpacing(masked.text),
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
        let lowered = style == .veryCasual ? lowerOutsidePlaceholders(result) : result
        return restore(lowered, tokens: masked.tokens)
    }

    private static func punctuation(for language: String, text: String) -> Punctuation {
        let code = language.lowercased().split(separator: "-").first.map(String.init) ?? ""
        let base: Punctuation
        switch code {
        case "ja", "zh": base = cjk
        case "ar", "fa", "ps": base = arabic
        case "ur", "sd", "ks": base = urdu
        case "hi", "mr", "ne", "bn", "as", "pa": base = danda
        case "ta", "te", "kn", "ml", "gu", "si": base = indicLatin
        case "th", "lo": base = unterminated
        case "my": base = burmese
        case "km": base = khmer
        case "bo": base = tibetan
        default:
            if text.contains(where: { "。、！？".contains($0) }) { base = cjk }
            else if text.contains(where: { "،؟".contains($0) }) { base = arabic }
            else if text.contains("۔") { base = urdu }
            else if text.contains("।") || containsDandaScript(text) { base = danda }
            else { base = latin }
        }
        var seen = Set<Character>()
        let merged = String((universalTerminators + base.terminators).filter { seen.insert($0).inserted })
        return Punctuation(
            terminator: base.terminator,
            separator: base.separator,
            exclamation: base.exclamation,
            question: base.question,
            terminators: merged,
            join: base.join
        )
    }

    /// Devanagari, Bengali/Assamese, and Gurmukhi conventionally use danda.
    /// This is the fallback when Automatic was selected and an engine did not
    /// expose the language it detected.
    private static func containsDandaScript(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x0900...0x097F, 0x0980...0x09FF, 0x0A00...0x0A7F:
                true
            default:
                false
            }
        }
    }

    private static func mask(_ text: String) -> Masked {
        let regex = try! NSRegularExpression(pattern: protectedPattern)
        let string = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: string.length))
        let tokens = matches.map { string.substring(with: $0.range) }
        let result = NSMutableString(string: text)
        for index in matches.indices.reversed() {
            result.replaceCharacters(
                in: matches[index].range,
                with: "__VOCA_TOKEN_\(index)__"
            )
        }
        return Masked(text: String(result), tokens: tokens)
    }

    /// Index of the last character of `__VOCA_TOKEN_<n>__` starting at `index`.
    private static func endOfPlaceholder(in characters: [Character], from index: Int) -> Int? {
        let prefix: [Character] = Array("__VOCA_TOKEN_")
        guard index + prefix.count + 3 <= characters.count else { return nil }
        for offset in prefix.indices where characters[index + offset] != prefix[offset] {
            return nil
        }
        var cursor = index + prefix.count
        var sawDigit = false
        while cursor < characters.count {
            let character = characters[cursor]
            guard character >= "0", character <= "9" else { break }
            sawDigit = true
            cursor += 1
        }
        guard sawDigit,
              cursor + 1 < characters.count,
              characters[cursor] == "_",
              characters[cursor + 1] == "_"
        else { return nil }
        return cursor + 1
    }

    private static func restore(_ text: String, tokens: [String]) -> String {
        let regex = try! NSRegularExpression(pattern: placeholderPattern)
        let original = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: original.length))
        let result = NSMutableString(string: text)
        for match in matches.reversed() {
            let index = Int(original.substring(with: match.range(at: 1))) ?? -1
            guard tokens.indices.contains(index) else { continue }
            result.replaceCharacters(in: match.range, with: tokens[index])
        }
        return String(result)
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
        punctuation: Punctuation
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

    private static func ensureTerminator(_ text: String, punctuation: Punctuation) -> String {
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
            // `__VOCA_TOKEN_N__` contains the letters TOKEN. Copy the marker
            // whole; flatten would lowercase it and restore could not match.
            if let end = endOfPlaceholder(in: characters, from: index) {
                result.append(contentsOf: characters[index...end])
                index = end + 1
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

    private static func capitalizeSentenceStarts(_ text: String, punctuation: Punctuation) -> String {
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

    private static func casual(_ text: String, punctuation: Punctuation) -> String {
        let capitalized = capitalizeSentenceStarts(text, punctuation: punctuation)
        guard !punctuation.terminator.isEmpty, !capitalized.hasSuffix("..") else { return capitalized }
        return capitalized.hasSuffix(punctuation.terminator)
            ? String(capitalized.dropLast(punctuation.terminator.count))
            : capitalized
    }

    private static func segments(_ text: String, punctuation: Punctuation) -> [String] {
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
        punctuation: Punctuation
    ) -> (body: String, terminator: String) {
        let body = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = body.last,
              punctuation.terminators.contains(last),
              !(last == "." && body.hasSuffix(".."))
        else { return (body, "") }
        return (String(body.dropLast()), String(last))
    }

    private static func veryCasual(_ sentences: [String], punctuation: Punctuation) -> String {
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

    private static func excited(_ sentences: [String], punctuation: Punctuation) -> String {
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

    private static func lowerOutsidePlaceholders(_ text: String) -> String {
        let regex = try! NSRegularExpression(pattern: placeholderPattern)
        let original = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: original.length))
        var result = ""
        var cursor = 0
        for match in matches {
            let before = NSRange(location: cursor, length: match.range.location - cursor)
            result += original.substring(with: before).lowercased()
            result += original.substring(with: match.range)
            cursor = match.range.location + match.range.length
        }
        result += original.substring(from: cursor).lowercased()
        return result
    }
}
