import UIKit

/// Curly quotes, em dashes and ellipses — and the field's right to refuse them.
///
/// `UITextInputTraits` exposes `smartQuotesType`, `smartDashesType` and
/// `smartInsertDeleteType` on the proxy, and fields set them deliberately: a
/// code editor turns smart quotes off precisely so that a keyboard does not curl
/// them into something that will not compile. Honouring the field is both the
/// native behaviour and the respectful one.
///
/// Pure, so every substitution can be checked against its preceding text without
/// a document.
enum SmartPunctuation {
    /// What a substitution does to the document: remove the characters already
    /// typed, then insert the replacement.
    struct Substitution: Equatable {
        let deletions: Int
        let insertion: String
    }

    /// What the field allows, resolved from its own traits.
    struct Traits: Equatable {
        var allowsQuotes = true
        var allowsDashes = true

        static let all = Traits()
        static let none = Traits(allowsQuotes: false, allowsDashes: false)

        @MainActor
        static func resolve(for proxy: UITextDocumentProxy, enabled: Bool) -> Traits {
            guard enabled else { return .none }
            // URL and email fields are typed into by machines as often as by
            // people, and a curled apostrophe in a query string is a broken link.
            switch proxy.keyboardType ?? .default {
            case .URL, .emailAddress, .webSearch, .asciiCapable:
                return .none
            default:
                break
            }
            return Traits(
                allowsQuotes: (proxy.smartQuotesType ?? .default) != .no,
                allowsDashes: (proxy.smartDashesType ?? .default) != .no
            )
        }
    }

    static let leftSingleQuote = "\u{2018}"
    static let rightSingleQuote = "\u{2019}"
    static let leftDoubleQuote = "\u{201C}"
    static let rightDoubleQuote = "\u{201D}"
    static let emDash = "\u{2014}"
    static let ellipsis = "\u{2026}"

    /// The substitution for one typed character, or `nil` to insert it as typed.
    static func substitution(
        for typed: String,
        before: String,
        traits: Traits
    ) -> Substitution? {
        // Anything that smells of a path, a handle, a URL or an identifier is
        // left exactly as typed. Getting this wrong turns working text into
        // text that looks right and no longer works.
        guard !looksLikeCode(before) else { return nil }

        switch typed {
        case "'":
            guard traits.allowsQuotes else { return nil }
            return Substitution(
                deletions: 0,
                insertion: opensQuote(after: before) ? leftSingleQuote : rightSingleQuote
            )
        case "\"":
            guard traits.allowsQuotes else { return nil }
            return Substitution(
                deletions: 0,
                insertion: opensQuote(after: before) ? leftDoubleQuote : rightDoubleQuote
            )
        case "-":
            guard traits.allowsDashes, before.hasSuffix("-"), !before.hasSuffix("--") else {
                return nil
            }
            return Substitution(deletions: 1, insertion: emDash)
        case ".":
            guard traits.allowsDashes, before.hasSuffix(".."), !before.hasSuffix("...") else {
                return nil
            }
            return Substitution(deletions: 2, insertion: ellipsis)
        default:
            return nil
        }
    }

    /// Whether a quote here opens or closes.
    ///
    /// Opening after nothing, after whitespace, or after an opening bracket;
    /// closing after a word or its punctuation — which is what makes "don't"
    /// come out with the right apostrophe without anyone thinking about it.
    static func opensQuote(after before: String) -> Bool {
        guard let last = before.last else { return true }
        if last.isWhitespace { return true }
        return "([{\u{201C}\u{2018}".contains(last)
    }

    /// Whether the token the cursor sits in looks like code rather than prose.
    static func looksLikeCode(_ before: String) -> Bool {
        let token = before.reversed().prefix { !$0.isWhitespace }
        guard !token.isEmpty else { return false }
        return token.contains { "/\\_@#$<>{}[]|~^=".contains($0) }
    }
}

/// Sentence capitalization that knows an abbreviation from a full stop.
///
/// `updateAutomaticShift` treats ". " as the end of a sentence. So does "e.g. ",
/// "Mr. ", "vs. " and "3. " at the start of a numbered list — and capitalizing
/// after each of them is a small annoyance that arrives several times a day.
enum SentenceBoundary {
    /// Abbreviations that end in a full stop without ending a sentence.
    static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st",
        "e.g", "i.e", "etc", "vs", "approx", "dept", "est",
        "fig", "no", "vol", "p", "pp", "al", "inc", "ltd", "co",
    ]

    /// Whether the text before the cursor genuinely ends a sentence.
    static func endsSentence(_ before: String) -> Bool {
        if before.isEmpty { return true }
        if before.hasSuffix("\n") { return true }
        guard before.hasSuffix(". ") || before.hasSuffix("! ") || before.hasSuffix("? ")
        else {
            return before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        // "!" and "?" are never abbreviations.
        guard before.hasSuffix(". ") else { return true }

        let beforeStop = before.dropLast(2)
        let token = String(beforeStop.reversed().prefix { !$0.isWhitespace }.reversed())
        guard !token.isEmpty else { return true }

        // A numbered or lettered list item: "3. " and "a. " start an item, not a
        // sentence — though the item itself is usually capitalized anyway, so
        // this only avoids forcing it.
        if token.allSatisfy({ $0.isNumber }) { return false }
        return !abbreviations.contains(token.lowercased())
    }
}
