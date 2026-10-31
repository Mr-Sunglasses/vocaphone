import Foundation

/// A word or a mark in Writing check's split, with its UTF-16 range, so a
/// suggestion lands on the same characters on both platforms.
/// Mirrors android/.../writing/WritingText.kt.
struct WritingToken: Equatable, Sendable {
    let text: String
    let start: Int
    let end: Int
    let isWord: Bool
    /// Lowercase, apostrophes straight: what rules and tables compare.
    let key: String

    init(text: String, start: Int, end: Int, isWord: Bool) {
        self.text = text
        self.start = start
        self.end = end
        self.isWord = isWord
        key = WritingToken.normalize(text)
    }

    var hasLetter: Bool { isWord && text.unicodeScalars.contains(where: WritingText.isLetter) }

    static func normalize(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "’", with: "'")
    }
}

/// Token indices `first...last` and their UTF-16 range. `paragraph` counts
/// line breaks seen before the sentence.
struct WritingSentence: Equatable, Sendable {
    let first: Int
    let last: Int
    let start: Int
    let end: Int
    let paragraph: Int
}

enum WritingText {
    static func tokenize(_ text: String) -> [WritingToken] {
        var out: [WritingToken] = []
        let scalars = Array(text.unicodeScalars)
        // UTF-16 offset of each scalar, and one past the end.
        var offsets: [Int] = []
        offsets.reserveCapacity(scalars.count + 1)
        var at = 0
        for scalar in scalars {
            offsets.append(at)
            at += scalar.utf16.count
        }
        offsets.append(at)
        func slice(_ from: Int, _ to: Int) -> String {
            var s = String.UnicodeScalarView()
            s.append(contentsOf: scalars[from..<to])
            return String(s)
        }
        var i = 0
        while i < scalars.count {
            let scalar = scalars[i]
            if isSpace(scalar) {
                i += 1
            } else if isWordScalar(scalar) {
                let start = i
                i += 1
                while i < scalars.count {
                    if isWordScalar(scalars[i]) {
                        i += 1
                        continue
                    }
                    if isApostrophe(scalars[i]), i + 1 < scalars.count, isWordScalar(scalars[i + 1]) {
                        i += 1
                        continue
                    }
                    break
                }
                out.append(WritingToken(text: slice(start, i), start: offsets[start], end: offsets[i], isWord: true))
            } else {
                out.append(WritingToken(text: slice(i, i + 1), start: offsets[i], end: offsets[i + 1], isWord: false))
                i += 1
            }
        }
        return out
    }

    static func sentences(_ text: String, _ tokens: [WritingToken]) -> [WritingSentence] {
        let ns = text as NSString
        var out: [WritingSentence] = []
        var first = 0
        var paragraph = 0
        var i = 0
        while i < tokens.count {
            var last = i
            var boundary = false
            if terminals.contains(tokens[i].text) {
                while last + 1 < tokens.count, closers.contains(tokens[last + 1].text),
                      tokens[last + 1].start == tokens[last].end {
                    last += 1
                }
                boundary = last + 1 == tokens.count || tokens[last + 1].start > tokens[last].end
            }
            let gap = last + 1 < tokens.count
                ? ns.substring(with: NSRange(location: tokens[last].end, length: tokens[last + 1].start - tokens[last].end))
                : ""
            let lineBreak = gap.unicodeScalars.contains { lineBreaks.contains($0) }
            if boundary || lineBreak || last + 1 == tokens.count {
                out.append(WritingSentence(
                    first: first, last: last, start: tokens[first].start, end: tokens[last].end, paragraph: paragraph
                ))
                first = last + 1
                if lineBreak { paragraph += 1 }
            }
            i = last + 1
        }
        return out
    }

    /// Whether token `index` opens `sentence`, past any opening quotes or brackets.
    static func isSentenceStart(_ tokens: [WritingToken], _ sentence: WritingSentence, _ index: Int) -> Bool {
        var j = index - 1
        while j >= sentence.first, openers.contains(tokens[j].text) { j -= 1 }
        return j < sentence.first
    }

    /// Joins words with single spaces, attaching punctuation to the word before it.
    static func join(_ parts: [String]) -> String {
        var out = ""
        for (i, part) in parts.filter({ !$0.isEmpty }).enumerated() {
            if i > 0, !attached.contains(part) { out += " " }
            out += part
        }
        return out
    }

    static func isPunctuation(_ text: String) -> Bool {
        !text.isEmpty && !text.unicodeScalars.contains(where: isLetterOrDigit)
    }

    static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: true
        default: false
        }
    }

    static func isLetterOrDigit(_ scalar: Unicode.Scalar) -> Bool {
        isLetter(scalar) || scalar.properties.generalCategory == .decimalNumber
    }

    static func isUppercase(_ text: String) -> Bool {
        guard let first = text.unicodeScalars.first else { return false }
        return first.properties.isUppercase
    }

    static func isLowercase(_ text: String) -> Bool {
        guard let first = text.unicodeScalars.first else { return false }
        return first.properties.isLowercase
    }

    static func capitalizeFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber:
            true
        default:
            false
        }
    }

    private static func isApostrophe(_ scalar: Unicode.Scalar) -> Bool { scalar == "'" || scalar == "’" }

    /// Python's `str.isspace()` set, as in the grammar tagger, so both platforms split alike.
    private static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09...0x0D, 0x1C...0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
            true
        default:
            false
        }
    }

    private static let terminals: Set<String> = [".", "!", "?", "…"]
    private static let closers: Set<String> = ["\"", "'", "”", "’", ")", "]", "»"]
    private static let openers: Set<String> = ["\"", "“", "'", "‘", "(", "[", "«"]
    private static let lineBreaks: Set<Unicode.Scalar> = ["\n", "\r", "\u{2028}", "\u{2029}"]
    private static let attached: Set<String> = [",", ".", ";", ":", "!", "?"]
}
