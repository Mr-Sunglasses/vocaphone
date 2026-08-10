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

    private static let protectedPattern = "(?i)(https?://[^\\s]+[^\\s.,;:!?\\\"“”'\\)\\]]|[\\w.+-]+@(?:[\\w-]+\\.)+[A-Za-z]{2,}|(?:[\\w-]+\\.)+[A-Za-z]{2,}(?:/[^\\s.,;:!?\\\"“”'\\)\\]]*)?|\\d+(?:[.,:/]\\d+)+|\\d+(?:st|nd|rd|th)\\b|(?:[A-Za-z]\\.){2,}|\\w+['’]\\w+)"
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
        let normalized = normalizeSpacing(masked.text)
        let result: String
        switch style {
        case .raw:
            result = normalized
        case .clean:
            result = ensureTerminator(normalized, punctuation: punctuation)
        case .formal:
            result = ensureTerminator(
                capitalizeSentenceStarts(normalized, punctuation: punctuation),
                punctuation: punctuation
            )
        case .casual:
            result = casual(normalized, punctuation: punctuation)
        case .veryCasual:
            result = veryCasual(segments(normalized, punctuation: punctuation), punctuation: punctuation)
        case .excited:
            result = excited(segments(normalized, punctuation: punctuation), punctuation: punctuation)
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
            else if text.contains("।") { base = danda }
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

    private static func ensureTerminator(_ text: String, punctuation: Punctuation) -> String {
        guard !text.isEmpty, !punctuation.terminator.isEmpty else { return text }
        guard let last = text.last, !punctuation.terminators.contains(last) else { return text }
        return text + punctuation.terminator
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
